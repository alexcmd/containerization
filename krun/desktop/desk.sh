#!/bin/sh
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

# GPU desktop inside a krun container: weston on the virtio-gpu display,
# vkcube rendering through Venus. Run it as the container's process with a
# host directory mounted at $DESK (default /desk) that holds this script and
# weston.ini; logs go to $DESK/out/.
#
#   cctl run --vmm krun --gpu venus --display 1280x800 ... \
#       --mount <dir>:/desk -i <image with weston, seatd, vkcube> /desk/desk.sh
#
# Control channel: drop NAME.sh into $DESK/ctl/ and it runs in the guest, with
# its output in $DESK/ctl/NAME.out (cctl has no exec).

DESK=${DESK:-/desk}
OUT=$DESK/out
mkdir -p "$OUT" "$DESK/ctl"
exec > "$OUT/desk.log" 2>&1
set -x

export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/virtio_icd.aarch64.json
ls -la /dev/dri /dev/input
cat /sys/class/drm/card0-*/modes 2>/dev/null | head -3

# Network check (gvproxy), in the background.
( cat /etc/resolv.conf; getent hosts example.com
  curl -sS -o /dev/null -w "curl https://example.com -> HTTP %{http_code} in %{time_total}s\n" https://example.com
) > "$OUT/net.log" 2>&1 &

# libinput only uses devices udev has initialised, and uevents never reach
# this container's network namespace, so write udev's database by hand.
mkdir -p /run/udev/data
for ev in /sys/class/input/event*; do
  [ -e "$ev/dev" ] || continue
  devno=$(cat "$ev/dev")
  {
    echo "I:1"
    udevadm test-builtin input_id "$ev" 2>/dev/null | grep '^ID_INPUT' | sed 's/^/E:/'
    echo "G:seat"
    echo "Q:seat"
  } > "/run/udev/data/c$devno"
  echo "== $ev ($(cat "$ev/device/name"))"; cat "/run/udev/data/c$devno"
done

seatd -g root > "$OUT/seatd.log" 2>&1 &
sleep 1
export LIBSEAT_BACKEND=seatd

weston --debug --config="$DESK/weston.ini" --backend=drm --renderer=pixman \
  --continue-without-input --idle-time=0 --log="$OUT/weston.log" &
WPID=$!
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.2; done
export WAYLAND_DISPLAY=wayland-1

weston-terminal > "$OUT/terminal.log" 2>&1 &
vkcube --wsi wayland > "$OUT/vkcube.log" 2>&1 &

set +x
while kill -0 $WPID 2>/dev/null; do
  for f in "$DESK"/ctl/*.sh; do
    [ -f "$f" ] || continue
    mv "$f" "$f.running"
    sh "$f.running" > "${f%.sh}.out" 2>&1
    mv "$f.running" "$f.done"
  done
  sleep 0.5
done
echo "weston exited"
