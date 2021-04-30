#!/bin/bash

# This script installs conda and datalad into the home
# directory of a CUBIC user.

# USAGE:
# bash cubic-install-conda.sh

set -e -u -x

# Turn off cbica python on login
chmod +w ${HOME}/.bashrc
echo "# Configure python for this user" >> ${HOME}/.bashrc
echo "module unload python/anaconda/3" >> ${HOME}/.bashrc
echo "unset PYTHONPATH" >> ${HOME}/.bashrc
chmod -w ${HOME}/.bashrc

# Download and install conda
cd ${HOME}
if [ ! -d ${HOME}/miniconda3 ]
then
    module unload python/anaconda/3
    unset PYTHONPATH

    curl -sSLO https://repo.anaconda.com/miniconda/Miniconda3-py38_4.9.2-Linux-x86_64.sh && \
        bash Miniconda3-py38_4.9.2-Linux-x86_64.sh -b -p ${HOME}/miniconda3 && \
        rm -f Miniconda3-py38_4.9.2-Linux-x86_64.sh

    # Unlock bashrc and edit it so conda works
    chmod +w ${HOME}/.bashrc
    echo "export CONDA_PREFIX=${HOME}/miniconda3"
    echo ". ${HOME}/miniconda3/etc/profile.d/conda.sh" >> ${HOME}/.bashrc
    chmod -w ${HOME}/.bashrc
    set +u
    source ${HOME}/.bashrc
    # Fix some permissions errors
    chown -R `whoami` ${PROJECTROOT}/miniconda3/bin
    set -u
fi

# Note: if your user does not have (base) in front of it when you log back into
# CUBIC, you may need to run these next lines manually
# Activate the base conda environment
conda activate
# Install CuBIDS and datalad
conda install -y -c conda-forge git-annex datalad
pip install --upgrade datalad datalad_container
