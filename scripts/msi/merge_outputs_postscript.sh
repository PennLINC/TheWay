# Load s3 credentials into env
DATA=`s3info keys --machine-output`
if [[ $? -eq 0 ]]
then
  read -r ACCESS_KEY SECRET_KEY <<< "$DATA"
  export AWS_ACCESS_KEY_ID=$ACCESS_KEY
  export AWS_SECRET_ACCESS_KEY=$SECRET_KEY
fi

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
git annex fsck --fast -f output-storage-s3

# This should not print anything
MISSING=$(git annex find --not --in output-storage-s3)

if [[ ! -z "$MISSING" ]]
then
    echo Unable to find data for $MISSING
    exit 1
fi

# stop tracking this branch
git annex dead here

datalad push --data nothing
echo SUCCESS
