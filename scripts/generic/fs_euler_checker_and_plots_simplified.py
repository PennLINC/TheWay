from pathlib import Path
import re
import pandas as pd
import subprocess
import zipfile
import sys
import os
import shutil
import matplotlib.pyplot as plt
import nilearn.image as nim
import nilearn.plotting as nip


"""
Get the FreeSurfer statistics and a plot of the T1w image after a
FMRIPrep/FreeSurfer run.  Must be run from a clone of the analysis directory.
Expects only one zip per subject.  A one-line CSV and a SVG image are written
to the csvs/ and svg/ directory respectively.

USAGE: fs_euler_checker_and_plots_simplified.py subjectID zips_dir

Arguments:
----------

  subjectID: sub-*, the BIDS subject identifier. NOTE: can also be
             sub-X_ses-Y if multisession
  zips_dir: path, relative to the current working directory
"""

subid = sys.argv[1]
input_zip_dir = Path(sys.argv[2])
if not input_zip_dir.exists():
    raise ValueError("Must provide a directory with zip files")

# Set up the working/output directories
unzip_temp_dir = Path("temp")
unzip_temp_dir.mkdir(exist_ok=True)
output_dir = Path("csvs")
output_dir.mkdir(exist_ok=True)
output_svg_dir = Path("svg")
output_svg_dir.mkdir(exist_ok=True)
# This dictionary holds all the info we're going to collect on this subject
fs_audit = {'SubjectID': subid}

# Find the zip files we need to extract
freesurfer_zips = list(
    input_zip_dir.rglob("**/*{}*freesurfer*zip".format(subid)))
print("Found FreeSurfer archives:\n   ",
      "\n   ".join(map(str, freesurfer_zips)))

fmriprep_zips = list(
    input_zip_dir.rglob("**/*{}*fmriprep*zip".format(subid)))
print("Found FMRIPrep archives:\n   ",
      "\n   ".join(map(str, fmriprep_zips)))

if not len(fmriprep_zips) == len(freesurfer_zips) == 1:
    raise Exception("Exactly 1 FMRIPrep and 1 FreeSurfer must match " + subid)

fmriprep_zip = str(fmriprep_zips[0])
freesurfer_zip = str(freesurfer_zips[0])

# Unpack the freesurfer zip
with zipfile.ZipFile(freesurfer_zip, 'r') as zip_ref:
    zip_ref.extractall(str(unzip_temp_dir))

# File paths
l_orig_nofix = str(unzip_temp_dir / 'freesurfer' / subid /
                   'surf' / 'lh.orig.nofix')
r_orig_nofix = str(unzip_temp_dir / 'freesurfer' / subid /
                   'surf' / 'rh.orig.nofix')
l_euler_textfile = str(unzip_temp_dir / "l_euler.txt")
r_euler_textfile = str(unzip_temp_dir / "r_euler.txt")

# run mris_euler
subprocess.run(["mris_euler_number", "-o", l_euler_textfile, l_orig_nofix])
subprocess.run(["mris_euler_number", "-o", r_euler_textfile, r_orig_nofix])


def read_euler(euler_file, hemi, info):
    """Reads the output from mris_euler_number
    """
    with open(euler_file) as eulerf:
        lines = eulerf.readlines()
    print("content of", euler_file)
    print("\n".join(lines))

    # sanity check the content of the euler output
    if not lines:
        raise Exception("Not enough lines generated")
    first_line = lines[0]

    # split into components
    tokens = first_line.strip().split(" ")

    if len(tokens) > 2:
        num_holes = float(tokens[3])
    elif len(tokens) == 1:
        num_holes = float(tokens[0])
    else:
        raise Exception("required number of outputs not available")

    info[hemi + '_NumHoles'] = num_holes
    euler_number = abs(2 - 2 * num_holes)
    info[hemi + '_EulerNumber'] = euler_number

    defect_index = 2 * num_holes
    info[hemi + '_DefectIndex'] = defect_index


