#!/bin/bash

# This script initializes a project directory on CUBIC
# so that The Way can be followed.

# USAGE:
# bash initialize_project.sh /full/path/to/directory

# To create a

# Check that we have conda installed
conda activate
if [ $? -gt 0 ]; then
    echo "Error initializing conda. Exiting"
    exit $?
fi

DATALAD_STATUS=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    exit 1
fi

echo USING DATALAD VERSION ${DATALAD_STATUS}

set -e -u -x

PROJECTROOT=$1
PROJECTNAME=$(basename ${PROJECTROOT})

if [[ -z ${PROJECTROOT} ]]
then
    echo Required argument is the full path to the project root
    exit 1
fi

if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    exit 1
fi

if [[ -d ${PROJECTROOT}_push ]]
then
    echo ${PROJECTROOT}_push already exists.
    exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    exit 1
fi

cd ${PROJECTROOT}

# Create the "production" dataset
datalad create --description "${PROJECTNAME}" -c yoda .

# Set up user info for git
git config --local user.email "${PROJECTNAME}@pennlinc.io"
git config --local user.name "${PROJECTNAME} on CUBIC"

# code/ is created by -c yoda
cd code
WAY_URL=https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic
SCRIPTS_TO_GET="\
 ${WAY_URL}/datalad-fmriprep-run.sh \
 ${WAY_URL}/setup_datalad_pre_pipelines.sh \
 ${WAY_URL}/submit-fmriprep-jobs.sh"

for WAY_URL in ${SCRIPTS_TO_GET}
do
    wget ${WAY_URL}
done
cp ${FREESURFER_HOME}/license.txt .

# Add the freesurfer license
cd ${PROJECTROOT}
datalad save -m "Add template scripts and license" code

# Create subdatasets for the major preps
mkdir ${PROJECTROOT}_push
PIPELINES="fmriprep qsiprep qsirecon freesurfer xcp cpac"
for PIPELINE in ${PIPELINES}
do
    datalad create \
        -D "${PIPELINE} outputs" \
        -d . \
        ${PIPELINE}

    datalad create-sibling \
        -d ${PIPELINE} \
        --name ${PIPELINE}_push \
        ${PROJECTROOT}_push/${PIPELINE}

    datalad push -d ${PIPELINE} --to ${PIPELINE}_push

done


