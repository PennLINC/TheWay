#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=25G
#$ -l tmpfree=200G

#########################################################
# QuickUnzip.sh                                         #
# -------------                                         #
#                                                       #
# A bootstrap used to extract all outputs from xcp      #
# into a DERIVATIVES directory                          #
#                                                       #
# Usage:                                                #
#                                                       #
# ./bootstrap-quickunzip.sh /PATH/TO/XCP/BOOTSTRAP/DIR  #
#                                                       #
# with QSUB:                                            #
#                                                       #
# qsub -cwd -N YOUR_JOB_NAME \                          #
#   bootstrap-quickunzip.sh /PATH/TO/XCP/BOOTSTRAP/DIR  #
#########################################################

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

### 2. Set up the directory that will contain the necessary directories
echo Setting up directories...

PROJECTROOT=$(basename $HOME)/DERIVATIVES
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    # exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    # exit 1
fi

mkdir -p $PROJECTROOT
cd ${PROJECTROOT}

XCPROOT=$1   # input 1: path to your XCP bootstrap

### 3. Datalad create and clone the XCP outputs to the cwd input
echo cloning XCP results to local unzip folder...
RIA=${XCPROOT}/output_ria
datalad create -c yoda -D "extract xcp results" XCP
cd XCP
datalad clone -d . --reckless ephemeral "ria+file://${RIA}#~data" inputs/data


### 4. Create the compute job spec
echo writing script to file...
cat > code/get_files.sh << "EOT"
#!/bin/bash
set -e -u -x

ZIP_FILE=$1
subid=$(basename $ZIP_FILE | cut -d '_' -f 1)
sesid=$(basename $ZIP_FILE | cut -d '_' -f 2)

# unzip outputs
unzip -n $ZIP_FILE 'xcp_abcd/*' -d . 

# rename html to include sesid
mv xcp_abcd/${subid}.html xcp_abcd/${subid}_${sesid}.html

# copy outputs out of xcp_abcd
cp -r xcp_abcd/* .

# remove unzip dir
rm -rf xcp_abcd


EOT

datalad save -m "Add data extraction code" code

### 5. run datalad
echo running datalad script
zip_files=$(find inputs/data/ -name '*.zip')
for input_zip in ${zip_files}
do
    subid=$(basename $input_zip | cut -d '_' -f 1)
    sesid=$(basename $input_zip | cut -d '_' -f 2)
    html=${subid}_${sesid}.html
    if 
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
