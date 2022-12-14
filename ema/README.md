EMA: An aligner for barcoded short-read sequencing data
=======================================================
![Build Status](https://github.com/arshajii/ema/actions/workflows/ci.yml/badge.svg) [![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://raw.githubusercontent.com/arshajii/ema/master/LICENSE) [![Mentioned in Awesome 10x Genomics](https://awesome.re/mentioned-badge.svg)](https://github.com/johandahlberg/awesome-10x-genomics)

EMA uses a latent variable model to align barcoded short-reads (such as those produced by [10x Genomics](https://www.10xgenomics.com)' sequencing platform). More information is available in [our paper](https://www.biorxiv.org/content/early/2017/11/16/220236). The full experimental setup is available [here](https://github.com/arshajii/ema-paper-data/blob/master/experiments.ipynb).

### Install
#### With `brew` 🍺

```bash
brew install brewsci/bio/ema
```

#### With `conda` 🐍

```bash
conda install -c bioconda ema
```

#### From source 🛠️

```bash
git clone --recursive https://github.com/arshajii/ema
cd ema
make
```

(The `--recursive` flag is needed because EMA uses BWA's C API.)

### Usage
```
usage: ema <count|preproc|align|help> [options]

count: perform preliminary barcode count (takes interleaved FASTQ via stdin)
  -w <whitelist path>: specify barcode whitelist [required]
  -o <output prefix>: specify output prefix [required]

preproc: preprocess barcoded FASTQ files (takes interleaved FASTQ via stdin)
  -w <whitelist path>: specify whitelist [required]
  -n <num buckets>: number of barcode buckets to make [500]
  -h: apply Hamming-2 correction [off]
  -o: <output directory> specify output directory [required]
  -b: output BX:Z-formatted FASTQs [off]
  -t <threads>: set number of threads [1]
  all other arguments: list of all output prefixes generated by count stage

align: choose best alignments based on barcodes
  -1 <FASTQ1 path>: first (preprocessed and sorted) FASTQ file [none]
  -2 <FASTQ2 path>: second (preprocessed and sorted) FASTQ file [none]
  -s <EMA-FASTQ path>: specify special FASTQ path [none]
  -x: multi-input mode; takes input files after flags and spawns a thread for each [off]
  -r <FASTA path>: indexed reference [required]
  -o <SAM file>: output SAM file [stdout]
  -R <RG string>: full read group string (e.g. '@RG\tID:foo\tSM:bar') [none]
  -d: apply fragment read density optimization [off]
  -p <platform>: sequencing platform (one of '10x', 'tru', 'cpt') [10x]
  -i <index>: index to follow 'BX' tag in SAM output [1]
  -t <threads>: set number of threads [1]
  all other arguments (only for -x): list of all preprocessed inputs

help: print this help message
```

### Input formats
EMA has several input modes:
- `-s <input>`: Input file is a single preprocessed "special" FASTQ generated by the preprocessing steps below.
- `-x`: Input files are listed after flags (as in `ema align -a -b -c <input 1> <input 2> ... <input N>`). Each of these inputs are processed and all results are written to the SAM file specified with `-o`.
- `-1 <first mate>`/`-2 <second mate>`: Input files are standard FASTQs. For interleaved FASTQs, `-2` can be omitted. The only restrictions in this input mode are that read identifiers must end in `:<barcode sequence>` and that the FASTQs must be sorted by barcode. For 10x data, the above two modes are preferred.

### Parallelism
Multithreading can be enabled with `-t <num threads>`. The actual threading mode is dependent on how the input is being read, however:
- `-s`, `-1`/`-2`: Multiple threads are spawned to work on the single input file (or pair of input files).
- `-x`: Threads work on the input files individually.

(Note that, because of this, it never makes sense to spawn more threads than there are input files when using `-x`.)

### End-to-end workflow (10x)
In this guide, we use the following additional tools:
- [pigz](https://github.com/madler/pigz)
- [sambamba](http://lomereiter.github.io/sambamba/)
- [samtools](https://github.com/samtools/samtools)
- [GNU Parallel](https://www.gnu.org/software/parallel/)

We also use a 10x barcode whitelist, which can be found [here](http://cb.csail.mit.edu/cb/ema/data/4M-with-alts-february-2016.txt).

#### Preprocessing
Preprocessing 10x data entails several steps, the first of which is counting barcodes (`-j` specifies the number of jobs to be spawned by `parallel`):

```bash
cd /path/to/gzipped_fastqs/
parallel -j40 --bar 'pigz -c -d {} | \
  ema count -w /path/to/whitelist.txt -o {/.} 2>{/.}.log' ::: *RA*.gz
```

Make sure that the FASTQs **are interleaved** and **only contain the actual reads**  in the files above (as opposed to sample indices, typically with `I1` in their filenames rather than `RA`). This will produce `*.ema-ncnt` and `*.ema-fcnt` files, containing the count data.

If you do not have interleaved files, you can interleave them as follows:

```bash
parallel -j40 --bar 'paste <(pigz -c -d {} | paste - - - -) <(pigz -c -d {= s:_R1_:_R2_: =} | paste - - - -) | tr "\t" "\n" |\
  ema count -w /path/to/whitelist.txt -o {/.} 2>{/.}.log' ::: *_R1_*.gz
```

where `s:_R1_:_R2_:` is the regex that casts first-end filenames into the second-end filenames (make sure to adjust this if your naming scheme is different).

Now we can do the actual preprocessing, which splits the input into barcode bins (500 by default; specified with `-n`). This preprocessing can be parallelized via `-t`, which specifies how many threads to use:

```bash
pigz -c -d *RA*.gz | ema preproc -w /path/to/whitelist.txt -n 500 -t 40 -o output_dir *.ema-ncnt 2>&1 | tee preproc.log
```

or if you do not have interleaved files:

```bash
paste <(pigz -c -d *_R1_*.gz | paste - - - -) <(pigz -c -d *_R2_*.gz | paste - - - -) | tr "\t" "\n" |\
  ema preproc -w /path/to/whitelist.txt -n 500 -t 40 -o output_dir *.ema-ncnt 2>&1 | tee preproc.log
```

#### Mapping
First we map each barcode bin with EMA. Here, we'll do this using a combination of GNU Parallel and EMA's internal multithreading, which we found to be optimal due to the runtime/memory trade-off. In the following, for instance, we use 10 jobs each with 4 threads (for 40 total threads). We also pipe EMA's SAM output (stdout by default) to `samtools sort`, which produces a sorted BAM:

```bash
parallel --bar -j10 "ema align -t 4 -d -r /path/to/ref.fa -s {} |\
  samtools sort -@ 4 -O bam -l 0 -m 4G -o {}.bam -" ::: output_dir/ema-bin-???
```

Lastly, we map the no-barcode bin with BWA:

```bash
bwa mem -p -t 40 -M -R "@RG\tID:rg1\tSM:sample1" /path/to/ref.fa output_dir/ema-nobc |\
  samtools sort -@ 4 -O bam -l 0 -m 4G -o output_dir/ema-nobc.bam
```

Note that `@RG\tID:rg1\tSM:sample1` is EMA's default read group. If you specify another for EMA, be sure to specify the same for BWA as well (both tools take the full read group string via `-R`).

#### Postprocessing
EMA performs duplicate marking automatically. We mark duplicates on BWA's output with `sambamba markdup`:

```bash
sambamba markdup -t 40 -p -l 0 output_dir/ema-nobc.bam output_dir/ema-nobc-dupsmarked.bam
rm output_dir/ema-nobc.bam
```

Now we merge all BAMs into a single BAM (might require modifying `ulimit`s, as in `ulimit -n 10000`):

```bash
sambamba merge -t 40 -p ema_final.bam output_dir/*.bam
```

Now you should have a single, sorted, duplicate-marked BAM `ema_final.bam`.

### Other sequencing platforms
Instructions for preprocessing and running EMA on data from other sequencing platforms can be found [here](https://github.com/arshajii/ema-paper-data/blob/master/experiments.ipynb).

### Output
EMA outputs a standard SAM file with several additional tags:

- `XG`: alignment probability
- `MI`: cloud identifier (compatible with Long Ranger)
- `XA`: alternate high-probability alignments
