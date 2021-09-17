#!/bin/bash
# this file checks the output ria for complete job branches and crosschecks
# the original list of jobs to find the difference. The remaining subjects
# printed to stdout or qsubbed using os.system

# USAGE
# python code/rerun_remaining 
#     --output_ria /path/to/output/ria/short_hash/long_hash 
#     [--execute]

import subprocess
import sys
import argparse
import os


def get_branches(ria):
    
    try:
        assert os.path.exists(ria)
        popdir = os.getcwd()
        os.chdir(ria)
        stdout = subprocess.check_output('git branch -a'.split())
        out = stdout.decode()
        branches = [b.strip('* ') for b in out.splitlines()]
        os.chdir(popdir)

        branches2 = [b for b in branches if "job" in b]
        branches3 = [b[b.find("sub"):] for b in branches2]
    
        return branches3
    except:
        print("Error finding RIA branches")
        print("Are you sure you gave the correct path?")
        raise ValueError("No git branches found")


def get_all_jobs():
    
    assert os.getcwd().endswith("analysis"), "Please only run this script from the ANALYSIS subdirectory of your bootstrap directory"
    
    with open('./code/qsub_calls.sh', 'r') as f:
        qsubs = f.readlines()
        
    qsubs2 = []
    
    for x in qsubs[1:]:
        
        subject_start = x[x.find(" sub-")+1:]
        subject_end = subject_start[:subject_start.find(" ")]
        qsubs2.append(subject_end.strip())
    
    return (qsubs, qsubs2)


def main():
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--output_ria", help="path to the output ria", type=str)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    completed_jobs = get_branches(args.output_ria)
    qsub_calls, all_jobs = get_all_jobs()
    
    for i, x in enumerate(all_jobs):
    
        if x in completed_jobs:

            del qsub_calls[i]
            
    if args.execute:
        print("Running qsub on remaining", len(qsub_calls), "jobs")
        for x in qsub_calls:
            os.system(x)
    else:
        print(len(qsub_calls), "remaining jobs:")
        print("\n".join(qsub_calls))
    

if __name__ == "__main__":
    
    main()