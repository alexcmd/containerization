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

// krun-display: a macOS window for libkrun's virtio-gpu scanout, plus a
// virtio-input keyboard and absolute pointer fed from that window.
//
// Threads: AppKit owns the main thread; libkrun calls the display backend
// from its GPU thread and polls the input pipe from its device thread. Frames
// cross over as CGImages assigned to a CALayer; input crosses over through a
// mutex-protected queue with a pipe as the readiness fd.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#include <stdatomic.h>
#include <time.h>
#include <Carbon/Carbon.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>

#include <libkrun.h>
#include <libkrun_display.h>
#include <libkrun_input.h>

#include "krun-display.h"

// Linux input-event-codes.h subset.
enum {
    EV_SYN = 0x00, EV_KEY = 0x01, EV_REL = 0x02, EV_ABS = 0x03, EV_REP = 0x14,
    SYN_REPORT = 0,
    REL_WHEEL = 0x08, REL_HWHEEL = 0x06,
    ABS_X = 0x00, ABS_Y = 0x01,
    BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112,
    BUS_VIRTUAL = 0x06,
};
#define ABS_MAX_COORD 32767u

// ---------------------------------------------------------------- frames
//
// Frame path: libkrun copies the guest's scanout into one of our staging
// buffers (alloc_frame -> present_frame), we copy it into an IOSurface (shown
// by Core Animation without any conversion or upload) and queue it for the
// main thread. A display link then picks what goes on screen at each refresh.
//
// Pacing (default on, Cmd+Option+P toggles live): the guest paces its frames
// with its own timers, so they arrive a couple of ms early or late. On a
// 120 Hz screen that moves a frame to the neighbouring refresh, and motion
// judders even at a steady 60 fps. With pacing, frames wait in a short queue
// and are shown at an even cadence, at the cost of up to one frame of latency.

#define MAX_SCANOUTS 1
#define FRAMES_PER_SCANOUT 3
#define NSURF 6

typedef struct {
    uint32_t width, height, format;
    bool enabled;
    uint8_t *frames[FRAMES_PER_SCANOUT];
    size_t frame_size;
    uint32_t next;
    IOSurfaceRef surf[NSURF];
    _Atomic bool surf_busy[NSURF]; // queued or on screen (our side)
    bool use_iosurface;
} scanout_t;

static scanout_t g_scanouts[MAX_SCANOUTS];
static CALayer *g_layer;     // main thread only
static NSWindow *g_window;   // main thread only
static uint32_t g_display_w, g_display_h;

// ---------------------------------------------------------------- telemetry
//
// Every frame is timed through each stage of the host path:
//   gap     - time since the previous frame arrived (the guest's cadence)
//   copy    - alloc_frame -> present_frame: libkrun reading the guest's 2D
//             resource into our staging buffer
//   build   - copying it into an IOSurface (or wrapping it in a CGImage)
//   queue   - from queued to shown (main-thread wait, plus the deliberate
//             hold when pacing)
//   commit  - handing it to Core Animation
//   latency - present_frame -> shown
// and per screen refresh the display link records the on-screen interval:
// how long each guest frame stayed visible. That interval is what the eye
// sees; at 60 fps on a 120 Hz screen it should always be 16.7 ms.
//
// Outputs: an on-screen HUD (Cmd+Option+F), one log line per spike
// (gap > 25 ms) plus a summary every 10 s, and with KRUN_DISPLAY_TELEMETRY=PATH
// a CSV row per frame (PATH) and per shown frame (PATH.onscreen.csv).
//
// With KRUN_DISPLAY_DUMP=PATH the guest screen is also written to PATH (PNG)
// every 2 s while PATH.enable exists; it costs tens of ms, so it is off unless
// asked for.

// Mach absolute time in seconds, the same clock as CADisplayLink timestamps.
static double now_s(void) { return CACurrentMediaTime(); }

static double wall_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

// GPU-thread state.
static uint64_t g_seq;
static double g_last_present, g_last_dump, g_t0;
static double g_alloc_t[FRAMES_PER_SCANOUT];
static _Atomic uint64_t g_host_drops; // no free IOSurface

// Glitch capture (Cmd+Option+G): the last RING frames, exactly as libkrun
// delivered them, are kept in memory and written out as PNGs on request, so a
// glitch someone saw can be checked against what the guest actually sent.
#define RING 20
static pthread_mutex_t g_ring_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *g_ring[RING];
static uint64_t g_ring_seq[RING];
static double g_ring_t[RING];
static size_t g_ring_size;
static uint32_t g_ring_w, g_ring_h, g_ring_fmt;
static unsigned g_ring_pos;

static void ring_put(const uint8_t *px, uint32_t w, uint32_t h, uint32_t fmt, size_t size, uint64_t seq, double t) {
    pthread_mutex_lock(&g_ring_lock);
    if (size != g_ring_size) {
        for (int i = 0; i < RING; i++) {
            free(g_ring[i]);
            g_ring[i] = malloc(size);
            g_ring_seq[i] = 0;
        }
        g_ring_size = size;
    }
    unsigned i = g_ring_pos++ % RING;
    if (g_ring[i]) {
        memcpy(g_ring[i], px, size);
        g_ring_seq[i] = seq;
        g_ring_t[i] = t;
    }
    g_ring_w = w;
    g_ring_h = h;
    g_ring_fmt = fmt;
    pthread_mutex_unlock(&g_ring_lock);
}

// Content check: compare each frame with the previous one on a sparse grid.
// A steadily animating scene changes by a similar amount every frame; a
// frame that did not change (repeat) or changed about twice as much (jump)
// is visible stutter even when the timing is perfect.
#define SAMPLE_STEP 16
static uint8_t *g_prev_samples;
static size_t g_n_samples;
static double g_delta_hist[9];
static unsigned g_delta_n;

static int cmp_dd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void content_check(const uint8_t *px, uint32_t w, uint32_t h, double *delta, int *kind) {
    size_t n = (size_t)(w / SAMPLE_STEP) * (h / SAMPLE_STEP);
    if (n != g_n_samples) {
        free(g_prev_samples);
        g_prev_samples = calloc(n, 1);
        g_n_samples = n;
        g_delta_n = 0;
    }
    uint64_t sum = 0;
    size_t i = 0;
    for (uint32_t y = SAMPLE_STEP / 2; y + SAMPLE_STEP / 2 <= h && i < n; y += SAMPLE_STEP)
        for (uint32_t x = SAMPLE_STEP / 2; x + SAMPLE_STEP / 2 <= w && i < n; x += SAMPLE_STEP, i++) {
            uint8_t g = px[((size_t)y * w + x) * 4 + 1]; // green, any 32-bit layout
            sum += (uint64_t)abs((int)g - (int)g_prev_samples[i]);
            g_prev_samples[i] = g;
        }
    *delta = n ? (double)sum / n : 0;
    // Median of the last 9 deltas is the "normal step".
    double med = 0;
    if (g_delta_n >= 9) {
        double tmp[9];
        memcpy(tmp, g_delta_hist, sizeof tmp);
        qsort(tmp, 9, sizeof(double), cmp_dd);
        med = tmp[4];
    }
    *kind = 0;
    if (med > 0.02) {
        if (*delta < med * 0.15) *kind = 1;
        else if (*delta > med * 1.7) *kind = 2;
    }
    g_delta_hist[g_delta_n % 9] = *delta;
    g_delta_n++;
}

