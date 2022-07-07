## NOTE ##
# This workflow is derived from the Datalad Handbook

# USAGE: $0 bids-dir fmriprep-version

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u

VERSION=$2

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/fmriprep-${VERSION}
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

FMRIPREP_BOOTSTRAP_DIR=$1
FMRIPREP_INPUT=ria+file://${FMRIPREP_BOOTSTRAP_DIR}"/output_ria#~data"
if [[ -z ${FMRIPREP_BOOTSTRAP_DIR} ]]
then
    echo "Required argument is the path to the freesurfer bootstrap directory."
    echo "This directory should contain analysis/, input_ria/ and output_ria/."
    # exit 1
fi

# Is it a directory on the filesystem?
FMRIPREP_INPUT_METHOD=clone
if [[ ! -d "${FMRIPREP_BOOTSTRAP_DIR}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "freesurfer output dataset"
    # exit 1
fi

# Check that there are some freesurfer zip files present in the input
# If you only need freesurfer, comment this out
# FREESURFER_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *freesurfer*.zip)
# if [[ -z "${FREESURFER_ZIPS}" ]]; then
#    echo No freesurfer zip files found in ${FMRIPREP_INPUT}
#    exit 1
# fi

# Check that freesurfer data exists. If you only need freesurfer zips, comment
# this out
# FREESURFER_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *freesurfer*.zip)
# if [[ -z "${FREESURFER_ZIPS}" ]]; then
#    echo No freesurfer zip files found in ${FMRIPREP_INPUT}
#    exit 1
# fi

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
cd $PROJECTROOT
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

datalad install -d . -r --source ${FMRIPREP_INPUT} inputs/data

# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'

SUBJECTS=$(cat ~/fmriprep-bug-check/pnc_exemplars.txt)

## the actual compute job specification
cat > code/participant_job.sh << "EOT"

#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=5G
#$ -l s_vmem=3.5G
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
#cd /cbica/comp_space/$(basename $HOME)

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}
datalad clone "${dssource}" ds
cd ds
git remote add outputstore "$pushgitremote"
git checkout -b "${BRANCH}"
# ------------------------------------------------------------------------------
# Do the run!

# Do the run!

BIDS_DIR=${PWD}/inputs/data/inputs/data
ZIPS_DIR=${PWD}/inputs/data
ERROR_DIR=${PWD}/inputs/freesurfer_logs
CSV_DIR=csvs
mkdir ${CSV_DIR}
datalad get -n inputs/data
INPUT_ZIP=$(ls inputs/data/${subid}_fmriprep*.zip | cut -d '@' -f 1 || true)

echo DATALAD RUN INPUT
echo ${INPUT_ZIP}
datalad get ${INPUT_ZIP}
datalad unlock ${INPUT_ZIP}

BOLDREFS=$(bsdtar -tf ${INPUT_ZIP} | grep 152NLin6Asym_res-2_boldref)
MNI_DSEG=$(bsdtar -tf ${INPUT_ZIP} | grep func | grep aparc)
datalad save
set +u
OUTPUTS=""
for fname in $BOLDREFS $MNI_DSEG
do
    OUTPUTS="-o $fname $OUTPUTS"
    OUTPUT_FILES="$fname $OUTPUT_FILES"
done

set -u

datalad run \
    -i ${INPUT_ZIP} \
    ${OUTPUTS} \
    --explicit \
    -m "get warped files ${subid}" \
    "echo ${OUTPUT_FILES} | xargs 7z x -aoa ${INPUT_ZIP}"
    
# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir 
echo TMPDIR TO DELETE
echo ${BRANCH}

datalad drop -r . --nocheck
datalad uninstall -r inputs/data
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS
# job handler should clean up workspace


EOT

chmod +x code/participant_job.sh

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Add code for extracting data"

################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT

echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh

cat >> code/merge_outputs.sh << "EOT"
datalad clone ${outputsource} merge_ds
cd merge_ds
NBRANCHES=$(git branch -a | grep job- | sort | wc -l)
echo "Found $NBRANCHES branches to merge"
gitref=$(git show-ref master | cut -d ' ' -f1 | head -n 1)
# query all branches for the most recent commit and check if it is identical.
# Write all branch identifiers for jobs without outputs into a file.
for i in $(git branch -a | grep job- | sort); do [ x"$(git show-ref $i \
  | cut -d ' ' -f1)" = x"${gitref}" ] && \
  echo $i; done | tee code/noresults.txt | wc -l
for i in $(git branch -a | grep job- | sort); \
  do [ x"$(git show-ref $i  \
     | cut -d ' ' -f1)" != x"${gitref}" ] && \
     echo $i; \
done | tee code/has_results.txt
mkdir -p code/merge_batches
num_branches=$(wc -l < code/has_results.txt)
CHUNKSIZE=5000
set +e
num_chunks=$(expr ${num_branches} / ${CHUNKSIZE})
[[ $num_chunks == 0 ]] && num_chunks=1
set -e -x
for chunknum in $(seq 1 $num_chunks)
do
    startnum=$(expr $(expr ${chunknum} - 1) \* ${CHUNKSIZE} + 1)
    endnum=$(expr ${chunknum} \* ${CHUNKSIZE})
    batch_file=code/merge_branches_$(printf %04d ${chunknum}).txt
    [[ ${num_branches} -lt ${endnum} ]] && endnum=${num_branches}
    branches=$(sed -n "${startnum},${endnum}p;$(expr ${endnum} + 1)q" code/has_results.txt)
    echo ${branches} > ${batch_file}
    git merge -m "freesurfer results batch ${chunknum}/${num_chunks}" $(cat ${batch_file})
done
# Push the merge back
git push
# Get the file availability info
git annex fsck --fast -f output-storage
# This should not print anything
MISSING=$(git annex find --not --in output-storage)
if [[ ! -z "$MISSING" ]]
then
    echo Unable to find data for $MISSING
    exit 1
fi
# stop tracking this branch
git annex dead here
datalad push --data nothing
echo SUCCESS
EOT


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
datalad uninstall -r --nocheck inputs/data

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS
