#!/bin/bash
# DESCRIPTION
#    eNano script.
#
# IMPLEMENTATION
#    author   Glen Dierickx (glen.dierickx@ugent.be or glen.dierickx@inbo.be)
#

# Error and dependencies function - install if needed
# ---------------------------------------------------
# Function to handle errors and exit with a specific message and code
die() {
    echo "Error: $1" >&2
    exit "$2"
}

# Check if a command is available in the system
check_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1" 1
}

# Check if Conda is installed and install eNano_env environment
install_conda() {
    # Check if Conda is installed
    check_command "conda"
    TMP_DIR=$(pwd)
    # Check if the 'eNano_env' environment already exists
    if conda info --envs | grep -q "eNano_env"; then
        die "'eNano_env' Conda environment already exists. Please remove it or choose a different environment name." 1
    fi

    # Create and update the Conda environment using the YAML file
    conda env create -n eNano_env -f eNano_env.yml -y || die "Failed to create or update Conda environment." 1
    
    # Activate the Conda environment using conda activate
    eval "$(conda shell.bash hook)"
    conda activate eNano_env || die "Failed to activate Conda environment." 1
    
    #adjustments for MUMU
    conda install -n eNano_env -y gcc_linux-64>=10 gxx_linux-64>=10 || die "Failed to install GCC 11 in Conda environment." 1

    # Install MUMU within the Conda environment - first maek sure the correct compilers are used
    MUMU_DIR=$(conda info --base)/envs/eNano_env/mumu
    git clone https://github.com/frederic-mahe/mumu.git $MUMU_DIR || die "Failed to clone MUMU repository." 1
    cd $MUMU_DIR || die "Failed to access MUMU directory." 1
    make CXX=$(conda info --base)/envs/eNano_env/bin/x86_64-conda-linux-gnu-g++ || die "Failed to build MUMU." 1
    make install prefix=$(conda info --base)/envs/eNano_env || die "Failed to install MUMU." 1
    check_command "mumu"
    cd $TMP_DIR
    # Move the eNano script to the Conda environment's bin directory
    chmod +x eNano.sh
    mv eNano.sh "$(conda info --root)/envs/eNano_env/bin/eNano"
    chmod +x "$(conda info --root)/envs/eNano_env/bin/eNano"
    
    echo "eNano has been installed in the 'eNano_env' Conda environment."
    echo "activate the environment with: conda activate eNano_env."
    echo "You can now use 'eNano' command to run the pipeline."
}
# Check if the --install-conda flag is provided
if [ "$1" = "--install-conda" ]; then
    install_conda
    exit 0
fi

# Function to check the first column for OTU IDs
check_otu_ids() {
    if ! awk -F '\t' '{print $1}' "$1" | grep -q 'OTU_[0-9]\+'; then
        die "The first column of the $2 does not contain OTU IDs." 1
    fi
}

# Default values for variables
OUTPUT_PATH="eNano_out"
THREADS="1"
FWP="CTTGGTCATTTAGAGGAAGTAA"
RVP="GCATATCAATAAGCGGAGGA"
MIN_LENGTH="400"
MAX_LENGTH="1200"
EE="0.2"
Q_THRESHOLD="25"
CLUSTER_PERCENT="0.98"
Q_MAX="1000"
SINTAX_CUTOFF="0.8"

# Skip flags for different steps (0: do not skip, 1: skip)
SKIP_CONCAT=0
SKIP_PROCESS=0
SKIP_OTU=0
SKIP_LULU=1
CHIM_REF=0
SKIP_SP=1

# Set required variables
REQUIRED_FASTQGZ_PATH="1"
REQUIRED_DB_FASTA="1"

