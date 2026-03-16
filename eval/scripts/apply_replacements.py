#!/usr/bin/env python3
"""Replace outlier rows in evaluation CSVs with rerun data."""
import csv
import sys
import os

RESULTS_DIR = 'eval/results'
RERUN_FILE = 'eval/results/rerun-outliers/replacements.csv'

CONFIG_TO_FILE = {
    'statefulset-sequential': 'migration-metrics-statefulset-sequential-20260316-010528.csv',
    'statefulset-shadowpod': 'migration-metrics-statefulset-shadowpod-20260316-041245.csv',
    'statefulset-shadowpod-swap': 'migration-metrics-statefulset-shadowpod-swap-20260316-061626.csv',
    'deployment-registry': 'migration-metrics-deployment-registry-20260316-092946.csv',
}

# Read replacements
replacements = {}  # (config, run_num) -> csv_line
with open(RERUN_FILE) as f:
    reader = csv.reader(f)
    header = next(reader)
    for row in reader:
        run_num = row[0]
        config = row[2]
        replacements[(config, run_num)] = row

print(f"Loaded {len(replacements)} replacement rows")

# Apply to each file
for config, filename in CONFIG_TO_FILE.items():
    filepath = os.path.join(RESULTS_DIR, filename)

    # Read all rows
    with open(filepath) as f:
        reader = csv.reader(f)
        file_header = next(reader)
        rows = list(reader)

    # Replace matching rows
    replaced = 0
    for i, row in enumerate(rows):
        run_num = row[0]
        key = (config, run_num)
        if key in replacements:
            new_row = replacements[key]
            print(f"  {config} run={run_num}: replacing")
            print(f"    OLD: {','.join(row)}")
            print(f"    NEW: {','.join(new_row)}")
            rows[i] = new_row
            replaced += 1

    if replaced > 0:
        # Write back
        with open(filepath, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(file_header)
            writer.writerows(rows)
        print(f"  -> Updated {replaced} rows in {filename}")
    else:
        print(f"  -> No changes for {filename}")

print(f"\nDone. Total replacements applied: {sum(1 for c in CONFIG_TO_FILE for r in replacements if r[0] == c)}")
