## NOTE ##
# This workflow is derived from the Datalad Handbook

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


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/fmriprep-multises-audit
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
    echo "Required argument is the path to the fmriprep bootstrap directory."
    echo "This directory should contain analysis/, input_ria/ and output_ria/."
    # exit 1
fi

# Is it a directory on the filesystem?
FMRIPREP_INPUT_METHOD=clone
if [[ ! -d "${FMRIPREP_BOOTSTRAP_DIR}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "fmriprep output dataset"
    # exit 1
fi

# Check that there are some fmriprep zip files present in the input
# If you only need freesurfer, comment this out
# FMRIPREP_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *fmriprep*.zip)
# if [[ -z "${FMRIPREP_ZIPS}" ]]; then
#    echo No fmriprep zip files found in ${FMRIPREP_INPUT}
#    exit 1
# fi

# Check that freesurfer data exists. If you only need fmriprep zips, comment
# this out
# FREESURFER_ZIPS=$(cd ${FMRIPREP_INPUT} && ls *freesurfer*.zip)
# if [[ -z "${FREESURFER_ZIPS}" ]]; then
#    echo No freesurfer zip files found in ${FMRIPREP_INPUT}
#    exit 1
# fi

## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}


# Create a dataset with the logs in it
mkdir fmriprep_logs
cd fmriprep_logs
datalad create -D "Logs from the fmriprep runs"
cp ${FMRIPREP_BOOTSTRAP_DIR}/analysis/logs/* .
datalad save -m "add logs"

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
datalad install -d . -r --source ${PROJECTROOT}/fmriprep_logs inputs/fmriprep_logs

# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'

SUBJECTS=$(find inputs/data -type d -name 'sub-*' | cut -d '/' -f 5 )
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

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
sesid="$4"

# change into the cluster-assigned temp directory. Not done by default in SGE
cd ${CBICA_TMPDIR}

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}-${sesid}"
mkdir ${BRANCH}
cd ${BRANCH}
datalad clone "${dssource}" ds
cd ds
git remote add outputstore "$pushgitremote"
git checkout -b "${BRANCH}"

# ------------------------------------------------------------------------------
# Do the run!
BIDS_DIR=${PWD}/inputs/data/inputs/data
ZIPS_DIR=${PWD}/inputs/data
ERROR_DIR=${PWD}/inputs/fmriprep_logs
CSV_DIR=csvs
mkdir ${CSV_DIR}
output_file=${CSV_DIR}/${subid}_${sesid}_fmriprep_audit.csv

datalad get -n inputs/data

INPUT_ZIP=$(ls inputs/data/${subid}_${sesid}_fmriprep*.zip | cut -d '@' -f 1 || true)
if [ ! -z "${INPUT_ZIP}" ]; then
    INPUT_ZIP="-i ${INPUT_ZIP}"
fi

echo DATALAD RUN INPUT
echo ${INPUT_ZIP}

datalad run \
    -i code/bootstrap-fmriprep-multises-audit.py \
    ${INPUT_ZIP} \
    -i inputs/data/inputs/data/${subid} \
    -i inputs/fmriprep_logs/*${subid}*${sesid}* \
    --explicit \
    -o ${output_file} \
    -m "fmriprep-audit ${subid} ${sesid}" \
    "python code/bootstrap-fmriprep-multises-audit.py ${subid}_${sesid} ${BIDS_DIR} ${ZIPS_DIR} ${ERROR_DIR} ${output_file}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

echo TMPDIR TO DELETE
echo ${BRANCH}

datalad uninstall -r --nocheck --if-dirty ignore inputs/data
datalad drop -r . --nocheck
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh

# Sydney, please wget your audit script here!
wget https://raw.githubusercontent.com/PennLINC/RBC/master/PennLINC/Generic/bootstrap-fmriprep-multises-audit.py
mv bootstrap-fmriprep-multises-audit.py code/
chmod +x code/bootstrap-fmriprep-multises-audit.py

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Add logs from fmriprep runs"

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
    git merge -m "fmriprep results batch ${chunknum}/${num_chunks}" $(cat ${batch_file})

done

# Push the merge back
git push

# Get the file availability info
git annex fsck --fast -f output-storage

# This should not print anything
set +u
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

##### concat_outputs.sh START ####

cat > code/concat_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT

echo "PROJECT_ROOT=${PROJECTROOT}" >> code/concat_outputs.sh
echo "cd ${PROJECTROOT}" >> code/concat_outputs.sh

cat >> code/concat_outputs.sh << "EOT"
# set up concat_ds and run concatenator on it
cd ${CBICA_TMPDIR}
datalad clone ria+file://${PROJECT_ROOT}/output_ria#~data concat_ds
cd concat_ds/code
wget https://raw.githubusercontent.com/PennLINC/RBC/master/PennLINC/Generic/concatenator.py
cd ..
datalad save -m "added concatenator script"
datalad run -i 'csvs/*' -o '${PROJECT_ROOT}/FMRIPREP_AUDIT.csv' --expand inputs --explicit "python code/concatenator.py csvs ${PROJECT_ROOT}/FMRIPREP_AUDIT.csv"
datalad save -m "generated report"
# push changes
datalad push
# remove concat_ds
git annex dead here
cd ..
chmod +w -R concat_ds
rm -rf concat_ds
echo SUCCESS

EOT

#### concat_output.sh END ####

env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"

echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in ${SUBJECTS}; do
  SESSIONS=$(ls  inputs/data/inputs/data/$subject | grep ses- | cut -d '/' -f 1)
  for session in ${SESSIONS}; do
    echo "qsub -cwd ${env_flags} -N audit${subject}_${session} ${eo_args} \
    ${PWD}/code/participant_job.sh \
    ${dssource} ${pushgitremote} ${subject} ${session}" >> code/qsub_calls.sh
  done
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

# Add an alias to the data in the RIA store
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

# if we get here, we are happy
echo SUCCESS
