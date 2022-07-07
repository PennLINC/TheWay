#!/bin/bash 

# create alias 
mkdir -p ~/production/PNC/fmriprep-audit/output_ria/alias
ln -s ~/production/PNC/fmriprep-audit/output_ria/adb/be4a6-4a9f-402a-92ea-e4cfd624b974 ~/production/PNC/fmriprep-audit/output_ria/alias/data


# set up concat_ds and run concatenator on it 
cd ~/testing
datalad clone ria+file:///cbica/projects/RBC/production/PNC/fmriprep-audit/output_ria#~data concat_ds
cd concat_ds/code
wget https://raw.githubusercontent.com/PennLINC/RBC/master/PennLINC/Generic/concatenator.py
cd ~/testing/concat_ds
datalad save -m "added concatenator script"
datalad run -i 'csvs/*' -o '~/testing/concat_ds/group_report.csv' --expand inputs --explicit "python code/concatenator.py ~/testing/concat_ds/csvs ~/testing/concat_ds/group_report.csv"

# copy report to a directory that isn't getting deleted
cp ~/testing/concat_ds/group_report.csv ~/testing/

datald save -m "generated report"
# push changes
datalad push

# remove concat_ds
git annex dead here
cd ~/testing
chmod +w -R concat_ds
rm -rf concat_ds

echo SUCCESS