typedef struct {
    uint64_t seq;
    double wall, t_present, gap, copy, build, t_enqueued;
    double delta;          // content change vs previous frame (mean |dG| over samples)
    int content;           // 0 normal, 1 repeat (no change), 2 jump (double step)
    int surf;              // index into scanout surf[], or -1 with image
    CGImageRef image;      // fallback path (formats IOSurface cannot take)
} frame_rec_t;

// Main-thread state.
#define WIN 1024
typedef struct {
    double gap[WIN], copy[WIN], build[WIN], queue[WIN], commit[WIN], onscreen[WIN];
    unsigned n, n_on;
    unsigned spikes, uneven, repeats_c, jumps_c;
    uint64_t presented, shown, dropped, repeats;
    double t_window;
} stats_t;
static stats_t g_st;

#define FIFO_CAP 8
static frame_rec_t g_fifo[FIFO_CAP];
static unsigned g_fifo_n;
static bool g_pacing = true;
static double g_guest_period = 1.0 / 60;
static double g_last_show_target;
static int g_shown_surf = -1;
static uint64_t g_shown_seq, g_vsync_seen_seq;
static double g_seq_target_prev;
static double g_refresh_hz, g_vsync_period = 1.0 / 60;
static FILE *g_csv, *g_csv_on;
static double g_log_t;
static CATextLayer *g_hud;
static bool g_hud_on = true;

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

// p-th percentile and max of v[0..n).
static void pct(const double *v, unsigned n, double p, double *out_p, double *out_max) {
    if (n == 0) {
        *out_p = *out_max = 0;
        return;
    }
    double tmp[WIN];
    memcpy(tmp, v, n * sizeof(double));
    qsort(tmp, n, sizeof(double), cmp_d);
    *out_p = tmp[(unsigned)(p * (n - 1))];
    *out_max = tmp[n - 1];
}

static void record_frame(const frame_rec_t *r, double queue, double commit, double latency) {
    stats_t *st = &g_st;
    if (st->n < WIN) {
        st->gap[st->n] = r->gap;
        st->copy[st->n] = r->copy;
        st->build[st->n] = r->build;
        st->queue[st->n] = queue;
        st->commit[st->n] = commit;
        st->n++;
    }
    if (r->content == 1) st->repeats_c++;
    if (r->content == 2) st->jumps_c++;
    if (r->content) {
        fprintf(stderr, "krun-vmm: display: CONTENT %s frame %llu delta %.2f (gap %.1f ms)\n",
                r->content == 1 ? "REPEAT" : "JUMP", (unsigned long long)r->seq, r->delta, r->gap * 1e3);
    }
    if (r->gap > 0.025) {
        st->spikes++;
        // Name the slowest host stage; if none is large the delay came from
        // the guest (it presented late) or from libkrun before alloc_frame.
        const char *who = "guest/libkrun before copy";
        if (r->copy > 0.008 && r->copy >= r->build) who = "libkrun copy";
        else if (r->build > 0.008) who = "IOSurface/CGImage build";
        fprintf(stderr, "krun-vmm: display: SPIKE frame %llu gap %.1f ms (copy %.1f, build %.1f) -> %s\n",
                (unsigned long long)r->seq, r->gap * 1e3, r->copy * 1e3, r->build * 1e3, who);
    }
    if (g_csv) {
        fprintf(g_csv, "%llu,%.6f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%d\n", (unsigned long long)r->seq, r->wall,
                (r->t_present - g_t0) * 1e3, r->gap * 1e3, r->copy * 1e3, r->build * 1e3, queue * 1e3, commit * 1e3,
                latency * 1e3, g_pacing ? 1 : 0, r->delta, r->content);
    }
}

static void update_hud(double t) {
    stats_t *st = &g_st;
    double span = t - st->t_window;
    if (span < 0.5) return;
    double gp, gm, cp, cm, bp, bm, qp, qm, mp, mm, op50, op, om;
    pct(st->gap, st->n, 0.99, &gp, &gm);
    pct(st->copy, st->n, 0.99, &cp, &cm);
    pct(st->build, st->n, 0.99, &bp, &bm);
    pct(st->queue, st->n, 0.99, &qp, &qm);
    pct(st->commit, st->n, 0.99, &mp, &mm);
    pct(st->onscreen, st->n_on, 0.5, &op50, &om);
    pct(st->onscreen, st->n_on, 0.99, &op, &om);
    NSString *text = [NSString
        stringWithFormat:@"guest %.1f fps  shown %.1f fps  screen %.0f Hz  pacing %@ (⌘⌥P)\n"
                         @"on-screen interval p50 %.1f p99 %.1f max %.1f ms  uneven %u  drops %llu\n"
                         @"guest gap p99 %.1f max %.1f ms  spikes>25ms %u  content: repeat %u jump %u\n"
                         @"⌘⌥G = capture glitch   copy %.1f/%.1f build %.1f/%.1f queue %.1f/%.1f commit %.1f/%.1f ms (p99/max)",
                         st->presented / span, st->shown / span, g_refresh_hz, g_pacing ? @"ON" : @"off", op50 * 1e3,
                         op * 1e3, om * 1e3, st->uneven,
                         (unsigned long long)(st->dropped + atomic_exchange(&g_host_drops, 0)), gp * 1e3, gm * 1e3,
                         st->spikes, st->repeats_c, st->jumps_c, cp * 1e3, cm * 1e3, bp * 1e3, bm * 1e3, qp * 1e3, qm * 1e3, mp * 1e3, mm * 1e3];
    if (g_hud && g_hud_on) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_hud.string = text;
        [CATransaction commit];
    }
    if (t - g_log_t >= 10) {
        g_log_t = t;
        fprintf(stderr, "krun-vmm: display: %s\n", [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] UTF8String]);
        if (g_csv) fflush(g_csv);
        if (g_csv_on) fflush(g_csv_on);
    }
    memset(st, 0, sizeof *st);
    st->t_window = t;
}

static void dump_png(CGImageRef image, const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CFRelease(url);
    if (!dst) return;
    CGImageDestinationAddImage(dst, image, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
}

static CGBitmapInfo bitmap_info_for(uint32_t format, bool *ok) {
    *ok = true;
    switch (format) {
    case KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM: // bytes B G R A
        return kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    case KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM: // bytes B G R X
        return kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    case KRUN_DISPLAY_FORMAT_A8R8G8B8_UNORM: // bytes A R G B
        return kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst;
    case KRUN_DISPLAY_FORMAT_X8R8G8B8_UNORM: // bytes X R G B
        return kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
    case KRUN_DISPLAY_FORMAT_R8G8B8A8_UNORM: // bytes R G B A
        return kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast;
    case KRUN_DISPLAY_FORMAT_R8G8B8X8_UNORM: // bytes R G B X
        return kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast;
    case KRUN_DISPLAY_FORMAT_A8B8G8R8_UNORM: // bytes A B G R
        return kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedLast;
    case KRUN_DISPLAY_FORMAT_X8B8G8R8_UNORM: // bytes X B G R
        return kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipLast;
    default:
        *ok = false;
        return 0;
    }
}

static IOSurfaceRef make_surface(uint32_t w, uint32_t h) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth : @(w),
        (id)kIOSurfaceHeight : @(h),
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static int32_t d_disable_scanout(void *inst, uint32_t sid) {
    (void)inst;
    if (sid >= MAX_SCANOUTS) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    g_scanouts[sid].enabled = false;
    dispatch_async(dispatch_get_main_queue(), ^{ g_layer.contents = nil; });
    return 0;
}

static int32_t d_configure_scanout(void *inst, uint32_t sid, uint32_t dw, uint32_t dh, uint32_t w, uint32_t h,
                                   uint32_t format) {
    (void)inst; (void)dw; (void)dh;
    if (sid >= MAX_SCANOUTS) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    bool ok;
    bitmap_info_for(format, &ok);
    if (!ok || w == 0 || h == 0) return KRUN_DISPLAY_ERR_INVALID_PARAM;
    scanout_t *s = &g_scanouts[sid];
    size_t size = (size_t)w * h * 4;
    if (size != s->frame_size || w != s->width) {
        for (int i = 0; i < FRAMES_PER_SCANOUT; i++) {
            free(s->frames[i]);
            s->frames[i] = calloc(1, size);
            if (!s->frames[i]) return KRUN_DISPLAY_ERR_INTERNAL;
        }
        s->frame_size = size;
        // Surfaces still referenced by a queued frame or the layer stay alive
        // through those references (CFRetain in the queue, the layer's own).
        for (int i = 0; i < NSURF; i++) {
            if (s->surf[i]) CFRelease(s->surf[i]);
            s->surf[i] = NULL;
            atomic_store(&s->surf_busy[i], false);
        }
    }
    // IOSurface 'BGRA' matches the B G R A/X byte order; other formats take
    // the CGImage path.
    s->use_iosurface = format == KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM || format == KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM;
    if (s->use_iosurface && !s->surf[0]) {
        for (int i = 0; i < NSURF; i++) {
            s->surf[i] = make_surface(w, h);
            if (!s->surf[i]) {
                s->use_iosurface = false;
                break;
            }
        }
    }
    s->width = w;
    s->height = h;
    s->format = format;
    s->enabled = true;
    fprintf(stderr, "krun-vmm: display: scanout %u configured %ux%u format %u (%s)\n", sid, w, h, format,
            s->use_iosurface ? "IOSurface" : "CGImage");
    return 0;
}

static int32_t d_alloc_frame(void *inst, uint32_t sid, uint8_t **buffer, size_t *size) {
    (void)inst;
    if (sid >= MAX_SCANOUTS) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    scanout_t *s = &g_scanouts[sid];
    if (!s->enabled) return KRUN_DISPLAY_ERR_INVALID_PARAM;
    uint32_t fid = s->next;
    s->next = (s->next + 1) % FRAMES_PER_SCANOUT;
    g_alloc_t[fid] = now_s();
    *buffer = s->frames[fid];
    *size = s->frame_size;
    return (int32_t)fid;
}

// Main thread: put a frame on screen now.
static void show_frame(frame_rec_t *r, double target) {
    scanout_t *s = &g_scanouts[0];
    double t0 = now_s();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (r->surf >= 0) g_layer.contents = (__bridge id)s->surf[r->surf];
    else g_layer.contents = (__bridge id)r->image;
    [CATransaction commit];
    double t1 = now_s();
    // The previously shown surface may be reused once the window server has
    // let go of it (checked with IOSurfaceIsInUse when picking).
    if (g_shown_surf >= 0 && g_shown_surf != r->surf) atomic_store(&s->surf_busy[g_shown_surf], false);
    g_shown_surf = r->surf;
    if (r->image) CGImageRelease(r->image);
    g_shown_seq = r->seq;
    record_frame(r, t0 - r->t_enqueued, t1 - t0, (target > 0 ? target : t1) - r->t_present);
}

static void fifo_drop_oldest(void) {
    frame_rec_t *r = &g_fifo[0];
    if (r->surf >= 0) atomic_store(&g_scanouts[0].surf_busy[r->surf], false);
    if (r->image) CGImageRelease(r->image);
    memmove(&g_fifo[0], &g_fifo[1], (g_fifo_n - 1) * sizeof(frame_rec_t));
    g_fifo_n--;
    g_st.dropped++;
}

// Main thread: a frame arrived from the GPU thread.
static void frame_arrived(frame_rec_t r) {
    g_st.presented++;
    if (r.gap > 0.004 && r.gap < 0.1) g_guest_period = g_guest_period * 0.9 + r.gap * 0.1;
    if (!g_pacing) {
        while (g_fifo_n) fifo_drop_oldest();
        show_frame(&r, 0);
        return;
    }
    if (g_fifo_n == FIFO_CAP) fifo_drop_oldest();
    g_fifo[g_fifo_n++] = r;
}

static int32_t d_present_frame(void *inst, uint32_t sid, uint32_t fid, const struct krun_rect *damage) {
    (void)inst; (void)damage;
    if (sid >= MAX_SCANOUTS || fid >= FRAMES_PER_SCANOUT) return KRUN_DISPLAY_ERR_INVALID_PARAM;
    scanout_t *s = &g_scanouts[sid];
    double t_present = now_s();
    if (g_t0 == 0) g_t0 = t_present;
    frame_rec_t rec = {
        .seq = ++g_seq,
        .wall = wall_s(),
        .t_present = t_present,
        .gap = g_last_present > 0 ? t_present - g_last_present : 0,
        .copy = t_present - g_alloc_t[fid],
        .surf = -1,
    };
    g_last_present = t_present;
    const uint8_t *src = s->frames[fid];
    content_check(src, s->width, s->height, &rec.delta, &rec.content);
    ring_put(src, s->width, s->height, s->format, s->frame_size, rec.seq, t_present);

    if (s->use_iosurface) {
        int pick = -1;
        for (int i = 0; i < NSURF; i++) {
            if (!atomic_load(&s->surf_busy[i]) && !IOSurfaceIsInUse(s->surf[i])) {
                pick = i;
                break;
            }
        }
        if (pick < 0) {
            atomic_fetch_add(&g_host_drops, 1);
            return 0; // every surface queued or on screen: skip this frame
        }
        IOSurfaceRef surf = s->surf[pick];
        IOSurfaceLock(surf, 0, NULL);
        uint8_t *dst = IOSurfaceGetBaseAddress(surf);
        size_t dst_bpr = IOSurfaceGetBytesPerRow(surf), src_bpr = (size_t)s->width * 4;
        if (dst_bpr == src_bpr) memcpy(dst, src, src_bpr * s->height);
        else
            for (uint32_t y = 0; y < s->height; y++) memcpy(dst + y * dst_bpr, src + y * src_bpr, src_bpr);
        IOSurfaceUnlock(surf, 0, NULL);
        atomic_store(&s->surf_busy[pick], true);
        rec.surf = pick;
    } else {
        bool ok;
        CGBitmapInfo info = bitmap_info_for(s->format, &ok);
        if (!ok) return KRUN_DISPLAY_ERR_INVALID_PARAM;
        CFDataRef data = CFDataCreate(NULL, src, (CFIndex)s->frame_size);
        if (!data) return KRUN_DISPLAY_ERR_INTERNAL;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CFRelease(data);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        rec.image = CGImageCreate(s->width, s->height, 8, 32, (size_t)s->width * 4, cs, info, provider, NULL, false,
                                  kCGRenderingIntentDefault);
        CGColorSpaceRelease(cs);
        CGDataProviderRelease(provider);
        if (!rec.image) return KRUN_DISPLAY_ERR_INTERNAL;
    }
    rec.t_enqueued = now_s();
    rec.build = rec.t_enqueued - t_present;

    const char *dump = getenv("KRUN_DISPLAY_DUMP");
    if (dump && t_present - g_last_dump >= 2) {
        g_last_dump = t_present;
        // Only while PATH.enable exists, so it can be toggled at runtime.
        char flag[1100];
        snprintf(flag, sizeof flag, "%s.enable", dump);
        if (access(flag, F_OK) == 0) {
            bool ok;
            CGBitmapInfo info = bitmap_info_for(s->format, &ok);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef ctx = CGBitmapContextCreate((void *)src, s->width, s->height, 8, (size_t)s->width * 4, cs, info);
            CGColorSpaceRelease(cs);
            if (ctx) {
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                if (img) {
                    dump_png(img, dump);
                    CGImageRelease(img);
                }
                CGContextRelease(ctx);
            }
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ frame_arrived(rec); });
    return 0;
}

static CGBitmapInfo bitmap_info_for(uint32_t format, bool *ok);

// Main thread: copy the ring out under the lock, encode on a background queue.
static void capture_glitch(void) {
    const char *csv = getenv("KRUN_DISPLAY_TELEMETRY");
    NSString *base = csv ? [[NSString stringWithUTF8String:csv] stringByDeletingLastPathComponent] : NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"glitch-%.0f", wall_s()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    pthread_mutex_lock(&g_ring_lock);
    size_t size = g_ring_size;
    uint32_t w = g_ring_w, h = g_ring_h, fmt = g_ring_fmt;
    typedef struct {
        uint8_t *px[RING];
        uint64_t seq[RING];
        double t[RING];
    } snap_t;
    snap_t *snap = calloc(1, sizeof(snap_t));
    if (!snap) {
        pthread_mutex_unlock(&g_ring_lock);
        return;
    }
    for (unsigned k = 0; k < RING; k++) {
        unsigned i = (g_ring_pos + k) % RING; // oldest first
        snap->seq[k] = g_ring_seq[i];
        snap->t[k] = g_ring_t[i];
        if (g_ring[i] && snap->seq[k]) {
            snap->px[k] = malloc(size);
            if (snap->px[k]) memcpy(snap->px[k], g_ring[i], size);
        }
    }
    pthread_mutex_unlock(&g_ring_lock);
    fprintf(stderr, "krun-vmm: display: MARK glitch reported at frame %llu, saving %d frames to %s\n",
            (unsigned long long)g_seq, RING, dir.UTF8String);
    if (g_csv) fprintf(g_csv, "# MARK glitch at frame %llu wall %.6f\n", (unsigned long long)g_seq, wall_s());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        bool ok;
        CGBitmapInfo info = bitmap_info_for(fmt, &ok);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        for (unsigned k = 0; k < RING; k++) {
            if (!snap->px[k]) continue;
            CGContextRef ctx = CGBitmapContextCreate(snap->px[k], w, h, 8, (size_t)w * 4, cs, info);
            if (ctx) {
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                if (img) {
                    NSString *f = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%02u-frame%llu-t%.3f.png", k,
                                                                                                   (unsigned long long)snap->seq[k],
                                                                                                   snap->t[k] - g_t0]];
                    dump_png(img, f.UTF8String);
                    CGImageRelease(img);
                }
                CGContextRelease(ctx);
            }
            free(snap->px[k]);
        }
        free(snap);
        CGColorSpaceRelease(cs);
        fprintf(stderr, "krun-vmm: display: glitch capture written to %s\n", dir.UTF8String);
    });
}