def read_surf_stats(stats_name, source_id, info, get_measures=False):
    """Reads stats from the aparc stats table.

    Parameters:
    ===========

    stats_name: str
        Name of the .stats file to parts
    source_id: str
        ID for these stats in the output ()
    info: dict
        Dictionary containing other collected info about the run
    get_measures: bool
        Should the # Measure lines be parsed and added to info?
    Returns: Nothing. the info dict gets keys/values added to it

    """
    stats_file = unzip_temp_dir / "freesurfer" / subid / "stats" / stats_name
    if not stats_file.exists():
        raise Exception(str(stats_file) + "does not exist")

    with stats_file.open("r") as statsf:
        lines = statsf.readlines()

    # Get the column names by finding the line with the header tag in it
    header_tag = "# ColHeaders"
    header, = [line for line in lines if header_tag in line]
    header = header[len(header_tag):].strip().split()

    stats_df = pd.read_csv(
        str(stats_file),
        sep='\s+',
        comment="#",
        names=header).melt(id_vars=["StructName"])

    if stats_name.startswith("lh"):
        prefix = "Left"
    elif stats_name.startswith("rh"):
        prefix = "Right"
    else:
        prefix = "Both"

    # Get it into a nice form
    stats_df['FlatName'] = prefix + '_' + stats_df['variable'] + "_" \
        + source_id + "_" + stats_df['StructName']
    for _, row in stats_df.iterrows():
        info[row['FlatName']] = row['value']

    if get_measures:
        get_stat_measures(stats_file, prefix, info)


def get_stat_measures(stats_file, prefix, info):
    """Read a "Measure" from a stats file.

    Parameters:
    ===========

    stats_file: Path
        Path to a .stats file containing the measure you want
    info: dict
        Dictionary with all this subject's info
    """
    with stats_file.open("r") as statsf:
        lines = statsf.readlines()

    measure_pat = re.compile(
        "# Measure ([A-Za-z]+), ([A-Za-z]+),* [-A-Za-z ]+, ([0-9.]+), .*")
    for line in lines:
        match = re.match(measure_pat, line)
        if match:
            pt1, pt2, value = match.groups()
            key = "{}_{}_{}".format(prefix, pt1, pt2)
            info[key] = float(value)


# modify fs_audit inplace: stats from euler number
read_euler(l_euler_textfile, "Left", fs_audit)
read_euler(r_euler_textfile, "Right", fs_audit)
fs_audit['AverageEulerNumber'] = abs(
        float(fs_audit['Right_EulerNumber'] +
              fs_audit['Left_EulerNumber']) / 2.0)

# Add stats from the DKT atlas
read_surf_stats("lh.aparc.DKTatlas.stats", "DKT", fs_audit)
read_surf_stats("rh.aparc.DKTatlas.stats", "DKT", fs_audit)
read_surf_stats("lh.aparc.pial.stats", "Pial", fs_audit, get_measures=True)
read_surf_stats("rh.aparc.pial.stats", "Pial", fs_audit, get_measures=True)
read_surf_stats("aseg.stats", "aseg", fs_audit, get_measures=True)

pd.DataFrame([fs_audit]).to_csv(str(output_dir / (subid + "audit.csv")))


# Do the plotting!
t1w_pat = re.compile("((?!space-).)*T1w.nii.gz")
t1w_svg = re.compile("((?!space-).)*reconall_T1w.svg")

# Exract the t1w from the zip file
with zipfile.ZipFile(str(fmriprep_zip), 'r') as zip_ref_fmri:
    zip_contents = zip_ref_fmri.namelist()

    t1_svg_candidates = [
        fname for fname in zip_contents if re.match(t1w_svg, fname)]

    if not t1_svg_candidates:
        raise Exception("No native-space T1w svgs were found")
    if len(t1_svg_candidates) > 1:
        raise Exception("Too many possible T1w svgs were found")

    t1w_svg_path = t1_svg_candidates[0]
    svg_orig_filename = Path(t1w_svg_path).name
    svg_orig_path = str(Path(t1w_svg_path))
    svg_external_path = unzip_temp_dir /  svg_orig_path


    svg_fname = "%05d" % fs_audit['AverageEulerNumber'] + "_" \
        + svg_orig_filename

    svg_result_path = output_svg_dir / svg_fname

    # copy svg file to result directory
    with zip_ref_fmri.open(t1w_svg_path, "r") as t1w_svg_srcf:
        with svg_result_path.open('wb+') as t1w_svg_destf:
            shutil.copyfileobj(t1w_svg_srcf, t1w_svg_destf)
                              
