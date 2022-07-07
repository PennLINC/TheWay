#!/usr/bin/env python
import pandas as pd
import numpy as np 
import os
import glob
import subprocess

os.chdir('/cbica/projects/hcpya/xcp/analysis/code')
df = pd.read_csv('qsub_calls.sh').rename(columns={'#!/bin/bash':'call'})

subjects = np.zeros((df.shape[0]))
for line in df.iterrows():
    if  line[1].values[0]== 'sleep 600':
        subjects[line[0]] = sub 
        continue
    
    sub = line[1].values[0].split(' ')[-2]
    subjects[line[0]] = sub 

df['subject'] = subjects
ran = np.zeros((df.shape[0]))
os.chdir('/cbica/projects/hcpya/xcp/analysis/logs')
for line in df.iterrows():
    
    logs = glob.glob('xcp{0}.o**'.format(str(int(line[1].subject))))
    if len(logs) == 0:
        ran[line[0]] = 0
        continue
    latest_file = max(logs, key=os.path.getctime)
    with open("{0}".format(latest_file), 'r') as f:
        last_line = f.readlines()[-1].split('\n')[0]
        if last_line == 'SUCCESS':
            ran[line[0]] = 1
df['ran'] = ran.astype(bool)

for line in df.iterrows():
    if line[1].ran == True:continue
    else:
        os.system('sleep 600')
        os.system(line[1].call)
#qsub -l h_vmem=4G,s_vmem=4G -N rerunhcp -V -j y -b y -o /cbica/projects/hcpya/xcp/analysis/logs python code/rerun_hcp.py