# Function to display usage information
usage() {
    echo "./eNano --install-conda       installs eNano in the eNano_env conda environment and adds it to /envs/eNano_env/bin/ (only needed for initial install)"
    echo ""
    echo "eNano: Pipeline that generates an OTU table and associated taxonomy from demultiplexed Nanopore data outputted by Minknow.
          The input usually is a 'fastq_pass' directory with barcode01 - barcode96 subdirectories, each containing fastq files that passed some user-defined quality threshold.
          3 steps are performed, each of which can be skipped.
            1) concatenate fastq.gz files in each barcode subdirectory into a single fastq - outputted in concatenated_barcodes.
            2) processing each barcode fastq file - outputted in processed_fasta.
               - porechop trim
               - cutadapt reorient using forward primer and --rc flag
               - cutadapt trim of primers, only sequences with both forward and reverse primers are retained
               - chopper quality filter at user-defined phred score
               - vsearch convert to fasta
               - sed on sequence IDs prepends barcode name and removes whitespaces
               - vsearch appends sample names for parsing OTU table
            3) uses output from step 2 to generate a single OTU table and taxonomy - outputted in main folder
               - concatenate processed fasta files
               - sed on sequence IDs to append semicolon (temporary fix for parsing)
               - vsearch chimera filtering with uchime_denovo or uchime_ref
               - vsearch OTU cluster and relabel sequences
               - vsearch sorts OTUs by size
               - vsearch retrieve taxonomy with sintax from database fasta file
               - join otu-table with taxonomy
               - vsearch creates a match_list which can be used in mumu for curating OTU table
            4) uses match_list from step 3 to perform lulu curation of OTU table - outputted in the main folder.
               - runs mumu using otu-table and match list
               - join curated otu-table with taxonomy table  
            5) uses OTU table from 3 and/or LULU-curated table from step 4 to construct a table aggregated at the species-level - outputted in the main folder.
               - runs python
                 + takes OTU_TAX table and if present OTU_LULU table
                 + filters on sintax confindence and abundance
                     ° singletons need 0.95 confidence for retention
                     ° multitons need 0.80 confidence for retention
                 + aggregate species-level names of retained OTUs
    "
    echo ""
    echo "Usage: $0 [--help] (--fastqgz dir --output dir --threads value)
                             (--fwp string --rvp string --minlength value --maxlength value)
                             (--ee value --q value --maxqual value --clusterid value --db file)
                             (--mintax value --skip-concat [arg] --skip-process [arg] --skip-otu [arg])
                             (--skip-lulu [arg] --skip-sp [arg])"
    echo ""
    echo "Options:"
    echo "  -h, --help           Display this help message"
    echo "  --fastqgz PATH       Path to the directory with fastq.gz files (required, unless --skip-concat 1)"
    echo "  --output name        Foldername for the output directory (default: $OUTPUT_PATH)"
    echo "  --threads NUM        Number of threads to use (default: $THREADS)"
    echo "  --fwp SEQUENCE       Forward primer sequence for cutadapt (default=ITS1F: $FWP)"
    echo "  --rvp SEQUENCE       Reverse primer sequence for cutadapt (default=ITS4: $RVP)"
    echo "  --minlength NUM      Minimum length of reads to keep in cutadapt(default: $MIN_LENGTH)"
    echo "  --maxlength NUM      Maximum length of reads to keep in cutadapt(default: $MAX_LENGTH)"
    echo "  --ee NUM             Expected error rate for cutadapt (default: $EE)"
    echo "  --q NUM              Quality threshold for chopper (default: $Q_THRESHOLD)"
    echo "  --maxqual NUM        Max Quality threshold for chopper (default: $Q_MAX)"
    echo "  --mintax NUM         Min certainty for sintax cutoff (default: $SINTAX_CUTOFF)"
    echo "  --clusterid NUM      OTU clustering identity threshold in vsearch (default: $CLUSTER_PERCENT)"
    echo "  --db FASTAFILE       Path to the reference FASTA file for taxonomy assignment in vsearch (required, unless --skip-otu 1)"
    echo "  --chimref            De novo chimera filtering if set to 1 (default: $CHIM_REF Reference-based using --db)"
    echo "  --skip-concat        Skip the concatenation step if set to 1 (default: $SKIP_CONCAT)"
    echo "  --skip-process       Skip the processing step if set to 1 (default: $SKIP_PROCESS)"
    echo "  --skip-otu           Skip the OTU clustering and taxonomy assignment step if set to 1 (default: $SKIP_OTU)"
    echo "  --skip-lulu          Performs the LULU otu curation step if set to 0 (default: $SKIP_LULU)"
    echo "  --skip-sp            Aggregates otus at the species level step if set to 0 (default: $SKIP_SP)"
    echo "  --install-conda      Installs eNano and adds it to /envs/eNano_env/bin/"
    exit 1
}

