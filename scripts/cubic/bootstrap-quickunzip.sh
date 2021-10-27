#!/bin/bash

# used to extract all outputs from xcp 
PROJECTROOT=/cbica/projects/hcpya/xcp
cd ${PROJECTROOT}
RIA=${PROJECTROOT}/output_ria
datalad create -c yoda -D "extract hcpya xcp results" results
cd results
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
        -o xcp_abcd \
        -o ${outdir} \
        --explicit \
        "bash code/get_files.sh ${input_zip}"
done



# CRITICAL!!! Don't uninstall, just rm -rf the inputs
rm -rf inputs
