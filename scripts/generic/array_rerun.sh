#!/bin/bash

set -e -u
set -o pipefail

wd=${PWD}
PROJECTROOT=$(dirname ${PWD})
cd ${PROJECTROOT}/output_ria/alias/data/
completed_branches=$(git branch -a | grep job- | sed 's/job-[0-9][0-9]*-//' | sort | uniq | tr '\n' ' ')
cd $wd

# Print the previous subject batches sorted by their most recent edit date
previous_batches=$(find ${PROJECTROOT}/analysis/code/ -name 'subject_ids*.txt' -printf "%T@ %p\n" | sort -n | cut -d' ' -f 2-)
n_batches=$(echo ${previous_batches} | wc -w)
next_batchnum=$((n_batches + 1))
most_recent_batch_file=$(echo ${previous_batches} | cut -d ' ' -f ${n_batches})
next_batch_file=${most_recent_batch_file/.txt/_${next_batchnum}.txt}

echo Using ${most_recent_batch_file} as the reference branch list
echo Writing new subject list to ${next_batch_file}
branches_to_run=$(cat ${most_recent_batch_file})
n_from_previous_batch=$(wc -l < ${most_recent_batch_file})

>${next_batch_file}
set +e
for branch in ${branches_to_run}
do
    branch_ok=$(echo ${completed_branches} | grep ${branch} | wc -c)
    # echo $branch, $branch_ok
    if [ ${branch_ok} -gt 0 ]; then
        echo FINISHED: $branch
    else
       echo ${branch} >> ${next_batch_file}
    fi

done
set -e

# Make a new array file
previous_array_sub_file=$(find ${PROJECTROOT}/analysis/code/ -name 'qsub_array*.sh' -printf "%T@ %p\n" | sort -n | cut -d' ' -f 2- | tail -n 1)
new_array_sub_file=${previous_array_sub_file/.sh/_${next_batchnum}.sh}
new_njobs=$(wc -l < ${next_batch_file})

sed -e 's/#$ -t 1-.*/#$ -t 1-'${new_njobs}'/' \
    -e 's/batch_file_name=.*$/batch_file_name='$(basename ${next_batch_file})'/' \
    ${previous_array_sub_file} > ${new_array_sub_file}

echo A total of ${new_njobs} of the previous ${n_from_previous_batch} will be submitted
echo
echo To qubmit the new job array use
echo qsub code/$(basename ${new_array_sub_file})
