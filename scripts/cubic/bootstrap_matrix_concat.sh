#!/bin/bash

DATA=$(pwd)
PROJECTROOT=$DATA/fcon
mkdir $PROJECTROOT
cd $PROJECTROOT

datalad create -d .

datalad clone ria+file://$DATA/matrices/output_ria#~data concat_ds

wget https://raw.githubusercontent.com/PennLINC/RBC/master/PennLINC/Generic/matrix_concatenator.py

datalad save -m "added matrix concatenator script"
datalad run \
    -m "generated concatenated matrices" \
    -i 'concat_ds/*matrices.zip*' \
    -o 'group_matrices.zip' \
    --expand inputs \
    --explicit \
    "python matrix_concatenator.py"

# remove concat_ds
datalad uninstall concat_ds

echo SUCCESS
