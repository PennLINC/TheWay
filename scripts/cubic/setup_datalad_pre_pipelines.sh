#!/bin/bash

# The directory structure should be something like

# projectroot (superdataset)
# - code (directory)
# - bidsdatasets (subdataset)
# -- sub-X (directory)



# This script prepares a superdataset for container runs of
# various "preps"

# This is the "superdataset". Should only contain code/ as a directory
# and the rest should be subdatasets
PROJECTROOT=/cbica/projects/RBC/testing/PNC_Acq
cd ${PROJECTROOT}


# Make sure that any untracked stuff doesn't get added to the directory

# First, make sure we have a BIDS index in the bids dataset
# This creates a pybids_index directory in the bids tree and
# adds it to the .bidsignore file.
# atalad run \
#    -d ${PROJECTROOT}/bidsdatasets \
#    -m "add pybids index to BIDS tree" \
#    bond-index ${PROJECTROOT}/bidsdatasets

# Next start configuring the singularity images to run
# with datalad container-run. To do this, we need to
# add them with datalad container-add.

# Create a subdataset that will contain the singularity images
#CONTAINERROOT=${PROJECTROOT}/code/pipelines
#mkdir -p ${CONTAINERROOT}


#datalad create \
#    -D "Stores all the singularity images" \
#    -d ${PROJECTROOT} \
#    ${CONTAINERROOT}


## fMRIPrep: copy it into the correct repository
# CHANGE TO WHERE YOU ACTUALLY HAVE THE CONTAINER
fmriprep_sif=/cbica/projects/RBC/fmriprep/my_images/fmriprep-20.2.1.simg
#fmriprep_sif=/path/to/fmriprep-20.2.1.sif

#cp ${fmriprep_sif} ${CONTAINERROOT}
#datalad save -m "added fmriprep container" ${CONTAINERROOT}


# Copy the freesurfer license file into the repository
cp ${FREESURFER_HOME}/license.txt ${PROJECTROOT}/code
datalad save -m "add freesurfer license" ${PROJECTROOT}/code


# Initialize empty datasets for the fmriprep and freesurfer outputs
datalad create \
    -D "fmriprep outputs" \
    -d ${PROJECTROOT} \
    ${PROJECTROOT}/fmriprep

datalad create \
    -D "freesurfer outputs" \
    -d ${PROJECTROOT} \
    ${PROJECTROOT}/freesurfer


# Add the metadata info for the fmriprep container
datalad containers-add fmriprep-20-2-1 \
  --url ${fmriprep_sif} \
  --call-fmt \
    'singularity run --cleanenv -B "$PWD" {img} {cmd} --fs-license-file "$PWD"/code/license.txt'




