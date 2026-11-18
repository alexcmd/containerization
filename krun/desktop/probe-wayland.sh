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

# Guest probe (run through desk.sh's control channel): restart vkcube with
# Wayland protocol tracing for PROBE_SECONDS, then restart it normally. The
# trace shows vkcube's own frame cadence and whether weston presented or
# discarded each frame.
DESK=${DESK:-/desk}
export XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-1
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/virtio_icd.aarch64.json
pkill -x vkcube; sleep 0.5
WAYLAND_DEBUG=client timeout "${PROBE_SECONDS:-15}" vkcube --wsi wayland > /dev/null 2> "$DESK/out/wayland-trace.log"
setsid vkcube --wsi wayland > "$DESK/out/vkcube.log" 2>&1 < /dev/null &
echo "trace lines: $(wc -l < "$DESK/out/wayland-trace.log")"
