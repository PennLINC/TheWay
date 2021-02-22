#!/bin/bash

# Find all the subject directories that we want to run
PROJECTROOT=/cbica/projects/RBC/testing/PNC_Acq
cd $PROJECTROOT
SUBJECT_DIRS=`find bidsdatasets -maxdepth 1 | grep sub- | sort`


# submit one job 
for subject_dir in $SUBJECT_DIRS
do
    subj=$(basename ${subject_dir})
    #qsub 'fmriprep_'${subj} \
    qsub -N 'fmriprep_'${subj} \
	${PROJECTROOT}/code/datalad-fmriprep-run.sh ${subject_dir}
done



