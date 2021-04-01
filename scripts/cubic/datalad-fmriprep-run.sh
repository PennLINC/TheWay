#!/bin/bash
## Run this from the project root (ie contains code/, fmriprep/, bidsdatasets/ etc)
## USAGE: qsub datalad-fmriprep-run.sh bidsdatasets/sub=XX
# ADD SOME QSUB DIRECTIVES HERE
#$ -S /bin/bash
#$ -l h_vmem=25G
#$ -l s_vmem=23.5G
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x
# Set up where the remote (NFS) repository is. We create an empty
# text file $DSLOCKFILE in the .git directory there so two jobs
# don't try to simultaneously write to the central repository
# Ref: https://github.com/datalad-handbook/book/issues/640
PROJECTROOT=/cbica/projects/RBC/testing/colornest
PUSHROOT=/cbica/projects/RBC/testing/colornest_push
DSLOCKFILE=${PROJECTROOT}/.git/datalad_lock

dssource=${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)


# we pass in "bidsdatasets/sub-...", extract subject id from it
subjectbids=$1
echo subjectbids=$subjectbids
subid=$(basename $subjectbids)
echo detected subject id is $subid
# this is all running under /tmp inside a compute job, /tmp is a performant
# local filesystem
#cd $SBIA_TMPDIR
WORKDIR=$CBICA_TMPDIR/${subid}_${JOB_ID}

mkdir -p ${WORKDIR}
echo Using local working directory ${WORKDIR}
cd $WORKDIR
# get the output dataset, which includes the inputs as well
# flock makes sure that this does not interfere with another job
# finishing at the same time, and pushing its results back
# importantly, we clone from the location that we want to push the
# results too
#flock --verbose $DSLOCKFILE \
flock $DSLOCKFILE \
datalad clone ${PROJECTROOT}
# all following actions are performed in the context of the superdataset
LOCAL_SUPERDS=${WORKDIR}/$(basename $PROJECTROOT)
echo Using local superds ${LOCAL_SUPERDS}
cd ${LOCAL_SUPERDS}
# obtain all first-level subdatasets:
# dataset with fmriprep singularity container and pre-configured
# pipeline call; also get the output dataset to prep them for output
# consumption, we need to tune them for this particular job, sourcedata
# important: because we will push additions to the result datasets back
# at the end of the job, the installation of these result datasets
# must happen from the location we want to push back too
datalad get -n -r -R1 .
datalad get -n -r -R1 bidsdatasets
datalad get code/license.txt

git remote add
# checkout new branches in both subdatasets
# this enables us to store the results of this job, and push them back
# without interference from other jobs
git checkout -b "$subid-$JOB_ID"

# Explicitly add the RIA Push sibling
git -C fmriprep remote add fmriprep_push ria+file://${PROJECTPUSH}/fmriprep

# create workdir for fmriprep inside to simplify singularity call
# PWD will be available in the container
mkdir -p .git/tmp/wdir
# pybids (inside fmriprep) gets angry when it sees dangling symlinks
# of .json files -- wipe them out, spare only those that belong to
# the participant we want to process in this job
#find bidsdatasets -mindepth 2 -name '*.json' -a ! -wholename "$1"'*' -delete
# next one is important to get job-reruns correct. We remove all anticipated
# output, such that fmriprep isn't confused by the presence of stale
# symlinks. Otherwise we would need to obtain and unlock file content.
# But that takes some time, for no reason other than being discarded
# at the end
(cd fmriprep && rm -rf logs "$subid" "$subid.html" dataset_description.json desc-*.tsv)
(cd freesurfer && rm -rf fsaverage "$subid")

# Reomve all subjects we're not working on
(cd bidsdatasets && rm -rf `find . -type d -name 'sub*' | grep -v $subid`)

# the meat of the matter, add actual parameterization after --participant-label
echo PWD=$PWD
tree -L 4 .

datalad containers-run \
  -m "fMRIprep $subid" \
  --explicit \
  -o freesurfer -o fmriprep \
  -i "$subjectbids" \
  -i bidsdatasets/dataset_description.json \
  -n fmriprep-20-2-1 \
  bidsdatasets . participant \
  --n_cpus 1 \
  --skip-bids-validation \
  -w .git/tmp/wdir \
  --participant-label "$subid" \
  --force-bbr \
  --cifti-output 91k -v -v


# Send file content first -- does not need a lock, no interaction with Git
datalad push --to fmriprep_push-storage
# and the output branch
flock --verbose $DSLOCKFILE git push fmriprep_push

# selectively push outputs only
# ignore root dataset, despite recorded changes, needs coordinated
# merge at receiving end
flock $DSLOCKFILE datalad push -d fmriprep --to push_fmriprep
flock $DSLOCKFILE datalad push -d freesurfer --to push_freesurfer
