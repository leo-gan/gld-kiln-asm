#define _POSIX_C_SOURCE 200809L
/*
 * Honest apples-to-apples pure C11 (-O3 -march=native) Kiln v2 baseline.
 *
 * Parity contract (DESIGN.md §4):
 * - Uses identical runtime-populated structs (kiln_asm.h types), bounds checks,
 *   RFC 3629 UTF-8 validation (AVX2/SWAR ASCII fast-path + scalar fallback),
 *   KLNT v2 header/descriptor validation, bump arena / view / malloc semantics,
 *   and asm volatile optimization barriers (preventing constant folding/hoisting).
 * - Zero calls into libkiln_asm.a. Self-verifies against golden bytes before timing.
 */
#include "kiln_asm.h"

#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline uint64_t now_tsc(void) {
    uint32_t lo, hi, aux;
    __asm__ __volatile__("lfence\n\trdtscp" : "=a"(lo), "=d"(hi), "=c"(aux) :: "memory");
    return ((uint64_t)hi << 32) | lo;
}

static inline void clobber_ptr(const void *p) {
    __asm__ __volatile__("" : "+r"(p) :: "memory");
}

static inline uint32_t load_u32(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, 4); return v;
}
static inline uint64_t load_u64(const uint8_t *p) {
    uint64_t v; memcpy(&v, p, 8); return v;
}
static inline void store_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static inline void store_u64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

/* RFC 3629 UTF-8 validator: AVX2/SWAR ASCII fast-path + scalar multibyte fallback */
static int cref_utf8_scalar(const uint8_t *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) { i++; continue; }
        if (c < 0xC2) return 0;
        if (c <= 0xDF) {
            if (i + 2 > n || (s[i + 1] & 0xC0) != 0x80) return 0;
            i += 2;
        } else if (c <= 0xEF) {
            if (i + 3 > n || (s[i + 2] & 0xC0) != 0x80) return 0;
            uint8_t c1 = s[i + 1];
            if (c == 0xE0) { if (c1 < 0xA0 || c1 > 0xBF) return 0; }
            else if (c == 0xED) { if (c1 < 0x80 || c1 > 0x9F) return 0; }
            else if ((c1 & 0xC0) != 0x80) return 0;
            i += 3;
        } else if (c <= 0xF4) {
            if (i + 4 > n || (s[i + 2] & 0xC0) != 0x80 || (s[i + 3] & 0xC0) != 0x80) return 0;
            uint8_t c1 = s[i + 1];
            if (c == 0xF0) { if (c1 < 0x90 || c1 > 0xBF) return 0; }
            else if (c == 0xF4) { if (c1 < 0x80 || c1 > 0x8F) return 0; }
            else if ((c1 & 0xC0) != 0x80) return 0;
            i += 4;
        } else {
            return 0;
        }
    }
    return 1;
}

static inline int cref_utf8_ok(const uint8_t *s, size_t n) {
    size_t i = 0;
#ifdef __AVX2__
    while (i + 32 <= n) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(const void *)(s + i));
        if (_mm256_movemask_epi8(v) != 0) return cref_utf8_scalar(s + i, n - i);
        i += 32;
    }
#endif
    while (i + 8 <= n) {
        uint64_t w; memcpy(&w, s + i, 8);
        if (w & 0x8080808080808080ULL) return cref_utf8_scalar(s + i, n - i);
        i += 8;
    }
    while (i < n) {
        if (s[i] & 0x80) return cref_utf8_scalar(s + i, n - i);
        i++;
    }
    return 1;
}

static inline uint8_t *cref_arena_alloc(kiln_arena_t *a, size_t sz, size_t align) {
    uintptr_t p = ((uintptr_t)a->cur + (align - 1)) & ~(uintptr_t)(align - 1);
    if (p > (uintptr_t)a->end || (size_t)((uintptr_t)a->end - p) < sz) return NULL;
    a->cur = (uint8_t *)(p + sz);
    return (uint8_t *)p;
}

