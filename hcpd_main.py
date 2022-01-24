import os
import glob
import shutil
import csv
import subprocess

import json
import sys

# Change the current working directory
"""
Rename the HCP-D data downloaded from NDA S3

No datalad python api is used in this script

"""


def move_glob_files(glob_pattern,dest,cur_dir):
    """Move files with a certain glob pattern to a new directory in bulk"""
    glob_pattern = cur_dir + glob_pattern
    dest = cur_dir + dest
    for matches in glob.glob(glob_pattern):
        try:
            filename = os.path.basename(matches)
            rename_dest = os.path.join(dest,filename)
            os.rename(matches, rename_dest)
#            dl.save(message=f'Move {filename} to {dest}')
        # supress the File Exists errors, which cannot be avoided            
        except OSError as e:
            # Errno 17 is "File exists" and is inevitable during the re-organization
            if e.errno != 17:
                print("Error:", e)
    #dl.save(message=f'Moving files to {dest}')
def rename_list_of_files(pattern, replacement, cur_dir):
    """Rename files with a certain glob pattern in bulk"""
    file_list = os.listdir(cur_dir)
    for ii in file_list:
        newName = ii.replace(pattern,replacement)
        if newName != ii:
            source = os.path.join(cur_dir,ii) 
            dest = os.path.join(cur_dir,newName)
            os.rename(os.path.join(cur_dir,ii),
                      os.path.join(cur_dir,newName))
            #dl.save(dest) 
 #           dl.save(message=f'Renaming {ii} to {newName}')
def remove_glob_files(glob_pattern,cur_dir):
    """Delete files with a glob pattern in bulk"""
    glob_list = cur_dir + glob_pattern
    fileList = glob.glob(cur_dir+glob_pattern)
    for filePath in fileList:
        try:
            shutil.rmtree(os.path.join(cur_dir,filePath))
        except:
            print("Error while deleting file : ", filePath)
  #  dl.save(message=f'Deleting files with pattern {glob_pattern}')
