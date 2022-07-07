#!/bin/bash
#$ -l h_vmem=25G
#$ -R y 

# Adds output files to archive so thier filestubs are accessible by users 

# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

cd ${PWD}

BOOTSTRAP_DIR=$1

# clone output ria of bootstrap dir 
datalad clone ria+file:///${BOOTSTRAP_DIR}/output_ria#~data archive_clone

# cd into clone 
cd archive_clone

for zip in *.zip; do
    echo Adding archive content for ${zip}
    datalad get ${zip}
    datalad add-archive-content -e 'logs/.*' -e '.bidsignore' -e 'dataset_description.json' -e 'dwiqc.json' --drop-after ${zip}
done

datalad push
