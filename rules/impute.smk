import os
from snakemake.utils import Paramspace
import pandas as pd

# user specified configs
bam_dir = config["seq_directory"]
contigfile = config["contignames"]
samplenames = config["samplenames"]
variantfile = config["variantfile"]
# declare a dataframe to be a paramspace
paramspace = Paramspace(pd.read_csv(config["paramfile"], sep="\t"), param_sep = "", filename_params="*")

# determine number of contigs from the contig file
# deprecated in favor of contig names
#def contigparts(contig_file):
#    with open(contig_file, 'r') as fp:
#        for ncontigs, line in enumerate(fp):
#            pass
#    ncontigs += 1
#    return ncontigs
# ncontigs = contigparts(contigfile)

def contignames(contig_file):
    with open(contig_file) as f:
        lines = [line.rstrip() for line in f]
    return lines

contigs = contignames(contigfile)

# Pull out the basename of the variant file
if variantfile.lower().endswith(".vcf"):
    pass
elif variantfile.lower().endswith(".vcf.gz"):
    pass
elif variantfile.lower().endswith(".bcf"):
    pass
else:
    print("ERROR: Supplied variant call file (" + variantfile + ") must end in one of [.vcf | .vcf.gz | .bcf]")
    exit(1)

rule bam_list:
    input: expand(bam_dir + "/{sample}.bam", sample = samplenames)
    output: temp("Imputation/input/samples.list")
    message: "Creating list of alignment files"
    run:
        with open(output[0], "w") as fout:
            for bamfile in input:
                fout.write(bamfile + "\n")

rule split_contigs:
    input: contigfile
    output: expand("Imputation/input/contigs/{part}", part = contigs)
    message: "Splitting contig names for parallelization"
    shell:
        """
        awk '{{print > "Imputation/input/contigs/"$1}}' {input}
        #awk '{{print $1 > Imputation/input/contigs/$1;}}' {input}
        #awk '{{x="Imputation/contigs/contig."++i;}}{{print $1 > x;}}' {input}
        """

rule prepare_biallelic_snps:
    input: 
        vcf = variantfile,
        contig = "Imputation/input/contigs/{part}"
    output: pipe("Imputation/input/{part}.bisnp.bcf")
    message: "Keeping only biallelic SNPs from {wildcards.part}"
    threads: 1
    shell:
        """
        bcftools view -m2 -M2 -v snps --regions $(cat {input.contig}) --output-type b {input.vcf} > {output}
        """

rule STITCH_format:
    input: "Imputation/input/{part}.bisnp.bcf"
    output: "Imputation/input/{part}.stitch"
    message: "Converting biallelic data to STITCH format: {wildcards.part}"
    threads: 1
    params: 
        filters = "-i'QUAL>20 && DP>10'" if config["filtervcf"] else ""
    shell:
        """
        bcftools query {params} -f '%CHROM\\t%POS\\t%REF\\t%ALT\\n' {input} > {output}
        """

rule impute:
    input:
        bamlist = "Imputation/input/samples.list",
        infile = "Imputation/input/{part}.stitch",
        chromosome = "Imputation/input/contigs/{part}"
    output:
        # format a wildcard pattern like "k{k}/s{s}/ngen{ngen}"
        # into a file path, with k, s, ngen being the columns of the data frame
        f"Imputation/{paramspace.wildcard_pattern}/" + "{part}/impute.vcf.gz"
    log: f"Imputation/{paramspace.wildcard_pattern}/" + "{part}/stitch.log"
    params:
        # automatically translate the wildcard values into an instance of the param space
        # in the form of a dict (here: {"k": ..., "s": ..., "ngen": ...})
        parameters = paramspace.instance
    message: "Running STITCH: {wildcards.part}\n  Parameters:\n  " + "{params.parameters}"
    threads: 50
    script: "../utilities/stitch_impute.R"

rule index_vcf:
    input: "Imputation/{stitchparams}/{part}/impute.vcf.gz"
    output: "Imputation/{stitchparams}/{part}/impute.vcf.gz.tbi"
    message: "Indexing: {wildcards.stitchparams}/{wildcards.part}"
    threads: 1
    shell:
        """
        tabix {input}
        """

rule merge_vcfs:
    input: 
        vcf = expand("Imputation/{{stitchparams}}/{part}/impute.vcf.gz", part = contigs),
        idx = expand("Imputation/{{stitchparams}}/{part}/impute.vcf.gz.tbi", part = contigs)
    output: 
        bcf = "Imputation/{stitchparams}/variants.imputed.bcf",
        stats = "Imputation/{stitchparams}/variants.imputed.stats"
    log: 
        concats = "Imputation/{stitchparams}/concat.log"
    message: "Merging VCFs: {wildcards.stitchparams}"
    threads: 20
    shell:
        """
        bcftools concat --threads {threads} -o {output.bcf} --output-type b {input.vcf} 2> {log.concats}
        bcftools stats {output} > {output.stats}
        """

rule all:
    input: 
        bcf = expand("Imputation/{stitchparams}/variants.imputed.bcf", stitchparams=paramspace.instance_patterns),
        stats = expand("Imputation/{stitchparams}/{stitchparams}.stats", stitchparams=paramspace.instance_patterns)
    default_target: True    