def main():
    """Entry point """
    # make inputs/data the current working directory
    subid = sys.argv[1]
    fileList = glob.glob(str(subid))

    for ii in fileList:
        newName = ii.replace('HCD','sub-').replace('_V1_MR','')
        if newName != ii:
            os.rename(ii,newName)
    subjects = glob.glob("./sub*")
    # list of new directories to be created
    dir_names = ['ses-V1/anat','ses-V1/func','ses-V1/dwi','ses-V1/fmap','ses-V1/S1','ses-V1/S2','ses-V1/S3','ses-V1/S4','ses-V1/S5','ses-V1/S6','ses-V1/S7']
    for sub in subjects:
        os.chdir(sub)
        cur_dir = os.getcwd()
        try:
            os.rename('unprocessed','ses-V1')
        except:
            #print("Error while trying to rename directory unprocessed to ses-V1; unprocessed does not exist")
            pass
        
        for folder in dir_names:
            try:
                if not os.path.isdir(os.path.join(cur_dir,folder)):
                    os.mkdir(os.path.join(cur_dir,folder))
        #            dl.save(os.path.join(cur_dir,folder), message=f"creating new folder {folder}")
            except:
                print("Error while create directory: ", folder)
        
        move_glob_files('/ses-V1/Diffusion/*/*SpinEchoFieldMap*','/ses-V1/Diffusion/',cur_dir )
        move_glob_files('/ses-V1/T2w_SPC_vNav/*/*SpinEchoFieldMap*','/ses-V1/T2w_SPC_vNav/',cur_dir )
        move_glob_files('/ses-V1/T1w_MPR_vNav_4e_e1e2_mean/*/*SpinEchoFieldMap*','/ses-V1/T1w_MPR_vNav_4e_e1e2_mean/',cur_dir)

        os.chdir('ses-V1/')

        rest_files = glob.glob('*/*REST*')

        # bidify the resting state files
        for rest_file in rest_files:
            newName = (rest_file
                       .replace("_AP.nii.gz","_dir-AP_bold.nii.gz")
                       .replace("_AP.json","_dir-AP_bold.json")
                       .replace("_PA.nii.gz", "_dir-PA_bold.nii.gz")
                       .replace("_PA.json", "_dir-PA_bold.json")
                       .replace("AP_SBRef.nii.gz", "dir-AP_sbref.nii.gz")
                       .replace("AP_SBRef.json", "dir-AP_sbref.json")
                       .replace("PA_SBRef.nii.gz", "dir-PA_sbref.nii.gz")
                       .replace("PA_SBRef.json", "dir-PA_sbref.json")
                       .replace("_rfMRI_", "_task-rest_")
                       .replace("rest_REST", "rest_acq-REST"))
            os.rename(rest_file,newName)
        
        # rename sbref nii.gz files by the number of run of the same task      
        counter_sbref_nii=1
        cur_dir = os.getcwd()
        for sbref_file in glob.glob('*/*REST*_sbref.nii.gz'):
            if 'run' in sbref_file:
                continue
            
            newName = sbref_file.replace("_sbref",f"_run-0{counter_sbref_nii}_sbref")
            if newName != sbref_file:
                source = os.path.join(cur_dir,sbref_file)
                dest = os.path.join(cur_dir,newName)
                os.rename(source,dest)

            
            counter_sbref_nii += 1
            
        # rename sbref json files by the number of run of the same task 
        counter_sbref_json=1
        for sbref_json in glob.glob('*/*REST*_sbref.json' ):
            if 'run' in sbref_json:
                continue
            newName = sbref_json.replace("_sbref",f"_run-0{counter_sbref_json}_sbref")
            if newName != sbref_json:
                source = os.path.join(cur_dir,sbref_json)
                dest = os.path.join(cur_dir,newName)
                os.rename(source,dest)
            counter_sbref_json += 1
            
        # rename bold nii.gz files by the number of run of the same task 
        counter_bold_nii=1
        for bold_file in glob.glob('*/*REST*_bold.nii.gz' ):
            if 'run' in bold_file:
                continue
            newName = bold_file.replace("_bold",f"_run-0{counter_bold_nii}_bold")
            if newName != bold_file:
                source = os.path.join(cur_dir,bold_file)
                dest = os.path.join(cur_dir,newName)
                os.rename(source,dest)
            counter_bold_nii += 1
            
        # rename bold json files by the number of run of the same task 
        counter_bold_json=1
        for bold_json in glob.glob('*/*REST*_bold.json' ):
            if 'run' in bold_json:
                continue
            newName = bold_json.replace("_bold",f"_run-0{counter_bold_json}_bold")
            if newName != bold_json:
                source = os.path.join(cur_dir,bold_json)
                dest = os.path.join(cur_dir, newName)
                os.rename(source,dest)
            counter_bold_json += 1
            
        directories_in_curdir = list(filter(os.path.isdir, os.listdir(os.curdir)))
        # loop all subject folders
        for sub_dir in directories_in_curdir:
            os.chdir(sub_dir) #into each existing folder
            
            cur_dir = os.getcwd()

            source_list =["HCD",
                          "V1_MR",
                          "_SpinEchoFieldMap1_AP",
                          "_SpinEchoFieldMap1_PA",
                          "_SpinEchoFieldMap2_AP",
                          "_SpinEchoFieldMap2_PA",
                          "_SpinEchoFieldMap3_AP",
                          "_SpinEchoFieldMap3_PA",
                          "_SpinEchoFieldMap4_AP",
                          "_SpinEchoFieldMap4_PA",
                          "_SpinEchoFieldMap5_AP",
                          "_SpinEchoFieldMap5_PA",
                          "_SpinEchoFieldMap6_AP",
                          "_SpinEchoFieldMap6_PA",
                          "_SpinEchoFieldMap7_AP",
                          "_SpinEchoFieldMap7_PA",
                          "tfMRI_CARIT_AP_SBRef",
                          "tfMRI_CARIT_AP",
                          "tfMRI_CARIT_PA_SBRef",
                          "tfMRI_CARIT_PA",
                          "tfMRI_EMOTION_AP_SBRef",
                          "tfMRI_EMOTION_AP",
                          "tfMRI_EMOTION_PA_SBRef",
                          "tfMRI_EMOTION_PA",
                          "tfMRI_GUESSING_AP_SBRef",
                          "tfMRI_GUESSING_AP",
                          "tfMRI_GUESSING_PA_SBRef",
                          "tfMRI_GUESSING_PA",
                          "dMRI_dir98_AP_SBRef",
                          "dMRI_dir98_AP",
                          "dMRI_dir98_PA_SBRef",
                          "dMRI_dir98_PA",
                          "dMRI_dir99_AP_SBRef",
                          "dMRI_dir99_AP",
                          "dMRI_dir99_PA_SBRef",
                          "dMRI_dir99_PA",
                          "T1w_MPR_vNav_4e_e1e2_mean",
                          "T2w_SPC_vNav"]
            dest_list = ["sub-",
                         "ses-V1",
                         "_dir-AP_run-01_epi",
                         "_dir-PA_run-01_epi",
                         "_dir-AP_run-02_epi",
                         "_dir-PA_run-02_epi",
                         "_dir-AP_run-03_epi",
                         "_dir-PA_run-03_epi",
                         "_dir-AP_run-04_epi",
                         "_dir-PA_run-04_epi",
                         "_dir-AP_run-05_epi",
                         "_dir-PA_run-05_epi",
                         "_dir-AP_run-06_epi",
                         "_dir-PA_run-06_epi",
                         "_dir-AP_run-07_epi",
                         "_dir-PA_run-07_epi",
                         "task-carit_dir-AP_run-01_sbref",
                         "task-carit_dir-AP_run-01_bold",
                         "task-carit_dir-PA_run-02_sbref",
                         "task-carit_dir-PA_run-02_bold",
                         "task-emotion_dir-AP_run-01_sbref",
                         "task-emotion_dir-AP_run-01_bold",
                         "task-emotion_dir-PA_run-02_sbref",
                         "task-emotion_dir-PA_run-02_bold",
                         "task-guessing_dir-AP_run-01_sbref",
                         "task-guessing_dir-AP_run-01_bold",
                         "task-guessing_dir-PA_run-02_sbref",
                         "task-guessing_dir-PA_run-02_bold",
                         "acq-dir98_dir-AP_run-01_sbref",
                         "acq-dir98_dir-AP_run-01_dwi",
                         "acq-dir98_dir-PA_run-02_sbref",
                         "acq-dir98_dir-PA_run-02_dwi",
                         "acq-dir99_dir-AP_run-03_sbref",
                         "acq-dir99_dir-AP_run-03_dwi",
                         "acq-dir99_dir-PA_run-04_sbref",
                         "acq-dir99_dir-PA_run-04_dwi",
                         "T1w",
                         "T2w"]
            for index, item in enumerate(source_list):
                rename_list_of_files(source_list[index], dest_list[index], cur_dir)
            if glob.glob('*run-01_epi*'):
                move_glob_files('/*','/../S1',cur_dir )
            if glob.glob('*run-02_epi*'):
                move_glob_files('/*','/../S2',cur_dir)
            if glob.glob('*run-03_epi*'): 
                move_glob_files('/*','/../S3',cur_dir)
            if glob.glob('*run-04_epi*'): 
                move_glob_files('/*','/../S4',cur_dir)
            if glob.glob('*run-05_epi*'): 
                move_glob_files('/*','/../S5',cur_dir)
            if glob.glob('*run-06_epi*'): 
                move_glob_files('/*','/../S6',cur_dir)
            if glob.glob('*run-07_epi*'): 
                move_glob_files('/*','/../S7',cur_dir)
            os.chdir('..') #out of ses-V1
        
        # add IntendedFor fields for EPI fieldmap jsons
        fmap_poss = glob.glob('*/*epi.json')
        folders = glob.glob('*/')
        cur_dir = os.getcwd()
        folders = [ os.path.join(cur_dir, ls) for ls in folders] # using list comprehension
        fmap_poss = [ os.path.join(cur_dir, ls) for ls in fmap_poss]
        for b in range (0, len(fmap_poss)):
            intended_for = list()
            for m in range (0, len(folders)):
                folders[m] = os.path.join(cur_dir, folders[m])
                os.chdir(folders[m])
                folder_contents = glob.glob('*')
                intended_subset = list(set(glob.glob('*.nii.gz')) - set(glob.glob('*epi.nii.gz')))
                basename = os.path.basename(fmap_poss[b])
                if basename in folder_contents:
                    intended_for.append(intended_subset)
                else:
                    pass
                os.chdir('..')
        
           
            with open(fmap_poss[b]) as json_file:
                data = json.load(json_file)

            [new_list] = intended_for
            if intended_for == list():
                data['IntendedFor'] = str()
            else:
                data['IntendedFor'] = new_list
            with open(fmap_poss[b], 'w') as json_file:
                json.dump(data, json_file)
        
        os.chdir('..')
        cur_dir = os.getcwd()
        move_glob_files('/ses-V1/*/*epi*','/ses-V1/fmap',cur_dir )
        move_glob_files('/ses-V1/*/*task-*','/ses-V1/func',cur_dir)
        move_glob_files('/ses-V1/*/*acq-dir*','/ses-V1/dwi',cur_dir)
        move_glob_files('/ses-V1/*/*T1w*','/ses-V1/anat',cur_dir)
        move_glob_files('/ses-V1/*/*T2w*','/ses-V1/anat',cur_dir)
        #remove excess files / folders
        remove_glob_files('/ses-V1/*fMRI*/',cur_dir)
        remove_glob_files('/ses-V1/*vNav*/',cur_dir)
        remove_glob_files('/ses-V1/*PCAS*/',cur_dir)
        if os.path.isdir('./ses-V1/Diffusion'):
            shutil.rmtree(os.path.join(cur_dir, 'ses-V1/Diffusion'))
        if os.path.isdir('ses-V1/S1'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S1'))
        if os.path.isdir('ses-V1/S2'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S2'))
        if os.path.isdir('./ses-V1/S3'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S3'))
        if os.path.isdir('./ses-V1/S4'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S4'))
        if os.path.isdir('./ses-V1/S5'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S5'))
        if os.path.isdir('./ses-V1/S6'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S6'))
        if os.path.isdir('./ses-V1/S7'):
            shutil.rmtree(os.path.join(cur_dir,'ses-V1/S7'))
        os.chdir('..')


        
    # create participants.tsv file
    subjects = glob.glob('sub-*')

    
    # create problem_fmapjsons.txt
    fmap_json = glob.glob('sub*/*/fmap/*epi.json')
    t1w = '_T1w'
    t2w = '_T2w'
    dir99 = 'dir99'
    dir98 = 'dir98'
    
    # add ses-V1/dwi or ses-V1/anat or ses-V1/func to the IntendedFor field
    for i in range (0, len(fmap_json)):
        with open(fmap_json[i]) as json_file:
            data = json.load(json_file)
        if 'IntendedFor' in data:
            for j in range (0, len(data['IntendedFor'])):
                if dir99 in data['IntendedFor'][j]:
                    data['IntendedFor'][j] = 'ses-V1/dwi/' + str(data['IntendedFor'][j])
                elif dir98 in data['IntendedFor'][j]:
                    data['IntendedFor'][j] = 'ses-V1/dwi/' + str(data['IntendedFor'][j])
                elif t1w in data['IntendedFor'][j]:
                    data['IntendedFor'][j] = 'ses-V1/anat/' + str(data['IntendedFor'][j])
                elif t2w in data['IntendedFor'][j]:
                    data['IntendedFor'][j] = 'ses-V1/anat/' + str(data['IntendedFor'][j])
                else:
                    data['IntendedFor'][j] = 'ses-V1/func/' + str(data['IntendedFor'][j])


       
        with open(fmap_json[i], 'w') as json_file:
            json.dump(data,json_file)


if __name__ == '__main__':
    main()
