#!/usr/bin/env python3
"""Packs the per-window voice embeddings written by `minutes-bench --voices` into small binary
files (half-precision, compressed), so they can be published and studied.

usage: pack_voices.py DIR [--no-rho]     (needs numpy; replaces each <name>.voices.json with <name>.voices.npz)
--no-rho leaves out the second set of features, halving the size, for long recordings.
"""
import glob, json, os, sys
import numpy as np

keep_rho = "--no-rho" not in sys.argv
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.voices.json"))):
    rows = json.load(open(path))
    out = path[: -len(".json")] + ".npz"
    extra = {"rho": np.array([r["rho"] for r in rows], dtype=np.float16).reshape(len(rows), -1)} if keep_rho else {}
    np.savez_compressed(
        out,
        window=np.array([r["window"] for r in rows], dtype=np.int32),
        slot=np.array([r["slot"] for r in rows], dtype=np.int8),
        start=np.array([r["start"] for r in rows], dtype=np.float32),
        end=np.array([r["end"] for r in rows], dtype=np.float32),
        speaker=np.array([r["speaker"] for r in rows]),
        embedding=np.array([r["embedding"] for r in rows], dtype=np.float16).reshape(len(rows), -1),
        **extra,
    )
    os.remove(path)
    print(f"{os.path.basename(out)}: {len(rows)} window voices, {os.path.getsize(out) // 1024} KB")
