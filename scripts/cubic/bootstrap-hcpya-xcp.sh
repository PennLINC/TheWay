## NOTE ##
# This workflow is derived from the Datalad Handbook

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

##  hcp input
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

#get the workhorse script
wget -O code/xcp-hcpya-bootstrap.py https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic/xcp-hcpya-bootstrap.py

cat >> code/dataset_description.json << "EOT"
{
    "Name": "fMRIPrep - fMRI PREProcessing workflow",
    "BIDSVersion": "1.4.0",
    "DatasetType": "derivative",
    "GeneratedBy": [
        {
            "Name": "fMRIPrep",
            "Version": "20.2.1",
            "CodeURL": "https://github.com/nipreps/fmriprep/archive/20.2.1.tar.gz"
        }
    ],
    "HowToAcknowledge": "Please cite our paper (https://doi.org/10.1038/s41592-018-0235-4), and include the generated citation boilerplate within the Methods section of the text."
}
EOT

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"


echo "Cloning input dataset into analysis dataset"
datalad clone -d . ${BIDSINPUT} inputs/data
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'


SUBJECTS=$(find inputs/data/HCP1200/ -maxdepth 1 | cut -d '/' -f 4 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

cd ${PROJECTROOT}

# Clone the containers dataset. If specified on the command, use that path

#MUST BE AS NOT RBC USER
# build the container in /cbica/projects/hcpya/dropbox
# singularity build xcp-abcd-0.0.4.sif docker://pennlinc/xcp_abcd:0.0.4

#AS RBC
# then copy to /cbica/projects/hcpya/xcp-abcd-container
# datalad create -D "xcp-abcd container".
# do that actual copy
# datalad containers-add --url ~/dropbox/xcp-abcd-0.0.4.sif xcp-abcd-0.0.4 --update

#can delete
#rm /cbica/projects/hcpya/dropbox/xcp-abcd-0.0.4.sif

CONTAINERDS=~/xcp-abcd-container
datalad clone ${CONTAINERDS} pennlinc-containers

cd ${PROJECTROOT}/analysis
datalad install -d . --source ${PROJECTROOT}/pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=12G

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
#cd ${CBICA_TMPDIR}
# OR Run it on a shared network drive
cd /cbica/comp_space/$(basename $HOME)
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
echo GIT CHECKOUT FINISHED
# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original setup
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Do the run!
datalad get -r pennlinc-containers
echo GET CONTAINERS FINISHED
datalad run \
    -i code/xcp-hcpya-bootstrap.py \
    -i code/dataset_description.json \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*Atlas_MSMAll.dtseries.nii \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*LR.nii.gz* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*RL.nii.gz* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/Movement_AbsoluteRMS.txt \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/Movement_Regressors.txt \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/SBRef_dc.nii.gz \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*SBRef.nii.gz* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*CSF.txt* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/*WM.txt* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/ROIs/*2.nii.gz* \
    -i inputs/data/HCP1200/${subid}/MNINonLinear/Results/**/brainmask_fs.2.nii.gz \
    --explicit \
    -o ${subid}_xcp-0-0-4.zip \
    -m "xcp-abcd-run ${subid}" \
    "python code/xcp-hcpya-bootstrap.py ${subid}"
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
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh


cp ${FREESURFER_HOME}/license.txt code/license.txt

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
  echo "qsub -cwd ${env_flags} -N xcp${subject} ${eo_args} \
  ${PWD}/code/participant_job.sh \
  ${dssource} ${pushgitremote} ${subject} " >> code/qsub_calls.sh
done
chmod a+x code/qsub_calls.sh
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

#run last sge call to test
#$(tail -n 1 code/qsub_calls.sh)

#submit the jobs as a job 
#chmod a+x code/qsub_calls.sh
#qsub -l h_vmem=4G,s_vmem=4G -V -j y -b y -o /cbica/projects/hcpya/xcp/analysis/logs code/qsub_calls.sh
