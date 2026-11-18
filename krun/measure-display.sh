#!/bin/bash
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

# Display measurement stage for the libkrun GPU desktop.
#
# Boots the weston + vkcube desktop (krun/desktop/) in a window, waits for
# the first frame, warms up, then measures PHASE seconds with frame pacing on
# and PHASE seconds with it off (toggled with SIGUSR1, same boot), runs the
# guest Wayland probe, stops the VM and checks the telemetry against limits.
#
#   krun/measure-display.sh [OUT_DIR]
#
# Env: IMAGE (localhost/gpudesk:latest), PHASE (30), WARMUP (10),
#      BOOT_TIMEOUT (600; rootfs creation for a 1.4 GB image takes ~150 s),
#      KERNEL, INITFS, KRUN_VMM, CCTL, PROBE (1).
# Exit status: 0 all checks passed, 1 a check failed, 2 the run itself failed.
# Output: OUT_DIR/report.md, telemetry.csv (+ .onscreen.csv), vmm.log,
#         desk/out/ (guest logs and the Wayland trace).

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/.local/measure/$(date +%Y%m%d-%H%M%S)}
IMAGE=${IMAGE:-localhost/gpudesk:latest}
PHASE=${PHASE:-30}
WARMUP=${WARMUP:-10}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-600}
KERNEL=${KERNEL:-$REPO/bin/vmlinux-arm64}
INITFS=${INITFS:-$REPO/bin/initfs.ext4}
KRUN_VMM=${KRUN_VMM:-$REPO/bin/krun-vmm}
CCTL=${CCTL:-$REPO/.build/debug/cctl}
PROBE=${PROBE:-1}
ID=measure-$$

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; cleanup; exit 2; }

cleanup() {
    [ -n "${VMM_PID:-}" ] && kill "$VMM_PID" 2>/dev/null
    [ -n "${CCTL_PID:-}" ] && { sleep 2; kill "$CCTL_PID" 2>/dev/null; wait "$CCTL_PID" 2>/dev/null; }
}
trap 'cleanup; exit 2' INT TERM

for f in "$KERNEL" "$INITFS" "$KRUN_VMM" "$CCTL"; do [ -e "$f" ] || die "missing $f"; done
if pgrep -x krun-vmm >/dev/null; then
    die "another krun-vmm is running; stop it first (it would share the GPU and skew the numbers)"
fi

mkdir -p "$OUT/desk/ctl" || die "cannot create $OUT"
cp "$REPO/krun/desktop/desk.sh" "$REPO/krun/desktop/weston.ini" "$REPO/krun/desktop/probe-wayland.sh" "$OUT/desk/"
chmod +x "$OUT/desk/desk.sh"
log "output: $OUT"

# Host conditions: a FAIL under heavy load (other VMs, builds) is environment
# noise, not a regression; the report shows both snapshots.
host_snapshot() {
    echo "#### host $1: $(uptime | sed 's/.*load averages*: /load /')"
    echo '```'
    ps -Ao pcpu,comm -r | head -6 | sed 's#/.*/##' | cut -c1-60
    echo '```'
}
host_snapshot "before" > "$OUT/host.md"

export KRUN_DISPLAY_TELEMETRY=$OUT/telemetry.csv KRUN_DISPLAY_PACING=1 SWIFT_BACKTRACE=enable=no
# script(1) gives cctl the terminal it insists on.
script -q "$OUT/cctl.log" "$CCTL" run -k "$KERNEL" --vmm krun --gpu venus --display 1280x800 \
    --initfs "$INITFS" --krun-vmm "$KRUN_VMM" -i "$IMAGE" --id "$ID" --cpus 6 --memory 4096 --fs-size 4096 \
    --mount "$OUT/desk:/desk" /desk/desk.sh < /dev/null > /dev/null 2>&1 &
CCTL_PID=$!

log "booting (rootfs creation + boot; status every 60 s)"
start=$(date +%s)
while :; do
    [ -s "$OUT/telemetry.csv" ] && [ "$(wc -l < "$OUT/telemetry.csv")" -gt 10 ] && break
    kill -0 "$CCTL_PID" 2>/dev/null || die "cctl exited before the first frame; see $OUT/cctl.log"
    el=$(( $(date +%s) - start ))
    [ "$el" -ge "$BOOT_TIMEOUT" ] && die "no frames after ${BOOT_TIMEOUT}s"
    [ $((el % 60)) -lt 5 ] && [ "$el" -ge 5 ] && log "  still booting (${el}s)"
    sleep 5
done
VMM_PID=$(pgrep -x krun-vmm | head -1)
log "first frame after $(( $(date +%s) - start ))s (krun-vmm pid $VMM_PID)"

# Telemetry time 0 is the first frame; we noticed it a moment later.
T_FIRST=$(python3 -c 'import csv,sys; r=list(csv.DictReader(open(sys.argv[1]))); print(float(r[-1]["t_ms"])/1000)' "$OUT/telemetry.csv" 2>/dev/null || echo 0)
log "warmup ${WARMUP}s"; sleep "$WARMUP"
log "phase 1: pacing ON, ${PHASE}s"; sleep "$PHASE"
kill -USR1 "$VMM_PID"
log "phase 2: pacing OFF, ${PHASE}s"; sleep "$PHASE"

if [ "$PROBE" = 1 ]; then
    log "guest probe: vkcube Wayland trace (15 s)"
    cp "$OUT/desk/probe-wayland.sh" "$OUT/desk/ctl/probe.sh"
    for _ in $(seq 1 30); do [ -f "$OUT/desk/ctl/probe.sh.done" ] && break; sleep 1; done
    [ -f "$OUT/desk/ctl/probe.sh.done" ] || log "  probe did not finish"
fi

# Keep the helper's log before the VM's work directory is removed.
RT="$(getconf DARWIN_USER_TEMP_DIR)krun"
for d in "$RT"/*/; do
    if grep -q "display: scanout" "$d/vmm.log" 2>/dev/null; then cp "$d/vmm.log" "$OUT/vmm.log"; fi
done
host_snapshot "after the phases" >> "$OUT/host.md"
log "stopping the VM"
kill "$VMM_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$CCTL_PID" 2>/dev/null || break; sleep 0.5; done
kill "$CCTL_PID" 2>/dev/null
wait "$CCTL_PID" 2>/dev/null
VMM_PID= CCTL_PID=
pgrep -x krun-vmm >/dev/null && log "WARNING: a krun-vmm is still running"

log "analysis"
# Analyse only the two measured phases; the probe restarts vkcube (a frozen
# moment on purpose) and is reported from its own trace.
UNTIL=$(python3 -c "print($T_FIRST + $WARMUP + 2 * $PHASE)")
python3 "$REPO/krun/display-telemetry.py" "$OUT/telemetry.csv" --skip "$WARMUP" --until "$UNTIL" --check \
    --wayland-trace "$OUT/desk/out/wayland-trace.log" > "$OUT/report.md"
rc=$?
printf '\n## Host conditions\n\n' >> "$OUT/report.md"
cat "$OUT/host.md" >> "$OUT/report.md"
cat "$OUT/report.md"
log "report: $OUT/report.md ($([ $rc = 0 ] && echo PASS || echo FAIL))"
exit $rc
