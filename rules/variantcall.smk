import os

configfile: "config.yaml"
# user specified configs
bam_dir = config["seq_directory"]
genomefile = config["genome_file"]

# the samples config is generated by an external script that appends it to the config.yaml
samplenames = set([i.split('.bam')[0] for i in os.listdir(seq_dir) if i.endswith(".bam")])
#samplenames = [config["samples"][i]["name"] for i in config["samples"]]

#print("Samples detected: " + f"{len(samplenames)}")

#rule all:
#    input: "VariantCall/variants.raw.vcf"
#    message: "Variant Calling complete!"


rule merge_vcfs:
    input: expand("VariantCall/{sample}.vcf", sample = samplenames)
    output: "VariantCall/variants.raw.vcf"
    message: "Merging sample VCFs into single file: {output}"
    default_target: True
    threads: 20
    shell:
        """
        bcftools merge --threads -o {output} {input} 
        """

rule barcode_index:
    input: bam_dir + ""
    output: "VariantCall/{sample}.bci"
    message: "Indexing barcodes: {input}"
    threads: 1
    shell:
        """
        LRez index bam -p -b {input} -o {output}
        """

rule leviathan_variantcall:
    input:
        bam = bam_dir + "/{sample}" + ".bam",
        bai = bam_dir + "/{sample}" + ".bam.bai",
        bc_idx = "VariantCall/{sample}.bci",
        genome = genomefile
    output: "VariantCall/{sample}.vcf"
    message: "Calling variants: {wildcards.sample}"
    threads: 50
    shell:
        """
        LEVIATHAN -t {threads} -b {input.bam} -i {input.bc_idx} -g {input.genome} -o {output}      
        """