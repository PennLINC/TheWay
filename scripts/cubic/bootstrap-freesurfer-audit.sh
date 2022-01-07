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
PROJECTROOT=${PWD}/freesurfer-audit
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
FREESURFER_INPUT=ria+file://${FMRIPREP_BOOTSTRAP_DIR}"/output_ria#~data"
if [[ -z ${FMRIPREP_BOOTSTRAP_DIR} ]]
then
    echo "Required argument is the path to the freesurfer bootstrap directory."
    echo "This directory should contain analysis/, input_ria/ and output_ria/."
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
cd $PROJECTROOT
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

datalad install -d . -r --source ${FREESURFER_INPUT} inputs/data
datalad uninstall inputs/data/inputs/data

# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'

SUBJECTS=$(find inputs/data -name '*.zip' | cut -d '/' -f 3 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=8G
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
# cd ${CBICA_TMPDIR}

TMPDIR=${CBICA_TMPDIR}
cd $TMPDIR

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
ZIPS_DIR=${PWD}/inputs/data

datalad get -n inputs/data
FS_INPUT_ZIP=$(ls inputs/data/${subid}_freesurfer*.zip | cut -d '@' -f 1 || true)
if [ ! -z "${FS_INPUT_ZIP}" ]; then
    FS_INPUT_ZIP="-i ${FS_INPUT_ZIP}"
fi

FMRI_INPUT_ZIP=$(ls inputs/data/${subid}_fmriprep*.zip | cut -d '@' -f 1 || true)
if [ ! -z "${FMRI_INPUT_ZIP}" ]; then
    FMRI_INPUT_ZIP="-i ${FMRI_INPUT_ZIP}"
fi

echo DATALAD RUN INPUT
echo ${FS_INPUT_ZIP}
echo ${FMRI_INPUT_ZIP}
datalad run \
    -i code/fs_euler_checker_and_plots_simplified.py \
    ${FS_INPUT_ZIP} \
    ${FMRI_INPUT_ZIP} \
    --explicit \
    -o csvs \
    -o svg \
    -m "freesurfer-audit ${subid}" \
    "python code/fs_euler_checker_and_plots_simplified.py ${subid} ${ZIPS_DIR}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir
echo TMPDIR TO DELETE
echo ${BRANCH}

datalad uninstall --nocheck --if-dirty ignore -r inputs/data
datalad drop -r . --nocheck
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS

EOT

chmod +x code/participant_job.sh

# Sydney, please wget your audit script here!
wget https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/generic/fs_euler_checker_and_plots_simplified.py
mv fs_euler_checker_and_plots_simplified.py code/
chmod +x code/fs_euler_checker_and_plots_simplified.py

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

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
datalad run -i 'csvs/*' -o 'concat_ds/group_report.csv' --expand inputs --explicit "python code/concatenator.py concat_ds/csvs ${PROJECT_ROOT}/XCP_AUDIT.csv"
datalad save -m "generated report"
# push changes
datalad push
# remove concat_ds
git annex dead here
cd ..
chmod +w -R concat_ds
rm -rf concat_ds
echo SUCCESS

#### concat_output.sh END ####

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

# Add an alias to the data in the RIA store
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

# if we get here, we are happy
echo SUCCESS
