/*
 * Copyright © 2026 Apple Inc. and the Containerization project authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef KRUN_DISPLAY_H
#define KRUN_DISPLAY_H

#include <stdint.h>

// Adds a WIDTHxHEIGHT display, its window backend, and a keyboard plus an
// absolute pointer fed from that window. Call before krun_start_enter.
// Returns 0 or a negative errno.
int krun_display_configure(uint32_t ctx, uint32_t width, uint32_t height);

// Runs AppKit on the calling (main) thread and vm_main(arg) on a new thread.
// Never returns: the process exits when the VM stops or the window closes.
void krun_display_run(const char *title, void (*vm_main)(void *), void *arg);

// Stops helper processes (gvproxy) before the helper exits. Safe to call
// more than once. Defined in krun-vmm.c.
void krun_vmm_cleanup(void);

#endif
