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
PROJECTROOT=${PWD}/shoreline-benchmark
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
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"



# Install the input data and the containers at the same level as analysis/
cd ${PROJECTROOT}
# register the input dataset
echo "Cloning input dataset into analysis dataset"
datalad clone osf://38vce/ phantoms
(cd phantoms && datalad get -r .)

echo "Cloning the containers dataset"
datalad clone ///repronim/containers containers
(cd containers && datalad get images/bids/bids-qsiprep--0.14.3.sing)


cd analysis
datalad clone -d . ../phantoms inputs/data
git commit --amend -m 'Register phantom dataset as a subdataset'

datalad clone -d . ../containers containers
git commit --amend -m 'Register containers dataset as a subdataset'

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
scheme="$3"
noise="$4"
PERCENT_MOTION="$5"
simnum="$6"
method="$7"
transform="$8"
denoise="$9"
motion_severity="${10}"

# change into the cluster-assigned temp directory. Not done by default in SGE
# cd ${CBICA_TMPDIR}
# OR Run it on a shared network drive
cd /cbica/comp_space/$(basename $HOME)

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${method}-${scheme}-${noise}-${PERCENT_MOTION}-${transform}-${denoise}-${simnum}"
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
datalad get -n "inputs/data"

# ------------------------------------------------------------------------------
# Do the run!
outputname="${scheme}_${noise}_${PERCENT_MOTION}_${simnum}_${method}-${transform}-${denoise}-${motion_severity}-qsiprep-0.14.3.zip"
run_args="${scheme} ${noise} ${PERCENT_MOTION} ${simnum} ${method} ${transform} ${denoise} ${motion_severity} ${outputname}"

datalad run \
    -i "inputs/data/${noise}/"'*/sub-'"${scheme}" \
    -i "inputs/data/realistic/nomotion/dataset_description.json" \
    -i "inputs/data/ground_truth_motion" \
    -i "containers/images/bids/bids-qsiprep--0.14.3.sing" \
    --explicit \
    --expand inputs \
    -o ${outputname} \
    -m "${run_args}" \
    "bash ./code/qsiprep_zip.sh ${run_args}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir
echo TMPDIR TO DELETE
echo ${BRANCH}

datalad uninstall --nocheck --if-dirty ignore -r inputs/data
datalad drop -r --nocheck .
git annex dead here
cd ../..
rm -rf $BRANCH

echo SUCCESS
EOT

chmod +x code/participant_job.sh

cat > code/qsiprep_zip.sh << "EOT"
#!/bin/bash
set -e -u -x
sequence="$1"
noise="$2"
percent_motion="$3"
permutation_number="$4"
hmc_method="$5"
transform="$6"
denoise="$7"
motion_severity="$9"
outputname="$8"

CONTAINER=containers/images/bids/bids-qsiprep--0.14.3.sing
SOURCEBIND='-B /cbica/projects/Shoreline/code/qsiprep/qsiprep:/usr/local/miniconda/lib/python3.7/site-packages/qsiprep'

# Create the subset in bids_subset/
singularity exec --cleanenv -B ${PWD} \
    $CONTAINER python code/create_motion_subset.py \
        ${sequence} \
        ${noise} \
        ${percent_motion} \
        ${permutation_number} \
        ${motion_severity}


workdir=${PWD}/.git/tmp/wdir
mkdir -p ${workdir}

if [[ "${hmc_method}" == "eddy" ]];
then

    if [[ "${transform}" == "quadratic" ]];
    then
        singularity run --cleanenv -B ${PWD} \
            ${SOURCEBIND} \
            ${CONTAINER} \
            bids_subset \
            prep \
            participant \
            -v -v \
            -w ${workdir} \
            --n_cpus $NSLOTS \
            --stop-on-first-crash \
            --fs-license-file code/license.txt \
            --skip-bids-validation \
            --denoise-method ${denoise} \
            --eddy-config code/quadratic.json \
            --output-resolution 2.0
    else
        singularity run --cleanenv -B ${PWD} \
            ${SOURCEBIND} \
            ${CONTAINER} \
            bids_subset \
            prep \
            participant \
            -v -v \
            -w ${workdir} \
            --n_cpus $NSLOTS \
            --stop-on-first-crash \
            --fs-license-file code/license.txt \
            --skip-bids-validation \
            --denoise-method ${denoise} \
            --output-resolution 2.0
    fi

else
    # Run SHORELine
    singularity run --cleanenv -B ${PWD} \
        ${SOURCEBIND} \
        ${CONTAINER} \
        bids_subset \
        prep \
        participant \
        -v -v \
        -w ${workdir} \
        --n_cpus $NSLOTS \
        --stop-on-first-crash \
        --fs-license-file code/license.txt \
        --skip-bids-validation \
        --hmc-model 3dSHORE \
        --hmc_transform ${transform} \
        --shoreline-iters 2 \
        --b0-motion-corr-to first \
        --denoise-method ${denoise} \
        --output-resolution 2.0