// ---------------------------------------------------------------- input

#define QUEUE_CAP 4096

typedef struct {
    pthread_mutex_t lock;
    struct krun_input_event q[QUEUE_CAP];
    size_t head, len;
    int pipe_r, pipe_w;
} input_queue_t;

static input_queue_t g_kbd = {.lock = PTHREAD_MUTEX_INITIALIZER, .pipe_r = -1, .pipe_w = -1};
static input_queue_t g_ptr = {.lock = PTHREAD_MUTEX_INITIALIZER, .pipe_r = -1, .pipe_w = -1};

static bool queue_init(input_queue_t *q) {
    int fds[2];
    if (pipe(fds) != 0) return false;
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
    }
    q->pipe_r = fds[0];
    q->pipe_w = fds[1];
    return true;
}

// Push a batch of events (callers end each batch with SYN_REPORT).
static void queue_push(input_queue_t *q, const struct krun_input_event *ev, size_t n) {
    pthread_mutex_lock(&q->lock);
    if (q->len + n <= QUEUE_CAP) {
        for (size_t i = 0; i < n; i++) {
            q->q[(q->head + q->len) % QUEUE_CAP] = ev[i];
            q->len++;
        }
    }
    pthread_mutex_unlock(&q->lock);
    char b = 1;
    (void)write(q->pipe_w, &b, 1);
}

