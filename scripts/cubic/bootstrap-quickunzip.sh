#!/bin/bash

# used to extract all outputs from an xcp bootstrap dir 

PROJECTROOT=/cbica/projects/RBC/production/PNC/xcp # make sure to change this to the root of your bootstrap dir!
cd ${HOME}
mkdir DERIVATIVES
cd ${HOME}/DERIVATIVES
RIA=${PROJECTROOT}/output_ria
datalad create -c yoda -D "extract pnc xcp results" XCP
cd XCP
datalad clone -d . --reckless ephemeral "ria+file://${RIA}#~data" inputs/data


## the actual compute job specification
cat > code/get_files.sh << "EOT"
#!/bin/bash
set -e -u -x

ZIP_FILE=$1

# Create a xcp/ directory
unzip -n $ZIP_FILE

outdir=xcp_abcd/$(basename $ZIP_FILE | sed 's/\.zip//')

EOT

datalad save -m "Add data extraction code" code

zip_files=$(find inputs/data/ -name '*.zip')
for input_zip in ${zip_files}
do

    outdir=xcp_abcd/$(basename $input_zip | sed 's/\.zip//')

    datalad run \
        -i ${input_zip} \
        -o ${outdir} \
        --explicit \
        "bash code/get_files.sh ${input_zip}"
done

echo 'DATALAD RUN FINISHED'

# CRITICAL!!! Don't uninstall, just rm -rf the inputs
rm -rf inputs

echo 'REMOVED INPUTS'
echo 'SUCCESS'
