#!/bin/bash

# This script initializes a project directory on CUBIC
# so that The Way can be followed.

# USAGE
# bash initialize_project.sh /full/path/to/project/root
set -e -u -x

PROJECTROOT=$1
PROJECTNAME=$(basename ${PROJECTROOT})

if [[ -z ${PROJECTROOT} ]]
then
    echo Required argument is the full path to the project root
    exit 1
fi

if [[ ! -d ${PROJECTROOT} ]]
then
    echo Provide a project root that exists. ${PROJECTROOT} does not.
    exit 1
fi

if [[ ! -w ${PROJECTROOT} ]]i
then
    echo Unable to write to ${PROJECTROOT}. Change permissions and retry
    exit 1
fi

echo 'export PROJECTROOT='${PROJECTROOT} >> ${HOME}/.bashrc

DIRECTORIES_TO_CREATE="\
 ${PROJECTROOT}/original_data \
 ${PROJECTROOT}/working/testing \
 ${PROJECTROOT}/production"

# Create all these directories and warn if they already exist
for DIR_TO_CREATE in ${DIRECTORIES_TO_CREATE}
do
    if [[ -d ${DIR_TO_CREATE} ]]
    then
        echo WARNING ${DIR_TO_CREATE} exists
    else
        mkdir -p ${DIR_TO_CREATE}
    fi
done

# Download and install conda
cd ${PROJECTROOT}
if [ ! -d ${PROJECTROOT}/miniconda3 ]
then
    module unload python/anaconda/3
    unset PYTHONPATH

    curl -sSLO https://repo.anaconda.com/miniconda/Miniconda3-py38_4.9.2-Linux-x86_64.sh && \
        bash Miniconda3-py38_4.9.2-Linux-x86_64.sh -b -p ${PROJECTROOT}/miniconda3 && \
        rm -f Miniconda3-py38_4.9.2-Linux-x86_64.sh

    # Unlock bashrc and edit it so conda works
    chmod +w ${HOME}/.bashrc
    echo ". ${PROJECTROOT}/miniconda3/etc/profile.d/conda.sh" >> ${HOME}/.bashrc
    chmod -w ${HOME}/.bashrc
    source ${HOME}/.bashrc
    # Fix some permissions errors
    chown -R `whoami` ${PROJECTROOT}/miniconda3
fi

# Activate the base conda environment
conda activate
# Install CuBIDS and datalad
conda install -y -c conda-forge git-annex datalad
pip install --upgrade datalad datalad_container
cd ${PROJECTROOT}/production

# Set up user info for git
git config --global user.email "${PROJECTNAME}@pennlinc.io"
git config --global user.name "${PROJECTNAME} on CUBIC"

# Create the "production" dataset
datalad create --description "${PROJECTNAME}" -c text2git yoda .

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

datalad save -m "Add template scripts" -d ${PROJECTROOT}
