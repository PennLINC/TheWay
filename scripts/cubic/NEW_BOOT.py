#!/usr/bin/env python

# *PREP AUDIT: Currently configured for qsiprep and fmriprep

# command line: python audit_script.py pipeline bids_dir output_dir error_dir audit_path

# NEW CCNP EXEMPLARS
# PIPELINE: fmriprep
# BIDS_DIR: /cbica/projects/RBC/testing/ccnp_exemplars/exemplars
# OURPUT_DIR: /cbica/projects/RBC/testing/ccnp_exemplars/fmriprep/merge_ds
# ERROR DIR: /cbica/projects/RBC/testing/ccnp_exemplars/fmriprep/analysis/logs

from pathlib import Path
import pandas as pd
import numpy as np
import json
import sys
import os
import pdb
# from bs4 import BeautifulSoup
import glob
import os
import subprocess
import pdb
import time
import zipfile
#import pdb 

def get_sub_name(path):
    parts = path.parts
    for part in parts:
        if part.startswith("sub-"):
            return part

sub_id = sys.argv[1]

bids_dir = sys.argv[2]

output_dir = sys.argv[3]

error_dir = sys.argv[4]

pipeline = 'fmriprep'

# GET LIST OF ALL BRANCH NAMES
# CREATE DICTIONARY OF SUB_ID/BRANCH_NAME KEY/VALUE PAIRS
#sp = subprocess.Popen(["git", "branch", "-a"], stdout=subprocess.PIPE, cwd=output_dir)
#branches = sp.stdout.readlines()
#sub_branch_names = {}
#for branch in branches:
#    branch_name = branch.strip()
#    branch_name = str(branch_name)
#    branch_name = branch_name[2:len(branch_name)-1]
#    if branch_name.startswith("sub-"):
#        sub_branch_names[branch_name[:-8]] = branch_name

# save list of branch names
# save list of subject names

# get output subs list
output_subs = []
for path in Path(output_dir).glob('sub-*'):
    if 'fmriprep' in str(path):
        output_subs.append(path.parts[-1].split('fmriprep')[0][:-1])

sub_path = bids_dir + '/' + sub_id.replace('_',  '/')

if pipeline == "qsiprep":
    columns = ["SubjectID", "HasOutput",
            "ProducedPreprocessedDWIs", "ProducedPreprocesedANATs",
            "RanT1wSpatialNormalization", "HasDwiDir", "HasFmapDir",
            "AllFmapsHaveIntendedFors", "NoMissingDwiPhaseEncodingDirection",
            "NoMissingFmapPhaseEncodingDirection", "RuntimeErrorDescription",
            "OSErrorDescription", "CommandErrorDescription", "HadScratchSpace",
            "HadRAMSpace", "HadDiskSpace", "FinishedSuccessfully"]

if pipeline == "fmriprep":
    columns = ["SubjectID", "HasOutput",  "HasFuncDir",
            "HasBold", "ProducedFuncDir", "RanSurfBold", "RanVolBold", "HasErrorFile",
            "RuntimeErrorDescription", "OSErrorDescription", "CommandErrorDescription",
            "HadScratchSpace", "HadRAMSpace", "HadDiskSpace", "FinishedSuccessfully"]


audit = pd.DataFrame(np.nan, index=range(0,1), columns=columns, dtype="string")

audit["Path"] = sub_path
audit["SubjectID"] = sub_id

cntr = 0
z = None


