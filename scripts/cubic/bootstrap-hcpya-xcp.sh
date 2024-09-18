#!/bin/bash

## NOTE ##
# This workflow is derived from the Datalad Handbook

# Change these as needed
CONTAINERDS=/cbica/projects/RBC/production/xcpd-0.9.1-container
SUBJECT_LIST=/cbica/projects/RBC/production/HCP-YA/fmri_list.txt

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/xcp
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

# Make a directory for templateflow
TEMPLATEFLOW_HOME=${PROJECTROOT}/TEMPLATEFLOW_HOME
mkdir -p ${TEMPLATEFLOW_HOME}

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
datalad create-sibling-ria --new-store-ok -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --new-store-ok --storage-sibling off "${input_store}"

cd ${PROJECTROOT}

datalad clone ${CONTAINERDS} pennlinc-containers

cd ${PROJECTROOT}/analysis
datalad install -d . --source ${PROJECTROOT}/pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=80G
#SBATCH --tmp=250G
#SBATCH --time=10:00:00
# Uncomment after the test run finishes
###SBATCH --array=2-ARRAYREPLACEME
#SBATCH --array=1-1
#SBATCH --output=../logs/xcp_d-%A_%a.out
#SBATCH --error=../logs/xcp_d-%A-%a.err

# Filled in during the bootstrap
EOT
{
    echo "SUBJECT_LIST=${SUBJECT_LIST}";
    echo "DSLOCKFILE=${PWD}/.datalad_lock";
    echo "dssource=${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)";
    echo "pushgitremote=$(git remote get-url --push output)";
    echo "export TEMPLATEFLOW_HOME=${TEMPLATEFLOW_HOME}";
} >> code/participant_job.sh

cat >> code/participant_job.sh << "EOT"
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x
# Set up the remotes from the call
subid=$(head -n ${SLURM_ARRAY_TASK_ID} ${SUBJECT_LIST} | tail -n 1)

cd /cbica/comp_space/RBC
# Used for the branch names and the temp dir
BRANCH="job-${SLURM_JOB_ID}-${subid}"
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

# Fetch the sif file
datalad get -r pennlinc-containers

# Do the run!
datalad run \
    --explicit \
    -o ${subid}_xcp-0.9.1.zip \
    -m "Run XCPD on ${subid}" \
    "bash code/hcp_download_and_run.sh ${subid}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage

# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir
echo TMPDIR TO DELETE
echo ${BRANCH}
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS
# job handler should clean up workspace
EOT

# Set it up so that the array knows how many jobs to run
njobs=$(wc -l ${SUBJECT_LIST} | cut -d ' ' -f 1)
sed -i "s/ARRAYREPLACEME/${njobs}/g" code/participant_job.sh

chmod +x code/participant_job.sh

mkdir logs
{
    echo .datalad_lock;
    echo logs;
    echo HCP-YA/;
} >> .gitignore


# The actual code that is datalad run
cat > code/hcp_download_and_run.sh << "EOT"
#!/bin/bash

set -eux
subid="${1}"
WD=${PWD}

# Create the input dataset into the working directory
mkdir -p HCP-YA/${subid}
cd HCP-YA/${subid}
datalad clone \
    https://hub.datalad.org/hcp-openaccess/${subid}-mninonlinear.git \
    MNINonLinear

# Download only the files we need for XCPD
cd MNINonLinear
datalad get \
    Results/?fMRI_*/SBRef_dc.nii.gz \
    Results/?fMRI_*/?fMRI_*_??.nii.gz \
    Results/?fMRI_*/?fMRI_*_??_Atlas_MSMAll.dtseries.nii \
    Results/?fMRI_*/Movement_Regressors.txt \
    Results/?fMRI_*/Movement_AbsoluteRMS.txt \
    Results/?fMRI_*/brainmask_fs.2.nii.gz \
    fsaverage_LR32k/*L.pial.32k_fs_LR.surf.gii \
    fsaverage_LR32k/*R.pial.32k_fs_LR.surf.gii \
    fsaverage_LR32k/*L.white.32k_fs_LR.surf.gii \
    fsaverage_LR32k/*R.white.32k_fs_LR.surf.gii \
    fsaverage_LR32k/*.L.thickness.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.R.thickness.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.L.corrThickness.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.R.corrThickness.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.L.curvature.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.R.curvature.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.L.sulc.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.R.sulc.32k_fs_LR.shape.gii \
    fsaverage_LR32k/*.L.MyelinMap.32k_fs_LR.func.gii \
    fsaverage_LR32k/*.R.MyelinMap.32k_fs_LR.func.gii \
    fsaverage_LR32k/*.L.SmoothedMyelinMap.32k_fs_LR.func.gii \
    fsaverage_LR32k/*.R.SmoothedMyelinMap.32k_fs_LR.func.gii \
    T1w.nii.gz \
    aparc+aseg.nii.gz \
    brainmask_fs.nii.gz \
    ribbon.nii.gz
cd ${WD}


# Run xcpd!
mkdir -p ${PWD}/.git/tmp/wkdir
apptainer run --containall \
    -B "${PWD}" \
    -B "${FREESURFER_HOME}"/license.txt:/license.txt \
    -B "${TEMPLATEFLOW_HOME}:/templateflow_home" \
    --env "TEMPLATEFLOW_HOME=/templateflow_home" \
    ${PWD}/pennlinc-containers/.datalad/environments/xcpd-0-9-1/image \
    "${PWD}/HCP-YA" \
    "${PWD}/xcpd-0-9-1" \
    participant \
    --participant-label ${subid} \
    --mode linc \
    --input-type hcp \
    --combine-runs \
    -w "${PWD}/.git/tmp/wkdir" \
    --omp-nthreads ${NSLOTS} \
    --nprocs ${NSLOTS} \
    --atlases \
        4S1056Parcels \
        4S156Parcels \
        4S256Parcels \
        4S356Parcels \
        4S456Parcels \
        4S556Parcels \
        4S656Parcels \
        4S756Parcels \
        4S856Parcels \
        4S956Parcels \
        Glasser \
        Gordon \
        HCP \
        Tian \
    --fs-license-file /license.txt \
    --stop-on-first-crash \
    -vv

# Zip the output directory
rm -rfv xcpd-0-9-1/atlases
7z a ${subid}_xcpd-0.9.1.zip xcpd-0-9-1
rm -rf prep .git/tmp/wkdir
EOT

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

datalad save -m "finish setup" code/ .gitignore


# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS
