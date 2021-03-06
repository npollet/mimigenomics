#!/bin/bash
# Nicolas.Pollet@egce.cnrs-gif.fr
# This script automates the analysis of a set of long read sequences (nanopore) with the aim to
# identify mitochondrial variants.
# Usage: xenmito.sh -p=project_name -i=config_file_path 
# Config file example ( remove the leading characters # and first space ):
# FASTQPATH=starting_raw_seq_dir
# FQEXTENSION=fastq      
# DBPATH=/home/pollet/mimigenomics/db
# NUC_GENOME=xenmel/XENTRMEL_genome.mmi
# MITO_FASTA=XENMEL_mito.fasta
# MITO_BED=XENMEL_mito_pc.bed



################
#    Set up    #
################

# Activation of our conda environment with required executables
source activate minion_env

# Alternatively indicate the full path to executables
export MY_SAMTOOLS="samtools"
export MY_MINIMAP2="minimap2"
export MY_BEDTOOLS="bedtools"
export MY_BIOAWK="bioawk"
export MY_HTSBOX="htsbox"
export MY_MEDAKA="medaka_variant"
# I use vcf-annotate from vcftools, and it is distributed as a perl script from the git repository.
# This requires that Vcf.pm is declared on your system.
# You can include Vcf.pm to your system by adding the following command line to your .bashrc :
# export PERL5LIB=/opt/vcftools/src/perl
export MY_VCFTOOLS="vcf-annotate"

# Check versions of the dependencies
#samtools --version
#minimap2 --version
#bedtools --version
#bioawk
#seqtk
#htsbox
#medaka_variant


# Check the invocation
if [[ $# != 2 ]]; then
    echo "$0: Usage: xenmito.sh -p=project_name -i=config_file_path "
    exit 1
fi


for i in "$@"; do
    case $i in
        -p=*|--project=*)
        PROJECTNAME="${i#*=}"
        shift # past argument=value
        ;;
        -i=*|--config=*)
        CONFIG_FILE="${i#*=}"
        shift # past argument=value
        ;;
    esac
done


if [[ -f $CONFIG_FILE ]]; then
source $CONFIG_FILE
else
    echo " I can not find the config file"
    exit 1
fi

echo "PROJECT NAME          = ${PROJECTNAME}"

