import os

configfile: "config.yaml"
# user specified configs
seq_dir = config["seq_directory"]
nbins = config["EMA_bins"]
genomefile = config["genome_file"]

# this identifies whether .fastq.gz or .fq.gz is used as the file extension
fastqlist = [i for i in os.listdir(seq_dir) if i.endswith('.fastq.gz')]
fqext = "fq.gz" if not fastqlist else "fastq.gz"

Rlist = [i for i in os.listdir(seq_dir) if i.endswith('.R1.' + fqext)]
Rsep = "_R" if not Rlist else ".R"

# the samples config is generated by an external script that appends it to the config.yaml
samplenames = set([i.split('.')[0] for i in os.listdir(seq_dir) if i.endswith(fqext)])
#samplenames = [config["samples"][i]["name"] for i in config["samples"]]

#print("Samples detected: " + f"{len(samplenames)}")

rule all:
	input: 
		alignments = expand("ReadMapping/align/{sample}.bam", sample = samplenames),
		stats = expand("ReadMapping/align/stats/{sample}.stats", sample = samplenames),
		flagstat = expand("ReadMapping/align/flagstat/{sample}.flagstat", sample = samplenames)
	message: "Read mapping completed! Generating alignment reports ReadMapping/alignment.stats.html and ReadMapping/alignment.flagstat.html."
#	shell:
#		"""
#		multiqc ReadMapping/align/stats --force --quiet --filename ReadMapping/alignment.stats.html
#		multiqc ReadMapping/align/flagstat --force --quiet --filename ReadMapping/alignment.flagstat.html
#		"""

rule index_genome:
	input: genomefile
	output: multiext(genomefile, ".ann", ".bwt", ".fai", ".pac", ".sa", ".amb")
	message: "Indexing {input}"
	shell: 
		"""
		bwa index {input}
		samtools faidx {input}
		"""

rule ema_count:
	input:
		forward_reads = seq_dir + "/{sample}" + Rsep + "1." + fqext,
		reverse_reads = seq_dir + "/{sample}" + Rsep + "2." + fqext
	output: 
		counts = "ReadMapping/count/{sample}.ema-ncnt"
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Counting barcode frequency: {wildcards.sample}"
	log: "ReadMapping/count/logs/{sample}.count.log"
	params:
		prefix = lambda wc: "ReadMapping/count/" + wc.get("sample")
	threads: 1
	shell:
		"""
		emaInterleave {input.forward_reads} {input.reverse_reads} | ema-h count -p -o {params} 2> {log}
		"""

#TODO 2> redirect isnt working like it should
rule ema_preprocess:
	input: 
		forward_reads = seq_dir + "/{sample}" + Rsep + "1." + fqext,
		reverse_reads = seq_dir + "/{sample}" + Rsep + "2." + fqext,
		emacounts = "ReadMapping/count/{sample}.ema-ncnt"
	output: 
		bins = temp(expand("ReadMapping/preproc/{{sample}}/ema-bin-{bin}", bin = range(1, nbins+1))),
		unbarcoded = temp("ReadMapping/preproc/{sample}/ema-nobc")
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	log: "ReadMapping/preproc/logs/{sample}.preproc.log"
	message: "Preprocessing for EMA mapping: {wildcards.sample}"
	threads: 2
	params:
		outdir = lambda wc: "ReadMapping/preproc/" + wc.get("sample"),
		bins = nbins
	shell:
		"""
		emaInterleave {input.forward_reads} {input.reverse_reads} | ema-h preproc -p -b -n {params.bins} -t {threads} -o {params.outdir} {input.emacounts} 2>&1 | cat - > {log}
		"""

rule ema_align:
	input:
		readbin = "ReadMapping/preproc/{sample}/ema-bin-{bin}",
		genome = genomefile,
		genome_idx = multiext(genomefile, ".ann", ".bwt", ".fai", ".pac", ".sa", ".amb")
	output: pipe("ReadMapping/align/{sample}/{sample}-{bin}.sam")
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Mapping on {input.genome}: {wildcards.sample}-{wildcards.bin}"
	threads: 2
	params:
		sampleID = lambda wc: wc.get("sample")
	shell:
		"""
		ema-h align -t {threads} -p haptag -d -i -r {input.genome} -R '@RG\tID:{params}\tSM:{params}' -s {input.readbin} 2> /dev/null
		"""

rule ema_sort:
	input: "ReadMapping/align/{sample}/{sample}-{bin}.sam"
	output: "ReadMapping/align/{sample}/{sample}-{bin}.bam"
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Sorting with Samtools: {wildcards.sample}-{wildcards.bin}"
	threads: 2
	shell: 
		"""
		samtools sort -@ {threads} -O bam -l 0 -m 4G -o {output} -
		"""

rule ema_align_nobarcode:
	input:
		reads = "ReadMapping/preproc/{sample}/ema-nobc",
		genome = genomefile,
		genome_idx = multiext(genomefile, ".ann", ".bwt", ".fai", ".pac", ".sa", ".amb")
	output: 
		samfile = pipe("ReadMapping/align/{sample}/{sample}.nobarcode.sam")
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Mapping unbarcoded reads onto {input.genome}: {wildcards.sample}"
	threads: 2
	params:
		sampleID = lambda wc: wc.get("sample")
	shell:
		"""
		bwa mem -p -t {threads} -M -R "@RG\tID:{params}\tSM:{params}" {input.genome} {input.reads}
		"""

rule sort_nobarcode:
	input: "ReadMapping/align/{sample}/{sample}.nobarcode.sam"
	output: temp("ReadMapping/align/{sample}/{sample}.nobarcode.bam.tmp")
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Sorting unbarcoded alignments: {wildcards.sample}"
	threads: 2
	shell:
		"""
		samtools sort -@ {threads} -O bam -l 0 -m 4G -o {output} -
		"""    

rule markduplicates:
	input: "ReadMapping/align/{sample}/{sample}.nobarcode.bam.tmp"
	output: "ReadMapping/align/{sample}/{sample}.nobarcode.bam"
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Marking duplicates in unbarcoded alignments: {wildcards.sample} "
	threads: 4
	shell:
		"""
		sambamba markdup -t {threads} -p -l 0 {input} {output}
		"""   

rule merge_alignments:
	input:
		aln_barcoded = expand("ReadMapping/align/{{sample}}/{{sample}}-{bin}.bam", bin = range(1, nbins + 1)),
		aln_nobarcode = "ReadMapping/align/{sample}/{sample}.nobarcode.bam"
	output: 
		bam = "ReadMapping/align/{sample}.bam",
		stats = "ReadMapping/align/stats/{sample}.stats",
		flagstat = "ReadMapping/align/flagstat/{sample}.flagstat"
	wildcard_constraints:
		sample = "[a-zA-Z0-9_-]*"
	message: "Merging all the alignments: {wildcards.sample}"
	threads: 10
	shell:
		"""
		sambamba merge -t {threads} -p {output.bam} {input}
		samtools stats {output.bam} > {output.stats}
		samtools flagstat {output.bam} > {output.flagstat}
		"""