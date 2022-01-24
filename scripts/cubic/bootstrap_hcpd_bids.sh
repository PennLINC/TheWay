










DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/bootstrap_hcpd_bids
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

SUBJECTIDCSV=$1
HCPDCSV=$2
if [[ -z ${SUBJECTIDCSV} ]]
then
    echo "Required argument is an identifier of the HCPD csv source"
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

# register the input dataset

SUBJECTS=$(cut -d, -f1 ${SUBJECTIDCSV})



git annex initremote datalad type=external externaltype=datalad encryption=none


cat > code/participant_csv.py << "EOT"


#!/usr/bin/env python
"""
USAGE:

python participant_csv.py subid

Run this inside of participant_job.sh

Creates csv for one single participant 


"""
import pandas as pd
import sys

hcpdcsv = sys.argv[2]
df = pd.read_csv(hcpdcsv)

# the HCD*
prefix = sys.argv[1]

df2=df[df.filename.str.startswith(prefix)]

df3 = df2.drop_duplicates(subset ="filename", keep = 'first', ignore_index=True)

df3.to_csv(f"{prefix}.csv", index=False)


EOT



chmod +x code/participant_csv.py

datalad save -m "Participant csv implementation"


cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=25G
#$ -l tmpfree=200G
#$ -R y 
#$ -l h_rt=24:00:00
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

dssource="$1"
pushgitremote="$2"
subid="$3"
hcpdcsv="$4"

rename_subid="sub-${subid:3:7}"

cd ${CBICA_TMPDIR}
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}
datalad clone "${dssource}" ds
cd ds

python code/participant_csv.py ${subid} ${hcpdcsv}



SUBJECTCSV="${subid}.csv"


git annex enableremote datalad type=external externaltype=datalad encryption=none
datalad addurls -d . ${SUBJECTCSV} '{associated_file}' '{filename}'
rm ${SUBJECTCSV}

git remote add outputstore "$pushgitremote"

git checkout -b "${BRANCH}"


# ------------------------------------------------------------------------------
# Do the run!
# CREATE THE CSV FOR ONE SINGLE SUBJECT

# CLONE
datalad run \
    -i ${subid}_V1_MR \
    --explicit \
    -o ${subid}_V1_MR \
    -o ${rename_subid} \
    -m "rename for ${subid}" \
    "python /cbica/projects/RBC/mengjia_space/hcpd_main.py ${subid}_V1_MR"

datalad save -m "Records the deletion of raw non-BIDS directories"


# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage ${rename_subid}
# and the output branch
flock $DSLOCKFILE git push outputstore

echo TMPDIR TO DELETE
echo ${BRANCH}


datalad drop -r . --nocheck
git annex dead here
cd ../..

chmod +w -R $BRANCH
rm -rf $BRANCH 

echo SUCCESS

EOT

chmod +x code/participant_job.sh



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
#dssource="~/mengjia_space/hcpd_single_subject.csv"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
 
for subject in ${SUBJECTS}; do
  echo "qsub -cwd ${env_flags} -N ${subject} ${eo_args} \
  ${PWD}/code/participant_job.sh \
  ${dssource} ${pushgitremote} ${subject} ${HCPDCSV}" >> code/qsub_calls.sh
done
datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
#if [ "${BIDS_INPUT_METHOD}" = "clone" ]
#then
 #   datalad uninstall -r --nocheck inputs/data
#fi

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


