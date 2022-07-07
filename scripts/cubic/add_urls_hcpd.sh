#!/bin/bash
#$ -l h_vmem=25G
#$ -R y 
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

SUBJECTIDCSV=/cbica/projects/RBC/testing/hcpd/hcpd_subject_ids.csv
S3CSV=/cbica/projects/RBC/testing/hcpd/hcpd_s3.csv

# create HCPD datalad dataset
datalad create -c text2git HCPD

# cd into HCPD datalad dataset 
cd HCPD

# initialize git annex remote
git annex initremote datalad type=external externaltype=datalad encryption=none autoenable=true

# get the dataset config file from github
wget https://raw.githubusercontent.com/TobiasKadelka/build_hcp/master/code/cfg_hcp_dataset.sh

# get list of subject IDs and run addurls for each subject
SUBJECTS=$(cut -d, -f1 ${SUBJECTIDCSV})

# heredoc for subject csv creator 
cat > get_subject_csv.py << "EOT"
#!/usr/bin/env python
"""
USAGE:
python participant_csv.py subid
Run this inside of participant_job.sh
Creates csv for one single participant 
"""
import pandas as pd
import sys
hcpdcsv = sys.argv[1]
subid = sys.argv[2]
df = pd.read_csv(hcpdcsv)
df2=df[df.filename.str.startswith(subid)]
df3 = df2.drop_duplicates(subset ="filename", keep = 'first', ignore_index=True)
df3.to_csv("/cbica/projects/RBC/testing/hcpd/subject_csvs/" + subid + ".csv", index=False)
EOT



chmod +x get_subject_csv.py

datalad save -m "Added python file to create subject CSVs and HCPD dataset config"

for subject in ${SUBJECTS}; do
    echo Creating subject csv for ${subject}
    python get_subject_csv.py ${S3CSV} ${subject}

    echo Adding URLS for ${subject}
    datalad addurls -c hcp_dataset -d ${subject} ~/testing/hcpd/subject_csvs/${subject}.csv '{associated_file}' '{filename}'
    datalad save -m "Added URLs for ${subject}"
done
