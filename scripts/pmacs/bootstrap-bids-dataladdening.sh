## NOTE ##
# This workflow is derived from the Datalad Handbook

# workflow for converting many subjects into datalad

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/dataladdening
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


## Check the BIDS input
#BIDSINPUT=/project/msdepression/repos/ms-depression/nifti
BIDSINPUT=$1
if [[ -z ${BIDSINPUT} ]]
then
    echo "Required argument is an identifier of the BIDS source"
    # exit 1
fi

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# Only make a single ria store - we'll send all the subdatasets there
output_store="ria+file://${PROJECTROOT}/output_ria"
# and the directory for aliases
mkdir -p ${PROJECTROOT}/output_ria/alias
# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis
# Ensure the ria store is created
datalad create-sibling-ria -s output "${output_store}"

SUBJECTS=$(find ${BIDSINPUT} -maxdepth 1 -type d -name 'sub-*' | xargs -n 1 basename)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
# Set up the correct conda environment
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

echo $LSB_JOBID

# Set up the remotes and get the subject id from the call
collector_ria="$1"
# make $2 subid/sesid to have session subdatasets ##UNTESTED##
subid="$2"
bidsroot="$3"

# change into the cluster-assigned temp directory. Not done by default in LSF
workdir=/scratch/${LSB_JOBID}
mkdir -p ${workdir}
cd ${workdir}

# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results to, in order to avoid too many jobs blocking access to
# the same location and creating a throughput bottleneck
datalad create -D "Copy subject $subid" $subid

# all following actions are performed in the context of the superdataset
cd $subid
datalad create-sibling-ria -s output "${collector_ria}"

# Copy the entire input directory into the current dataset
# and save it as a subdataset.
datalad run \
    -m "Copy in ${subid}" \
    "cp -r ${bidsroot}/${subid}/* ."

ria_path=$(datalad siblings | grep 'output(-' | sed 's/.*\[\(.*\) (git)\]/\1/')

datalad push --to output
datalad drop --nocheck .
git annex dead here

# Make an alias in the RIA store
cd ${ria_path}/../../alias
pt1=$(basename `dirname $ria_path`)
pt2=$(basename $ria_path)
ln -s "../$pt1/$pt2" $subid

# cleanup
rm -rf $workdir

# Announce
echo SUCCESS
EOT

chmod +x code/participant_job.sh

mkdir logs
echo .LSF_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

################################################################################
# LSF SETUP START - remove or adjust to your needs
################################################################################
echo '#!/bin/bash' > code/bsub_calls.sh
eo_args="-e ${PWD}/logs -o ${PWD}/logs -n 1 -R 'rusage[mem=5000]'"
for subject in ${SUBJECTS}; do
    echo "bsub -J bids${subject} ${eo_args} \
    ${PWD}/code/participant_job.sh \
    ${output_store} ${subject} ${BIDSINPUT}" >> code/bsub_calls.sh
done
datalad save -m "LSF submission setup" code/ .gitignore

################################################################################
# LSF SETUP END
################################################################################


#########################
# Merge outputs script
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT
echo "output_store=${output_store}" >> code/merge_outputs.sh
echo "BIDSINPUT=${BIDSINPUT}" >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh

cat >> code/merge_outputs.sh << "EOT"
subjects=$(ls output_ria/alias)
datalad create -D "Collection of BIDS subdatasets" -c text2git -d merge_ds
cd merge_ds
for subject in $subjects
do
    datalad clone -d . ${output_store}"#~${subject}" $subject
done
datalad create-sibling-ria -s output "${output_store}"

# Copy the non-subject data into here
cp $(find $BIDSINPUT -maxdepth 1 -type f) .
datalad save -m "Add subdatasets"
datalad push --to output

ria_path=$(datalad siblings | grep 'output(-' | sed 's/.*\[\(.*\) (git)\]/\1/')

# stop tracking this branch
datalad drop --nocheck .
git annex dead here

cd ${ria_path}/../../alias
pt1=$(basename `dirname $ria_path`)
pt2=$(basename $ria_path)
ln -s "../$pt1/$pt2" data

EOT

# if we get here, we are happy
echo SUCCESS