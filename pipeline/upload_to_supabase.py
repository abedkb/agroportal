#!/usr/bin/env python3
"""
upload_to_supabase.py
======================
Uploads NOAA pipeline plot images (produced by noaa_pipeline.sh) to Supabase
Storage, and upserts their metadata into the `noaa_products` table that the
TMA AgroMet portal's "Gridded Data Products" gallery reads from.

Called automatically by noaa_pipeline.sh's Step 7 -- just drop this file into
the same directory as noaa_pipeline.sh (i.e. $OUTDIR) and it will be picked
up on the next run. Can also be run by hand:

    export SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
    export SUPABASE_SERVICE_KEY="eyJ..."   # service_role key (Settings > API)
                                            # NOT the anon/public key -- this
                                            # one bypasses Row Level Security
                                            # and must never be shipped to
                                            # the browser/frontend.
    python3 upload_to_supabase.py \
        --plots-dir ./NOAA/plots/shum \
        --var shum --level 850 \
        --start-year 1948 --end-year 2024 \
        --prefix shum/

Requires: pip install requests
"""
import argparse
import mimetypes
import os
import re
import sys

import requests

BUCKET = "noaa-products"
TABLE = "noaa_products"

# Matches the filenames noaa_plot.py actually writes, e.g.:
#   shum_850hPa_monthly_spatial.png
#   shum_850hPa_monthly_timeseries_20.0N_80.0E.png
#   shum_850hPa_monthly_hovmoller_20.0N.png
FNAME_RE_TEMPLATE = (
    r"^{var}_{level}hPa_(?P<aggr>[a-zA-Z]+)_(?P<plot_type>spatial|timeseries|hovmoller)"
)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--plots-dir", required=True, help="Directory of .png/.pdf/.svg plots to upload")
    p.add_argument("--var", required=True)
    p.add_argument("--level", required=True, help="Pressure level label used in the filenames")
    p.add_argument("--start-year", required=True)
    p.add_argument("--end-year", required=True)
    p.add_argument("--prefix", default="", help="Storage path prefix, e.g. 'shum/'")
    return p.parse_args()


def supabase_headers(service_key, extra=None):
    h = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    if extra:
        h.update(extra)
    return h


def upload_file(base_url, service_key, bucket, object_path, local_path):
    content_type = mimetypes.guess_type(local_path)[0] or "application/octet-stream"
    url = f"{base_url}/storage/v1/object/{bucket}/{object_path}"
    with open(local_path, "rb") as f:
        data = f.read()
    resp = requests.post(
        url,
        headers=supabase_headers(service_key, {
            "Content-Type": content_type,
            "x-upsert": "true",  # overwrite if re-uploading the same plot
        }),
        data=data,
        timeout=60,
    )
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Upload failed for {object_path}: {resp.status_code} {resp.text}")
    return f"{base_url}/storage/v1/object/public/{bucket}/{object_path}"


def upsert_row(base_url, service_key, row):
    # on_conflict matches the unique constraint on the table, so re-running
    # the pipeline for the same var/level/aggr/plot_type/years just refreshes
    # the row (new public_url if the file changed) instead of duplicating it.
    url = (
        f"{base_url}/rest/v1/{TABLE}"
        f"?on_conflict=var,level_hpa,aggr,plot_type,start_year,end_year"
    )
    resp = requests.post(
        url,
        headers=supabase_headers(service_key, {
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates,return=minimal",
        }),
        json=[row],
        timeout=30,
    )
    if resp.status_code not in (200, 201, 204):
        raise RuntimeError(f"Metadata upsert failed: {resp.status_code} {resp.text}")


def main():
    args = parse_args()

    base_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not base_url or not service_key:
        print("[ERROR] SUPABASE_URL / SUPABASE_SERVICE_KEY not set.", file=sys.stderr)
        sys.exit(1)
    base_url = base_url.rstrip("/")

    if not os.path.isdir(args.plots_dir):
        print(f"[ERROR] Plots directory not found: {args.plots_dir}", file=sys.stderr)
        sys.exit(1)

    fname_re = re.compile(
        FNAME_RE_TEMPLATE.format(var=re.escape(args.var), level=re.escape(str(args.level)))
    )

    try:
        level_hpa = float(args.level)
    except ValueError:
        level_hpa = None

    uploaded = 0
    skipped = 0
    failed = 0

    for fname in sorted(os.listdir(args.plots_dir)):
        local_path = os.path.join(args.plots_dir, fname)
        if not os.path.isfile(local_path):
            continue

        m = fname_re.match(fname)
        if not m:
            print(f"[SKIP] Doesn't match expected naming pattern: {fname}")
            skipped += 1
            continue

        aggr = m.group("aggr")
        plot_type = m.group("plot_type")
        object_path = f"{args.prefix}{fname}"

        print(f"[INFO] Uploading {fname} -> {BUCKET}/{object_path}")
        try:
            public_url = upload_file(base_url, service_key, BUCKET, object_path, local_path)
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)
            failed += 1
            continue

        row = {
            "var": args.var,
            "level_hpa": level_hpa,
            "aggr": aggr,
            "plot_type": plot_type,
            "start_year": int(args.start_year),
            "end_year": int(args.end_year),
            "public_url": public_url,
        }
        try:
            upsert_row(base_url, service_key, row)
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)
            failed += 1
            continue

        print(f"[OK] {fname} -> {public_url}")
        uploaded += 1

    print(f"\n[SUMMARY] Uploaded: {uploaded}, Skipped: {skipped}, Failed: {failed}")
    if uploaded == 0 and failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