fi

# Copy the ground-truth motion file into the results zip
cp bids_subset/sub-${sequence}/dwi/*_dwi_motion.txt prep/qsiprep/

cd prep
7z a ../${outputname} qsiprep
cd ..
rm -rf prep ${workdir}

EOT

cat > code/create_motion_subset.py << "EOT"
#!/usr/bin/env python
"""

USAGE:

python create_motion_subset.py sequence noise percent_motion permutation_number severity

Where
    sequence is HASC55, HCP, ABCD, PN, DSIQ5
    noise is "realistic" or "noisefree"
    percent_motion is 1-100
    permutation_number is an integer
    severity is "low" or "high"

Creates new version of the data with random volumes (determined by permutation_number)
are replaced with low|high motion versions of the same gradient direction. The percent
of volumes to be replaced is determined by percent_motion.
"""


import sys
import shutil
import os
import nibabel as nb
import numpy as np


def simulate_motion(
        seq='HASC55', noise='noisefree', percent_motion=10,
        permutation_number=999, severity=''):

    args = dict(seq=seq, noise=noise, percent_motion=percent_motion, severity=severity)

    dataset_description = \
        'inputs/data/{noise}/nomotion/' \
        'dataset_description.json'.format(**args)

    # No motion simulation
    nonmotion_dwi = \
        'inputs/data/{noise}/nomotion/sub-{seq}/' \
        'dwi/sub-{seq}_acq-{noise}Xnomotion_dwi.nii.gz'.format(**args)
    nonmotion_img = nb.load(nonmotion_dwi)
    nonmotion_data = nonmotion_img.get_fdata(dtype=np.float32)
    json = nonmotion_dwi[:-7] + '.json'
    bval = nonmotion_dwi[:-7] + '.bval'
    bvec = nonmotion_dwi[:-7] + '.bvec'

    # All motion simulation uses the low motion examples
    motion_file = 'inputs/data/ground_truth_motion/' \
        'sub-{seq}_acq-{noise}_run-{severity}motion_dwi_motion.txt'.format(**args)
    all_motion = np.loadtxt(motion_file)
    motion_dwi = \
        'inputs/data/{noise}/{severity}motion/sub-{seq}/' \
        'dwi/sub-{seq}_acq-{noise}X{severity}motion_dwi.nii.gz'.format(**args)
    motion_img = nb.load(motion_dwi)
    motion_data = motion_img.get_fdata(dtype=np.float32)

    out_dir = 'bids_subset/sub-{seq}/dwi'.format(**args)
    os.makedirs(out_dir, exist_ok=True)
    shutil.copyfile(dataset_description,
                    "bids_subset/dataset_description.json",
                    follow_symlinks=True)

    np.random.seed(permutation_number)
    args['permnum'] = permutation_number
    prefix = out_dir + '/sub-{seq}_acq-mot{percent_motion}perm' \
        '{permnum:03d}_dwi'.format(**args)
    shutil.copyfile(json, prefix + '.json', follow_symlinks=True)
    shutil.copyfile(bval, prefix + '.bval', follow_symlinks=True)
    shutil.copyfile(bvec, prefix + '.bvec', follow_symlinks=True)

    # Determine which volumes should get swapped with their motion version
    num_vols = nonmotion_img.shape[3]
    num_to_replace = int(num_vols * float(percent_motion) / 100)
    replace_vols = np.random.choice(num_vols - 1, size=num_to_replace,
                                    replace=False) + 1
    # create the new 4D image with the moved images mixed in
    nonmotion_data[..., replace_vols] = motion_data[..., replace_vols]
    nb.Nifti1Image(
        nonmotion_data, nonmotion_img.affine,
        nonmotion_img.header).to_filename(
            prefix + '.nii.gz')

    motion_params = np.zeros_like(all_motion)
    motion_params[replace_vols] = all_motion[replace_vols]
    np.savetxt(prefix + '_motion.txt', motion_params)


if __name__ == "__main__":
    sequence = sys.argv[1]
    noise = sys.argv[2]
    percent_motion = int(sys.argv[3])
    permutation_number = int(sys.argv[4])
    severity = sys.argv[5]
    simulate_motion(
        seq=sequence, noise=noise, percent_motion=percent_motion,
        permutation_number=permutation_number, severity=severity
    )

EOT


chmod +x code/create_motion_subset.py
cp ${FREESURFER_HOME}/license.txt code/license.txt

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT

# Add a script for merging outputs
MERGE_POSTSCRIPT=https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic/merge_outputs_postscript.sh
echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh
wget -qO- ${MERGE_POSTSCRIPT} >> code/merge_outputs.sh

################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"
echo '#!/bin/bash' > code/qsub_rerun.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
echo 'dssource='${dssource} >> code/qsub_rerun.sh
echo 'pushgitremote='${pushgitremote} >> code/qsub_rerun.sh
echo 'PROJECTROOT='${PROJECTROOT} >> code/qsub_rerun.sh
echo 'LOGDIR='${PROJECTROOT}/analysis/logs >> code/qsub_rerun.sh
echo 'DSLOCKFILE='${PROJECTROOT}/analysis/.SGE_datalad_lock >> code/qsub_rerun.sh


cat >> code/qsub_rerun.sh << "EOT"

# USAGE bash code/qsub_rerun.sh [do run]
# With no arguments, print whether the branch exists in
# the output_ria (the job has completed successfully)
#

QSIPREP_SCHEMES="ABCD DSIQ5 HCP HASC55"
EDDY_SCHEMES="ABCD HCP PNC"
NOISES="realistic"
PERCENT_MOTION=15
NUM_PERMS=10
#DENOISERS="dwidenoise none patch2self"
DENOISERS="dwidenoise"

getreq(){
    case $1 in

    HCP | DSIQ5)
        memreq="80G"
        threadreq="4-6"
        ;;
    ABCD)
        memreq="48G"
        threadreq="2-4"
        ;;
    PNC | HASC55)
        memreq="36G"
        threadreq="2-4"
        ;;
    *)
        memreq="54G"
        threadreq="2-4"
        ;;

    esac
}

dorun=0
if [ $# -gt 0 ]; then
    dorun=1
    echo Submitting jobs to SGE
fi

# Discover which branches have completed
cd ${PROJECTROOT}/output_ria/alias/data/
branches=$(git branch -a | grep job- | tr '\n' ' ' | sed 's/  */,/g')
running_branches=$(qstat -r | grep "Full jobname" | tr -s ' ' | cut -d ' ' -f 4 | tr '\n' ',')

