## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
conda activate
if [ $? -gt 0 ]; then
    echo "Error initializing conda. Exiting"
    exit $?
fi

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/fmriprep
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    #exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    #exit 1
fi


## Check the BIDS input
BIDSINPUT=/cbica/projects/RBC/testing/way2/exemplars
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
    set +e
    BIDS_DATALAD_ID=$(datalad -f '{infos[dataset][id]}' wtf -S dataset -d ${BIDSINPUT})
    #set -e
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

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

# register the input dataset
if [[ "${BIDS_INPUT_METHOD}" == "clone" ]]
then
    echo "Cloning input dataset into analysis dataset"
    datalad clone -d . ${BIDSINPUT} inputs/data
    # amend the previous commit with a nicer commit message
    git commit --amend -m 'Register input data dataset as a subdataset'
else
    echo "Copying input data into "
    mkdir inputs
    datalad create -d . inputs/data
    cp -rv ${BIDSINPUT}/* inputs/data
    datalad save -r -m "added input data"
fi

SUBJECTS=$(ls -d inputs/data/* | grep sub- | cut -d "/" -f 3 )
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    exit 1
fi


## Add the containers as a subdataset
datalad clone -d . ria+ssh://sciget.pmacs.upenn.edu:/project/bbl_project/containers#~pennlinc-containers
# download the image so we don't ddos pmacs
datalad get pennlinc-containers/.datalad/environments/fmriprep-20-2-1/image
.datalad/environments/fmriprep-20-2-1


## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=25G
#$ -l s_vmem=23.5G
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
datalad get -n "inputs/data/${subid}"

# Reomve all subjects we're not working on
(cd inputs/data && rm -rf `find . -type d -name 'sub*' | grep -v $subid`)

# ------------------------------------------------------------------------------
# Do the run!

datalad run \
    -m "copy ${subid}" \
    -i code/fmriprep_zip.sh \
    -i inputs/data/${subid} \
    -i pennlinc-containers/.datalad/environments/fmriprep-20-2-1/image
.datalad/environments/fmriprep-20-2-1 \
    -o ${subid}_fmriprep-20-2-1.tar.gz \
    -o ${subid}_freesurfer-20-2-1.tar.gz \
    "./code/fmriprep_zip.sh ${subid}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

echo SUCCESS
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh

cat > code/fmriprep_zip.sh << "EOT"
#!/bin/bash
set -e -u -x

subid="$1"
mkdir -p ${PWD}/.git/tmp/wdir
singularity run --cleanenv -B ${PWD} \
    pennlinc-containers.datalad/environments/fmriprep-20-2-1/image
.datalad/environments/fmriprep-20-2-1/image \
    inputs/data \
    prep \
    participant \
    -w ${PWD}/.git/wkdir \
    --n_cpus 1 \
    --skip-bids-validation \
    --participant-label "$subid" \
    --force-bbr \
    --cifti-output 91k -v -v

tar cvfz -C prep ${subid}_fmriprep-20-2-1.tar.gz fmriprep
tar cvfz -C prep ${subid}_freesurfer-20-2-1.tar.gz freesurfer
rm -rf prep .git/tmp/wkdir

EOT

chmod +x code/fmriprep_zip.sh
cp ${FREESURFER_HOME}/license.txt code/license.txt

datalad save -m "Participant compute job implementation"

mkdir logs
echo logs >> .gitignore

mkdir logs
echo logs >> .gitignore


################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################

echo .SGE_datalad_lock >> .gitignore
env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
for subject in sub-01 sub-02 sub-03 sub-04; do
  echo "qsub -cwd ${env_flags} ${eo_args} \
  ${PWD}/code/participant_job \
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