#!/usr/bin/env python3
"""Read cumulative CPU time and resident memory of a running Mochlet process.

Set up the native UI state before invoking this tool; it does not control the UI.
This measures an idle sample, not interaction latency or a mixed-workload soak.
"""
import argparse
import datetime
import json
import pathlib
import platform
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=int, default=60)
parser.add_argument("--label", required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
if args.pid <= 0 or not 10 <= args.seconds <= 7200:
    parser.error("Use a positive PID and a duration from 10 to 7200 seconds")


def field(name):
    return subprocess.check_output(["/bin/ps", "-p", str(args.pid), "-o", name + "="], text=True).strip()


def cpu_seconds(value):
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        days = int(day_text)
    parts = [float(item) for item in value.split(":")]
    total = 0.0
    for part in parts:
        total = total * 60 + part
    return days * 86400 + total


executable, started = field("comm"), field("lstart")
if pathlib.Path(executable).name != "Mochlet":
    parser.error("The selected PID is not Mochlet")
samples = []
begin = time.monotonic()
while True:
    if field("lstart") != started or field("comm") != executable:
        raise RuntimeError("Process identity changed; measurement is invalid")
    samples.append({"elapsedSeconds": time.monotonic() - begin,
                    "cpuSeconds": cpu_seconds(field("time")), "residentKiB": int(field("rss"))})
    remaining = args.seconds - (time.monotonic() - begin)
    if remaining <= 0:
        break
    time.sleep(min(5, remaining))
elapsed = samples[-1]["elapsedSeconds"] - samples[0]["elapsedSeconds"]
cpu = samples[-1]["cpuSeconds"] - samples[0]["cpuSeconds"]
result = {"recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "label": args.label, "executable": executable, "system": platform.platform(),
          "durationSeconds": elapsed, "cpuSeconds": cpu,
          "averageCPUPercentOfOneCore": cpu / elapsed * 100,
          "residentKiBStart": samples[0]["residentKiB"], "residentKiBEnd": samples[-1]["residentKiB"],
          "residentKiBPeakSampled": max(s["residentKiB"] for s in samples), "samples": samples,
          "limitations": "Single-process cumulative CPU/RSS sample; excludes child processes, GPU, energy, latency and mixed-workload stability."}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=2))