static int q_ready_fd(void *inst) { return ((input_queue_t *)inst)->pipe_r; }

static int32_t q_next_event(void *inst, struct krun_input_event *out) {
    input_queue_t *q = inst;
    pthread_mutex_lock(&q->lock);
    if (q->len == 0) {
        // Drain the wakeup bytes only when empty, so the fd stays readable
        // while events remain.
        char buf[256];
        while (read(q->pipe_r, buf, sizeof buf) > 0) {
        }
        pthread_mutex_unlock(&q->lock);
        return 0;
    }
    *out = q->q[q->head];
    q->head = (q->head + 1) % QUEUE_CAP;
    q->len--;
    pthread_mutex_unlock(&q->lock);
    return 1;
}

static int32_t create_with_userdata(void **instance, const void *userdata, const void *reserved) {
    (void)reserved;
    *instance = (void *)userdata;
    return 0;
}

static void set_bit(uint8_t *bm, size_t len, unsigned bit, size_t *used) {
    if (bit / 8 >= len) return;
    bm[bit / 8] |= (uint8_t)(1u << (bit % 8));
    if (bit / 8 + 1 > *used) *used = bit / 8 + 1;
}

static int32_t copy_name(uint8_t *buf, size_t len, const char *name) {
    size_t n = strlen(name);
    if (n > len) n = len;
    memcpy(buf, name, n);
    return (int32_t)n;
}

// The device kind rides in the instance pointer: 0 = keyboard, 1 = pointer.
#define KIND(inst) ((intptr_t)(inst))

static int32_t c_name(void *inst, uint8_t *buf, size_t len) {
    return copy_name(buf, len, KIND(inst) ? "krun Virtual Tablet" : "krun Virtual Keyboard");
}
static int32_t c_serial(void *inst, uint8_t *buf, size_t len) {
    return copy_name(buf, len, KIND(inst) ? "KRUN-PTR" : "KRUN-KBD");
}
static int32_t c_ids(void *inst, struct krun_input_device_ids *ids) {
    ids->bustype = BUS_VIRTUAL;
    ids->vendor = 0x4b52; // "KR"
    ids->product = KIND(inst) ? 2 : 1;
    ids->version = 1;
    return 0;
}
static int32_t c_caps(void *inst, uint8_t type, uint8_t *bm, size_t len) {
    memset(bm, 0, len);
    size_t used = 0;
    if (KIND(inst) == 0) {
        if (type == EV_KEY) {
            for (unsigned k = 1; k < 249; k++) set_bit(bm, len, k, &used);
        }
    } else {
        if (type == EV_KEY) {
            set_bit(bm, len, BTN_LEFT, &used);
            set_bit(bm, len, BTN_RIGHT, &used);
            set_bit(bm, len, BTN_MIDDLE, &used);
        } else if (type == EV_ABS) {
            set_bit(bm, len, ABS_X, &used);
            set_bit(bm, len, ABS_Y, &used);
        } else if (type == EV_REL) {
            set_bit(bm, len, REL_WHEEL, &used);
            set_bit(bm, len, REL_HWHEEL, &used);
        }
    }
    return (int32_t)used;
}
static int32_t c_absinfo(void *inst, uint8_t axis, struct krun_input_absinfo *ai) {
    if (KIND(inst) == 1 && (axis == ABS_X || axis == ABS_Y)) {
        *ai = (struct krun_input_absinfo){.min = 0, .max = ABS_MAX_COORD};
    }
    return 0;
}
static int32_t c_props(void *inst, uint8_t *bm, size_t len) {
    (void)inst;
    memset(bm, 0, len);
    return 0;
}

// macOS virtual key code -> Linux KEY_* code (0 = unmapped).
static uint16_t mac_to_linux(unsigned short k) {
    switch (k) {
    case kVK_ANSI_A: return 30; case kVK_ANSI_S: return 31; case kVK_ANSI_D: return 32;
    case kVK_ANSI_F: return 33; case kVK_ANSI_H: return 35; case kVK_ANSI_G: return 34;
    case kVK_ANSI_Z: return 44; case kVK_ANSI_X: return 45; case kVK_ANSI_C: return 46;
    case kVK_ANSI_V: return 47; case kVK_ANSI_B: return 48; case kVK_ANSI_Q: return 16;
    case kVK_ANSI_W: return 17; case kVK_ANSI_E: return 18; case kVK_ANSI_R: return 19;
    case kVK_ANSI_Y: return 21; case kVK_ANSI_T: return 20; case kVK_ANSI_1: return 2;
    case kVK_ANSI_2: return 3; case kVK_ANSI_3: return 4; case kVK_ANSI_4: return 5;
    case kVK_ANSI_6: return 7; case kVK_ANSI_5: return 6; case kVK_ANSI_Equal: return 13;
    case kVK_ANSI_9: return 10; case kVK_ANSI_7: return 8; case kVK_ANSI_Minus: return 12;
    case kVK_ANSI_8: return 9; case kVK_ANSI_0: return 11; case kVK_ANSI_RightBracket: return 27;
    case kVK_ANSI_O: return 24; case kVK_ANSI_U: return 22; case kVK_ANSI_LeftBracket: return 26;
    case kVK_ANSI_I: return 23; case kVK_ANSI_P: return 25; case kVK_Return: return 28;
    case kVK_ANSI_L: return 38; case kVK_ANSI_J: return 36; case kVK_ANSI_Quote: return 40;
    case kVK_ANSI_K: return 37; case kVK_ANSI_Semicolon: return 39; case kVK_ANSI_Backslash: return 43;
    case kVK_ANSI_Comma: return 51; case kVK_ANSI_Slash: return 53; case kVK_ANSI_N: return 49;
    case kVK_ANSI_M: return 50; case kVK_ANSI_Period: return 52; case kVK_Tab: return 15;
    case kVK_Space: return 57; case kVK_ANSI_Grave: return 41; case kVK_Delete: return 14;
    case kVK_Escape: return 1; case kVK_Command: return 125; case kVK_Shift: return 42;
    case kVK_CapsLock: return 58; case kVK_Option: return 56; case kVK_Control: return 29;
    case kVK_RightCommand: return 126; case kVK_RightShift: return 54; case kVK_RightOption: return 100;
    case kVK_RightControl: return 97; case kVK_F1: return 59; case kVK_F2: return 60;
    case kVK_F3: return 61; case kVK_F4: return 62; case kVK_F5: return 63; case kVK_F6: return 64;
    case kVK_F7: return 65; case kVK_F8: return 66; case kVK_F9: return 67; case kVK_F10: return 68;
    case kVK_F11: return 87; case kVK_F12: return 88; case kVK_Home: return 102;
    case kVK_PageUp: return 104; case kVK_ForwardDelete: return 111; case kVK_End: return 107;
    case kVK_PageDown: return 109; case kVK_LeftArrow: return 105; case kVK_RightArrow: return 106;
    case kVK_DownArrow: return 108; case kVK_UpArrow: return 103; case kVK_ISO_Section: return 86;
    case kVK_ANSI_KeypadDecimal: return 83; case kVK_ANSI_KeypadMultiply: return 55;
    case kVK_ANSI_KeypadPlus: return 78; case kVK_ANSI_KeypadClear: return 69;
    case kVK_ANSI_KeypadDivide: return 98; case kVK_ANSI_KeypadEnter: return 96;
    case kVK_ANSI_KeypadMinus: return 74; case kVK_ANSI_KeypadEquals: return 117;
    case kVK_ANSI_Keypad0: return 82; case kVK_ANSI_Keypad1: return 79; case kVK_ANSI_Keypad2: return 80;
    case kVK_ANSI_Keypad3: return 81; case kVK_ANSI_Keypad4: return 75; case kVK_ANSI_Keypad5: return 76;
    case kVK_ANSI_Keypad6: return 77; case kVK_ANSI_Keypad7: return 71; case kVK_ANSI_Keypad8: return 72;
    case kVK_ANSI_Keypad9: return 73;
    default: return 0;
    }
}

