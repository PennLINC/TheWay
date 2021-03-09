#!/bin/bash

cd ${PROJECTROOT}/production

## fMRIPrep: copy it into the correct repository
# CHANGE TO WHERE YOU ACTUALLY HAVE THE CONTAINER
fmriprep_sif=/cbica/projects/RBC/fmriprep/my_images/fmriprep-20.2.1.simg
#fmriprep_sif=/path/to/fmriprep-20.2.1.sif

# Add the metadata info for the fmriprep container
datalad containers-add fmriprep-20-2-1 \
  --url ${fmriprep_sif} \
  --call-fmt \
    'singularity run --cleanenv -B "$PWD" {img} {cmd} --fs-license-file "$PWD"/code/license.txt'


datalad containers-add qsiprep-0-13-0RC1 \
  --url ../qsiprep-0.13.0RC1.sif \
  --call-fmt \
    'singularity run --cleanenv -B "$PWD" {img} {cmd} --fs-license-file "$PWD"/code/license.txt'


