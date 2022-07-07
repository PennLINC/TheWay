#!/bin/bash

# Used for the shoreline project: Edit this for other kinds of unzipping
PROJECTROOT=/cbica/projects/Shoreline/shoreline-benchmark
cd ${PROJECTROOT}
RIA=${PROJECTROOT}/output_ria
datalad create -c yoda -D "extract shoreline results" results
cd results
datalad clone -d . --reckless ephemeral "ria+file://${RIA}#~data" inputs/data


## the actual compute job specification
cat > code/get_files.sh << "EOT"
#!/bin/bash
set -e -u -x

ZIP_FILE=$1

# Create a qsiprep/ directory
unzip $ZIP_FILE -x "*.nii.gz" -x "*.gif" -x "*.svg"

outdir=moco_results/$(basename $ZIP_FILE | sed 's/\.zip//')

mkdir -p ${outdir}/groundtruth

# Send the memory profile to the group csv
cat qsiprep/profiled.csv >> moco_results/memprof.csv

cp qsiprep/*_motion.txt ${outdir}/groundtruth/
cp qsiprep/sub-*/dwi/*confounds.tsv ${outdir}/
cp qsiprep/sub-*/dwi/*SliceQC* ${outdir}/
cp qsiprep/sub-*/dwi/*ImageQC* ${outdir}/

rm -rf qsiprep

EOT

datalad save -m "Add data extraction code" code

zip_files=$(find inputs/data/ -name '*.zip')
for input_zip in ${zip_files}
do

    outdir=moco_results/$(basename $input_zip | sed 's/\.zip//')

    datalad run \
        -i ${input_zip} \
        -o moco_results/memprof.csv \
        -o ${outdir} \
        --explicit \
        "bash code/get_files.sh ${input_zip}"
done



# CRITICAL!!! Don't uninstall, just rm -rf the inputs
rm -rf inputs
