#!/bin/bash
## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

# Arguments:
# 1. qsiprep bootstrap directory
# 2. fmriprep bootstrap directory
# 3. qsiprep container dataset directory

#bash bootstrap-qsirecon-hsvs.sh \
#    /cbica/projects/RBC/production/PNC/qsiprep \
#    /cbica/projects/RBC/production/PNC/fmriprep \
#    /cbica/projects/RBC/qsiprep-0.16.0RC3-container

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

##  qsiprep input
QSIPREPINPUT=$1
if [[ -z ${QSIPREPINPUT} ]]
then
    echo "Required argument is an identifier of the QSIPrep output zips"
    # exit 1
fi

if [[ ! -d "${QSIPREPINPUT}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "QSIPrep output dataset"
    # exit 1
fi

##  qsirecon input
FREESURFERINPUT=$2
if [[ -z ${FREESURFERINPUT} ]]
then
    echo "Required argument is an identifier of the FreeSurfer output zips"
    # exit 1
fi

if [[ ! -d "${FREESURFERINPUT}/output_ria/alias/data" ]]
then
    echo "There must be alias in the output ria store that points to the"
    echo "QSIPrep output dataset"
    # exit 1
fi

set -e -u

## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/gqihsvs-multises
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
datalad create-sibling-ria -s output "${output_store}" --new-store-ok
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}" --new-store-ok

echo "Cloning input dataset into analysis dataset"
datalad clone -d . ria+file://${QSIPREPINPUT}/output_ria#~data inputs/data/qsiprep
git commit --amend -m 'Register qsiprep results dataset as a subdataset'
datalad clone -d . ria+file://${FREESURFERINPUT}/output_ria#~data inputs/data/fmriprep
# amend the previous commit with a nicer commit message
git commit --amend -m 'Register freesurfer/fmriprep dataset as a subdataset'

SUBJECTS=$(find inputs/data/qsiprep -name '*.zip' | cut -d '/' -f 4 | cut -d '_' -f 1 | sort | uniq)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi

cd ${PROJECTROOT}

CONTAINERDS=$3
if [[ ! -z "${CONTAINERDS}" ]]; then
    datalad clone ${CONTAINERDS} pennlinc-containers
fi

cd ${PROJECTROOT}/analysis
datalad install  -d . --source ${PROJECTROOT}/pennlinc-containers

cp ${FREESURFER_HOME}/license.txt code/license.txt

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=32G
#$ -l tmpfree=200G
#$ -pe threaded 2-4
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
# OR Run it on a shared network drive
# cd /cbica/comp_space/$(basename $HOME)

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

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Do the run!

datalad get -r pennlinc-containers
datalad get -n -r inputs/data
QSIPREP_ZIP=$(ls inputs/data/qsiprep/${subid}_${sesid}_qsiprep*.zip | cut -d '@' -f 1 || true)
FREESURFER_ZIP=$(ls inputs/data/fmriprep/${subid}_${sesid}_free*.zip | cut -d '@' -f 1 || true)

if [ -z "${QSIPREP_ZIP}" ]; then
    echo NO QSIPREP ZIP FOUND FOR ${subid} ${sesid}
    exit 1
fi

if [ -z "${FREESURFER_ZIP}" ]; then
    echo NO FREESURFER ZIP FOUND FOR ${subid} ${sesid}
    exit 1
fi

datalad run \
    -i code/qsirecon_zip.sh \
    -i ${QSIPREP_ZIP} \
    -i ${FREESURFER_ZIP} \
    --explicit \
    -o ${subid}_qsirecon-0.16.0RC3_hsvs.zip \
    -m "Run HSVS + sift for ${subid}" \
    "bash ./code/qsirecon_zip.sh ${subid} ${QSIPREP_ZIP} ${FREESURFER_ZIP}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

# remove tempdir 
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


# Now create dsi studio pipeline specification file
cat > code/gqi_hsvs.json << "EOT"
{
  "name": "dsistudio_pipeline",
  "space": "T1w",
  "atlases": ["schaefer100", "schaefer200", "schaefer400", "brainnetome246", "aicha384", "gordon333", "aal116"],
  "anatomical": ["mrtrix_5tt_hsvs"],
  "nodes": [
    {
      "name": "dsistudio_gqi",
      "software": "DSI Studio",
      "action": "reconstruction",
      "input": "qsiprep",
      "output_suffix": "gqi",
      "parameters": {"method": "gqi"}
    },
    {
      "name": "scalar_export",
      "software": "DSI Studio",
      "action": "export",
      "input": "dsistudio_gqi",
      "output_suffix": "gqiscalar"
    },
    {
      "name": "tractography",
      "software": "DSI Studio",
      "action": "tractography",
      "input": "dsistudio_gqi",
      "parameters": {
        "turning_angle": 35,
        "method": 0,
        "smoothing": 0.0,
        "step_size": 1.0,
        "min_length": 30,
        "max_length": 250,
        "seed_plan": 0,
        "interpolation": 0,
        "initial_dir": 2,
        "fiber_count": 5000000
      }
    },
    {
      "name": "streamline_connectivity",
      "software": "DSI Studio",
      "action": "connectivity",
      "input": "tractography",
      "output_suffix": "gqinetwork",
      "parameters": {
        "connectivity_value": "count,ncount,mean_length,gfa",
        "connectivity_type": "pass,end"
      }
    }
  ]
}

EOT
chmod +x code/gqi_hsvs.json

# Now create Steinhardt calculation file
cat > code/calculate_steinhardt.py << "EOT"
#!/usr/bin/env python
# -*- coding: utf-8 -*-
# emacs: -*- mode: python; py-indent-offset: 4; indent-tabs-mode: nil -*-
# vi: set ft=python sts=4 ts=4 sw=4 et:
"""
Image tools interfaces
~~~~~~~~~~~~~~~~~~~~~~


"""

import sys
import os
import subprocess
import numpy as np
from glob import glob
import nibabel as nb
from nipype.utils.filemanip import fname_presuffix
import pdb
"""

The spherical harmonic coefficients are stored as follows. First, since the
signal attenuation profile is real, it has conjugate symmetry, i.e. Y(l,-m) =
Y(l,m)* (where * denotes the complex conjugate). Second, the diffusion profile
should be antipodally symmetric (i.e. S(x) = S(-x)), implying that all odd l
components should be zero. Therefore, only the even elements are computed. Note
that the spherical harmonics equations used here differ slightly from those
conventionally used, in that the (-1)^m factor has been omitted. This should be
taken into account in all subsequent calculations. Each volume in the output
image corresponds to a different spherical harmonic component.

Each volume will
correspond to the following:

volume 0: l = 0, m = 0 ;
volume 1: l = 2, m = -2 (imaginary part of m=2 SH) ;
volume 2: l = 2, m = -1 (imaginary part of m=1 SH)
volume 3: l = 2, m = 0 ;
volume 4: l = 2, m = 1 (real part of m=1 SH) ;
volume 5: l = 2, m = 2 (real part of m=2 SH) ; etc…


lmax = 2

vol	l	m
0	0	0
1	2	-2
2	2	-1
3	2	0
4	2	1
5	2	2

"""


lmax_lut = {
    6: 2,
    15: 4,
    28: 6,
    45: 8
}


def get_l_m(lmax):
    ell = []
    m = []
    for _ell in range(0, lmax + 1, 2):
        for _m in range(-_ell, _ell+1):
            ell.append(_ell)
            m.append(_m)

    return np.array(ell), np.array(m)


def calculate_steinhardt(sh_l, sh_m, data, q_num):
    l_mask = sh_l == q_num
    images = data[..., l_mask]
    scalar = 4 * np.pi / (2 * q_num + 1)
    s_param = scalar * np.sum(images ** 2, 3)
    return np.sqrt(s_param)


if __name__ == "__main__":

    if not len(sys.argv) == 4:
        print(sys.argv)
        print("USAGE: calculate_steinhardt.py input_sh.{nii/mif}[.gz] sh_order path/to/outputs")
        sys.exit(22)
    sh_image, sh_order, new_prefix = sys.argv[1:]
    sh_order = int(sh_order)

    using_temp_nifti = sh_image.endswith(".mif.gz") or sh_image.endswith(".mif")
    temp_nifti_name = new_prefix + "_temp.nii"
    if using_temp_nifti:
        print("converting %s %s" % (sh_image, temp_nifti_name))
        ret = subprocess.run(
            ['mrconvert', '-strides', '-1,-2,3', sh_image, temp_nifti_name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sh_image = temp_nifti_name

    # load the input nifti image
    img = nb.load(sh_image)

    # determine what the lmax was based on the number of volumes
    num_vols = img.shape[3]
    if not num_vols in lmax_lut:
        raise ValueError("Not an SH image")
    lmax = lmax_lut[num_vols]

    # Do we have enough SH coeffs to calculate all the SOPs?
    if sh_order > lmax:
        raise Exception("Not enough SH coefficients (found {}) "
                        "to calculate SOP order {}".format(
                            num_vols, sh_order))
    sh_l, sh_m = get_l_m(lmax)
    sh_data = img.get_fdata()

    # Normalize the FODs so they integrate to 1
    sh_data = sh_data / sh_data[:, :, :, 0, None]

    # to get a specific order
    def calculate_order(order):
        out_fname = new_prefix + "_q-%d_SOP.nii.gz" % order
        order_data = calculate_steinhardt(sh_l, sh_m, sh_data, order)

        # Save with the new name in the sandbox
        nb.Nifti1Image(order_data, img.affine).to_filename(out_fname)

    # calculate!
    for order in range(2, sh_order + 2, 2):
        calculate_order(order)

    # Clean up if we made a temp
    if using_temp_nifti:
        os.remove(temp_nifti_name)
EOT
chmod +x code/calculate_steinhardt.py

cat > code/qsirecon_zip.sh << "EOT"
#!/bin/bash
set -e -u -x

subid="$1"
qsiprep_zip="$2"
freesurfer_zip="$3"
wd=${PWD}

cd inputs/data/qsiprep
7z x `basename ${qsiprep_zip}`
cd ../fmriprep
7z x `basename ${freesurfer_zip}`
cd $wd

ompthreads=1
if [ ${NSLOTS} -gt 2 ]; then
    ompthreads=$(expr ${NSLOTS} - 1)
fi

mkdir -p ${PWD}/.git/tmp/wkdir
singularity run \
    --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/qsiprep-0-16-0RC3/image \
    inputs/data/qsiprep/qsiprep qsirecon participant \
    --participant_label $subid \
    --recon-input inputs/data/qsiprep/qsiprep \
    --fs-license-file code/license.txt \
    --nthreads ${NSLOTS} \
    --omp-nthreads ${ompthreads} \
    --stop-on-first-crash \
    --recon-only \
    --skip-odf-reports \
    --freesurfer-input inputs/data/fmriprep/freesurfer \
    --recon-spec ${PWD}/code/gqi_hsvs.json  \
    -w ${PWD}/.git/tmp/wkdir

fib_file=$(find qsirecon -name '*gqi.fib.gz')
ref_img=$(find qsirecon -name '*md_gqiscalar.nii.gz')
mif=${fib_file/fib.gz/mif.gz}
singularity exec \
    --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/qsiprep-0-16-0RC3/image \
    fib2mif \
    --fib ${fib_file} \
    --ref_image ${ref_img} \
    --mif ${mif}

stem=${mif/_gqi.mif.gz/_recon-gqi}
singularity exec \
    --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/qsiprep-0-16-0RC3/image \
    python \
    code/calculate_steinhardt.py \
    ${mif} \
    8 \
    ${stem}

# remove collision-causing files
mv qsirecon/qsirecon/* qsirecon/

rm -rf \
   qsirecon/dataset_description.json \
   qsirecon/dwiqc.json \
   qsirecon/logs \
   qsirecon/qsirecon

rm -rf .git/tmp/wkdir

EOT

chmod +x code/qsirecon_zip.sh

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
  SESSIONS=$(find inputs/data/fmriprep -name "${subject}*.zip" | xargs -n 1 basename | cut -d "_" -f 2 | sort | uniq)
  for session in ${SESSIONS}; do
    echo "qsub -cwd ${env_flags} -N qr${subject}_${session} ${eo_args} \
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

#run last sge call to test
#$(tail -n 1 code/qsub_calls.sh)

