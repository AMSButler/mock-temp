##################################################################################
## R processing script for ITS data of GLDS-200                                 ##
## https://genelab-data.ndc.nasa.gov/genelab/accession/GLDS-200/                ##
##                                                                              ##
## This code as written expects to be run within the processing_info/ directory ##
## Processed by Michael D. Lee (Mike.Lee@nasa.gov)                              ##
##################################################################################

# general procedure comes largely from these sources:
  # https://benjjneb.github.io/dada2/tutorial.html
  # https://astrobiomike.github.io/amplicon/dada2_workflow_ex

BiocManager::version() # 3.9

  # loading libraries
library(dada2); packageVersion("dada2") # 1.12.1
library(DECIPHER); packageVersion("DECIPHER") # 2.12.0
library(biomformat); packageVersion("biomformat") # 1.12.0

    ### general processing ###
  # reading in unique sample names into variable
sample.names <- scan("ITS-unique-sample-IDs.txt", what="character")

  # setting variables holding the paths to the cutadapt-trimmed forward and reverse reads
forward_trimmed_reads <- paste0("../Trimmed_Reads/", sample.names, "-R1-primer-trimmed.fastq.gz")
reverse_trimmed_reads <- paste0("../Trimmed_Reads/", sample.names, "-R2-primer-trimmed.fastq.gz")

  # setting variables holding what will be the output paths of all forward and reverse filtered reads
forward_filtered_reads <- paste0("../Filtered_Reads/", sample.names, "-R1-filtered.fastq.gz")
reverse_filtered_reads <- paste0("../Filtered_Reads/", sample.names, "-R2-filtered.fastq.gz")

  # adding sample names to the vectors holding the filtered-reads' paths
names(forward_filtered_reads) <- sample.names
names(reverse_filtered_reads) <- sample.names

  # running filering step
    # reads are written to the files specified in the variables, the "filtered_out" object holds the summary results within R
filtered_out <- filterAndTrim(fwd=forward_trimmed_reads, forward_filtered_reads, reverse_trimmed_reads, reverse_filtered_reads, maxN=0, maxEE=c(2,2), truncQ=2, rm.phix=TRUE, compress=TRUE, multithread=TRUE)

  # making and writing out summary table that includes counts of filtered reads
    # helper function
getN <- function(x) sum(getUniques(x))
filtered_count_summary_tab <- data.frame(sample=sample.names, cutadapt_trimmed=filtered_out[,1], dada2_filtered=filtered_out[,2])
        ## a large amount of sequences (like ~30-40%) are being dropped due to the maxEE=c(2,2) setting in the `filterAndTrim()` step just above. We still have a decent amount of seqs though, and not a lot are lost after this step, so i'm accepting it in order to retain stringency since this is a single-nucleotide approach
write.table(filtered_count_summary_tab, "../Filtered_Reads/ITS-filtered-read-counts.tsv", sep="\t", quote=F, row.names=F)

  # learning errors step
forward_errors <- learnErrors(forward_filtered_reads, multithread=TRUE)
reverse_errors <- learnErrors(reverse_filtered_reads, multithread=TRUE)

  # inferring sequences
forward_seqs <- dada(forward_filtered_reads, err=forward_errors, pool="pseudo", multithread=TRUE)
reverse_seqs <- dada(reverse_filtered_reads, err=reverse_errors, pool="pseudo", multithread=TRUE)

  # merging forward and reverse reads
merged_contigs <- mergePairs(forward_seqs, forward_filtered_reads, reverse_seqs, reverse_filtered_reads, verbose=TRUE)

  # generating a sequence table that holds the counts of each sequence per sample
seqtab <- makeSequenceTable(merged_contigs)

  # removing putative chimeras
seqtab.nochim <- removeBimeraDenovo(seqtab, method="consensus", multithread=TRUE, verbose=TRUE)

  # checking what percentage of sequences were retained after chimera removal
