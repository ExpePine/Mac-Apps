"""Terminal alternative to the app's Setup tab.
Usage:  python run_pipeline.py --root "/path/to/data" [--limit 200] [--steps index,extract,train]"""
import argparse
import config, pipeline

ap = argparse.ArgumentParser()
ap.add_argument("--root", default=None)
ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--steps", default="index,extract,train")
a = ap.parse_args()
s = config.load()
if a.root:
    s["data_root"] = a.root
    config.save(s)
steps = a.steps.split(",")
if "index" in steps:
    pipeline.build_index(s["data_root"], s)
if "extract" in steps:
    pipeline.extract(limit=a.limit)
if "train" in steps:
    pipeline.train()
