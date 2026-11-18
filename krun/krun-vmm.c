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

// krun-vmm: run one libkrun microVM described by command-line flags.
//
// libkrun's krun_start_enter() takes over the calling process and exit()s
// when the guest stops, so the VM has to live in its own process. The
// containerization backend spawns this helper the same way the
// cloud-hypervisor backend spawns `cloud-hypervisor`.
//
// Flags (repeatable ones marked *):
//   --cpus N --mem MiB --kernel PATH --cmdline STR
//   --disk* ID:PATH               raw block device (first disk = /dev/vda)
//   --disk-ro* ID:PATH            same, read-only (shares ordering with --disk)
//   (KEY:VALUE flags split at the first ':', so paths may contain ':')
//   --virtiofs* TAG:PATH
//   --vsock-connect* PORT:PATH    host connects to PATH -> guest PORT
//   --vsock-listen*  PORT:PATH    guest connects to PORT -> host socket PATH
//   --gpu none|venus              named GPU mode (OpenGL modes reserved)
//   --gpu-flags N                 raw VIRGLRENDERER_* flags, overrides --gpu
//   --gpu-shm BYTES               host-visible window size (default 16 GiB)
//   --console PATH                guest console output file
//   --log-level N                 libkrun log level 0..5
//
// Stopping: SIGTERM/SIGINT end the VM immediately (default action), like
// Virtualization.framework's stop(). libkrun's orderly-shutdown eventfd needs
// a guest-side handler that vminitd does not have. The helper also exits if
// its parent dies, so a crashed host process never leaves an orphaned VM.

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libkrun.h>

#define CHECK(call)                                                          \
    do {                                                                     \
        int32_t _rc = (call);                                                \
        if (_rc < 0) {                                                       \
            fprintf(stderr, "krun-vmm: %s failed: %s\n", #call, strerror(-_rc)); \
            return 1;                                                        \
        }                                                                    \
    } while (0)

// Reparenting to launchd means the host process that owns this VM is gone.
static void *parent_watchdog(void *arg) {
    pid_t parent = (pid_t)(intptr_t)arg;
    for (;;) {
        if (getppid() != parent) {
            fprintf(stderr, "krun-vmm: parent %d exited, stopping VM\n", (int)parent);
            _exit(1);
        }
        usleep(250 * 1000);
    }
    return NULL;
}

// Split "KEY:VALUE" in place at the first ':' only, so VALUE (a host path)
// may itself contain ':' — legal in macOS file names. Returns false if there
// is no ':' or either side is empty.
static bool split_kv(char *s, char **key, char **value) {
    char *colon = strchr(s, ':');
    if (!colon || colon == s || colon[1] == '\0') {
        return false;
    }
    *colon = '\0';
    *key = s;
    *value = colon + 1;
    return true;
}

// Named GPU modes. Only Venus is wired today; OpenGL paths (virgl, native
// context, Zink/ANGLE guest stacks) become new names here once proven.
static int gpu_mode_flags(const char *mode, uint32_t *flags) {
    if (strcmp(mode, "none") == 0) {
        *flags = 0;
        return 0;
    }
    if (strcmp(mode, "venus") == 0) {
        *flags = VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL;
        return 0;
    }
    return -1;
}

static void usage(void) {
    fprintf(stderr, "usage: krun-vmm --kernel PATH --cmdline STR [--cpus N] [--mem MiB] "
                    "[--disk ID:PATH]... [--disk-ro ID:PATH]... [--virtiofs TAG:PATH]... "
                    "[--vsock-connect PORT:PATH]... [--vsock-listen PORT:PATH]... "
                    "[--gpu none|venus] [--gpu-flags N] [--gpu-shm BYTES] "
                    "[--console PATH] [--log-level N]\n");
}

int main(int argc, char **argv) {
    // Record the parent first: if it is already gone (reparented to launchd),
    // there is no owner to run for.
    pid_t parent = getppid();
    if (parent == 1) {
        fprintf(stderr, "krun-vmm: parent already exited\n");
        return 1;
    }
    const char *kernel = NULL, *cmdline = NULL, *console = NULL;
    unsigned long cpus = 2, mem = 1024, log_level = 1;
    uint32_t gpu_flags = 0;
    bool gpu_flags_raw = false;
    uint64_t gpu_shm = 16ULL << 30;

    // First pass: scalars, so the context can be configured in one go.
    for (int i = 1; i < argc; i += 2) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!v) {
            usage();
            return 2;
        }
        if (!strcmp(a, "--kernel")) kernel = v;
        else if (!strcmp(a, "--cmdline")) cmdline = v;
        else if (!strcmp(a, "--console")) console = v;
        else if (!strcmp(a, "--cpus")) cpus = strtoul(v, NULL, 0);
        else if (!strcmp(a, "--mem")) mem = strtoul(v, NULL, 0);
        else if (!strcmp(a, "--log-level")) log_level = strtoul(v, NULL, 0);
        else if (!strcmp(a, "--gpu-shm")) gpu_shm = strtoull(v, NULL, 0);
        else if (!strcmp(a, "--gpu-flags")) {
            gpu_flags = (uint32_t)strtoul(v, NULL, 0);
            gpu_flags_raw = true;
        } else if (!strcmp(a, "--gpu")) {
            if (!gpu_flags_raw && gpu_mode_flags(v, &gpu_flags) < 0) {
                fprintf(stderr, "krun-vmm: unknown --gpu mode '%s'\n", v);
                return 2;
            }
        } else if (strcmp(a, "--disk") && strcmp(a, "--disk-ro") && strcmp(a, "--virtiofs") && strcmp(a, "--vsock-connect") &&
                   strcmp(a, "--vsock-listen")) {
            fprintf(stderr, "krun-vmm: unknown flag %s\n", a);
            usage();
            return 2;
        }
    }
    if (!kernel || !cmdline || cpus == 0 || cpus > 255 || mem == 0) {
        usage();
        return 2;
    }

    CHECK(krun_set_log_level((uint32_t)log_level));
    int32_t ctx = krun_create_ctx();
    if (ctx < 0) {
        fprintf(stderr, "krun-vmm: krun_create_ctx failed: %s\n", strerror(-ctx));
        return 1;
    }
    CHECK(krun_set_vm_config((uint32_t)ctx, (uint8_t)cpus, (uint32_t)mem));
    CHECK(krun_disable_implicit_init((uint32_t)ctx));
    // Plain vsock: no TSI, so guest sockets stay guest sockets and only the
    // explicitly mapped ports reach the host.
    CHECK(krun_disable_implicit_vsock((uint32_t)ctx));
    CHECK(krun_add_vsock((uint32_t)ctx, 0));

    // Second pass: repeatable devices, in command-line order.
    for (int i = 1; i + 1 < argc; i += 2) {
        const char *a = argv[i];
        char *key = NULL, *value = NULL;
        bool is_disk = !strcmp(a, "--disk") || !strcmp(a, "--disk-ro");
        bool is_vsock = !strcmp(a, "--vsock-connect") || !strcmp(a, "--vsock-listen");
        if (!is_disk && !is_vsock && strcmp(a, "--virtiofs")) {
            continue;
        }
        if (!split_kv(argv[i + 1], &key, &value)) {
            fprintf(stderr, "krun-vmm: %s expects KEY:VALUE, got '%s'\n", a, argv[i + 1]);
            return 2;
        }
        if (is_disk) {
            bool ro = !strcmp(a, "--disk-ro");
            CHECK(krun_add_disk2((uint32_t)ctx, key, value, KRUN_DISK_FORMAT_RAW, ro));
        } else if (is_vsock) {
            // listen=true: libkrun owns the socket and the host side dials in.
            bool host_dials = !strcmp(a, "--vsock-connect");
            CHECK(krun_add_vsock_port2((uint32_t)ctx, (uint32_t)strtoul(key, NULL, 0), value, host_dials));
        } else {
            CHECK(krun_add_virtiofs((uint32_t)ctx, key, value));
        }
    }

    if (gpu_flags != 0) {
        CHECK(krun_set_gpu_options2((uint32_t)ctx, gpu_flags, gpu_shm));
    }
    if (console) {
        CHECK(krun_set_console_output((uint32_t)ctx, console));
    }
    CHECK(krun_set_kernel((uint32_t)ctx, kernel, KRUN_KERNEL_FORMAT_RAW, NULL, cmdline));

    pthread_t watchdog;
    if (pthread_create(&watchdog, NULL, parent_watchdog, (void *)(intptr_t)parent) == 0) {
        pthread_detach(watchdog);
    } else {
        fprintf(stderr, "krun-vmm: could not start parent watchdog\n");
    }

    int32_t rc = krun_start_enter((uint32_t)ctx);
    fprintf(stderr, "krun-vmm: krun_start_enter failed: %s\n", strerror(-rc));
    return 1;
}
