## NOTE ##
# This script likely does not work
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

# The commit before everyone was run
GITHUB_URL="$1"
PRE_RUN_COMMIT="$2"

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/c-pac-1.8.5
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
datalad clone "$GITHUB_URL" analysis
cd analysis
git checkout -b prerun "${PRE_RUN_COMMIT}"
datalad get pennlinc-containers

# To list all the subjects
datalad get -n inputs/data

# Then get the subjects that you need to run
cd inputs/data
datalad get $(cat ${PROJECTROOT}/analysis/code/subs_to_run.txt)
cd ${PROJECTROOT}/analysis

# Now you have to delete the old outputstore

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}" --new-store-ok
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input "${input_store}" --new-store-ok

# # Push the input data to input storage and drop the copy in analysis
# cd ${PROJECTROOT}/analysis/inputs/data
# datalad push --to input
# datalad drop .

# # Push the container
# cd ${PROJECTROOT}/analysis/pennlinc-containers
# datalad push --to input $(cat ${PROJECTROOT}/analysis/code/subs_to_run.txt)
# datalad drop .

# No need to add logs to gitignore, it's already there
mkdir logs

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
echo '#!/bin/bash' > code/qsub_calls_rerun.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in $(cat ${PROJECTROOT}/analysis/code/subs_to_rerun.txt); do
    SESSIONS=$(ls  inputs/data/$subject | grep ses- | cut -d '/' -f 1)
    for session in ${SESSIONS}; do
        echo "qsub -cwd ${env_flags} -N c-pac_${subject} ${eo_args} \
        ${PWD}/code/participant_job.sh \
        ${dssource} ${pushgitremote} ${subject} ${session}" >> code/qsub_calls_rerun.sh
    done
done
datalad save -m "SGE submission setup" code/ .gitignore

for subses in $(cat ${PROJECTROOT}/analysis/code/subses_to_rerun.txt); do
    subject=$(echo $subses | cut -d '/' -f 1)
    session=$(echo $subses | cut -d '/' -f 2)
    echo "qsub -cwd ${env_flags} -N c-pac_${subject} ${eo_args} \
    ${PWD}/code/participant_job.sh \
    ${dssource} ${pushgitremote} ${subject} ${session}" >> code/qsub_calls_rerun.sh
done
################################################################################
# SGE SETUP END
################################################################################

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS
