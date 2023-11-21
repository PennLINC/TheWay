#!/bin/bash

# From an analysis directory, find stderr files that
# dont contain UCCESS. Run from analysis/

#fails=$(grep -L "UCCESS" logs/*.e*)
#nfails=$(echo $fails | wc -w )
# for XCP: 
fails=$(grep -L "successfully" logs/*.e*)
nfails=$(echo $fails | wc -w )


echo found $nfails unsuccessful runs

subjects=$(echo $fails | tr " " "\n" | \
            sed 's/.*sub-\([A-Za-z0-9][A-Za-z0-9]*\)\.e.*/sub-\1/')
            
#for array scripts use: 
#subjects=$(cat $fails |grep "subid=sub-*"| cut -c 9-)


>code/qsub_calls2.sh
for subject in $subjects
do
    grep $subject code/qsub_calls.sh >> code/qsub_calls2.sh
    #for array scripts use: 
    #grep -m 1 $subject code/qsub_calls.sh >> code/qsub_calls2.sh
done


