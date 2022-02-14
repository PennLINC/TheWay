#!/bin/bash
# This workflow is derived from the Datalad Handbook

set -euf -o pipefail

usage() {
    # Note that errors are sent to STDERR
    echo "$0 --bids-input ria+file:///path/to/bids  --container-ds /path/or/uri/to/containers" 1>&2
    echo 1>&2
    echo "$*" 1>&2
    exit 1
}

checkandexit() {
    if [ $? != 0 ]; then
        # there was an error
        echo "$2" 1>&2
        exit $1
    fi
}

BIDSINPUT=""
CONTAINERDS=""
FILTERFILE=""
OUTDIR="mimosa"
##### CLI parsing
while [ ${1-X} != "X" ]; do
    case $1 in
    -i | --bids-input)
        shift
        BIDSINPUT=$1
        shift
        ;;

    -c | --container-ds)
        shift
        CONTAINERDS=$1
        shift
        ;;

    -f | --filter-file)
        shift
        FILTERFILE=$1
        shift
        ;;

    -o | --outdir)
        shift
        OUTDIR=$1
        shift
        ;;

    *)
        usage "Unrecognized argument: \"$1\""
        ;;
    esac
done

DATALAD_VERSION=$(datalad --version)
checkandexit $? "No datalad available in your conda environment; try pip install datalad"

echo USING DATALAD VERSION ${DATALAD_VERSION}

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/${OUTDIR}
test ! -d ${PROJECTROOT}
checkandexit $? "${PROJECTROOT} already exists"

test -w $(dirname ${PROJECTROOT})
checkandexit $? "Unable to write to ${PROJECTROOT}'s parent. Change permissions and retry"

## Check the BIDS input
test ! -z ${BIDSINPUT}
checkandexit $? "--bids-input is a required argument"

## Check the container DS
test ! -z ${CONTAINERDS}
checkandexit $? "--container-ds is a required argument"

# If we were given a filter file, check that it exists
test ! -z ${FILTERFILE} || true && test -f ${FILTERFILE}
checkandexit $? "Was given the filter file: '${FILTERFILE}' but no such file exists"

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
echo "Cloning input dataset into analysis dataset"
datalad clone -d . ${BIDSINPUT} inputs/data
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register input data dataset as a subdataset'

SUBJECTS=$(find inputs/data -type d -name 'sub-*' | cut -d '/' -f 3)
test ! -z "${SUBJECTS}"
checkandexit $? "No subjects found in input data"

cd ${PROJECTROOT}/analysis
datalad install -d . --source ${CONTAINERDS} pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
subid="$3"

# change into the cluster-assigned temp directory. Not done by default in LSF
cd ${TMPDIR}
# OR Run it on a shared network drive
# cd /cbica/comp_space/$(basename $HOME)

# Used for the branch names and the temp dir
BRANCH="job-${LSB_JOBID}-${subid}"
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

# Remove all subjects we're not working on
(cd inputs/data && rm -rf `find . -type d -name 'sub*' | grep -v $subid`)


# ------------------------------------------------------------------------------
# Do the run!

