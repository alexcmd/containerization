#!/usr/bin/env python3
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Summarise krun-vmm display telemetry (KRUN_DISPLAY_TELEMETRY=PATH).

Usage: display-telemetry.py telemetry.csv [--skip S] [--spike MS] [--check]
                                          [--wayland-trace FILE]

Prints a markdown report: per pacing phase, the per-stage percentiles, the
gap histogram, spikes with the stage that caused them, how long frames stayed
on screen, and content repeats. With --check it also applies the limits
below and exits 1 if any fails. --wayland-trace adds the guest-side view
(vkcube's frame cadence and weston's presentation feedback).
"""

import argparse
import csv
import re
import statistics
import sys

# Limits for --check, per phase. Chosen from the healthy runs measured while
# fixing the stutter (IOSurface frames, weston repaint-window=12):
# 59.9 fps, commit p99 0.3 ms, 0.07 guest spikes/s, 99.5% even frames.
LIMITS = {
    "fps_min": 58.0,                # frames from the guest per second
    "spikes_per_s_max": 0.2,        # guest gaps > 25 ms
    "commit_p99_max_ms": 2.0,       # Core Animation commit on the main thread
    "content_repeats_max": 0,       # frames identical to the previous one
    "uneven_pct_max_paced": 2.0,    # on-screen interval off by > 4 ms, pacing on
    "uneven_pct_max_unpaced": 10.0, # same, pacing off (arrival jitter shows)
}


def pct(values, p):
    if not values:
        return 0.0
    v = sorted(values)
    return v[min(len(v) - 1, int(p * (len(v) - 1)))]


def read_csv(path):
    rows = []
    try:
        with open(path) as f:
            for r in csv.DictReader(line for line in f if not line.startswith("#")):
                if all(v not in (None, "") for v in r.values()):  # skip a half-written last row
                    rows.append({k: float(v) for k, v in r.items()})
    except FileNotFoundError:
        pass
    return rows


def phase_report(name, rows, onscreen, spike_ms, paced, checks):
    out = []
    if len(rows) < 10:
        out.append(f"### {name}\n\nnot enough frames ({len(rows)})\n")
        if checks is not None:
            checks.append((f"{name}: enough frames", False))
        return out
    # Sum of this phase's own frame gaps: phases can interleave when pacing is
    # toggled more than once, so first-to-last time would overcount.
    dur = sum(r["gap_ms"] for r in rows) / 1000
    fps = len(rows) / dur if dur > 0 else 0
    out.append(f"### {name}\n")
    out.append(f"{len(rows)} frames over {dur:.1f} s = **{fps:.1f} fps**\n")
    out.append("| stage | p50 | p90 | p99 | max (ms) |\n|---|---|---|---|---|")
    stats = {}
    for k in ["gap", "copy", "build", "queue", "commit", "latency"]:
        if f"{k}_ms" not in rows[0]:
            continue
        v = [r[f"{k}_ms"] for r in rows]
        stats[k] = (pct(v, .5), pct(v, .9), pct(v, .99), max(v))
        out.append(f"| {k} | {stats[k][0]:.2f} | {stats[k][1]:.2f} | {stats[k][2]:.2f} | {stats[k][3]:.2f} |")

    edges = [0, 12, 15, 18, 20, 25, 34, 50, 100, 1e9]
    out.append("\ngap histogram:\n```")
    for lo, hi in zip(edges, edges[1:]):
        n = sum(1 for r in rows if lo <= r["gap_ms"] < hi)
        label = f"{lo:g}-{hi:g} ms" if hi < 1e9 else f">={lo:g} ms"
        out.append(f"{label:>12} {n:6d} {'#' * min(60, n * 60 // max(1, len(rows)))}")
    out.append("```")

    spikes = [r for r in rows if r["gap_ms"] > spike_ms]
    out.append(f"\n{len(spikes)} spikes > {spike_ms:g} ms ({len(spikes) / dur:.2f}/s)")
    for r in spikes[:15]:
        st = {k: r[f"{k}_ms"] for k in ["copy", "build", "queue", "commit"] if f"{k}_ms" in r}
        worst = max(st, key=st.get)
        cause = worst if st[worst] > 8 else "guest (presented late)"
        out.append(f"- t={r['t_ms'] / 1000:.3f}s frame {int(r['seq'])} gap {r['gap_ms']:.1f} ms -> {cause}")

    repeats = sum(1 for r in rows if r.get("content") == 1)
    if "content" in rows[0]:
        jumps = sum(1 for r in rows if r.get("content") == 2)
        out.append(f"\ncontent: {repeats} repeated frames; {jumps} large steps (noisy with a rotating cube, report only)")

    uneven_pct = None
    if onscreen:
        iv = [o["onscreen_ms"] for o in onscreen]
        mode = statistics.median(iv)
        uneven = sum(1 for x in iv if abs(x - mode) > 4)
        uneven_pct = 100 * uneven / len(iv)
        buckets = {}
        for x in iv:
            b = round(x / 8.333)
            buckets[b] = buckets.get(b, 0) + 1
        out.append(f"\non-screen interval: p50 {pct(iv, .5):.2f} p99 {pct(iv, .99):.2f} max {max(iv):.2f} ms; "
                   f"{uneven} of {len(iv)} ({uneven_pct:.1f}%) off by > 4 ms")
        out.append("refreshes on screen (120 Hz units): " + "  ".join(f"{k}x:{v}" for k, v in sorted(buckets.items())))

    if checks is not None:
        uneven_max = LIMITS["uneven_pct_max_paced" if paced else "uneven_pct_max_unpaced"]
        tests = [
            ("fps", fps, f">= {LIMITS['fps_min']}", fps >= LIMITS["fps_min"]),
            ("guest spikes/s", len(spikes) / dur, f"<= {LIMITS['spikes_per_s_max']}", len(spikes) / dur <= LIMITS["spikes_per_s_max"]),
            ("commit p99 ms", stats["commit"][2], f"<= {LIMITS['commit_p99_max_ms']}", stats["commit"][2] <= LIMITS["commit_p99_max_ms"]),
            ("content repeats", repeats, f"<= {LIMITS['content_repeats_max']}", repeats <= LIMITS["content_repeats_max"]),
        ]
        if uneven_pct is not None:
            tests.append(("uneven on-screen %", uneven_pct, f"<= {uneven_max}", uneven_pct <= uneven_max))
        out.append("\n| check | value | limit | result |\n|---|---|---|---|")
        for label, value, limit, ok in tests:
            out.append(f"| {label} | {value:.2f} | {limit} | {'PASS' if ok else '**FAIL**'} |")
            checks.append((f"{name}: {label}", ok))
    out.append("")
    return out


def wayland_report(path):
    ts = re.compile(r"^\[(\d+):(\d+):(\d+)\.(\d+)\]")
    pr = re.compile(r"presented\((\d+), (\d+), (\d+),")
    commits, presented, discarded = [], [], 0
    try:
        f = open(path, errors="replace")
    except FileNotFoundError:
        return ["### guest (Wayland trace)\n\nno trace\n"]
    with f:
        for line in f:
            m = ts.match(line)
            if not m:
                continue
            t = ((int(m.group(1)) * 60 + int(m.group(2))) * 60 + int(m.group(3))) * 1000 + int(m.group(4)) / 1000
            if "-> wl_surface" in line and ".attach(" in line:
                commits.append(t)
            elif ".presented(" in line:
                p = pr.search(line)
                if p:
                    hi, lo, ns = map(int, p.groups())
                    presented.append(((hi << 32) | lo) * 1000 + ns / 1e6)
            elif ".discarded()" in line:
                discarded += 1
    out = ["### guest (Wayland trace of vkcube)\n"]
    d = [b - a for a, b in zip(commits, commits[1:])][30:]
    if d:
        out.append(f"vkcube frames: {len(commits)}; interval p50 {pct(d, .5):.2f} p99 {pct(d, .99):.2f} max {max(d):.2f} ms")
    p = [b - a for a, b in zip(presented, presented[1:])][30:]
    if p:
        out.append(f"weston presented {len(presented)}, discarded {discarded}; presentation interval "
                   f"p50 {pct(p, .5):.2f} p99 {pct(p, .99):.2f} max {max(p):.2f} ms")
    out.append("")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--skip", type=float, default=5.0, help="ignore the first N seconds (startup)")
    ap.add_argument("--until", type=float, default=1e12, help="ignore frames after N seconds (e.g. a probe)")
    ap.add_argument("--spike", type=float, default=25.0, help="gap threshold in ms")
    ap.add_argument("--check", action="store_true", help="apply limits, exit 1 on failure")
    ap.add_argument("--wayland-trace", help="WAYLAND_DEBUG=client trace of vkcube from the guest")
    a = ap.parse_args()

    def window(t):
        return a.skip * 1000 <= t < a.until * 1000

    rows = [r for r in read_csv(a.csv) if window(r["t_ms"]) and r["gap_ms"] > 0]
    onscreen = [o for o in read_csv(a.csv + ".onscreen.csv") if window(o["t_ms"])]
    paced_of = {int(r["seq"]): int(r.get("paced", 1)) for r in rows}

    out = ["# krun display measurement\n"]
    checks = [] if a.check else None
    for paced in sorted(set(paced_of.values()), reverse=True):
        pr = [r for r in rows if int(r.get("paced", 1)) == paced]
        po = [o for o in onscreen if paced_of.get(int(o["seq"])) == paced]
        out += phase_report(f"pacing {'ON' if paced else 'OFF'}", pr, po, a.spike, paced, checks)
    if not paced_of and checks is not None:
        checks.append(("frames recorded", False))
    if a.wayland_trace:
        out += wayland_report(a.wayland_trace)
    if checks is not None:
        failed = [n for n, ok in checks if not ok]
        out.append(f"## Result: {'PASS' if not failed else 'FAIL'} ({len(checks) - len(failed)}/{len(checks)} checks)")
        for n in failed:
            out.append(f"- failed: {n}")
    print("\n".join(out))
    if checks is not None and any(not ok for _, ok in checks):
        sys.exit(1)


if __name__ == "__main__":
    main()