static void send_key(uint16_t code, bool down) {
    struct krun_input_event ev[2] = {{EV_KEY, code, down ? 1 : 0}, {EV_SYN, SYN_REPORT, 0}};
    queue_push(&g_kbd, ev, 2);
}

// ---------------------------------------------------------------- window

@interface KrunView : NSView
@end

@implementation KrunView {
    NSUInteger _modifierState;
}

// Once per screen refresh: pick the frame for this refresh (pacing) and
// measure how long each guest frame stays on screen.
- (void)vsync:(CADisplayLink *)link {
    double target = link.targetTimestamp;
    double period = link.targetTimestamp - link.timestamp;
    if (period > 0.002 && period < 0.1) {
        g_vsync_period = period;
        g_refresh_hz = 1.0 / period;
    }
    if (g_pacing && g_fifo_n > 0) {
        double due = g_last_show_target + g_guest_period;
        bool due_now = g_last_show_target == 0 || target >= due - g_vsync_period / 2;
        // Keep one frame in reserve so a late arrival does not miss its
        // refresh; show a lone frame anyway once it has waited a full guest
        // period (the guest slowed down or stopped).
        bool lone_overdue = g_fifo_n == 1 && now_s() - g_fifo[0].t_enqueued > g_guest_period;
        if (due_now && (g_fifo_n >= 2 || lone_overdue)) {
            while (g_fifo_n > 2) fifo_drop_oldest(); // fell behind: catch up
            frame_rec_t r = g_fifo[0];
            memmove(&g_fifo[0], &g_fifo[1], (g_fifo_n - 1) * sizeof(frame_rec_t));
            g_fifo_n--;
            show_frame(&r, target);
            g_last_show_target = target;
        }
    }
    // On-screen interval: refreshes between the first appearances of
    // consecutive frames.
    if (g_shown_seq != g_vsync_seen_seq) {
        if (g_seq_target_prev > 0 && g_st.n_on < WIN) {
            double iv = target - g_seq_target_prev;
            g_st.onscreen[g_st.n_on++] = iv;
            if (fabs(iv - g_guest_period) > g_vsync_period / 2) g_st.uneven++;
            if (g_csv_on) fprintf(g_csv_on, "%llu,%.3f,%.3f\n", (unsigned long long)g_shown_seq, (target - g_t0) * 1e3, iv * 1e3);
        }
        g_seq_target_prev = target;
        g_vsync_seen_seq = g_shown_seq;
        g_st.shown++;
    } else if (g_shown_seq) {
        g_st.repeats++;
    }
    update_hud(now_s());
}

- (void)captureGlitch:(id)sender {
    (void)sender;
    capture_glitch();
}

- (void)togglePacing:(id)sender {
    (void)sender;
    g_pacing = !g_pacing;
    g_last_show_target = 0;
    if (!g_pacing)
        while (g_fifo_n) {
            frame_rec_t r = g_fifo[--g_fifo_n];
            if (g_fifo_n == 0) show_frame(&r, 0);
            else {
                if (r.surf >= 0) atomic_store(&g_scanouts[0].surf_busy[r.surf], false);
                if (r.image) CGImageRelease(r.image);
            }
        }
    fprintf(stderr, "krun-vmm: display: pacing %s\n", g_pacing ? "on" : "off");
}

- (void)toggleHUD:(id)sender {
    (void)sender;
    g_hud_on = !g_hud_on;
    g_hud.hidden = !g_hud_on;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:self.bounds
                                   options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
}

- (void)sendPointer:(NSEvent *)e button:(int)button down:(bool)down {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect b = self.bounds;
    double fx = b.size.width > 0 ? p.x / b.size.width : 0;
    double fy = b.size.height > 0 ? 1.0 - p.y / b.size.height : 0;
    fx = fx < 0 ? 0 : fx > 1 ? 1 : fx;
    fy = fy < 0 ? 0 : fy > 1 ? 1 : fy;
    struct krun_input_event ev[4];
    size_t n = 0;
    ev[n++] = (struct krun_input_event){EV_ABS, ABS_X, (uint32_t)(fx * ABS_MAX_COORD)};
    ev[n++] = (struct krun_input_event){EV_ABS, ABS_Y, (uint32_t)(fy * ABS_MAX_COORD)};
    if (button) ev[n++] = (struct krun_input_event){EV_KEY, (uint16_t)button, down ? 1 : 0};
    ev[n++] = (struct krun_input_event){EV_SYN, SYN_REPORT, 0};
    queue_push(&g_ptr, ev, n);
}