if [ $# -eq 4 ]; then
    datalad run \
        -i code/mimosa_zip.sh \
        -i inputs/data/${subid} \
        -i inputs/data/dataset_description.json \
        -i pennlinc-containers/.datalad/environments/mimosa-0-2-1/image \
        -i $4 \
        --explicit \
        -o ${subid}_mimosa-0.2.1.zip \
        -m "mimosa:0.2.1 ${subid}" \
        "bash ./code/mimosa_zip.sh ${subid} ${4}"
else
    datalad run \
        -i code/mimosa_zip.sh \
        -i inputs/data/${subid} \
        -i inputs/data/dataset_description.json \
        -i pennlinc-containers/.datalad/environments/mimosa-0-2-1/image \
        --explicit \
        -o ${subid}_mimosa-0.2.1.zip \
        -m "mimosa:0.2.1 ${subid}" \
        "bash ./code/mimosa_zip.sh ${subid}"
fi

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

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

cat > code/mimosa_zip.sh << "EOT"
#!/bin/bash
set -e -u -x

export SINGULARITYENV_CORES=1
export SINGULARITYENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
export SINGULARITYENV_OMP_NUM_THREADS=1
export SINGULARITYENV_OMP_THREAD_LIMIT=1
export SINGULARITYENV_MKL_NUM_THREADS=1
export SINGULARITYENV_OPENBLAS_NUM_THREADS=1
export SINGULARITYENV_TMPDIR=$TMPDIR

subid="$1"

if [ $# -eq 2 ]; then
    filterfile=$2

    singularity run --cleanenv -B ${PWD} -B ${TMPDIR} \
        pennlinc-containers/.datalad/environments/mimosa-0-2-1/image \
        inputs/data \
        mimosa \
        participant \
        --participant_label $(echo $subid | cut -d '-' -f 2) \
        --bids-filter-file $filterfile \
        --strip mass \
        --n4 \
        --register \
        --whitestripe \
        --thresh 0.25 \
        --debug \
        --skip_bids_validator
else
    singularity run --cleanenv -B ${PWD} -B ${TMPDIR} \
        pennlinc-containers/.datalad/environments/mimosa-0-2-1/image \
        inputs/data \
        mimosa \
        participant \
        --participant_label $(echo $subid | cut -d '-' -f 2) \
        --strip mass \
        --n4 \
        --register \
        --whitestripe \
        --thresh 0.25 \
        --debug \
        --skip_bids_validator
fi

outdirs=$(ls | grep mimosa)
7z a ${subid}_mimosa-0.2.1.zip $outdirs
rm -rf $outdirs

EOT

chmod +x code/mimosa_zip.sh

mkdir logs
echo .LSF_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

# Add a script for merging outputs
cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT
echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh

cat >> code/merge_outputs.sh << "EOT"

# The following should be pasted into the merge_outputs.sh script
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
if [[ $num_chunks == 0 ]]; then
    num_chunks=1
fi
set -e
for chunknum in $(seq 1 $num_chunks)
do
    startnum=$(expr $(expr ${chunknum} - 1) \* ${CHUNKSIZE} + 1)
    endnum=$(expr ${chunknum} \* ${CHUNKSIZE})
    batch_file=code/merge_branches_$(printf %04d ${chunknum}).txt
    [[ ${num_branches} -lt ${endnum} ]] && endnum=${num_branches}
    branches=$(sed -n "${startnum},${endnum}p;$(expr ${endnum} + 1)q" code/has_results.txt)
    echo ${branches} > ${batch_file}
    git merge -m "merge results batch ${chunknum}/${num_chunks}" $(cat ${batch_file})

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


################################################################################
# LSF SETUP START - remove or adjust to your needs
################################################################################
echo '#!/bin/bash' > code/bsub_calls.sh
echo "export DSLOCKFILE=${PWD}/.LSF_datalad_lock" >> code/bsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs -n 1 -R 'rusage[mem=20000]'"
if [ ! -z "${FILTERFILE}" ]; then
    cp ${FILTERFILE} code/filterfile.json
    FILTERFILE="code/filterfile.json"
fi
for subject in ${SUBJECTS}; do
    echo "bsub ${eo_args} \
        ${PWD}/code/participant_job.sh \
        ${dssource} ${pushgitremote} ${subject} ${FILTERFILE}" >> code/bsub_calls.sh
done
datalad save -m "LSF submission setup" code/ .gitignore

################################################################################
# LSF SETUP END
################################################################################

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
datalad uninstall -r --nocheck inputs/data

# Add an alias to the data in the RIA store
RIA_DIR=$(find $PROJECTROOT/output_ria/???/ -maxdepth 1 -type d | sort | tail -n 1)
mkdir -p ${PROJECTROOT}/output_ria/alias
ln -s ${RIA_DIR} ${PROJECTROOT}/output_ria/alias/data

# if we get here, we are happy
echo SUCCESS
