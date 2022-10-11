#!/bin/bash
## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

# Arguments:
# 1. BIDS directory bootstrap directory
# 2. existing freesurfer output directory (zips)
# 3. fmriprep container dataset directory

#bash bootstrap-fmriprep-ingressed.sh \
#    /cbica/projects/RBC/RBC_RAWDATA/bidsdatasets/BIDS_ROOT \
#    /cbica/projects/RBC/production/PNC/anat-only \
#    /cbica/projects/RBC/fmriprepXXX-container

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

## Check the BIDS input
BIDSINPUT=$1
if [[ -z ${BIDSINPUT} ]]
then
    echo "Required argument is an identifier of the BIDS source"
    # exit 1
fi

# Is it a directory on the filesystem?
BIDS_INPUT_METHOD=clone
if [[ -d "${BIDSINPUT}" ]]
then
    # Check if it's datalad
    BIDS_DATALAD_ID=$(datalad -f '{infos[dataset][id]}' wtf -S \
                      dataset -d ${BIDSINPUT} 2> /dev/null || true)
    [ "${BIDS_DATALAD_ID}" = 'N/A' ] && BIDS_INPUT_METHOD=copy
fi

##  qsirecon input
FREESURFERINPUT=$2
if [[ -z ${FREESURFERINPUT} ]]
then
    echo "Required argument is an identifier of the FreeSurfer output zips"
    # exit 1
fi

if [[ ! -d "${FREESURFERINPUT}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "FREESURFER output dataset"
    # exit 1
fi

set -e -u

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/fmriprep-func
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

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# RIA-URL to a different RIA store from which the dataset will be cloned from.
# Both RIA stores will be created
input_store="ria+file://${PROJECTROOT}/input_ria"
output_store="ria+file://${PROJECTROOT}/output_ria"

# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

# register the input dataset
if [[ "${BIDS_INPUT_METHOD}" == "clone" ]]
then
    echo "Cloning input dataset into analysis dataset"
    datalad clone -d . ${BIDSINPUT} inputs/data/BIDS
    # amend the previous commit with a nicer commit message
    git commit --amend -m 'Register input data dataset as a subdataset'
else
    echo "WARNING: copying input data into repository"
    mkdir -p inputs/data/BIDS
    cp -r ${BIDSINPUT}/* inputs/data
    datalad save -r -m "added input data"
fi

datalad clone -d . ria+file://${FREESURFERINPUT}/output_ria#~data inputs/data/freesurfer
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register freesurfer/fmriprep dataset as a subdataset'

SUBJECTS=$(find inputs/data/freesurfer -name '*.zip' | cut -d '/' -f 4 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

cd ${PROJECTROOT}

CONTAINERDS=$3
if [[ ! -z "${CONTAINERDS}" ]]; then
    datalad clone ${CONTAINERDS} pennlinc-containers
fi

cd ${PROJECTROOT}/analysis
datalad install  -d . --source ${PROJECTROOT}/pennlinc-containers

cp ${FREESURFER_HOME}/license.txt code/license.txt

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=24G
#$ -pe threaded 2
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`
# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x
# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
subid="$3"
# change into the cluster-assigned temp directory. Not done by default in SGE
cd ${CBICA_TMPDIR}
# OR Run it on a shared network drive
#cd /cbica/comp_space/$(basename $HOME)
# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}
# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results to, in order to avoid too many jobs blocking access to
# the same location and creating a throughput bottleneck
datalad clone "${dssource}" ds
# all following actions are performed in the context of the superdataset
cd ds
# in order to avoid accumulation temporary git-annex availability information
# and to avoid a syncronization bottleneck by having to consolidate the
# git-annex branch across jobs, we will only push the main tracking branch
# back to the output store (plus the actual file content). Final availability
# information can be establish via an eventual `git-annex fsck -f joc-storage`.
# this remote is never fetched, it accumulates a larger number of branches
# and we want to avoid progressive slowdown. Instead we only ever push
# a unique branch per each job (subject AND process specific name)
git remote add outputstore "$pushgitremote"
# all results of this job will be put into a dedicated branch
git checkout -b "${BRANCH}"
# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original setup
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Do the run!
datalad get -r pennlinc-containers
datalad get -n -r "inputs/data/BIDS/${subid}"
# Reomve all subjects we're not working on
(cd inputs/data && rm -rf `find . -type d -name 'sub*' | grep -v $subid`)
datalad get -n "inputs/data/freesurfer"
FREESURFER_ZIP=$(ls inputs/data/freesurfer/${subid}_free*.zip | cut -d '@' -f 1 || true)

echo Freesurfer Zipfile
echo ${FREESURFER_ZIP}

if [ -z "${FREESURFER_ZIP}" ]; then
    echo "No freesurfer results found for ${subid}"
    exit 99
fi
datalad run \
    -i code/fmriprep_zip.sh \
    -i inputs/data/BIDS/${subid} \
    -i inputs/data/BIDS/*json \
    -i ${FREESURFER_ZIP} \
    --explicit \
    -o ${subid}_fmriprep-22.0.2.zip \
    --expand outputs \
    -m "fmriprep:22.0.2 ${subid}" \
    "bash ./code/fmriprep_zip.sh ${subid} ${FREESURFER_ZIP}"
# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore
# remove tempdir 
echo TMPDIR TO DELETE
echo ${BRANCH}
datalad drop -r . --nocheck
datalad uninstall -r inputs/data/BIDS
datalad uninstall -r inputs/data/freesurfer
git annex dead here
cd ../..
rm -rf $BRANCH
echo SUCCESS
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh

cat > code/fmriprep_zip.sh << "EOT"
#!/bin/bash
set -e -u -x
subid="$1"
freesurfer_zip="$2"
wd=${PWD}
cd inputs/data/freesurfer
7z x `basename ${freesurfer_zip}`
cd $wd
mkdir -p ${PWD}/.git/tmp/wdir
singularity run --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/fmriprep-22-0-2/image \
    inputs/data/BIDS \
    prep/fmriprep \
    participant \
    -w ${PWD}/.git/tmp/wkdir \
    --n_cpus 1 \
    --stop-on-first-crash \
    --fs-license-file code/license.txt \
    --skip-bids-validation \
    --output-spaces MNI152NLin6Asym:res-2 \
    --participant-label "$subid" \
    --force-bbr \
    --cifti-output 91k -v -v \
    --fs-subjects-dir inputs/data/freesurfer/freesurfer
cd prep
7z a ../${subid}_fmriprep-22.0.2.zip fmriprep
rm -rf prep .git/tmp/wkdir
EOT

chmod +x code/fmriprep_zip.sh

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

# Add a script for merging outputs
MERGE_POSTSCRIPT=https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic/merge_outputs_postscript.sh
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT
echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh
wget -qO- ${MERGE_POSTSCRIPT} >> code/merge_outputs.sh


################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"
echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in ${SUBJECTS}; do
  echo "qsub -cwd ${env_flags} -N fp${subject} ${eo_args} \
  ${PWD}/code/participant_job.sh \
  ${dssource} ${pushgitremote} ${subject} " >> code/qsub_calls.sh
done
datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
if [ "${BIDS_INPUT_METHOD}" = "clone" ]
then
    datalad uninstall -r --nocheck inputs/data
fi

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# Add an alias to the data in the RIA store
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

# if we get here, we are happy
echo SUCCESS
