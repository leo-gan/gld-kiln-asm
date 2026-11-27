#include "kiln_asm.h"

#include <stdio.h>
#include <string.h>

int main(void) {
    uint8_t wire[1024];
    uint8_t arena_mem[1024];
    kiln_arena_t arena;
    kiln_result_t res;

    /* 1. Frozen Point round-trip (8 B) */
    kiln_point_t pt_in = {9, -4}, pt_out = {0, 0};
    if (kiln_asm_encode_point(&pt_in, wire, sizeof(wire), NULL, &res) != KILN_OK) return 1;
    if (kiln_asm_decode_point(wire, (size_t)res.bytes, &pt_out, NULL, &res) != KILN_OK) return 1;
    printf("Point: x=%d y=%d (%llu B)\n", pt_out.x, pt_out.y, (unsigned long long)res.bytes);

    /* 2. KLN0-framed Message round-trip (owned bump arena + UTF-8 check) */
    kiln_message_t m_in = {
        .f_int64    = 99,
        .f_float64  = 1.5,
        .f_string   = {(const uint8_t *)"hi", 2},
        .f_string_2 = {(const uint8_t *)"z", 1},
        .f_int32    = -2,
        .f_int32_2  = 7,
        .f_bool     = 1,
        .f_bool_2   = 0
    };
    if (kiln_asm_encode_message_framed(&m_in, wire, sizeof(wire), NULL, &res) != KILN_OK) return 1;
    size_t flen = (size_t)res.bytes;

    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    kiln_read_opts_t owned = {0, 0, 0, KILN_OPT_OWNED};
    kiln_message_t m_out;
    memset(&m_out, 0, sizeof(m_out));
    if (kiln_asm_decode_message_framed(wire, flen, &m_out, &arena, &owned, &res) != KILN_OK) return 1;
    printf("Message (framed): len=%zu hash=0x%016llx s1=%.*s s2=%.*s arena=%zu B\n",
           flen, (unsigned long long)res.hash,
           (int)m_out.f_string.len, (const char *)m_out.f_string.ptr,
           (int)m_out.f_string_2.len, (const char *)m_out.f_string_2.ptr,
           kiln_arena_used(&arena));

    /* 3. KLNT v2 tensor directory round-trip (named f32 vector) */
    float vec[2] = {1.0f, -2.0f};
    kiln_tensor_t t;
    kiln_tensor_init(&t);
    t.name     = (const uint8_t *)"weights";
    t.name_len = 7;
    t.dtype    = 2; /* f32 */
    t.rank     = 1;
    t.shape[0] = 2;
    t.data     = (const uint8_t *)vec;
    t.data_len = sizeof(vec);
    kiln_tensor_dir_t dir_in = {&t, 1, 0, 0, 2}, dir_out;
    if (kiln_asm_encode_tensors(&dir_in, wire, sizeof(wire), NULL, &res) != KILN_OK) return 1;
    size_t tlen = (size_t)res.bytes;

    kiln_arena_reset(&arena);
    if (kiln_asm_decode_tensors(wire, tlen, &dir_out, &arena, NULL, &res) != KILN_OK) return 1;
    float back[2];
    memcpy(back, dir_out.items[0].data, sizeof(back));
    printf("KLNT v2: name=%.*s dtype=%s shape=[%llu] values=[%.1f, %.1f] block=%llu B\n",
           (int)dir_out.items[0].name_len, (const char *)dir_out.items[0].name,
           kiln_asm_dtype_name(dir_out.items[0].dtype),
           (unsigned long long)dir_out.items[0].shape[0],
           back[0], back[1], (unsigned long long)dir_out.block_length);

    return 0;
}
