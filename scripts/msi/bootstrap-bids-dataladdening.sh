## NOTE ##
# This workflow is derived from the Datalad Handbook

# workflow for converting many subjects into datalad

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
source /home/umii/hendr522/SW/miniconda3/etc/profile.d/conda.sh
conda activate datalad_and_nda
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/dataladdening
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    exit 1
fi


## Check the BIDS input: This will be the copy of Anders's read-only ABCC BIDS data
BIDSINPUT=$1
if [[ -z ${BIDSINPUT} ]]
then
    echo "Required argument is an identifier of the BIDS source"
    exit 1
fi

SUBJECTS=$(find ${BIDSINPUT} -maxdepth 1 -type d -name 'sub-*' | xargs -n 1 basename)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    exit 1
fi

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# Only make a single ria store - we'll send all the subdatasets there
output_store="${PROJECTROOT}/BIDS_DATASETS"
mkdir -p ${output_store}

# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#SBATCH -J qsiprep
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=20gb
#SBATCH -t 24:00:00
#SBATCH -p small,amdsmall
#SBATCH -A feczk001
#SBATCH --mail-type=ALL
#SBATCH --mail-user=hendr522@umn.edu

# Set up the correct conda environment
source /home/umii/hendr522/SW/miniconda3/etc/profile.d/conda.sh
conda activate datalad_and_nda
echo I\'m in $PWD using `which python`

# set up AWS credentials as environment variables
export AWS_ACCESS_KEY_ID=`cat ${HOME}/.s3cfg | grep access_key | awk '{print $3}'`
export AWS_SECRET_ACCESS_KEY=`cat ${HOME}/.s3cfg | grep secret_key | awk '{print $3}'`

# fail whenever something is fishy, use -x to get verbose logfiles
export PS4='> '
set -e -u -x

echo $SLURM_JOB_ID
# Set up the remotes and get the subject id from the call
collector_dir="$1"
# make $2 subid/sesid to have session subdatasets ##UNTESTED##
subid="$2"
bidsroot="$3"
bucket="$4"
srname="$5"

# change into the directory where the individual subject datasets will go
cd $collector_dir

# New dataset to house this subject
datalad create -D "Copy subject $subid" $subid
cd $subid

# Add the s3 output
git annex initremote "$srname" \
    type=S3 \
    autoenable=true \
    bucket=$bucket \
    encryption=none \
    "fileprefix=$subid/" \
    host=s3.msi.umn.edu \
    partsize=1GiB \
    port=443 \
    public=no

# Copy the entire input directory into the current dataset
# and save it as a subdataset.
datalad run \
    -m "Copy in ${subid}" \
    "cp -rL ${bidsroot}/${subid}/* ."

# Push to s3
datalad push --to $srname

# Cleanup
datalad drop .

# Announce
echo SUCCESS

EOT

chmod +x code/participant_job.sh

mkdir logs
echo .SLURM_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

#TODO add s3info credential dynamically

################################################################################
# SLURM SETUP START - remove or adjust to your needs
################################################################################
echo '#!/bin/bash' > code/srun_calls.sh
for subject in ${SUBJECTS}; do
    eo_args="-e ${PWD}/logs/${subject}.err -o ${PWD}/logs/${subject}.out"
    echo "sbatch -J bids${subject} ${eo_args} \
    ${PWD}/code/participant_job.sh \
    ${output_store} ${subject} ${BIDSINPUT} hendr522-dataladdening private-umn-s3" >> code/srun_calls.sh
done
datalad save -m "SLURM submission setup" code/ .gitignore

################################################################################
#  SETUP END
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
cd $output_store
subjects=$(find . -maxdepth 1 -type d -name 'sub-')
datalad create -D "Collection of BIDS subdatasets" -c text2git -d BIDS
cd BIDS
for subject in $subjects
do
    datalad clone -d . ${output_store}/${subject} $subject
done
datalad save -m "added subject data"
EOT

# if we get here, we are happy
echo SUCCESS