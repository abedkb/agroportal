#!/usr/bin/env python3
"""
period_aggregate.py
====================
Calendar-aligned dekad (10-day) and pentad (5-day) aggregation.

CDO has no native operator for these, because they are anchored to
calendar months (dekad: days 1-10, 11-20, 21-end; pentad: days 1-5,
6-10, 11-15, 16-20, 21-25, 26-end), not fixed N-day windows. CDO's
timselmean/timselsum,N instead chunk the flat sequence of timesteps by
N regardless of month boundaries -- fine for the first 30-day month,
then drifts out of calendar alignment. This script groups by pandas
calendar fields instead, which stays correctly anchored indefinitely.

Used by both noaa_pipeline.sh (--stat mean, for state variables like
temperature/humidity/wind) and run_chirps_pipeline.sh (--stat sum, for
accumulative rainfall -- summing daily mm gives period-total mm, which
is the standard meteorological convention for rainfall products).

Usage:
    python3 period_aggregate.py --nc input.nc --var precip \
        --period dekad --stat sum --out output.nc
    python3 period_aggregate.py --nc input.nc --var air \
        --period pentad --stat mean --out output.nc
"""
import argparse
import sys

import numpy as np
import pandas as pd
import xarray as xr


def dekad_index(day: int) -> int:
    """1, 2, or 3 -- days 1-10, 11-20, 21-end of month."""
    if day <= 10:
        return 1
    if day <= 20:
        return 2
    return 3


def pentad_index(day: int) -> int:
    """1..6 -- days 1-5, 6-10, 11-15, 16-20, 21-25, 26-end of month
    (the 6th group absorbs the trailing 3-6 days depending on month
    length, rather than creating a short 7th group)."""
    return min((day - 1) // 5 + 1, 6)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--nc", required=True)
    p.add_argument("--var", required=True)
    p.add_argument("--period", required=True, choices=["dekad", "pentad"])
    p.add_argument("--stat", required=True, choices=["sum", "mean"],
                    help="sum for accumulative quantities (rainfall); mean for state variables")
    p.add_argument("--out", required=True)
    args = p.parse_args()

    ds = xr.open_dataset(args.nc)
    if args.var not in ds:
        print(f"[ERROR] Variable '{args.var}' not found in {args.nc}. "
              f"Available: {list(ds.data_vars)}", file=sys.stderr)
        sys.exit(1)

    da = ds[args.var]

    # Normalize the time axis to pandas datetime fields regardless of
    # whether xarray decoded it as datetime64 or a cftime calendar.
    time_vals = da["time"].values
    if np.issubdtype(time_vals.dtype, np.datetime64):
        pt = pd.DatetimeIndex(time_vals)
        years, months, days = pt.year.values, pt.month.values, pt.day.values
    else:
        cft = xr.CFTimeIndex(time_vals)
        years = np.array([t.year for t in cft])
        months = np.array([t.month for t in cft])
        days = np.array([t.day for t in cft])

    idx_fn = dekad_index if args.period == "dekad" else pentad_index
    period_idx = np.array([idx_fn(int(d)) for d in days])

    # Single integer key identifying one dekad/pentad instance, e.g.
    # 2020, June, dekad 2 -> 202006 02 -> 20200602
    group_key = years.astype(np.int64) * 10000 + months.astype(np.int64) * 100 + period_idx
    da = da.assign_coords(_group=("time", group_key))

    if args.stat == "sum":
        out = da.groupby("_group").sum(dim="time", skipna=True)
    else:
        out = da.groupby("_group").mean(dim="time", skipna=True)

    # Rebuild a real, usable timestamp per group (first day of that
    # dekad/pentad) from the group labels xarray actually produced --
    # not recomputed separately, to guarantee matching order/values.
    resolved_keys = out["_group"].values
    rep_times = []
    for g in resolved_keys:
        g = int(g)
        yy, rem = divmod(g, 10000)
        mm, pidx = divmod(rem, 100)
        first_day = {1: 1, 2: 11, 3: 21}[pidx] if args.period == "dekad" else (pidx - 1) * 5 + 1
        rep_times.append(np.datetime64(f"{yy:04d}-{mm:02d}-{first_day:02d}"))

    out = out.assign_coords(_group=np.array(rep_times)).rename({"_group": "time"})
    out = out.sortby("time")
    out.attrs = da.attrs

    out.to_dataset(name=args.var).to_netcdf(args.out)
    print(f"[OK] {args.period} {args.stat} -> {args.out} ({out.sizes['time']} periods)")


if __name__ == "__main__":
    main()
