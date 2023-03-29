set -e -u

###############################################################################
#                               HOW TO USE                                    #
#                                                                             #
#       Please adjust every variable within a "FIXME" markup to your          #
#       filesystem, data, and software container.                             #
#       Depending on which job scheduling system you use, comment out         #
#       or remove the irrelevant system (optional).                           #
#       More information about this script can be found in the README.        #
#                                                                             #
###############################################################################


# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# The bucket name is needed, and the bucket must be created before you run this
# script. Here, for example we'd need to run
#
# $ s3cmd mb s3://datalad_s3_test_output
#

bucket_name="datalad_s3_test_output"

# Set up your s3 credentials in the datalad-specific env variables:
DATA=`s3info keys --machine-output`
if [[ $? -eq 0 ]]
then
  read -r ACCESS_KEY SECRET_KEY <<< "$DATA"
  export AWS_ACCESS_KEY_ID=$ACCESS_KEY
  export AWS_SECRET_ACCESS_KEY=$SECRET_KEY
fi

# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


# ------------------------------------------------------------------------------
# FIXME: Supply the name of container you have registered (see README for info)
# FIXME: Supply a path or URL to the place where your container dataset is
# located, and a path or URL to the place where an input (super)dataset exists.
containername='bids-fmriprep'
container="https://github.com/ReproNim/containers.git"
data="https://github.com/psychoinformatics-de/studyforrest-data-structural.git"
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


#-------------------------------------------------------------------------------
# FIXME: Replace this name with a dataset name of your choice.
bootstrap_root=$PWD
source_ds="analysis"
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda $source_ds
cd $source_ds

# clone the container-dataset as a subdataset. Please see README for
# instructions how to create a container dataset.
datalad clone -d . "${container}" code/pipeline

# Register the container in the top-level dataset.
#-------------------------------------------------------------------------------
# FIXME: If necessary, configure your own container call in the --call-fmt
# argument. If your container does not need a custom call format, remove the
# --call-fmt flag and its options below.
# This container call-format is customized to execute an fmriprep call defined
# in a separate script, and does not need modifications if you stick to
# fmriprep.
datalad containers-add \
  --call-fmt 'singularity exec -B {{pwd}} --cleanenv {img} {cmd}' \
  -i code/pipeline/images/bids/bids-fmriprep--20.2.0.sing \
  $containername
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


# amend the previous commit with a nicer commit message
git commit --amend -m 'Register pipeline dataset'


# import custom code
# ------------------------------------------------------------------------------
# FIXME: If you need custom scripts, copy them into the analysis source
# dataset. If you don't need custom scripts, remove the copy and commit
# operations below. A freesurfer license file (expected to lie in your home
# directory is copied into the dataset in order to be available for fmriprep
cp ~/license.txt code/license.txt
datalad save -m "Add Freesurfer license file"
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
input_store=ria+file://${bootstrap_root}/input_ria
output_store=ria+file://${bootstrap_root}/output_ria
datalad create-sibling-ria -s input --storage-sibling off --new-store-ok "${input_store}"
datalad create-sibling-ria -s output --storage-sibling off --new-store-ok "${output_store}"
pushremote=$(git remote get-url --push output)

# Add the s3 output
git annex initremote "output-storage-s3" \
    type=S3 \
    autoenable=true \
    bucket=${bucket_name} \
    encryption=none \
    host=s3.msi.umn.edu \
    partsize=1GiB \
    port=443 \
    public=no

# register the input dataset
datalad clone -d . ${data} inputs/data
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'



# the actual compute job specification. This is a bash script that is used to
# perform the computation in a job. It is fully portable, and this portability
# is crucial for infrastructure-independent recomputations.
cat > code/participant_job << "EOT"
#!/bin/bash

# the job assumes that it is a good idea to run everything in PWD
# the job manager should make sure that is true

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

dssource="$1"
pushgitremote="$2"

# Set up your s3 credentials in the datalad-specific env variables:
DATA=`s3info keys --machine-output`
if [[ $? -eq 0 ]]
then
  read -r ACCESS_KEY SECRET_KEY <<< "$DATA"
  export AWS_ACCESS_KEY_ID=$ACCESS_KEY
  export AWS_SECRET_ACCESS_KEY=$SECRET_KEY
fi

# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results too, in order to avoid too many jobs blocking access to
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
git remote add output "$pushgitremote"


# all results of this job will be put into a dedicated branch
git checkout -b "job-$JOBID"

# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original Condor setup
# datalad get -n "inputs/data/${subid}"

# ------------------------------------------------------------------------------
# FIXME: Replace the datalad containers-run command starting below with a
# command that fits your analysis. Here, it invokes the script "runfmriprep.sh"
# that contains an fmriprep parametrization.

datalad run -o ${JOBID}.txt "echo ${JOBID} > ${JOBID}.txt"


# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


# push result file content first - does not need a lock, no interaction with Git
datalad push --to output-storage-s3

# and the output branch next - needs a lock to prevent concurrency issues
flock --verbose $DSLOCKFILE git push output

echo SUCCESS
# job handler should clean up workspace
EOT
chmod +x code/participant_job
datalad save -m "Participant compute job implementation"

mkdir logs
echo logs >> .gitignore

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