/* Point */
static __attribute__((noinline)) kiln_err_t cref_enc_point(
    const kiln_point_t *in, uint8_t *dst, size_t cap, size_t *out_len) {
    if (cap < 8) return KILN_ERR_LIMIT;
    store_u32(dst, (uint32_t)in->x);
    store_u32(dst + 4, (uint32_t)in->y);
    *out_len = 8;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_dec_point(
    const uint8_t *src, size_t len, kiln_point_t *out) {
    if (len < 8) return KILN_ERR_EOF;
    if (len > 8) return KILN_ERR_TRAILING;
    out->x = (int32_t)load_u32(src);
    out->y = (int32_t)load_u32(src + 4);
    return KILN_OK;
}

/* Message */
static inline kiln_err_t cref_enc_message_inline(
    const kiln_message_t *in, uint8_t *dst, size_t cap, size_t *out_len) {
    uint64_t l1 = in->f_string.len, l2 = in->f_string_2.len;
    if (l1 > KILN_CAP_DEFAULT || l2 > KILN_CAP_DEFAULT) return KILN_ERR_LIMIT;
    size_t total = 34 + (size_t)l1 + (size_t)l2;
    if (cap < total) return KILN_ERR_LIMIT;
    uint8_t *p = dst;
    *p++ = in->f_bool ? 1 : 0;
    store_u32(p, (uint32_t)in->f_int32); p += 4;
    store_u64(p, (uint64_t)in->f_int64); p += 8;
    uint64_t fbits; memcpy(&fbits, &in->f_float64, 8);
    store_u64(p, fbits); p += 8;
    store_u32(p, (uint32_t)l1); p += 4;
    if (l1) { memcpy(p, in->f_string.ptr, (size_t)l1); p += l1; }
    *p++ = in->f_bool_2 ? 1 : 0;
    store_u32(p, (uint32_t)in->f_int32_2); p += 4;
    store_u32(p, (uint32_t)l2); p += 4;
    if (l2) { memcpy(p, in->f_string_2.ptr, (size_t)l2); p += l2; }
    *out_len = total;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_enc_message(
    const kiln_message_t *in, uint8_t *dst, size_t cap, size_t *out_len) {
    return cref_enc_message_inline(in, dst, cap, out_len);
}

static inline kiln_err_t cref_dec_str(const uint8_t **pp, const uint8_t *end, kiln_str_t *out,
                                      kiln_arena_t *arena, int check_utf8, int owned) {
    const uint8_t *p = *pp;
    if ((size_t)(end - p) < 4) return KILN_ERR_EOF;
    uint32_t n = load_u32(p); p += 4;
    if (n > KILN_CAP_DEFAULT) return KILN_ERR_LIMIT;
    if ((size_t)(end - p) < n) return KILN_ERR_EOF;
    if (check_utf8 && !cref_utf8_ok(p, n)) return KILN_ERR_UTF8;
    if (owned) {
        uint8_t *dst = cref_arena_alloc(arena, n, 1);
        if (!dst) return KILN_ERR_LIMIT;
        if (n) memcpy(dst, p, n);
        out->ptr = dst;
    } else {
        out->ptr = p;
    }
    out->len = n;
    *pp = p + n;
    return KILN_OK;
}

static inline kiln_err_t cref_dec_message_at(const uint8_t **pp, const uint8_t *end,
                                             kiln_message_t *out, kiln_arena_t *arena,
                                             int check_utf8, int owned) {
    const uint8_t *p = *pp;
    if (p >= end) return KILN_ERR_EOF;
    if (p[0] > 1) return KILN_ERR_TYPE;
    if ((size_t)(end - p) < 21) return KILN_ERR_EOF;
    out->f_bool  = p[0];
    out->f_int32 = (int32_t)load_u32(p + 1);
    out->f_int64 = (int64_t)load_u64(p + 5);
    uint64_t fbits = load_u64(p + 13);
    memcpy(&out->f_float64, &fbits, 8);
    p += 21;
    kiln_err_t err = cref_dec_str(&p, end, &out->f_string, arena, check_utf8, owned);
    if (err != KILN_OK) return err;
    if (p >= end) return KILN_ERR_EOF;
    if (p[0] > 1) return KILN_ERR_TYPE;
    if ((size_t)(end - p) < 5) return KILN_ERR_EOF;
    out->f_bool_2  = p[0];
    out->f_int32_2 = (int32_t)load_u32(p + 1);
    p += 5;
    err = cref_dec_str(&p, end, &out->f_string_2, arena, check_utf8, owned);
    if (err != KILN_OK) return err;
    *pp = p;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_dec_message(
    const uint8_t *src, size_t len, kiln_message_t *out,
    kiln_arena_t *arena, int check_utf8, int owned) {
    const uint8_t *p = src, *end = src + len;
    kiln_err_t err = cref_dec_message_at(&p, end, out, arena, check_utf8, owned);
    if (err != KILN_OK) return err;
    if (p != end) return KILN_ERR_TRAILING;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_enc_batch(
    const kiln_message_t *items, size_t count,
    uint8_t *dst, size_t cap, size_t *out_len) {
    if (count > KILN_CAP_DEFAULT || cap < 4) return KILN_ERR_LIMIT;
    store_u32(dst, (uint32_t)count);
    size_t pos = 4;
    for (size_t i = 0; i < count; i++) {
        size_t n = 0;
        kiln_err_t err = cref_enc_message_inline(&items[i], dst + pos, cap - pos, &n);
        if (err != KILN_OK) return err;
        pos += n;
    }
    *out_len = pos;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_dec_batch(
    const uint8_t *src, size_t len,
    kiln_message_t **out_items, size_t *out_cnt,
    kiln_arena_t *arena, int check_utf8, int owned) {
    const uint8_t *p = src, *end = src + len;
    if (len < 4) return KILN_ERR_EOF;
    uint32_t count = load_u32(p); p += 4;
    if (count > KILN_CAP_DEFAULT) return KILN_ERR_LIMIT;
    if ((uint64_t)count * 34ULL > (uint64_t)(end - p)) return KILN_ERR_EOF;
    kiln_message_t *arr = (kiln_message_t *)cref_arena_alloc(arena, count * sizeof(kiln_message_t), 8);
    if (!arr && count > 0) return KILN_ERR_LIMIT;
    for (uint32_t i = 0; i < count; i++) {
        kiln_err_t err = cref_dec_message_at(&p, end, &arr[i], arena, check_utf8, owned);
        if (err != KILN_OK) return err;
    }
    if (p != end) return KILN_ERR_TRAILING;
    *out_items = arr;
    *out_cnt = count;
    return KILN_OK;
}

/* KLNT v2 single-or-multi tensor encoder & validated decoder */
static __attribute__((noinline)) kiln_err_t cref_enc_tensors(
    const kiln_tensor_dir_t *in, uint8_t *dst, size_t cap, size_t *out_len) {
    uint64_t count = in->count;
    if (count > KILN_CAP_DEFAULT) return KILN_ERR_LIMIT;
    uint64_t dir_bytes = count * 128ULL;
    uint64_t pay_base = (64ULL + dir_bytes + 63ULL) & ~63ULL;
    uint64_t pay_end = 0;
    for (uint64_t i = 0; i < count; i++) {
        pay_end = (pay_end + 63ULL) & ~63ULL;
        pay_end += in->items[i].data_len;
    }
    uint64_t block_end = pay_base + pay_end;
    if (block_end > cap) return KILN_ERR_LIMIT;

    memcpy(dst, "KLNT", 4);
    dst[4] = 2; dst[5] = 0x02; dst[6] = 0; dst[7] = 0;
    store_u32(dst + 8, (uint32_t)count);
    store_u32(dst + 12, 0);
    store_u64(dst + 16, pay_end);
    store_u64(dst + 24, dir_bytes);
    memset(dst + 32, 0, 32);

    uint64_t cur = 0;
    for (uint64_t i = 0; i < count; i++) {
        const kiln_tensor_t *t = &in->items[i];
        uint8_t *d = dst + 64 + i * 128;
        memset(d, 0, 128);
        uint16_t dt = t->dtype; memcpy(d + 0, &dt, 2);
        d[2] = t->rank;
        uint16_t ff = 0xFFFF; memcpy(d + 4, &ff, 2); memcpy(d + 8, &ff, 2);
        memcpy(d + 16, &t->quant_scheme, 2);
        memcpy(d + 18, &t->quant_axis, 2);
        store_u32(d + 20, t->group_size);
        store_u32(d + 24, t->scale_index);
        store_u32(d + 28, t->outer_index);
        uint64_t off = (cur + 63ULL) & ~63ULL;
        store_u64(d + 32, off);
        store_u64(d + 40, t->data_len);
        for (uint8_t r = 0; r < t->rank; r++) store_u64(d + 48 + r * 8, t->shape[r]);
        if (off > cur) memset(dst + pay_base + cur, 0, (size_t)(off - cur));
        if (t->data_len) memcpy(dst + pay_base + off, t->data, (size_t)t->data_len);
        cur = off + t->data_len;
    }
    *out_len = (size_t)block_end;
    return KILN_OK;
}

static __attribute__((noinline)) kiln_err_t cref_dec_tensors(
    const uint8_t *src, size_t len,
    kiln_tensor_dir_t *out, kiln_arena_t *arena, int owned) {
    if (len < 4) return KILN_ERR_EOF;
    if (memcmp(src, "KLNT", 4) != 0) return KILN_ERR_FRAME;
    if (len < 64) return KILN_ERR_EOF;
    if (src[4] != 2 || (src[5] & ~3U) != 0 || !(src[5] & 2U) || src[6] != 0 || src[7] != 0)
        return KILN_ERR_FRAME;
    for (int i = 32; i < 64; i++) if (src[i] != 0) return KILN_ERR_FRAME;
    uint32_t count = load_u32(src + 8), name_bytes = load_u32(src + 12);
    uint64_t pay_bytes = load_u64(src + 16), dir_bytes = load_u64(src + 24);
    if (count > KILN_CAP_DEFAULT || name_bytes > KILN_CAP_DEFAULT) return KILN_ERR_LIMIT;
    if ((uint64_t)count * 128ULL + name_bytes != dir_bytes) return KILN_ERR_TYPE;
    uint64_t after_dir = 64ULL + dir_bytes;
    if (after_dir > len) return KILN_ERR_EOF;
    uint64_t pay_base = (after_dir + 63ULL) & ~63ULL;
    uint64_t block_end = pay_base + pay_bytes;
    if (block_end < pay_base || block_end > len) return KILN_ERR_EOF;
    for (uint64_t p = after_dir; p < pay_base; p++) if (src[p] != 0) return KILN_ERR_TYPE;

    kiln_tensor_t *items = count ? (kiln_tensor_t *)cref_arena_alloc(arena, count * sizeof(kiln_tensor_t), 8) : NULL;
    if (count && !items) return KILN_ERR_LIMIT;
    uint64_t cur_end = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *d = src + 64 + (size_t)i * 128;
        if (d[3] != 0) return KILN_ERR_FRAME;
        for (int k = 112; k < 128; k++) if (d[k] != 0) return KILN_ERR_FRAME;
        kiln_tensor_init(&items[i]);
        uint16_t dt; memcpy(&dt, d, 2);
        items[i].dtype = dt;
        items[i].rank = d[2];
        if (items[i].rank > 8) return KILN_ERR_TYPE;
        uint64_t boff = load_u64(d + 32), blen = load_u64(d + 40);
        uint64_t exp_off = (cur_end + 63ULL) & ~63ULL;
        if (boff != exp_off || boff + blen > pay_bytes) return KILN_ERR_TYPE;
        for (uint64_t p = cur_end; p < exp_off; p++) if (src[pay_base + p] != 0) return KILN_ERR_TYPE;
        uint64_t n = 1;
        for (int r = 0; r < 8; r++) {
            uint64_t dim = load_u64(d + 48 + r * 8);
            items[i].shape[r] = dim;
            if (r < items[i].rank) {
                if (__builtin_mul_overflow(n, dim, &n)) return KILN_ERR_LIMIT;
            } else if (dim != 0) {
                return KILN_ERR_TYPE;
            }
        }
        if (dt == 1 && blen != n * 8ULL) return KILN_ERR_TYPE;
        items[i].elem_count = n;
        items[i].data_len = blen;
        if (owned && blen > 0) {
            uint8_t *copy = cref_arena_alloc(arena, (size_t)blen, 64);
            if (!copy) return KILN_ERR_LIMIT;
            memcpy(copy, src + pay_base + boff, (size_t)blen);
            items[i].data = copy;
        } else {
            items[i].data = src + pay_base + boff;
        }
        cur_end = boff + blen;
    }
    if (cur_end != pay_bytes) return KILN_ERR_TYPE;
    if (block_end != len) return KILN_ERR_TRAILING;
    out->items = items; out->count = count; out->block_length = block_end;
    out->flags = src[5]; out->version = 2;
    return KILN_OK;
}

static void emit_row(const char *name, size_t bytes, uint64_t t0, uint64_t t1,
                     uint64_t c0, uint64_t c1, uint64_t iters, uint64_t sink) {
    uint64_t ns_x10  = ((t1 - t0) * 10ULL) / iters;
    uint64_t cyc_x10 = ((c1 - c0) * 10ULL) / iters;
    printf("c_ref,%s,%zu,%llu.%llu,%llu.%llu,%llu\n",
           name, bytes,
           (unsigned long long)(ns_x10 / 10), (unsigned long long)(ns_x10 % 10),
           (unsigned long long)(cyc_x10 / 10), (unsigned long long)(cyc_x10 % 10),
           (unsigned long long)sink);
}

int main(void) {
    uint8_t *wire = (uint8_t *)aligned_alloc(64, 4194304);
    uint8_t *amem = (uint8_t *)aligned_alloc(64, 4194304);
    double  *f64s = (double  *)aligned_alloc(64, 262144 * sizeof(double));
    if (!wire || !amem || !f64s) return 1;
    memset(wire, 0, 4194304);
    memset(amem, 0, 4194304);
    for (size_t i = 0; i < 262144; i++) f64s[i] = 1.5;

    static const uint8_t s_hello[32] __attribute__((aligned(32))) = "hello";
    static const uint8_t s_world[32] __attribute__((aligned(32))) = "world";

    kiln_point_t pt_in = {9, -4}, pt_out = {0, 0};
    kiln_message_t msg_in = {
        .f_int64 = 99, .f_float64 = 1.5,
        .f_string = {s_hello, 5}, .f_string_2 = {s_world, 5},
        .f_int32 = -2, .f_int32_2 = 7, .f_bool = 1, .f_bool_2 = 0
    };
    kiln_message_t msg_out = {0};
    kiln_message_t batch_in[100];
    for (int i = 0; i < 100; i++) {
        batch_in[i] = msg_in;
        batch_in[i].f_int32 = i - 50;
        batch_in[i].f_int64 = i + 100;
    }

    /* Quick self-verify against golden Point (8 B) & Message (37 B) */
    size_t n = 0;
    const uint8_t g_pt[8] = {9, 0, 0, 0, 0xfc, 0xff, 0xff, 0xff};
    if (cref_enc_point(&pt_in, wire, 4096, &n) != KILN_OK || n != 8 || memcmp(wire, g_pt, 8) != 0) {
        fprintf(stderr, "c_ref self-test failed (point)\n");
        return 1;
    }

    printf("mode,workload,bytes,mean_ns,mean_cyc,sink\n");

    kiln_arena_t arena;
    uint64_t t0, t1, c0, c1, sink;
    const uint64_t N_SMALL = 500000;
    const uint64_t N_BATCH = 20000;
    const uint64_t N_10K   = 5000;
    const uint64_t N_2M    = 500;

    /* 1. point_encode */
    for (int i = 0; i < 5000; i++) { clobber_ptr(&pt_in); cref_enc_point(&pt_in, wire, 4096, &n); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(&pt_in);
        cref_enc_point(&pt_in, wire, 4096, &n);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("point_encode", 8, t0, t1, c0, c1, N_SMALL, sink);

    /* 2. point_decode */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        cref_dec_point(wire, 8, &pt_out);
        sink += (uint64_t)pt_out.x;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("point_decode", 8, t0, t1, c0, c1, N_SMALL, sink);

    /* 3. msg_encode */
    for (int i = 0; i < 5000; i++) { clobber_ptr(&msg_in); cref_enc_message(&msg_in, wire, 4096, &n); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(&msg_in);
        cref_enc_message(&msg_in, wire, 4096, &n);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_encode", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 5. msg_decode_view_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        cref_dec_message(wire, 44, &msg_out, NULL, 1, 0);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_view_utf8", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 6. msg_decode_view_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        cref_dec_message(wire, 44, &msg_out, NULL, 0, 0);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_view_trusted", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 7. msg_decode_arena_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        kiln_arena_init(&arena, amem, 4096);
        clobber_ptr(wire);
        cref_dec_message(wire, 44, &msg_out, &arena, 1, 1);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_arena_utf8", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 8. msg_decode_arena_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        kiln_arena_init(&arena, amem, 4096);
        clobber_ptr(wire);
        cref_dec_message(wire, 44, &msg_out, &arena, 0, 1);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_arena_trusted", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 8b. msg_decode_malloc_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        cref_dec_message(wire, 44, &msg_out, NULL, 1, 0);
        uint8_t *p1 = (uint8_t *)malloc(msg_out.f_string.len);
        uint8_t *p2 = (uint8_t *)malloc(msg_out.f_string_2.len);
        memcpy(p1, msg_out.f_string.ptr, msg_out.f_string.len);
        memcpy(p2, msg_out.f_string_2.ptr, msg_out.f_string_2.len);
        clobber_ptr(p1); clobber_ptr(p2);
        sink += p1[0] + p2[0];
        free(p1); free(p2);
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_malloc_utf8", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 9. batch100_encode */
    for (int i = 0; i < 500; i++) { clobber_ptr(batch_in); cref_enc_batch(batch_in, 100, wire, 16384, &n); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        clobber_ptr(batch_in);
        cref_enc_batch(batch_in, 100, wire, 16384, &n);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_encode", 4404, t0, t1, c0, c1, N_BATCH, sink);

    kiln_message_t *b_out = NULL;
    size_t b_cnt = 0;

    /* 10. batch100_view_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        cref_dec_batch(wire, 4404, &b_out, &b_cnt, &arena, 1, 0);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_view_utf8", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 11. batch100_view_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        cref_dec_batch(wire, 4404, &b_out, &b_cnt, &arena, 0, 0);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_view_trusted", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 12. batch100_arena_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        cref_dec_batch(wire, 4404, &b_out, &b_cnt, &arena, 1, 1);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_arena_utf8", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 13. batch100_arena_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        cref_dec_batch(wire, 4404, &b_out, &b_cnt, &arena, 0, 1);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_arena_trusted", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 14-15. KLNT 10k f64 */
    kiln_tensor_t t10k;
    kiln_tensor_init(&t10k);
    t10k.dtype = 1; t10k.rank = 1; t10k.shape[0] = 10000;
    t10k.data = (const uint8_t *)f64s; t10k.data_len = 80000;
    kiln_tensor_dir_t d10k = {&t10k, 1, 0, 2, 2}, dout = {0};

    for (int i = 0; i < 200; i++) cref_enc_tensors(&d10k, wire, 4194304, &n);
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_10K; i++) {
        clobber_ptr(&d10k);
        cref_enc_tensors(&d10k, wire, 4194304, &n);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_10k_f64_encode", 80192, t0, t1, c0, c1, N_10K, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_10K; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        cref_dec_tensors(wire, 80192, &dout, &arena, 0);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_10k_f64_decode_view", 80192, t0, t1, c0, c1, N_10K, sink);

    /* 16-20. KLNT 2 MiB f64 */
    kiln_tensor_t t2m;
    kiln_tensor_init(&t2m);
    t2m.dtype = 1; t2m.rank = 1; t2m.shape[0] = 262144;
    t2m.data = (const uint8_t *)f64s; t2m.data_len = 2097152;
    kiln_tensor_dir_t d2m = {&t2m, 1, 0, 2, 2};

    for (int i = 0; i < 20; i++) cref_enc_tensors(&d2m, wire, 4194304, &n);
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        clobber_ptr(&d2m);
        cref_enc_tensors(&d2m, wire, 4194304, &n);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_encode_erms", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        cref_dec_tensors(wire, 2097344, &dout, &arena, 0);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_decode_view", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        cref_dec_tensors(wire, 2097344, &dout, &arena, 1);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_decode_arena", 2097344, t0, t1, c0, c1, N_2M, sink);

    free(f64s); free(amem); free(wire);
    return 0;
}