- (void)mouseMoved:(NSEvent *)e { [self sendPointer:e button:0 down:false]; }
- (void)mouseDragged:(NSEvent *)e { [self sendPointer:e button:0 down:false]; }
- (void)rightMouseDragged:(NSEvent *)e { [self sendPointer:e button:0 down:false]; }
- (void)otherMouseDragged:(NSEvent *)e { [self sendPointer:e button:0 down:false]; }
- (void)mouseDown:(NSEvent *)e { [self sendPointer:e button:BTN_LEFT down:true]; }
- (void)mouseUp:(NSEvent *)e { [self sendPointer:e button:BTN_LEFT down:false]; }
- (void)rightMouseDown:(NSEvent *)e { [self sendPointer:e button:BTN_RIGHT down:true]; }
- (void)rightMouseUp:(NSEvent *)e { [self sendPointer:e button:BTN_RIGHT down:false]; }
- (void)otherMouseDown:(NSEvent *)e { [self sendPointer:e button:BTN_MIDDLE down:true]; }
- (void)otherMouseUp:(NSEvent *)e { [self sendPointer:e button:BTN_MIDDLE down:false]; }

- (void)scrollWheel:(NSEvent *)e {
    int dy = (int)lround(e.scrollingDeltaY / (e.hasPreciseScrollingDeltas ? 10.0 : 1.0));
    int dx = (int)lround(e.scrollingDeltaX / (e.hasPreciseScrollingDeltas ? 10.0 : 1.0));
    if (!dx && !dy) return;
    struct krun_input_event ev[3];
    size_t n = 0;
    if (dy) ev[n++] = (struct krun_input_event){EV_REL, REL_WHEEL, (uint32_t)(int32_t)dy};
    if (dx) ev[n++] = (struct krun_input_event){EV_REL, REL_HWHEEL, (uint32_t)(int32_t)-dx};
    ev[n++] = (struct krun_input_event){EV_SYN, SYN_REPORT, 0};
    queue_push(&g_ptr, ev, n);
}

- (void)keyDown:(NSEvent *)e {
    uint16_t code = mac_to_linux(e.keyCode);
    if (code) send_key(code, true); // autorepeat is left to the guest
}
- (void)keyUp:(NSEvent *)e {
    uint16_t code = mac_to_linux(e.keyCode);
    if (code) send_key(code, false);
}
- (void)flagsChanged:(NSEvent *)e {
    // Modifier keys only arrive here; work out press vs release per key.
    NSUInteger mask = 0;
    switch (e.keyCode) {
    case kVK_Shift: case kVK_RightShift: mask = NSEventModifierFlagShift; break;
    case kVK_Control: case kVK_RightControl: mask = NSEventModifierFlagControl; break;
    case kVK_Option: case kVK_RightOption: mask = NSEventModifierFlagOption; break;
    case kVK_Command: case kVK_RightCommand: mask = NSEventModifierFlagCommand; break;
    case kVK_CapsLock: mask = NSEventModifierFlagCapsLock; break;
    default: return;
    }
    uint16_t code = mac_to_linux(e.keyCode);
    if (!code) return;
    if (mask == NSEventModifierFlagCapsLock) {
        send_key(code, true);
        send_key(code, false);
        return;
    }
    send_key(code, (e.modifierFlags & mask) != 0);
}
@end

@interface KrunAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

static uint32_t g_ctx;
static uint32_t g_req_w, g_req_h; // last size sent to the guest (main thread)

// Tell the guest the window's new size (1 point = 1 guest pixel, matching the
// initial window). libkrun raises VIRTIO_GPU_EVENT_DISPLAY; the guest re-reads
// the display info and EDID and its compositor switches to the new mode.
// Sent once a live resize ends (not per frame of the drag), and on
// zoom/fullscreen, which resize without a live-resize phase.
static void request_guest_resize(void) {
    NSSize s = g_window.contentView.bounds.size;
    uint32_t w = (uint32_t)s.width & ~7u, h = (uint32_t)s.height & ~1u;
    if (w < 320 || h < 200 || (w == g_req_w && h == g_req_h)) return;
    int rc = krun_display_resize(g_ctx, 0, w, h);
    if (rc < 0) {
        fprintf(stderr, "krun-vmm: display: resize to %ux%u failed (%d)\n", w, h, rc);
        return;
    }
    g_req_w = w;
    g_req_h = h;
    fprintf(stderr, "krun-vmm: display: asked guest for %ux%u\n", w, h);
}

@implementation KrunAppDelegate
- (void)windowDidEndLiveResize:(NSNotification *)n { (void)n; request_guest_resize(); }
- (void)windowDidResize:(NSNotification *)n {
    (void)n;
    if (!g_window.inLiveResize) request_guest_resize();
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return YES; }
- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    // Closing the window stops the VM, like pulling the plug.
    krun_vmm_cleanup();
    _exit(0);
}
@end

static struct krun_display_backend g_display_backend;
static struct krun_input_config g_kbd_cfg, g_ptr_cfg;
static struct krun_input_event_provider g_kbd_ev, g_ptr_ev;

