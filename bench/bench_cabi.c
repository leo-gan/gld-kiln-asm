#define _POSIX_C_SOURCE 200809L
#include "kiln_asm.h"

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

static void emit_row(const char *name, size_t bytes, uint64_t t0, uint64_t t1,
                     uint64_t c0, uint64_t c1, uint64_t iters, uint64_t sink) {
    uint64_t ns_x10  = ((t1 - t0) * 10ULL) / iters;
    uint64_t cyc_x10 = ((c1 - c0) * 10ULL) / iters;
    printf("cabi,%s,%zu,%llu.%llu,%llu.%llu,%llu\n",
           name, bytes,
           (unsigned long long)(ns_x10 / 10), (unsigned long long)(ns_x10 % 10),
           (unsigned long long)(cyc_x10 / 10), (unsigned long long)(cyc_x10 % 10),
           (unsigned long long)sink);
}

int main(void) {
    uint8_t *wire  = (uint8_t *)aligned_alloc(64, 4194304);
    uint8_t *amem  = (uint8_t *)aligned_alloc(64, 4194304);
    double  *f64s  = (double  *)aligned_alloc(64, 262144 * sizeof(double));
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
    kiln_message_t msg_out;
    kiln_message_t batch_in[100];
    for (int i = 0; i < 100; i++) {
        batch_in[i] = msg_in;
        batch_in[i].f_int32 = i - 50;
        batch_in[i].f_int64 = i + 100;
    }

    kiln_arena_t arena;
    kiln_result_t res;
    kiln_read_opts_t opt_def     = {0, 0, 0, 0};
    kiln_read_opts_t opt_slop    = {0, 0, 0, KILN_OPT_SLOP32};
    kiln_read_opts_t opt_trusted = {0, 0, 0, KILN_OPT_TRUSTED};
    kiln_read_opts_t opt_owned   = {0, 0, 0, KILN_OPT_OWNED};
    kiln_read_opts_t opt_owntr   = {0, 0, 0, KILN_OPT_OWNED | KILN_OPT_TRUSTED};
    kiln_read_opts_t opt_avx2    = {0, 0, 0, KILN_OPT_COPY_AVX2};
    kiln_read_opts_t opt_nt      = {0, 0, 0, KILN_OPT_COPY_NT};

    printf("mode,workload,bytes,mean_ns,mean_cyc,sink\n");

    uint64_t t0, t1, c0, c1, sink;
    const uint64_t N_SMALL = 500000;
    const uint64_t N_BATCH = 20000;
    const uint64_t N_10K   = 5000;
    const uint64_t N_2M    = 500;

    /* 1. point_encode */
    for (int i = 0; i < 5000; i++) { clobber_ptr(&pt_in); kiln_asm_encode_point(&pt_in, wire, 4096, &opt_def, &res); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(&pt_in);
        kiln_asm_encode_point(&pt_in, wire, 4096, &opt_def, &res);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("point_encode", 8, t0, t1, c0, c1, N_SMALL, sink);

    /* 2. point_decode */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        kiln_asm_decode_point(wire, 8, &pt_out, &opt_def, &res);
        sink += (uint64_t)pt_out.x;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("point_decode", 8, t0, t1, c0, c1, N_SMALL, sink);

    /* 3. msg_encode */
    for (int i = 0; i < 5000; i++) { clobber_ptr(&msg_in); kiln_asm_encode_message(&msg_in, wire, 4096, &opt_def, &res); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(&msg_in);
        kiln_asm_encode_message(&msg_in, wire, 4096, &opt_def, &res);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_encode", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 4. msg_encode_slop32 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(&msg_in);
        kiln_asm_encode_message(&msg_in, wire, 4096, &opt_slop, &res);
        sink += wire[0];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_encode_slop32", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 5. msg_decode_view_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        kiln_asm_decode_message(wire, 44, &msg_out, NULL, &opt_def, &res);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_view_utf8", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 6. msg_decode_view_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        kiln_asm_decode_message(wire, 44, &msg_out, NULL, &opt_trusted, &res);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_view_trusted", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 7. msg_decode_arena_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        kiln_arena_init(&arena, amem, 4096);
        clobber_ptr(wire);
        kiln_asm_decode_message(wire, 44, &msg_out, &arena, &opt_owned, &res);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_arena_utf8", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 8. msg_decode_arena_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        kiln_arena_init(&arena, amem, 4096);
        clobber_ptr(wire);
        kiln_asm_decode_message(wire, 44, &msg_out, &arena, &opt_owntr, &res);
        sink += (uint64_t)msg_out.f_int64;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("msg_decode_arena_trusted", 44, t0, t1, c0, c1, N_SMALL, sink);

    /* 8b. msg_decode_malloc_utf8 (view decode + heap malloc/copy/free per string) */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_SMALL; i++) {
        clobber_ptr(wire);
        kiln_asm_decode_message(wire, 44, &msg_out, NULL, &opt_def, &res);
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
    for (int i = 0; i < 500; i++) { clobber_ptr(batch_in); kiln_asm_encode_batch(batch_in, 100, wire, 16384, &opt_def, &res); }
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        clobber_ptr(batch_in);
        kiln_asm_encode_batch(batch_in, 100, wire, 16384, &opt_def, &res);
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
        kiln_asm_decode_batch(wire, 4404, &b_out, &b_cnt, &arena, &opt_def, &res);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_view_utf8", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 11. batch100_view_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        kiln_asm_decode_batch(wire, 4404, &b_out, &b_cnt, &arena, &opt_trusted, &res);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_view_trusted", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 12. batch100_arena_utf8 */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        kiln_asm_decode_batch(wire, 4404, &b_out, &b_cnt, &arena, &opt_owned, &res);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_arena_utf8", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 13. batch100_arena_trusted */
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_BATCH; i++) {
        kiln_arena_init(&arena, amem, 65536);
        clobber_ptr(wire);
        kiln_asm_decode_batch(wire, 4404, &b_out, &b_cnt, &arena, &opt_owntr, &res);
        sink += b_cnt;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("batch100_arena_trusted", 4404, t0, t1, c0, c1, N_BATCH, sink);

    /* 14-15. KLNT 10k f64 (80,192 B) */
    kiln_tensor_t t10k;
    kiln_tensor_init(&t10k);
    t10k.dtype = 1; t10k.rank = 1; t10k.shape[0] = 10000;
    t10k.data = (const uint8_t *)f64s; t10k.data_len = 80000;
    kiln_tensor_dir_t d10k = {&t10k, 1, 0, 2, 2}, dout;

    for (int i = 0; i < 200; i++) kiln_asm_encode_tensors(&d10k, wire, 4194304, &opt_def, &res);
    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_10K; i++) {
        clobber_ptr(&d10k);
        kiln_asm_encode_tensors(&d10k, wire, 4194304, &opt_def, &res);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_10k_f64_encode", 80192, t0, t1, c0, c1, N_10K, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_10K; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        kiln_asm_decode_tensors(wire, 80192, &dout, &arena, &opt_def, &res);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_10k_f64_decode_view", 80192, t0, t1, c0, c1, N_10K, sink);

    /* 16-20. KLNT 2 MiB f64 (2,097,344 B) */
    kiln_tensor_t t2m;
    kiln_tensor_init(&t2m);
    t2m.dtype = 1; t2m.rank = 1; t2m.shape[0] = 262144;
    t2m.data = (const uint8_t *)f64s; t2m.data_len = 2097152;
    kiln_tensor_dir_t d2m = {&t2m, 1, 0, 2, 2};

    for (int i = 0; i < 20; i++) kiln_asm_encode_tensors(&d2m, wire, 4194304, &opt_def, &res);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        clobber_ptr(&d2m);
        kiln_asm_encode_tensors(&d2m, wire, 4194304, &opt_def, &res);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_encode_erms", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        clobber_ptr(&d2m);
        kiln_asm_encode_tensors(&d2m, wire, 4194304, &opt_avx2, &res);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_encode_avx2", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        clobber_ptr(&d2m);
        kiln_asm_encode_tensors(&d2m, wire, 4194304, &opt_nt, &res);
        sink += wire[192];
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_encode_nt", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        kiln_asm_decode_tensors(wire, 2097344, &dout, &arena, &opt_def, &res);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_decode_view", 2097344, t0, t1, c0, c1, N_2M, sink);

    sink = 0; t0 = now_ns(); c0 = now_tsc();
    for (uint64_t i = 0; i < N_2M; i++) {
        kiln_arena_init(&arena, amem, 4194304);
        clobber_ptr(wire);
        kiln_asm_decode_tensors(wire, 2097344, &dout, &arena, &opt_owned, &res);
        sink += dout.block_length;
    }
    c1 = now_tsc(); t1 = now_ns();
    emit_row("klnt_2m_f64_decode_arena", 2097344, t0, t1, c0, c1, N_2M, sink);

    free(f64s); free(amem); free(wire);
    return 0;
}