# Check eNano is installed and dependencies before proceeding
check_dependencies() {
    check_command "zcat"
    check_command "porechop"
    check_command "cutadapt"
    check_command "chopper"
    check_command "vsearch"
}
#check dependencies
check_dependencies

# Main pipeline function
eNano() {
        # Check if no arguments are provided
        if [[ $# -eq 0 ]]; then
            usage
        fi
    # Parse command-line arguments using getopts
        while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                ;;
            --fastqgz)
                FASTQGZ_PATH=$(realpath "$2")
                shift 2
                ;;
            --output)
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --fwp)
                FWP="$2"
                shift 2
                ;;
            --rvp)
                RVP="$2"
                shift 2
                ;;
            --minlength)
                MIN_LENGTH="$2"
                shift 2
                ;;
            --maxlength)
                MAX_LENGTH="$2"
                shift 2
                ;;
            --ee)
                EE="$2"
                shift 2
                ;;
            --q)
                Q_THRESHOLD="$2"
                shift 2
                ;;
            --maxqual)
                Q_MAX="$2"
                shift 2
                ;;
            --mintax)
                SINTAX_CUTOFF="$2"
                shift 2
                ;;
            --clusterid)
                CLUSTER_PERCENT="$2"
                shift 2
                ;;
            --db)
                DB_FASTA="$2"
                shift 2
                ;;
            --chimref)
                CHIM_REF="$2"
                shift 2
                ;;
            --skip-concat)
                SKIP_CONCAT="$2"
                # If --skip-concat is set to 1, fastqgz flag is not required
                if [ "$SKIP_CONCAT" -eq 1 ]; then
                    REQUIRED_FASTQGZ_PATH=0
                fi
                shift 2
                ;;
            --skip-process)
                SKIP_PROCESS="$2"
                shift 2
                ;;
            --skip-otu)
                SKIP_OTU="$2"
                # If --skip-otu is set to 1, db flag is not required
                if [ "$SKIP_OTU" -eq 1 ]; then
                    REQUIRED_DB_FASTA=0
                fi
                shift 2
                ;;
            --skip-lulu)
                SKIP_LULU="$2"
                shift 2
                ;;
            --skip-sp)
                SKIP_SP="$2"
                shift 2
                ;;
            *)
                echo "Error: Unrecognized option: $1"
                usage
                ;;
        esac
    done
    
    # Validate the input parameters
    validate_parameters() {
        if [[ ! "$THREADS" =~ ^[0-9]+$ ]]; then
            die "Invalid number of threads: $THREADS. It must be an integer." 1
        fi
    
        if [[ ! "$MIN_LENGTH" =~ ^[0-9]+$ ]]; then
            die "Invalid minimum length: $MIN_LENGTH. It must be an integer." 1
        fi
    
        if [[ ! "$MAX_LENGTH" =~ ^[0-9]+$ ]]; then
            die "Invalid maximum length: $MAX_LENGTH. It must be an integer." 1
        fi
    
        if [[ ! "$EE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            die "Invalid expected error rate: $EE. It must be a number." 1
        fi
    
        if [[ ! "$Q_THRESHOLD" =~ ^[0-9]+$ ]]; then
            die "Invalid quality threshold: $Q_THRESHOLD. It must be an integer." 1
        fi
    
        if [[ ! "$CLUSTER_PERCENT" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            die "Invalid OTU clustering identity threshold: $CLUSTER_PERCENT. It must be a number." 1
        fi

        if ! [[ "$CHIM_REF" =~ ^(0|1)$ ]]; then
            die "Invalid chimref value: $CHIM_REF. It must be an integer: 0 or 1" 1

fi
    }
    
    validate_parameters
    check_command "eNano"
    
    # Check if fastqgz and db is provided when required
    if [ "$REQUIRED_FASTQGZ_PATH" -eq 1 ] && [ -z "$FASTQGZ_PATH" ]; then
        die "The --fastqgz flag is required unless --skip-concat is set to 1" 1
    fi
    # Check if db flag is provided when required
    if [ "$REQUIRED_DB_FASTA" -eq 1 ] && [ -z "$DB_FASTA" ]; then
        die "The --db flag is required unless --skip-otu is set to 1." 1
    fi

    # Start pipeline -------------------------------------------------------------------------------
    echo "running with settings:"
    echo "  --fastqgz $FASTQGZ_PATH"
    echo "  --output $OUTPUT_PATH"
    echo "  --threads $THREADS"
    echo "  --fwp $FWP"
    echo "  --rvp $RVP"
    echo "  --minlength $MIN_LENGTH"
    echo "  --maxlength $MAX_LENGTH"
    echo "  --ee $EE"
    echo "  --q $Q_THRESHOLD"
    echo "  --maxqual $Q_MAX"
    echo "  --mintax $SINTAX_CUTOFF"
    echo "  --clusterid $CLUSTER_PERCENT"
    echo "  --db $DB_FASTA"
    echo "  --chimref $CHIM_REF"
    echo "  --skip-concat $SKIP_CONCAT"
    echo "  --skip-process $SKIP_PROCESS"
    echo "  --skip-otu $SKIP_OTU"
    echo "  --skip-lulu $SKIP_LULU"
    echo "  --skip-sp $SKIP_SP"

    echo "#################################################### starting pipeline for Nanopore simplex data #######################################################"

    # Create the output directory if it doesn't exist
    MAIN_DIR=$(pwd)
    mkdir -p "$OUTPUT_PATH/concatenated_barcodes" || die "Failed to create output directory: $OUTPUT_PATH/concatenated_barcodes" 1
    BARCODE_PATH="$MAIN_DIR/$OUTPUT_PATH/concatenated_barcodes"
    OUTPUT_PATH="$MAIN_DIR/$OUTPUT_PATH"
    export LC_ALL=C

    # Step 1: Create output folder that holds all files and redirect concatenated barcode files
    if [ "$SKIP_CONCAT" -eq 0 ]; then
        echo "STEP 1 - creating output folder and concatenating fastq.gz files"
        # Gather all basecalled (fastq.gz) data from a nanopore run and put them in a single folder with 1 file per barcode
        cd "$FASTQGZ_PATH" || die "FASTQGZ_PATH directory not found: $FASTQGZ_PATH" 1
        for subdir in "$FASTQGZ_PATH"/*; do
            if [ -d "$subdir" ]; then
                # Extract subdirectory name
                subdirname=$(basename "$subdir")
                # Move into subdirectory
                cd "$subdir" || die "Failed to enter subdirectory: $subdir" 1
                echo "Start concatenating *.fastq.gz files of ${subdirname}"
                # Unzip .fastq.gz files and combine into one .fastq file
                zcat *.fastq.gz > "$BARCODE_PATH/$subdirname.fastq"
                echo "Done with ${subdirname}"
                # Move back to the main directory
                cd - || die "Failed to return to the fastqgz directory" 1
            else
                echo "no subdirectories barcodes"
            fi
        done
    else
        echo "Skipping Step 1 - creating output folder and concatenating fastq.gz files"
    fi

    # Step 2: Process each barcode file
    if [ "$SKIP_PROCESS" -eq 0 ]; then
        echo "STEP 2 - processing each barcode file"
        cd "${OUTPUT_PATH}" || die "OUTPUT_PATH directory not found: $OUTPUT_PATH" 1
        mkdir -p "processed_fasta"
        for FILE in ${BARCODE_PATH}/barcode*.fastq; do
            FILE_NAME=$(basename "${FILE%.*}")
            echo "$PWD"
            echo "for ${FILE_NAME} - start trimming adapter, primers, quality filtering, converting to fasta, and adding sample info"

            porechop -i "$FILE"  --extra_end_trim 0 --check_reads 1000 --discard_middle --adapter_threshold 97 --threads "$THREADS" > "${BARCODE_PATH}/temp1.fastq"
            cutadapt -g "$FWP"  --action=none -e "$EE" --discard-untrimmed --rc "${BARCODE_PATH}/temp1.fastq" > "${BARCODE_PATH}/temp2.fastq"
            cutadapt -g "${FWP}...${RVP}" --action=trim -e "$EE" --discard-untrimmed -m "$MIN_LENGTH" -M "$MAX_LENGTH" --times 2 "${BARCODE_PATH}/temp2.fastq" > "${BARCODE_PATH}/temp3.fastq"
            cat "${BARCODE_PATH}/temp3.fastq" | chopper --quality "$Q_THRESHOLD" --maxqual "$Q_MAX" -t "$THREADS" > "${BARCODE_PATH}/temp4.fastq"
            vsearch --fastq_filter "${BARCODE_PATH}/temp4.fastq" --fastaout "${BARCODE_PATH}/temp5.fasta" --fastq_ascii 33 --fastq_qmax 93
            sed -i.bak -e "s|^>|>${FILE_NAME}_|" -e "s/;/__/g; s/ //g" "${BARCODE_PATH}/temp5.fasta"
            vsearch --fastx_filter "$BARCODE_PATH/temp5.fasta" --sample "${FILE_NAME}" --fastaout "${OUTPUT_PATH}/processed_fasta/${FILE_NAME}.fasta"
            rm "$BARCODE_PATH"/*.bak "$BARCODE_PATH"/temp*.fastq "$BARCODE_PATH"/temp*.fasta

            echo "done processing ${FILE} - written to processed_fasta/${FILE_NAME}.fasta"
        done
    else
        echo "Skipping Step 2 - processing each barcode file"
    fi
    # Step 3: concat processed fasta files, OTU clustering and taxonomy assignment
    if [ "$SKIP_OTU" -eq 0 ]; then
        cd "$MAIN_DIR" || die "Failed to enter main directory: $MAIN_DIR" 1
        echo "STEP 3 - concatenating processed barcode files, OTU clustering and taxonomy assignment"
        echo "concatenating processed barcode files"
        find "$OUTPUT_PATH/processed_fasta" -maxdepth 1 -type f -name 'barcode*.fasta' -execdir cat {} + > "$OUTPUT_PATH/barcodes.fasta"

        # Temporary fix for vsearch v2.21.1 - add another semicolon after the sample name
        echo "adding semicolon to sample ID"
        sed -i.bak "s/;sample=bc[0-9][0-9]/&;/" "${OUTPUT_PATH}/barcodes.fasta"
        rm "$OUTPUT_PATH"/*.bak

        # OTU clustering
        # Chimera filtering (compare reference-based and de novo!)
        echo "start chimera filtering"
        if [ "$CHIM_REF" -eq 0 ]; then
            vsearch --uchime_ref "${OUTPUT_PATH}/barcodes.fasta" --db "$DB_FASTA" --nonchimeras "${OUTPUT_PATH}/temp1.fasta"
        else
            vsearch --uchime_denovo "${OUTPUT_PATH}/barcodes.fasta" --nonchimeras "${OUTPUT_PATH}/temp1.fasta"
        fi

        # Extract centroid sequences of OTUs, clustered on id% identity threshold with the standard algorithm, then sort by size
        echo "start OTU clustering"
        vsearch --cluster_smallmem "${OUTPUT_PATH}/temp1.fasta" --usersort --relabel OTU_ --centroids "${OUTPUT_PATH}/temp2.fasta" --otutabout "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_otutable.tsv" --sizeout --log "${OUTPUT_PATH}/clusterlog.txt" --id "$CLUSTER_PERCENT" --threads "$THREADS"
        vsearch --sortbysize "${OUTPUT_PATH}/temp2.fasta" --output "${OUTPUT_PATH}/centroids.fasta"
        rm "$OUTPUT_PATH"/temp*.fasta

        # Get taxonomy
        echo "start taxonomic assignment"
        vsearch --db "$DB_FASTA" --sintax "${OUTPUT_PATH}/centroids.fasta" --tabbedout "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_sintaxonomy.tsv" --sintax_cutoff "$SINTAX_CUTOFF"

        # combine taxonomy and otu-table - remove string ';size=X' from the taxonomy file, sort both TAX and OTU files
        sed 's/;size=[0-9]\+//' "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_sintaxonomy.tsv" > "${OUTPUT_PATH}/temp3.tsv"
        check_otu_ids "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_otutable.tsv" "OTU table"
        check_otu_ids "${OUTPUT_PATH}/temp3.tsv" "taxonomy file"
        sort -k1,1 "${OUTPUT_PATH}/temp3.tsv" > "${OUTPUT_PATH}/temp4.tsv"
        cut -f1,2,4 "${OUTPUT_PATH}/temp4.tsv" > "${OUTPUT_PATH}/temp4_cut.tsv"
        sed -i '1i #OTU ID\tSINTAX\tTAX' "${OUTPUT_PATH}/temp4_cut.tsv"
        sort -k1,1 "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_otutable.tsv" > "${OUTPUT_PATH}/temp5.tsv"
        
        # Join sorted OTU and TAX files into combined OTU_TAX file
        join -1 1 -2 1 -t $'\t' "${OUTPUT_PATH}/temp5.tsv" "${OUTPUT_PATH}/temp4_cut.tsv" > "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_temp.tsv"
        
        # Process the OTU_TAX file using awk
        awk 'BEGIN{FS=OFS="\t"} 
        NR==1 {
            print $0, "domain", "phylum", "class", "order", "family", "genus", "species"
            for(i=1; i<=NF; i++) {
                if($i == "TAX") {
                    tax_index = i
                }
            }
        }
        NR>1 {
            split($tax_index,a,","); 
            for(i in a) {
                split(a[i],b,":"); tax[b[1]]=b[2]
            }
            $(NF+1)=tax["d"]; $(NF+1)=tax["p"]; $(NF+1)=tax["c"]; $(NF+1)=tax["o"]; $(NF+1)=tax["f"]; $(NF+1)=tax["g"]; $(NF+1)=tax["s"]; 
            print; delete tax
        }' "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_temp.tsv" > "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX.tsv"
        
        # LULU clean-up - Produce a match-list with vsearch, remove string ';size=X' from match file for processing in LULU
         echo "producing LULU match list"
         sed "s/;size=[0-9]\+//" "${OUTPUT_PATH}/centroids.fasta" > "${OUTPUT_PATH}/temp6.fasta"
         vsearch --usearch_global "${OUTPUT_PATH}/temp6.fasta"  --db "${OUTPUT_PATH}/temp6.fasta"  --self --id .84 --iddef 1 --userout "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_LULU_match_list.txt" -userfields query+target+id --maxaccepts 0 --query_cov .9 --maxhits 10
        
        # Remove temporary files
        rm "$OUTPUT_PATH"/*temp*
        
    else
        echo "Skipping Step 3 - OTU clustering, chimera filtering, and taxonomy assignment"
    fi

    # Step 4: LULU otu-table curation, produce match-list and run mumu
    if [ "$SKIP_LULU" -eq 0 ]; then
        check_command "mumu"
        echo "Starting Step 4 - LULU curation using mumu"

        # Run MUMU with specified input and output files
        mumu --otu_table "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_otutable.tsv" --match_list "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_LULU_match_list.txt" --log "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_lulu_log.txt" --new_otu_table "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_LULU.tsv"

        #combine curated table with taxonomy table, remove string ';size=X'from the taxonomy file, sort both TAX and OTU files
        sed 's/;size=[0-9]\+//' "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_sintaxonomy.tsv" > "${OUTPUT_PATH}/temp7.tsv"
        check_otu_ids "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_LULU.tsv" "LULU OTU table"
        check_otu_ids "${OUTPUT_PATH}/temp7.tsv" "taxonomy file"
        sort -k1,1 "${OUTPUT_PATH}/temp7.tsv" > "${OUTPUT_PATH}/temp8.tsv"
        cut -f1,2,4 "${OUTPUT_PATH}/temp8.tsv" > "${OUTPUT_PATH}/temp8_cut.tsv"
        sed -i '1i #OTU ID\tSINTAX\tTAX' "${OUTPUT_PATH}/temp8_cut.tsv"
        sort -k1,1 "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_LULU.tsv" > "${OUTPUT_PATH}/temp9.tsv"
        sed '1s/^[^\t]*/#OTU ID/' "${OUTPUT_PATH}/temp9.tsv" > "${OUTPUT_PATH}/temp10.tsv"
        # Join sorted OTU and TAX files into combined OTU_TAX file
        join -1 1 -2 1 -t $'\t' "${OUTPUT_PATH}/temp10.tsv" "${OUTPUT_PATH}/temp8_cut.tsv" > "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_LULU_temp.tsv"
        
        # Process the OTU_TAX file using awk
        awk 'BEGIN{FS=OFS="\t"} 
        NR==1 {
            print $0, "domain", "phylum", "class", "order", "family", "genus", "species"
            for(i=1; i<=NF; i++) {
                if($i == "TAX") {
                    tax_index = i
                }
            }
        }
        NR>1 {
            split($tax_index,a,","); 
            for(i in a) {
                split(a[i],b,":"); tax[b[1]]=b[2]
            }
            $(NF+1)=tax["d"]; $(NF+1)=tax["p"]; $(NF+1)=tax["c"]; $(NF+1)=tax["o"]; $(NF+1)=tax["f"]; $(NF+1)=tax["g"]; $(NF+1)=tax["s"]; 
            print; delete tax
        }' "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_LULU_temp.tsv" > "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_LULU.tsv"
        
        # Clean up temporary files
        rm "$OUTPUT_PATH"/*temp*
        
    else
        echo "Skipping Step 4 - LULU otu-table curation as implemented in mumu"
    fi
    
    # Step 5: Species-table creation in Python
    if [ "$SKIP_SP" -eq 0 ]; then
        echo "starting Step 5 - Species-table creation"
        # Run SH-table in Python, produce Species-table
        python3 - <<END
import pandas as pd
import re
import os

output_path = "${OUTPUT_PATH}"
otu_table = "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX.tsv"
lulu_table = "${OUTPUT_PATH}/$(basename "$OUTPUT_PATH")_OTU_TAX_LULU.tsv"

# Check if LULU table exists, otherwise set to None
lulu_exists = os.path.exists(lulu_table)
lulu_table = lulu_table if lulu_exists else None

# Extract the base name of the output directory
base_name = os.path.basename(output_path)

def parse_sintax_column(df, sintax_col):
    taxon_patterns = {
        'domain': r'd:([^,]+)',
        'phylum': r'p:([^,]+)',
        'class': r'c:([^,]+)',
        'order': r'o:([^,]+)',
        'family': r'f:([^,]+)',
        'genus': r'g:([^,]+)',
        'species': r's:([^,]+)'
    }
    
    for rank, pattern in taxon_patterns.items():
        df[rank] = df[sintax_col].apply(lambda x: re.search(pattern, x).group(1) if pd.notnull(x) and re.search(pattern, x) else None)
        df[f'{rank}_confidence'] = df[rank].apply(lambda x: float(re.search(r'\((\d+\.\d+)\)', x).group(1)) if x and re.search(r'\((\d+\.\d+)\)', x) else None)
        df[rank] = df[rank].apply(lambda x: re.sub(r'\(.*\)', '', x) if x else None)
    
    return df

def aggregate_species(df, barcode_columns):
    df['abundance'] = df[barcode_columns].sum(axis=1)
    df['Include'] = ((df['abundance'] == 1) & (df['species_confidence'] >= 0.95)) | ((df['abundance'] > 1) & (df['species_confidence'] >= 0.80))
    filtered_df = df[df['Include']].copy()
    species_df = filtered_df.groupby('species')[barcode_columns].sum().reset_index()
    return species_df

def main(otu_table, otu_output_file, lulu_table=None, lulu_output_file=None):
    otu_df = pd.read_csv(otu_table, sep='\t')
    barcode_columns = [col for col in otu_df.columns if col.startswith('barcode')]
    
    # Process OTU table
    parsed_otu_df = parse_sintax_column(otu_df, 'SINTAX')
    species_otu_df = aggregate_species(parsed_otu_df, barcode_columns)
    species_otu_df.to_csv(otu_output_file, sep='\t', index=False)

    # Process LULU table if it exists
    if lulu_table and lulu_output_file:
        lulu_df = pd.read_csv(lulu_table, sep='\t')
        parsed_lulu_df = parse_sintax_column(lulu_df, 'SINTAX')
        species_lulu_df = aggregate_species(parsed_lulu_df, barcode_columns)
        species_lulu_df.to_csv(lulu_output_file, sep='\t', index=False)

# Determine output file names using base_name and output_path
otu_output_file = f"{output_path}/{base_name}_OTU_SP.tsv"
lulu_output_file = f"{output_path}/{base_name}_LULU_SP.tsv" if lulu_exists else None

# Run the main function
main(otu_table, otu_output_file, lulu_table, lulu_output_file)
END
    else
        echo "Skipping Step 5 - Species-table creation"
    fi
    # End of pipeline
    echo "################# pipeline done #################"
}

# Call the eNano function with the provided arguments
eNano "$@"