int krun_display_configure(uint32_t ctx, uint32_t width, uint32_t height) {
    g_display_w = width;
    g_display_h = height;
    g_ctx = ctx;
    g_req_w = width;
    g_req_h = height;
    if (!queue_init(&g_kbd) || !queue_init(&g_ptr)) return -errno;

    memset(&g_display_backend, 0, sizeof g_display_backend);
    g_display_backend.features = KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER;
    g_display_backend.vtable.basic_framebuffer = (struct krun_display_basic_framebuffer_vtable){
        .disable_scanout = d_disable_scanout,
        .configure_scanout = d_configure_scanout,
        .alloc_frame = d_alloc_frame,
        .present_frame = d_present_frame,
    };
    int rc = krun_add_display(ctx, width, height);
    if (rc < 0) return rc;
    // One guest pixel is one macOS point (~110 per inch on Mac screens). The
    // EDID default of 300 DPI makes mutter treat every new size as a HiDPI
    // panel and fall back to 200% scale after each resize. Override with
    // KRUN_DISPLAY_DPI (e.g. 220 to get 2x when the window is sized in pixels).
    uint32_t dpi = 110;
    const char *dpi_env = getenv("KRUN_DISPLAY_DPI");
    if (dpi_env && atoi(dpi_env) > 0) dpi = (uint32_t)atoi(dpi_env);
    rc = krun_display_set_dpi(ctx, (uint32_t)rc, dpi);
    if (rc < 0) return rc;
    rc = krun_set_display_backend(ctx, &g_display_backend, sizeof g_display_backend);
    if (rc < 0) return rc;

    struct krun_input_config_vtable cvt = {
        .query_device_name = c_name,
        .query_serial_name = c_serial,
        .query_device_ids = c_ids,
        .query_event_capabilities = c_caps,
        .query_abs_info = c_absinfo,
        .query_properties = c_props,
    };
    struct krun_input_event_provider_vtable evt = {.get_ready_efd = q_ready_fd, .next_event = q_next_event};

    g_kbd_cfg = (struct krun_input_config){.features = KRUN_INPUT_CONFIG_FEATURE_QUERY, .create_userdata = (void *)(intptr_t)0, .create = create_with_userdata, .vtable = cvt};
    g_ptr_cfg = (struct krun_input_config){.features = KRUN_INPUT_CONFIG_FEATURE_QUERY, .create_userdata = (void *)(intptr_t)1, .create = create_with_userdata, .vtable = cvt};
    g_kbd_ev = (struct krun_input_event_provider){.features = KRUN_INPUT_EVENT_PROVIDER_FEATURE_QUEUE, .create_userdata = &g_kbd, .create = create_with_userdata, .vtable = evt};
    g_ptr_ev = (struct krun_input_event_provider){.features = KRUN_INPUT_EVENT_PROVIDER_FEATURE_QUEUE, .create_userdata = &g_ptr, .create = create_with_userdata, .vtable = evt};
    rc = krun_add_input_device(ctx, &g_kbd_cfg, sizeof g_kbd_cfg, &g_kbd_ev, sizeof g_kbd_ev);
    if (rc == -ENOTSUP) {
        // libkrun built without its "input" feature (Homebrew's build, as of
        // 1.19.8): the screen still works, keyboard and mouse do not.
        fprintf(stderr, "krun-vmm: this libkrun has no virtio-input support; the window is view-only\n");
        return 0;
    }
    if (rc < 0) return rc;
    return krun_add_input_device(ctx, &g_ptr_cfg, sizeof g_ptr_cfg, &g_ptr_ev, sizeof g_ptr_ev);
}

typedef struct {
    void (*fn)(void *);
    void *arg;
} thread_start_t;

static void *vm_thread(void *p) {
    thread_start_t *t = p;
    t->fn(t->arg);
    return NULL;
}

void krun_display_run(const char *title, void (*vm_main)(void *), void *arg) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        KrunAppDelegate *delegate = [KrunAppDelegate new];
        app.delegate = delegate;

        NSMenu *menubar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [menubar addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        NSMenuItem *hud = [appMenu addItemWithTitle:@"Toggle FPS / telemetry overlay"
                                             action:@selector(toggleHUD:)
                                      keyEquivalent:@"f"];
        hud.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        NSMenuItem *cap = [appMenu addItemWithTitle:@"Capture glitch (last 20 frames)" action:@selector(captureGlitch:) keyEquivalent:@"g"];
        cap.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        NSMenuItem *pace = [appMenu addItemWithTitle:@"Toggle frame pacing" action:@selector(togglePacing:) keyEquivalent:@"p"];
        pace.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        app.mainMenu = menubar;

        // Points, not pixels: on a Retina screen the guest image is scaled up.
        NSRect frame = NSMakeRect(0, 0, g_display_w, g_display_h);
        g_window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        g_window.title = [NSString stringWithUTF8String:title];
        // Free resizing: the guest follows the window size (request_guest_resize).
        // Until it catches up, the layer letterboxes the old frame.
        g_window.contentMinSize = NSMakeSize(640, 400);
        g_window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
        g_window.delegate = delegate;
        KrunView *view = [[KrunView alloc] initWithFrame:frame];
        // Layer-hosting (layer set before wantsLayer), so AppKit never
        // redraws over the frames assigned to layer.contents.
        g_layer = [CALayer layer];
        view.layer = g_layer;
        view.wantsLayer = YES;
        g_layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        g_layer.contentsGravity = kCAGravityResizeAspect;
        g_layer.magnificationFilter = kCAFilterNearest;
        g_layer.opaque = YES; // BGRX: ignore the X byte
        g_window.contentView = view;

        g_hud = [CATextLayer layer];
        g_hud.font = (__bridge CFTypeRef)[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
        g_hud.fontSize = 11;
        g_hud.foregroundColor = CGColorCreateGenericRGB(0.4, 1.0, 0.4, 1.0);
        g_hud.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 0.6);
        g_hud.contentsScale = g_window.backingScaleFactor;
        g_hud.anchorPoint = CGPointMake(0, 1);
        g_hud.frame = CGRectMake(6, frame.size.height - 66, 700, 60);
        g_hud.autoresizingMask = kCALayerMaxXMargin | kCALayerMinYMargin;
        g_hud.string = @"waiting for the guest's first frame...";
        g_hud_on = !(getenv("KRUN_DISPLAY_HUD") && strcmp(getenv("KRUN_DISPLAY_HUD"), "0") == 0);
        g_hud.hidden = !g_hud_on;
        [g_layer addSublayer:g_hud];

        const char *csv = getenv("KRUN_DISPLAY_TELEMETRY");
        if (csv) {
            g_csv = fopen(csv, "w");
            if (g_csv) fprintf(g_csv, "seq,wall_s,t_ms,gap_ms,copy_ms,build_ms,queue_ms,commit_ms,latency_ms,paced,delta,content\n");
            char on[1100];
            snprintf(on, sizeof on, "%s.onscreen.csv", csv);
            g_csv_on = fopen(on, "w");
            if (g_csv_on) fprintf(g_csv_on, "seq,t_ms,onscreen_ms\n");
        }
        g_pacing = !(getenv("KRUN_DISPLAY_PACING") && strcmp(getenv("KRUN_DISPLAY_PACING"), "0") == 0);
        // For scripted measurements: SIGUSR1 toggles pacing, SIGUSR2 captures
        // the last frames, same as the menu items.
        static dispatch_source_t sig_pace, sig_cap;
        signal(SIGUSR1, SIG_IGN);
        signal(SIGUSR2, SIG_IGN);
        sig_pace = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sig_pace, ^{ [view togglePacing:nil]; });
        dispatch_resume(sig_pace);
        sig_cap = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sig_cap, ^{ capture_glitch(); });
        dispatch_resume(sig_cap);

        CADisplayLink *link = [view displayLinkWithTarget:view selector:@selector(vsync:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [g_window makeFirstResponder:view];
        [g_window center];
        [g_window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        static thread_start_t start;
        start = (thread_start_t){vm_main, arg};
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8 << 20);
        pthread_t tid;
        if (pthread_create(&tid, &attr, vm_thread, &start) != 0) {
            fprintf(stderr, "krun-vmm: could not start the VM thread\n");
            _exit(1);
        }
        pthread_detach(tid);
        [app run];
    }
}