# Error checking for the presence of at least one sequence file
NUM_FASTQ_FILES=$(ls "${FASTQPATH}"/*."${FQEXTENSION}" | wc -l)
if [[ $NUM_FASTQ_FILES > 0 ]]; then
    echo "Number of fastq files = $NUM_FASTQ_FILES"
    else
    echo " I can not find fastq files in ${FASTQPATH}"
    exit 1
fi

echo "FASTQ PATH            = ${FASTQPATH}"
echo "FASTQ EXTENSION       = ${FQEXTENSION}"



############################
# Input and output folders #
############################
# Let us define the real path of folders for our project
# Input fastq sequences. Would be a plus to check that there is no redundancy and no problem with the fastq format.
export START_SEQ_DIR=$(realpath ${FASTQPATH})
echo "Input files are in the directory at $START_SEQ_DIR"


# Define the path to the reference nuclear genome minimap2 index
# Run this to build the index
# minimap2 -x map-ont -d nuclear_reference_genome.mmi nuclear_reference_genome.fasta
#HERE Edit the following line to specify the file name you want to use
export REF_NUC_GENOME=$(realpath ${DBPATH}/${NUC_GENOME})
if [[ -f $REF_NUC_GENOME ]]; then
    echo "I found the minimap2 index for the nuclear reference genome at " $REF_NUC_GENOME
    else
    echo "I did not found the minimap2 index for the nuclear reference genome at " $REF_NUC_GENOME
    exit 1
fi

# Define the path to the reference mitochondrial genome in fasta format to call variants
#HERE Edit the following line to specify the file name you want to use
export MY_MTDNA_REF=$(realpath ${DBPATH}/${MITO_FASTA})
if [[ -f $MY_MTDNA_REF ]]; then
    echo "I found the reference mitochondrial genome in fasta format at " $MY_MTDNA_REF
    else
    echo "I did not found the reference mitochondrial genome in fasta format at " $MY_MTDNA_REF
    exit 1
fi

# Define the path to the reference mitochondrial genome as a bed file
#HERE Edit the following line to specify the file name you want to use
export MY_MTDNA_REF_BED=$(realpath ${DBPATH}/${MITO_BED})
if [[ -f $MY_MTDNA_REF_BED ]]; then
    echo "I found the reference mitochondrial genome in bed format at " $MY_MTDNA_REF_BED
    else
    echo "I did not found the reference mitochondrial genome in bed format at " $MY_MTDNA_REF_BED
    exit 1
fi

# We get the reference mtDNA accession number from the fasta file
MTDNA_REF_ACC=$(grep '^>' $MY_MTDNA_REF | sed -e 's/^>//' -e 's/ .*//')

# We set up the result directory from the project name
if [[ -d ./$PROJECTNAME ]]; then
    # the directory exists
    export PROJECT_DIR=$(realpath -q ${PROJECTNAME})
    echo "Output will be in the project directory at $PROJECT_DIR"
    else
    # there is no such directory, so let's make it
    mkdir -p ./$PROJECTNAME
    export PROJECT_DIR=$(realpath -q ${PROJECTNAME})
    echo "Output will be in the project directory at $PROJECT_DIR"
fi

# We will store the results of our mappings against the genome in another directory
if [[ -d starting_raw_seq_mapping_dir ]]; then
    # the directory exists
    export MAPPING_DIR=${PROJECT_DIR}/starting_raw_seq_mapping_dir
    else
    # there is no such directory, so let's make it
    mkdir -p $PROJECT_DIR/starting_raw_seq_mapping_dir
    export MAPPING_DIR=${PROJECT_DIR}/starting_raw_seq_mapping_dir
fi

# We will store the results of our mappings to our mitochondrial reference in a separate directory
if [[ -d starting_raw_seq_mapping_ref_dir ]]; then
    export MAPPING_REF_DIR=${PROJECT_DIR}/starting_raw_seq_mapping_ref_dir
    else
    mkdir -p $PROJECT_DIR/starting_raw_seq_mapping_ref_dir
    export MAPPING_REF_DIR=${PROJECT_DIR}/starting_raw_seq_mapping_ref_dir
fi


############################################
# Fraction of mtDNA reads vs nuclear reads #
############################################

# A first analysis is to quantify the proportion of mitochondrial reads vs nuclear reads
# Step 1: Mapping against the reference nuclear genome

if ! (( $(grep -c "Step1 completed" ${PROJECT_DIR}/progress.log) )) ; then
    for seqfile in "${START_SEQ_DIR}"/*."${FQEXTENSION}"; do
    # Checking the fastq sequences for redundancy. In addition, if bioawk can format them then they are corectly formatted.
        bioawk -c fastx '!x[$0]++ {print "@"$name"\n"$seq"\n+\n"$qual}' $seqfile > tmp_seq_file.fastq
       N_SEQ_START=$(grep -c "^@" $seqfile)
       N_SEQ_END=$(grep -c "^@" tmp_seq_file.fastq)
       if [[ $N_SEQ_START != $N_SEQ_END ]]; then
           echo "Redundancy problem encountered with $seqfile"
       fi
       echo "Step 1 : Mapping $seqfile against $REF_NUC_GENOME..."
       # 1.1-extract the base name by removing fastq
       base=$(basename $seqfile ."${FQEXTENSION}")
       outmapfile=$(echo $base".aln.sam")
       # 1.2-run minimap2 using --secondary=no to suppress multiple mappings
       ${MY_MINIMAP2} --secondary=no -t 48 -a ${REF_NUC_GENOME} tmp_seq_file.fastq > ${MAPPING_DIR}/$outmapfile
       rm tmp_seq_file.fastq
    done
# Logging progress
echo "Step1 completed" >> ${PROJECT_DIR}/progress.log
fi

# Step 2: Counting the matches to mtDNA
if ! (( $(grep -c "Step2.6 completed" ${PROJECT_DIR}/progress.log) )) ; then
    for samfile in ${MAPPING_DIR}/barcode*.sam; do
        # 2.1 extract the base name by removing .sam
        base=$(basename $samfile .aln.sam)
        echo "Step 2 : Counting the matches to mtDNA for " $base

        # 2.2 use samtools view to count primary mappings to the mtDNA sequence
        mito_count=$(${MY_SAMTOOLS} view -c -L $MY_MTDNA_REF_BED $samfile)

        # 2.3 Recover mitochondrial DNA matching read's identifiers - Note the use of sort to make it unique
        ${MY_SAMTOOLS} view -L $MY_MTDNA_REF_BED $samfile | awk '{print $1}' | sort -u > ${MAPPING_DIR}/$base.matchmtDNA.ids

        # 2.4 use samtools view to count all primary mappings
        all_count=$(${MY_SAMTOOLS} view -c  $samfile)

        # 2.5 do the arithmetics to count non-mtDNA mappings
        let nuc_count="$all_count - $mito_count"

        # 2.6 output the counts to an output file
        printf "%-10s %7d %7d %7d\n" $base $all_count $nuc_count $mito_count > ${MAPPING_DIR}/$base.full.count
    done

    # Edit a header and collect counting results in a single file
    echo "name all_count nuc_count mito_count" > ${MAPPING_DIR}/mapping_stats.txt
    cat ${MAPPING_DIR}/*.full.count >> ${MAPPING_DIR}/mapping_stats.txt

    # Logging progress
    echo "Step2.6 completed" >> ${PROJECT_DIR}/progress.log
fi

#  2.7 prepare a sorted bam index to compute the coverage
if ! (( $(grep -c "Step2.7 completed" ${PROJECT_DIR}/progress.log) )) ; then

    for samfile in ${MAPPING_DIR}/barcode*.sam; do
        base=$(basename $samfile .aln.sam)
        bamfile=$(echo $base".sorted.bam")
        ${MY_SAMTOOLS} view -@ 24 -bS $samfile | ${MY_SAMTOOLS} sort -  -m 4G -@ 24 -o ${MAPPING_DIR}/$bamfile
        ${MY_SAMTOOLS} index -b -m 4G -@ 24 ${MAPPING_DIR}/$bamfile
        # 2.8 compute coverage
        pos_coverage_bedfile=$(echo $base"_coverage_pos.bed")
        neg_coverage_bedfile=$(echo $base"_coverage_neg.bed")
        #unstranded
        coverage_bedfile=$(echo $base"_coverage.bed")
        bedtools coverage -a $MY_MTDNA_REF_BED -b ${MAPPING_DIR}/$bamfile -bed -d -s > ${MAPPING_DIR}/$pos_coverage_bedfile
        bedtools coverage -a $MY_MTDNA_REF_BED -b ${MAPPING_DIR}/$bamfile -bed -d -S > ${MAPPING_DIR}/$neg_coverage_bedfile
        bedtools coverage -a $MY_MTDNA_REF_BED -b ${MAPPING_DIR}/$bamfile -bed -d > ${MAPPING_DIR}/$coverage_bedfile
    done
    # Clean up the sam files
    rm ${MAPPING_DIR}/*.sam

    # Logging progress
    echo "Step2.7 completed" >> ${PROJECT_DIR}/progress.log
fi

# rm ${MAPPING_DIR}/*.full.count

# Step 3: Compiling reads sizes, qualities and origin for statistics

# We will store these statistics in a separate directory
if [[ -d starting_raw_seq_stats_dir ]]; then
    export READS_STATS_DIR=${PROJECT_DIR}/starting_raw_seq_stats_dir
    else
    mkdir -p $PROJECT_DIR/starting_raw_seq_stats_dir
    export READS_STATS_DIR=${PROJECT_DIR}/starting_raw_seq_stats_dir
fi

# Collecting all required informations
# We will store mtDNA read files in a separate directory
if [[ -d starting_raw_seq_mtDNA_dir ]]; then
export READS_MTDNA_DIR=${PROJECT_DIR}/starting_raw_seq_mtDNA_dir
else
mkdir -p $PROJECT_DIR/starting_raw_seq_mtDNA_dir
export READS_MTDNA_DIR=${PROJECT_DIR}/starting_raw_seq_mtDNA_dir
fi

if ! (( $(grep -c "Step3.3 completed" ${PROJECT_DIR}/progress.log) )) ; then

    for seqfile in ${START_SEQ_DIR}/*."${FQEXTENSION}"; do
        # 3.1 extract the base name by removing .fastq
        base=$(basename $seqfile ."${FQEXTENSION}")
        echo "Step 3: " $base
        outstatfile=$(echo $base".seqlenqual.txt")
        # 3.2 extract read name, size, mean quality, add mapping information : mtDNA or nuclear and barcode of origin
        mtDNA_id_infile=$(echo ${MAPPING_DIR}/$base.matchmtDNA.ids)
        bioawk -v match_file="$mtDNA_id_infile" -c fastx 'BEGIN {while ((getline k <match_file)>0)i[k]=1} {if(i[$name]) print $name,"   ",length($seq)," ",meanqual($qual)," mtDNA"; else print $name," ",length($seq)," ",meanqual($qual)," nucDNA"}' $seqfile | sed - e "s/$/ $base/" > ${READS_STATS_DIR}/$outstatfile
        # 3.3 extract mtDNA readname and read sequence
        outmtreadfile=$(echo $base".mtDNA.fastq")
        seqtk subseq $seqfile $mtDNA_id_infile > $READS_MTDNA_DIR/$outmtreadfile
    done

# Logging progress
echo "Step3.3 completed" >> ${PROJECT_DIR}/progress.log
fi

# Step 4: Long mtDNA reads dir
# Preparation of the directory
# We will store the results of Long mtDNA reads in another directory named starting_raw_seq_long_mtDNA_reads_dir
if [[ -d starting_raw_seq_long_mtDNA_reads_dir ]]; then
    # the directory exists
    export LONG_MTDNA_READS_DIR=${PROJECT_DIR}/starting_raw_seq_long_mtDNA_reads_dir
else
    # there is no such directory, so let's make it
mkdir -p ${PROJECT_DIR}/starting_raw_seq_long_mtDNA_reads_dir
export LONG_MTDNA_READS_DIR=${PROJECT_DIR}/starting_raw_seq_long_mtDNA_reads_dir
fi

# Identification of the long mtDNA reads using a filtering step on the alignments with htsbox

if ! (( $(grep -c "Step4 completed" ${PROJECT_DIR}/progress.log) )) ; then


    # We use a criteria of half of the mtDNA genome
    MTDNA_LENGTH=$(bioawk -c fastx '{print length($seq)}' $MY_MTDNA_REF)
    let SIZE_CUTOFF="$MTDNA_LENGTH/2"

    for bamfile in ${MAPPING_DIR}/*.sorted.bam; do
        base=$(basename $bamfile .sorted.bam)

        # We use a awk command to select long mtDNA reads
        ${MY_HTSBOX} samview -p $bamfile | awk -v cutoff=$SIZE_CUTOFF -v mt_ref_acc=$MTDNA_REF_ACC '(($6 ~ mt_ref_acc ) && ($10 > cutoff))  {print $1,$2,$10,$10/$11}' > ${LONG_MTDNA_READS_DIR}/$base.long_mtDNA_reads.info
        nb=$(wc -l ${LONG_MTDNA_READS_DIR}/$base.long_mtDNA_reads.info|awk '{print $1}')
        echo "Found $nb long mtDNA reads in $base"
    done

    for long_mtDNA_read_ids_file in ${LONG_MTDNA_READS_DIR}/*.long_mtDNA_reads.info; do
        base=$(basename $long_mtDNA_read_ids_file .long_mtDNA_reads.info)
        echo "Step 4: " $base

        awk '{print $1}' $long_mtDNA_read_ids_file > ${LONG_MTDNA_READS_DIR}/$base.long_mtDNA_reads.ids
        long_mtDNA_id_infile=$(echo "${LONG_MTDNA_READS_DIR}/$base.long_mtDNA_reads.ids")
        bioawk -v match_file=$long_mtDNA_id_infile -v match_length=$MTDNA_LENGTH -c fastx 'BEGIN {while ((getline k <match_file)>0)i[k]=1}  {if((i[$name])&&(length($seq)<=match_length)) print ">"$name,length($seq),"\n"$seq;}' ${START_SEQ_DIR}/$base.fastq > $  {LONG_MTDNA_READS_DIR}/$base.small.long_mtDNA_reads.fasta
        count_small_long_mtDNA_reads=$(grep -c '>' ${LONG_MTDNA_READS_DIR}/$base.small.long_mtDNA_reads.fasta)
        bioawk -v match_file=$long_mtDNA_id_infile -v match_length=$MTDNA_LENGTH -c fastx 'BEGIN {while ((getline k <match_file)>0)i[k]=1}  {if((i[$name])&&(length($seq)>=match_length)) print ">"$name,length($seq),"\n"$seq;}' ${START_SEQ_DIR}/$base.fastq > $  {LONG_MTDNA_READS_DIR}/$base.very.long_mtDNA_reads.fasta
        count_very_long_mtDNA_reads=`grep -c '>' ${LONG_MTDNA_READS_DIR}/$base.very.long_mtDNA_reads.fasta`
    done

    # Logging progress
    echo "Step4 completed" >> ${PROJECT_DIR}/progress.log
fi

# Comparison of mtDNA to long mtDNA reads
# the final aim will be to plot long mtDNA read size vs alignment length
# if long read size is superior to mtDNA size we do a glsearch of mtDNA vs long read


# Step 5: Mapping to the chosen reference mitochondrial genome for variant calling
# Define the location of medaka output files
mkdir -p ${MAPPING_REF_DIR}/medaka_dir
export MEDAKA_FOLDERS_DIR=${MAPPING_REF_DIR}/medaka_dir

if ! (( $(grep -c "Step5.5 completed" ${PROJECT_DIR}/progress.log) )) ; then

    cd ${START_SEQ_DIR};
    for seqfile in $READS_MTDNA_DIR/*.mtDNA.fastq; do
        # 5.1 extract the base name
        base=$(basename $seqfile .mtDNA.fastq)
        echo "Step 5: Mapping to mitochondrial reference alone " $base
        outmapfile=$(echo $base".mtDNA.aln.sam")
        bamfile=$(echo $base".mtDNA.sorted.bam")
        medaka_out=$(echo $base".medaka_variant")
        # 5.2 run minimap2 using --secondary=no to suppress multiple mappings
        ${MY_MINIMAP2} --secondary=no -t 48 -ax map-ont $MY_MTDNA_REF $seqfile > ${MAPPING_REF_DIR}/$outmapfile

        # 5.3 Convert to sorted bam files and indexing
        ${MY_SAMTOOLS} sort ${MAPPING_REF_DIR}/$outmapfile -o ${MAPPING_REF_DIR}/$bamfile -T reads.tmp
        ${MY_SAMTOOLS} index ${MAPPING_REF_DIR}/$bamfile

        # 5.4 Deleting the intermediary sam output file
        rm ${MAPPING_REF_DIR}/$outmapfile

        # 5.5 Running medaka_variant to call phased variants (SNPs, indels); without keeping intermediary files
        ${MY_MEDAKA} -f $MY_MTDNA_REF -i ${MAPPING_REF_DIR}/$bamfile -o ${MEDAKA_FOLDERS_DIR}/$medaka_out -d -t 12
    done
    # Logging progress
    echo "Step5.5 completed" >> ${PROJECT_DIR}/progress.log
fi

# 5.6 Edit Sample information and rename individual vcf files
# Create a directory for output files
mkdir -p ${MEDAKA_FOLDERS_DIR}/final_vcf_dir

for medaka_folders in ${MEDAKA_FOLDERS_DIR}/*.medaka_variant; do
    #renaming Sample information based on barcode id (possibility for customization here) and filtering using default filters from vcftools, e.g. QUAL values less than 10 are removed.
    medaka_base=$(basename $medaka_folders)

#HERE
sample_id=`echo $medaka_base|sed -e s'/.medaka_variant_/XENMITO_/' -e 's/barcode/BARCODE/'`
    sed -e "s/SAMPLE/$sample_id/" $medaka_folders/round_2_final_phased.vcf | vcf-annotate -f + -H > ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/$medaka_base.vcf
    # Customize the awk command to suit your samples id names
awk -v samplid=$sample_id -v mt_dna_acc=$MTDNA_REF_ACC 'BEGIN{startmt="^mt_dna_acc"} $1 ~ startmt { print $2," ",$6," ",samplid}' ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/$medaka_base.vcf > ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/$medaka_base.qual_stats.txt
done

cat ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/*.qual_stats.txt > ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/all_qual_stats.txt

# Step 5.7 Merge vcf files
# -p -d -t 12Before merging vcf files we need to compress them using bgzip and index them with tabix from the htslib package
for individual_vcf_files in ${MEDAKA_FOLDERS_DIR}/final_vcf_dir/*.vcf; do
    bgzip $individual_vcf_files
    tabix -p vcf $individual_vcf_files.gz
done
