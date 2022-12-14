import os
configfile: "samples.yaml"

# sanity check of the multiplexed sequences performed earlier in bash script
# this identifies whether .fastq.gz or .fq.gz was used
fastqlist = [i for i in os.listdir(config["seq_directory"]) if i.endswith('.fastq.gz')]
fqext = "fq.gz" if not fastqlist else "fastq.gz"

samplenames = [config["samples"][i]["name"] for i in config["samples"]]
libprefix   = [config["samples"][i]["source"] for i in config["samples"]]

rule all:
    input: 
        forward = expand("Samples/{sample}.F.fq.gz", sample = samplenames),
        reverse = expand("Samples/{sample}.R.fq.gz", sample = samplenames),
        rep = expand("Samples/QC/{sample}.html", sample = samplenames)
    message: "Demultiplexing completed!"

#rule assign_barcodes:
#    input: 
#        raw_seqs = rawseqs
#    output:
#    message: "Assigning barcodes to {input}"
#    shell:
#        """
#        tag_fastq_13plus13.0 {input} {output}       
#        """

rule demultiplex_read1:
    input: expand("SeqRaw/{library}" + ".R1." + fqext, library = libprefix)
    output: "Samples/{sample}.F.fq.gz"
    message: "Extracting sample {wildcards.sample} (read 1) from {params.library}"
    params:
        library = lambda wildcards: config["samples"][wildcards.sample]["source"],
        sample  = lambda wildcards: config["samples"][wildcards.sample]["name"],
        index   = lambda wildcards: config["samples"][wildcards.sample]["index"],
        seqdir = config["seq_directory"]
    shell:
        """
        zgrep -A 3 "{params.index}B" {params.seqdir}/{params.library}.R1.fq.gz | grep -v "^\-\-$" | bgzip > {output}
        """
        
rule demultiplex_read2:
    input: expand("SeqRaw/{library}" + ".R2." + fqext, library = libprefix)
    output: "Samples/{sample}.R.fq.gz"
    message: "Extracting sample {wildcards.sample} (read 2) from {params.library}"
    params:
        library = lambda wildcards: config["samples"][wildcards.sample]["source"],
        sample  = lambda wildcards: config["samples"][wildcards.sample]["name"],
        index   = lambda wildcards: config["samples"][wildcards.sample]["index"],
        seqdir = config["seq_directory"]
    shell:
        """
        zgrep -A 3 "{params.index}B" {params.seqdir}/{params.library}.R2.fq.gz | grep -v "^\-\-$" | bgzip > {output}
        """

rule fastqc:
    input: "Samples/{sample}.F.fq.gz"
    output: 
        html = temp("Samples/.QC/{sample}.F.html"),
        zip = temp("Samples/.QC/{sample}.F.zip")
    message: "Performing quality assessment on sample {wildcards.sample} (read 1)"
    threads: 2
    params:
        extra = ""
    wrapper: "master/bio/fastqc"

rule fastqc_read2:
    input: "Samples/{sample}.R.fq.gz"
    output: 
        html = temp("Samples/.QC/{sample}.R.html"),
        zip = temp("Samples/.QC/{sample}.R.zip")
    message: "Performing quality assessment on sample {wildcards.sample} (read 2)"
    threads: 2
    params:
        extra = ""
    wrapper: "master/bio/fastqc"

rule fastqc_report:
    input: 
        forward = "Samples/.QC/{sample}.F.html",
        reverse = "Samples/.QC/{sample}.R.html"
    output: "Samples/QC/{sample}.html"
    message: "Creating QC report for sample {wildcards.sample}"
    params:
        extra = "",
        use_input_files_only = True
    wrapper: "master/bio/multiqc"