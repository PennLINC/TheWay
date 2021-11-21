#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=25G
#$ -l tmpfree=200G

# Run this script when there already exists an unzip dir but the unzip job got killed and needs to be rerun mid unzip 

### 0. Set up environment
source ${CONDA_PREFIX}/bin/activate # activate a specific environment if necessary 
echo I\'m in $PWD using `which python`

set -e -u -x

### 1. check datalad

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

PROJECTROOT=$(basename $HOME)/DERIVATIVES
cd ${PROJECTROOT}/XCP

### 5. run datalad
echo running datalad script
zip_files=$(find inputs/data/ -name '*.zip')
for input_zip in ${zip_files}
do
    subid=$(basename $input_zip | cut -d '_' -f 1)
    sesid=$(basename $input_zip | cut -d '_' -f 2)
    html=${subid}_${sesid}.html

    if [[ -f html ]] # check sub has already been unzipped 
    then
        echo "${subid} ${sesid} ALREADY UNZIPPED"
    fi
        datalad run \
            -i ${input_zip} \
            -o ${subid} \
            -o ${html} \
            -m "unzipped ${input_zip}" \
            --explicit \
            "bash code/get_files.sh ${input_zip}"
done

echo 'DATALAD RUN FINISHED'

# remove reckless ephemeral clone of zips
rm -rf inputs

# make inputs/data exist again so working directory is clean 
mkdir -p inputs/data

echo 'REMOVED INPUTS'
echo 'SUCCESS'
