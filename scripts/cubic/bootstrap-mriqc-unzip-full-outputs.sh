#!/bin/bash
PROJECTROOT=/cbica/projects/RBC/production/PNC/mriqc
cd ${PROJECTROOT}
RIA=${PROJECTROOT}/output_ria
datalad create -c yoda -D "extract mriqc results" unzipped-results-duplicate
cd unzipped-results-duplicate
datalad clone -d . --reckless ephemeral "ria+file://${RIA}#~data" inputs/data
datalad clone -d . ../pennlinc-containers

## the actual compute job specification
cat > code/get_files.sh << "EOT"
#!/bin/bash
set -e -u -x

ZIP_FILE=$1

# Create a mriqc/ directory
#unzip -j $ZIP_FILE "mriqc/sub-4238772277/ses-PNC1/anat/sub-4238772277_ses-PNC1_acq-refaced_T1w.json" -d "mriqc_results" 


#subid=$(basename "${ZIP_FILE%.*}")
#subid=${subid%_*}
#echo $subid
# Create a mriqc/ directory
unzip -o $ZIP_FILE -x 'mriqc/*.html' 


EOT

cat > code/mriqc-group.sh << "EOT"
#!/bin/bash
set -e -u -x
datalad get ${PWD}/pennlinc-containers/.datalad/environments/mriqc-0-16-1/image
# create group reports for the anatomical T1w data
singularity exec --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/mriqc-0-16-1/image \
    python code/group_results.py

EOT

cat > code/group_results.py << "EOT"

from pathlib import Path
from mriqc.reports import group_html
from mriqc.utils.bids import DEFAULT_TYPES
from mriqc.utils.misc import generate_tsv

if __name__ == '__main__':
    output_dir = Path(".") / "mriqc"
    # Generate reports
    mod_group_reports = []
    for mod in DEFAULT_TYPES:
        dataframe, out_tsv = generate_tsv(output_dir, mod)
        # If there are no iqm.json files, nothing to do.
        if dataframe is None:
            continue

        print(f"Generated summary TSV table for the {mod} data ({out_tsv})")

        # out_pred = generate_pred(derivatives_dir, settings['output_dir'], mod)
        # if out_pred is not None:
        #     log.info('Predicted QA CSV table for the %s data generated (%s)',
        #                    mod, out_pred)

        out_html = output_dir / f"group_{mod}.html"
        group_html(
            out_tsv,
            mod,
            csv_failed=output_dir / f"group_variant-failed_{mod}.csv",
            out_file=out_html,
        )

        print(f"Group-{mod} report generated ({out_html})")
        mod_group_reports.append(mod)

    if not mod_group_reports:
        raise Exception("No data found. No group level reports were generated.")

    print("Group level finished successfully.")
EOT

datalad save -m "Add data extraction code" code

zip_files=$(find inputs/data/ -name '*.zip')
for input_zip in ${zip_files}
do
    subid=$(basename "${input_zip%.*}")
    subid=${subid%_*}
    outdir=.

    datalad run \
        -i pennlinc-containers/.datalad/environments/fmriprep-20-2-3/image \
        -i ${input_zip} \
        -o ${outdir}/${subid} \
        --explicit \
        "bash code/get_files.sh ${input_zip}"
done

# CRITICAL: Don't uninstall the inputs - it will delete your data
rm -rf inputs