for row in range(len(audit)):
    cntr += 1
    # get output branch name for input dir
    # if it doesn't exist, then HasOutput = False!
    #subject = sub_id.replace('_', '-')
    #pdb.set_trace()
    subject = audit.loc[row, 'SubjectID'].replace('_', '-')
    print("OUTPUT SUBS: ", output_subs)
    print("SUBJECT: ", subject)
    print("OUTPUT SUB: ", audit.loc[row, 'SubjectID'])
    if audit.loc[row, 'SubjectID'] in output_subs:
        audit.at[row, "HasOutput"] = "True"
        # need to checkout to the subject specific branch!
        # subproces.call IS BLOCKING (necessary!)
        # msg = subprocess.call(["git", "checkout", sub_branch_names[subject]], stdout=subprocess.PIPE, cwd=output_dir)
        # print(cntr)
        # if msg != 0:
        #     print("On branch ", sub_branch_names[subject])
        #     print("Checkout error code: ", msg)

        # # ON BRANCH, CHECK IF OUTPUT DIR GOT CREATED
        # if Path(output_dir + "/" + subject).exists:
        #     audit.at[row, "HasOutput"] = "True"
        # else:
        #     audit.at[row, "HasOutput"] = "False"

        # NEW: Instead of checking out to a branch,
        # UNZIP the file!

        #subprocess.run(['datalad', 'get', subject + '_fmriprep-20.2.1.zip'], cwd=output_dir)
        #subprocess.run(['datalad', 'unlock', subject + '_fmriprep-20.2.1.zip'], cwd=output_dir)
        z = zipfile.ZipFile(output_dir + '/' + sub_id + '_fmriprep-20.2.3.zip')

    # IN THE CASE OF NO ZIP FILE CREATED
    else:
        audit.at[row, "HasOutput"] = "False"
        audit.at[row, "ProducedFuncDir"] = "False"
        audit.at[row, "RanSurfBold"] = "False"
        audit.at[row, "RanVolBold"] = "False"

    # NON PIPELINE SPECIFIC CHECKS


    #if sub_id in output_subs and z != None:
        
	#if 'fmriprep/' + sub_id + '.html' in z.namelist():

            #html = z.read('fmriprep/' + subject + '.html')
            #audit.at[row, 'HasHTML'] = "True"

            # soup = BeautifulSoup(open(html_filename),"html.parser")
            # if len(soup.findAll(text='No errors to report!')) == 1:
            #if "No errors to report!" in str(html):
            #    audit.at[row, "NoErrorsToReport"] = "True"
            #else:
            #    audit.at[row, "NoErrorsToReport"] = "False"


    # no html file generated
    #else:
    #    audit.at[row, 'HasHTML'] = "False"
    #    audit.at[row, "NoErrorsToReport"] = "False"

    # grab the last line of the error file
    try:
        e_file = sorted(glob.glob('%s/*%s*.e*'%(error_dir, audit.loc[row, 'SubjectID'])),key=os.path.getmtime)[-1]
    except IndexError:
        e_file = ''

    # Assume none, overwrite if exists

    if e_file != '':
        audit.at[row, "HasErrorFile"] = "True"
        audit.at[row, "RuntimeErrorDescription"] = "No Runtime Error"
        audit.at[row, "OSErrorDescription"] = "No OS Error"
        audit.at[row, "CommandErrorDescription"] = "No Command Error"
        audit.at[row, "HadScratchSpace"] = "True"
        audit.at[row, "HadRAMSpace"] = "True"
        audit.at[row, "HadDiskSpace"] = "True"
        audit.at[row, "FinishedSuccessfully"] = "False"

        with open(e_file) as f:
            for line in f:
                # get runtime error if exists
                if "RuntimeError:" in line:
                    audit.at[row, "RuntimeErrorDescription"] = line
                # get OS error if exists
                if "OSError:" in line:
                    audit.at[row, "OSErrorDescription"] = line
                # get command error if exists
                if "CommandError:" in line:
                    audit.at[row, "CommandErrorDescription"] = line
                # check if no space, indicated by 4 print statements we know of
                if "No space left on device" in line or "not enough free space" in line or "fatal: failed to copy file to '/scratch/" in line:
                    audit.at[row, "HadScratchSpace"] = "False"
                if "Cannot allocate memory" in line:
                    audit.at[row, "HadRAMSpace"] = "False"
                if line == '+ echo SUCCESS\n':
                    audit.at[row, "FinishedSuccessfully"] = "True"
                if "Disk quota exceeded" in line:
                    audit.at[row, "HadDiskSpace"] = "False"
    else:
        audit.at[row, "HasErrorFile"] = "False"
        audit.at[row, "RuntimeErrorDescription"] = ""
        audit.at[row, "OSErrorDescription"] = ""
        audit.at[row, "CommandErrorDescription"] = ""
        audit.at[row, "HadScratchSpace"] = ""
        audit.at[row, "HadRAMSpace"] = ""
        audit.at[row, "FinishedSuccessfully"] = ""

    # THE REST OF THE CHECKS ARE PIPELINE DEPENDENT

    if pipeline == "qsiprep":

        # check if bids_dir has dwi data

        #for ses_path in Path(bids_dir + "/" + audit.iloc[row]["SubjectID"].replace('_','/').glob('*'):
        ses_path = audit.loc[row, 'Path']
        if Path(ses_path + "/dwi/").exists():
            audit.at[row, 'HasDwiDir'] = "True"

                # checking for missing PhaseEncodingDirection
            for filepath in Path(ses_path).rglob("dwi/*.json"):
                #print(filepath)
                IntendedForMissing = False
                MissingdPED = False

                filestr = str(filepath)
                with open(filestr) as f:
                    data = json.load(f)

                # Check for PhaseEncodingDirection
                if filestr.endswith("_dwi.json"):
                    if "PhaseEncodingDirection" not in list(data.keys()):
                        MissingdPED = True
            if MissingdPED == False:
                audit.at[row, "NoMissingDwiPhaseEncodingDirection"] = "True"
            else:
                audit.at[row, "NoMissingDwiPhaseEncodingDirection"] = "False"

        else:
            audit.at[row, 'HasDwiDir'] = "False"
            audit.at[row, "NoMissingDwiPhaseEncodingDirection"] = "False"

        # now want to check if fmap directories are present in the bids dir
        #for ses_path in Path(bids_dir + "/" + audit.iloc[row]["SubjectID"].replace('_', '/')).glob():
        
        #print(ses_path)
        if Path(ses_path + "/fmap/").exists():
            audit.at[row, "HasFmapDir"] = "True"

            # checking if fmaps have intended fors
            IntendedForMissing = False
            MissingfPED = False
            for filepath in Path(ses_path).rglob("fmap/*.json"):

                filestr = str(filepath)
                with open(filestr) as f:
                    data = json.load(f)
                
                # Check for IntendedFor
                if "IntendedFor" not in list(data.keys()):
                    IntendedForMissing = True
                # empty IntendedFor case
                elif len(data["IntendedFor"]) == 0:
                    IntendedForMissing = True

                    # Check for PhaseEncodingDirection
                    if filestr.endswith("_epi.json"):
                        #print(list(data.keys()))
                        if "PhaseEncodingDirection" not in list(data.keys()):
                            MissingfPED = True

            if IntendedForMissing == False:
                audit.at[row, "AllFmapsHaveIntendedFors"] = "True"
            else:
                audit.at[row, "AllFmapsHaveIntendedFors"] = "False"

            if MissingfPED == False:
                audit.at[row, "NoMissingFmapPhaseEncodingDirection"] = "True"
            else:
                audit.at[row, "NoMissingFmapPhaseEncodingDirection"] = "False"
        else:
            audit.at[row, "HasFmapDir"] = "False"
            audit.at[row, "AllFmapsHaveIntendedFors"] = "False"
            audit.at[row, "NoMissingPhaseEncodingDirection"] = "False"

        # check if qsiprep generated dwi
        #for ses_path in Path(audit.iloc[row]["Path"]).glob():
            #print(ses_path)
            
        if Path(ses_path + "/dwi/").exists():
            audit.at[row, "ProducedPreprocessedDWIs"] = "True"
        else:
            audit.at[row, "ProducedPreprocessedDWIs"] = "False"

        # check if qsiprep generated anat
        if Path(audit.iloc[row]["Path"] + "/anat/").exists():
            audit.at[row, "ProducedPreprocesedANATs"] = "True"
            # now check for .h5 files
            spacial = False
            for filename in Path(audit.iloc[row]["Path"]).glob("anat/*"):
                if str(filename).endswith(".h5"):
                    spacial = True
            if spacial == True:
                audit.at[row, "RanT1wSpatialNormalization"] = "True"
            else:
                audit.at[row, "RanT1wSpatialNormalization"] = "False"
        else:
            audit.at[row, "ProducedPreprocesedANATs"] = "False"
            audit.at[row, "RanT1wSpatialNormalization"] = "False"

    if pipeline == "fmriprep":

        # check for bold scans in bids dir and output dir
        #for ses_path in Path(bids_dir + "/" + audit.iloc[row]["SubjectID"].replace('_','/')).glob():
        ses_path = audit.loc[row, 'Path']
        if Path(str(ses_path) + "/func/").exists():
            audit.at[row, "HasFuncDir"] = "True"

            has_bold = False
            for filepath in Path(str(ses_path)).rglob("func/*"):
                if "bold" in str(filepath):
                    #print(str(filepath))
                    has_bold = True
            if has_bold == True:
                audit.at[row, "HasBold"] = "True"
            else:
                audit.at[row, "HasBold"] = "False"
        else:
            audit.at[row, "HasFuncDir"] = "False"
            audit.at[row, "HasBold"] = "False"

        #for ses_path in Path(bids_dir + "/" + audit.iloc[row]["SubjectID"]).glob("ses-*/"):
           
            # get output dir ses_path
            #o_ses_path = str(ses_path).replace(bids_dir, "fmriprep/")
        has_func = False
        has_surf_bold = False
        has_vol_bold = False
        # for filepath in Path(str(ses_path)).rglob("func/*"):
        if z != None:
            for filepath in z.namelist():

                #if o_ses_path in filepath:
                if "/func/" in filepath:
                    has_func = True
                if "/func/" in filepath and "fsLR_den-91k_bold.dtseries" in filepath:
                    has_surf_bold = True
                if "/func/" in filepath and "MNI152NLin6Asym_res-2_desc-preproc_bold" in filepath:
                    has_vol_bold = True
                #else:
                #    audit.at[row, "ProducedFuncDir"] = "False"
                #        audit.at[row, "RanSurfBold"] = "False"
                #        audit.at[row, "RanVolBold"] = "False"

            if has_func == True:
                audit.at[row, "ProducedFuncDir"] = "True"
            else:
                audit.at[row, "ProducedFuncDir"] = "False"

            if has_surf_bold == True:
                audit.at[row, "RanSurfBold"] = "True"
            else:
                audit.at[row, "RanSurfBold"] = "False"

            if has_vol_bold == True:
                audit.at[row, "RanVolBold"] = "True"
            else:
                audit.at[row, "RanVolBold"] = "False"

# REMOVE PATH
audit = audit.drop(["Path"], axis=1)

# write output to a csv
audit.to_csv(sys.argv[5])
print("Saved audit csv")
