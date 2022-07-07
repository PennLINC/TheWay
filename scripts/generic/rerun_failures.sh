#!/bin/bash

# From an analysis directory, find stderr files that
# dont contain UCCESS. Run from analysis/

fails=$(grep -L "UCCESS" logs/*.e*)
nfails=$(echo $fails | wc -w )

echo found $nfails unsuccessful runs

subjects=$(echo $fails | tr " " "\n" | \
            sed 's/.*sub-\([A-Za-z0-9][A-Za-z0-9]*\)\.e.*/sub-\1/')


>code/qsub_calls2.sh
for subject in $subjects
do
    grep $subject code/qsub_calls.sh >> code/qsub_calls2.sh
done