submit_unfinished(){

    BRANCH="${method}-${scheme}-${noise}-${PERCENT_MOTION}-${transform}-${denoise}-${simnum}"
    branch_ok=$(echo $branches | grep "${BRANCH}," | wc -c)
    branch_submitted=$(echo $running_branches | grep "${BRANCH}," | wc -c)

    # check status of this branch
    if [ ${branch_ok} -gt 0 ]; then
        echo FINISHED: $BRANCH

    elif [ "${branch_submitted}" -gt 0  ]; then
        echo WAITING FOR: ${BRANCH}

    else
        echo INCOMPLETE: $BRANCH

        # Run it if we got an extra argument
        if [ ${dorun} -gt 0 ]; then

            # Set variables for resource requirements
            getreq

            # Do the qsub call
            set +x
            qsub \
                -e ${LOGDIR} -o ${LOGDIR} \
                -cwd \
                -l "h_vmem=${memreq}" \
                -pe threaded ${threadreq} \
                -N x${BRANCH} \
                -v DSLOCKFILE=$DSLOCKFILE \
                code/participant_job.sh \
                    ${dssource} \
                    ${pushgitremote} \
                    ${scheme} \
                    ${noise} \
                    ${PERCENT_MOTION} \
                    ${simnum} \
                    ${method} \
                    ${transform} \
                    ${denoise}
            set -x
        fi

    fi
}

cd $PROJECTROOT/analysis
for denoise in ${DENOISERS}
do
    for noise in ${NOISES}
    do
        for simnum in `seq ${NUM_PERMS}`
        do
            method=3dSHORE
            for scheme in ${QSIPREP_SCHEMES}
            do
                transform=Rigid
                submit_unfinished

                transform=Affine
                submit_unfinished
            done

            method=eddy
            for scheme in ${EDDY_SCHEMES}
            do
                # One for linear
                transform=Linear
                submit_unfinished

                # One for quadratic
                transform=Quadratic
                submit_unfinished
            done
        done
    done
done

EOT

# Eddy config for using quadratic
cat > code/quadratic.json << "EOT"
{
  "flm": "quadratic",
  "slm": "quadratic",
  "fep": false,
  "interp": "spline",
  "nvoxhp": 1000,
  "fudge_factor": 10,
  "dont_sep_offs_move": false,
  "dont_peas": false,
  "niter": 5,
  "method": "jac",
  "repol": true,
  "num_threads": 1,
  "is_shelled": true,
  "use_cuda": false,
  "cnr_maps": true,
  "residuals": false,
  "output_type": "NIFTI_GZ",
  "args": ""
}

EOT

datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS
