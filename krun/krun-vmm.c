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
//   --display WxH                 open a macOS window showing the guest's
//                                 virtio-gpu output, with keyboard and pointer
//   --title STR                   window title (with --display)
//   --gvproxy BIN                 network: run gvproxy (userspace NAT) as a
//                                 child and attach a virtio-net device to it
//   --net-socket PATH             gvproxy's vfkit datagram socket (with --gvproxy;
//                                 PATH.api is its services API for port forwards)
//   --net-mac MAC                 guest MAC, aa:bb:cc:dd:ee:ff (with --gvproxy)
//   --log-level N                 libkrun log level 0..5
//
// Stopping: SIGTERM/SIGINT end the VM immediately (default action), like
// Virtualization.framework's stop(). libkrun's orderly-shutdown eventfd needs
// a guest-side handler that vminitd does not have. The helper also exits if
// its parent dies, so a crashed host process never leaves an orphaned VM.

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libkrun.h>

#include "krun-display.h"

#define CHECK(call)                                                          \
    do {                                                                     \
        int32_t _rc = (call);                                                \
        if (_rc < 0) {                                                       \
            fprintf(stderr, "krun-vmm: %s failed: %s\n", #call, strerror(-_rc)); \
            return 1;                                                        \
        }                                                                    \
    } while (0)

extern char **environ;

// gvproxy runs as our child and must not outlive the VM. Every exit path
// (guest shutdown via exit(), SIGTERM/SIGINT, parent death, window close)
// goes through krun_vmm_cleanup().
static volatile pid_t g_gvproxy = 0;

void krun_vmm_cleanup(void) {
    pid_t p = g_gvproxy;
    if (p > 0) {
        g_gvproxy = 0;
        kill(p, SIGTERM);
    }
}

static void on_signal(int sig) {
    krun_vmm_cleanup();
    signal(sig, SIG_DFL);
    raise(sig);
}

static int start_gvproxy(const char *bin, const char *sock) {
    char listen[1100], services[1100], logfile[1100];
    snprintf(listen, sizeof listen, "unixgram://%s", sock);
    snprintf(services, sizeof services, "unix://%s.api", sock);
    snprintf(logfile, sizeof logfile, "%s.log", sock);
    unlink(sock);
    char *argv[] = {(char *)bin, "-listen-vfkit", listen, "-services", services, "-ssh-port", "-1", "-mtu", "1500",
                    "-log-file", logfile, NULL};
    pid_t pid;
    int rc = posix_spawn(&pid, bin, NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "krun-vmm: cannot start %s: %s\n", bin, strerror(rc));
        return -1;
    }
    g_gvproxy = pid;
    atexit(krun_vmm_cleanup);
    // Wait for its datagram socket (it binds within milliseconds).
    for (int i = 0; i < 100; i++) {
        struct stat st;
        if (stat(sock, &st) == 0 && S_ISSOCK(st.st_mode)) return 0;
        int status;
        if (waitpid(pid, &status, WNOHANG) == pid) {
            g_gvproxy = 0;
            fprintf(stderr, "krun-vmm: gvproxy exited early; see %s\n", logfile);
            return -1;
        }
        usleep(50 * 1000);
    }
    fprintf(stderr, "krun-vmm: gvproxy socket %s did not appear\n", sock);
    return -1;
}

static bool parse_mac(const char *s, uint8_t mac[6]) {
    unsigned b[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) return false;
    for (int i = 0; i < 6; i++) mac[i] = (uint8_t)b[i];
    return true;
}

// Reparenting to launchd means the host process that owns this VM is gone.
static void *parent_watchdog(void *arg) {
    pid_t parent = (pid_t)(intptr_t)arg;
    for (;;) {
        if (getppid() != parent) {
            fprintf(stderr, "krun-vmm: parent %d exited, stopping VM\n", (int)parent);
            krun_vmm_cleanup();
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

static void start_vm(void *arg) {
    int32_t rc = krun_start_enter((uint32_t)(intptr_t)arg);
    fprintf(stderr, "krun-vmm: krun_start_enter failed: %s\n", strerror(-rc));
    krun_vmm_cleanup();
    _exit(1);
}

static void usage(void) {
    fprintf(stderr, "usage: krun-vmm --kernel PATH --cmdline STR [--cpus N] [--mem MiB] "
                    "[--disk ID:PATH]... [--disk-ro ID:PATH]... [--virtiofs TAG:PATH]... "
                    "[--vsock-connect PORT:PATH]... [--vsock-listen PORT:PATH]... "
                    "[--gpu none|venus] [--gpu-flags N] [--gpu-shm BYTES] "
                    "[--console PATH] [--display WxH] [--title STR] "
                    "[--gvproxy BIN --net-socket PATH --net-mac MAC] [--log-level N]\n");
}

int main(int argc, char **argv) {
    // Record the parent first: if it is already gone (reparented to launchd),
    // there is no owner to run for.
    pid_t parent = getppid();
    if (parent == 1) {
        fprintf(stderr, "krun-vmm: parent already exited\n");
        return 1;
    }
    const char *kernel = NULL, *cmdline = NULL, *console = NULL, *title = "krun";
    unsigned display_w = 0, display_h = 0;
    const char *gvproxy = NULL, *net_socket = NULL;
    uint8_t net_mac[6];
    bool have_mac = false;
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
        else if (!strcmp(a, "--title")) title = v;
        else if (!strcmp(a, "--gvproxy")) gvproxy = v;
        else if (!strcmp(a, "--net-socket")) net_socket = v;
        else if (!strcmp(a, "--net-mac")) {
            if (!parse_mac(v, net_mac)) {
                fprintf(stderr, "krun-vmm: --net-mac expects aa:bb:cc:dd:ee:ff, got '%s'\n", v);
                return 2;
            }
            have_mac = true;
        }
        else if (!strcmp(a, "--display")) {
            if (sscanf(v, "%ux%u", &display_w, &display_h) != 2 || display_w < 64 || display_h < 64 ||
                display_w > 8192 || display_h > 8192) {
                fprintf(stderr, "krun-vmm: --display expects WxH, got '%s'\n", v);
                return 2;
            }
        }
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
    if (gvproxy && (!net_socket || !have_mac)) {
        fprintf(stderr, "krun-vmm: --gvproxy needs --net-socket and --net-mac\n");
        return 2;
    }

    // Debug override without touching the caller's flags.
    const char *env_level = getenv("KRUN_VMM_LOG_LEVEL");
    if (env_level) log_level = strtoul(env_level, NULL, 0);
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

    if (gvproxy) {
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
        signal(SIGHUP, on_signal);
        if (start_gvproxy(gvproxy, net_socket) < 0) return 1;
        // NET_FLAG_VFKIT: gvproxy's vfkit mode expects the "VFKT" handshake.
        int nrc = krun_add_net_unixgram((uint32_t)ctx, net_socket, -1, net_mac, COMPAT_NET_FEATURES, NET_FLAG_VFKIT);
        if (nrc < 0) {
            fprintf(stderr, "krun-vmm: krun_add_net_unixgram failed: %s\n", strerror(-nrc));
            krun_vmm_cleanup();
            return 1;
        }
    }
    if (display_w && gpu_flags == 0) {
        fprintf(stderr, "krun-vmm: --display needs a GPU mode (--gpu venus)\n");
        return 2;
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

    if (display_w) {
        int drc = krun_display_configure((uint32_t)ctx, display_w, display_h);
        if (drc < 0) {
            fprintf(stderr, "krun-vmm: display setup failed: %s\n", strerror(-drc));
            return 1;
        }
        // AppKit needs the main thread, so the VM runs on another one.
        krun_display_run(title, start_vm, (void *)(intptr_t)ctx);
    }
    start_vm((void *)(intptr_t)ctx);
    return 1;
}