sum(seqtab.nochim)/sum(seqtab) * 100

  # making and writing out a summary table that includes read counts at all steps
    # reading in raw and trimmed read counts
raw_and_trimmed_read_counts <- read.table("../Trimmed_Reads/ITS-trimmed-read-counts.tsv", header=T, sep="\t")

    # reading in filtered read counts
filtered_read_counts <- read.table("../Filtered_Reads/ITS-filtered-read-counts.tsv", header=T, sep="\t")

count_summary_tab <- data.frame(raw_and_trimmed_read_counts, dada2_filtered=filtered_read_counts[,3],
                                dada2_denoised_F=sapply(forward_seqs, getN),
                                dada2_denoised_R=sapply(reverse_seqs, getN),
                                dada2_merged=rowSums(seqtab),
                                dada2_chimera_removed=rowSums(seqtab.nochim),
                                final_perc_reads_retained=round(rowSums(seqtab.nochim)/raw_and_trimmed_read_counts$raw_reads * 100, 1),
                                row.names=NULL)

write.table(count_summary_tab, "../Final_Outputs/ITS-read-count-tracking.tsv", sep = "\t", quote=F, row.names=F)

    ### assigning taxonomy ###
  # creating a DNAStringSet object from the ASVs
dna <- DNAStringSet(getSequences(seqtab.nochim))

  # downloading reference R taxonomy object (at some point this will be stored somewhere on GeneLab's server and we won't download it, but should leave the code here, just commented out)
download.file("http://www2.decipher.codes/Classification/TrainingSets/UNITE_v2020_February2020.RData", "UNITE_v2020_February2020.RData")
  # loading reference taxonomy object
load("UNITE_v2020_February2020.RData")
  # removing downloaded file
file.remove("UNITE_v2020_February2020.RData")

  # classifying
tax_info <- IdTaxa(dna, trainingSet, strand="both", processors=NULL)

    ### generating and writing out standard outputs ###
  # giving our sequences more manageable names (e.g. ASV_1, ASV_2..., rather than the sequence itself)
asv_seqs <- colnames(seqtab.nochim)
asv_headers <- vector(dim(seqtab.nochim)[2], mode="character")

for (i in 1:dim(seqtab.nochim)[2]) {
  asv_headers[i] <- paste(">ASV_ITS", i, sep="_")
}

  # making and writing out a fasta of our final ASV seqs:
asv_fasta <- c(rbind(asv_headers, asv_seqs))
write(asv_fasta, "../Final_Outputs/ITS-ASVs.fasta")

  # making and writing out a count table:
asv_tab <- t(seqtab.nochim)
asv_ids <- sub(">", "", asv_headers)
row.names(asv_tab) <- NULL
asv_tab <- data.frame("ASV_ID"=asv_ids, asv_tab, check.names=FALSE)

write.table(asv_tab, "../Final_Outputs/ITS-counts.tsv", sep="\t", quote=F, row.names=FALSE)

  # making and writing out a taxonomy table:
    # creating vector of desired ranks
ranks <- c("kingdom", "phylum", "class", "order", "family", "genus", "species")

  # creating table of taxonomy and setting any that are unclassified as "NA"
tax_tab <- t(sapply(tax_info, function(x) {
  m <- match(ranks, x$rank)
  taxa <- x$taxon[m]
  taxa[startsWith(taxa, "unclassified_")] <- NA
  taxa
}))

colnames(tax_tab) <- ranks
row.names(tax_tab) <- NULL
tax_tab <- data.frame("ASV_ID"=asv_ids, "domain"="Eukarya", tax_tab, check.names=FALSE)

write.table(tax_tab, "../Final_Outputs/ITS-taxonomy.tsv", sep = "\t", quote=F, row.names=FALSE)

    ### generating and writing out biom file format ###
biom_object <- make_biom(data=asv_tab, observation_metadata=tax_tab)
write_biom(biom_object, "../Final_Outputs/ITS-taxonomy-and-counts.biom")
