from pathlib import Path
import pandas as pd
from glob import glob
import zipfile
from tqdm import tqdm

def process_zip(zip_path):
    freesurfer_zip = Path(zip_path)
    subid = freesurfer_zip.stem.split("_")[0]
    sesid = ""
    if "ses-" in freesurfer_zip.stem:
        sesid = freesurfer_zip.stem.split("_")[1]
    if not freesurfer_zip.exists():
        raise ValueError("Must provide a zip file")

    # Get a handle for the freesurfer zip
    zip_ref = zipfile.ZipFile(freesurfer_zip, 'r')

    zip_contents = zip_ref.namelist()
    reconlog, = [pth for pth in zip_contents if 
                    pth.endswith("scripts/recon-all.log") and "sub-" in pth]
    with zip_ref.open(reconlog, "r") as reconlogf:
        log_lines = [line.decode("utf-8").strip() for line in reconlogf]

    def read_qc(target_str):
        data, = [line for line in log_lines if target_str in line]
        data = data.replace(",", "")
        tokens = data.split()
        rh_val = float(tokens[-1])
        lh_val = float(tokens[-4])
        return rh_val, lh_val

    rh_euler, lh_euler = read_qc("lheno")
    rh_holes, lh_holes = read_qc("lhholes")
    return {"rbc_id": subid, "archive": zip_path, "session": sesid,
            "lh_euler": lh_euler, "rh_euler": rh_euler, 
            "lh_holes": lh_holes, "rh_holes": rh_holes}

zip_files = glob("*freesurfer*.zip")
results = []
for zip_file in tqdm(zip_files):
    results.append(process_zip(zip_file))

pd.DataFrame(results).to_csv("../surface_qc.csv", index=False)

