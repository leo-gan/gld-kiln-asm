#include "kiln_asm.h"
#include "point.h"
#include "message.h"
#include "id_tensors.h"
#include "complex_record.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__, (msg)); \
        g_failures++; \
    } \
} while (0)

static uint8_t *read_all(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf); fclose(f); return NULL;
    }
    buf[n] = 0;
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

static void test_golden_parity(void) {
    size_t glen = 0;
    uint8_t buf[8192];
    uint8_t arena_mem[32768];
    kiln_arena_t arena;
    kiln_result_t res;

    /* Verify exact normative FNV-1a-64 schema hashes */
    CHECK(GEN_HASH_POINT == KILN_HASH_POINT, "generated Point hash == normative");
    CHECK(GEN_HASH_MESSAGE == KILN_HASH_MESSAGE, "generated Message hash == normative");
    CHECK(GEN_HASH_ID_TENSORS == KILN_HASH_ID_TENSORS, "generated IdTensors hash == normative");

    /* 1. Point golden parity */
    uint8_t *g_pt = read_all("testdata/golden/point.kiln", &glen);
    CHECK(g_pt != NULL && glen == 8, "load point.kiln");
    if (g_pt) {
        gen_point_t pt = {0, 0};
        CHECK(kiln_asm_decode_gen_point(g_pt, glen, &pt, NULL, NULL, &res) == KILN_OK, "gen decode point");
        CHECK(res.bytes == 8 && pt.x == 9 && pt.y == -4, "gen point values");
        CHECK(kiln_asm_encode_gen_point(&pt, buf, sizeof(buf), NULL, &res) == KILN_OK, "gen encode point");
        CHECK(res.bytes == 8 && memcmp(buf, g_pt, 8) == 0, "gen point byte-exact match");

        CHECK(kiln_asm_encode_gen_point_framed(&pt, buf, sizeof(buf), NULL, &res) == KILN_OK && res.bytes == 24,
              "gen encode point framed");
        gen_point_t pt2 = {0, 0};
        CHECK(kiln_asm_decode_gen_point_framed(buf, 24, &pt2, NULL, NULL, &res) == KILN_OK,
              "gen decode point framed");
        CHECK(res.hash == KILN_HASH_POINT && pt2.x == 9 && pt2.y == -4, "gen framed point hash & values");
        buf[8] ^= 1;
        CHECK(kiln_asm_decode_gen_point_framed(buf, 24, &pt2, NULL, NULL, &res) == KILN_ERR_SCHEMA,
              "gen framed point bad hash -> SCHEMA");
        free(g_pt);
    }

    /* 2. Message golden parity (unframed, framed, owned, view, batch[100]) */
    uint8_t *g_msg = read_all("testdata/golden/message.kiln", &glen);
    CHECK(g_msg != NULL && glen == 37, "load message.kiln");
    if (g_msg) {
        gen_message_t m;
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_gen_message(g_msg, glen, &m, NULL, NULL, &res) == KILN_OK, "gen decode msg view");
        CHECK(res.bytes == 37 && m.f_bool == 1 && m.f_int32 == -2 && m.f_int64 == 99 && m.f_float64 == 1.5,
              "gen msg scalars");
        CHECK(m.f_string.len == 2 && memcmp(m.f_string.ptr, "hi", 2) == 0 && m.f_string.ptr == g_msg + 25,
              "gen msg str1 view");
        CHECK(m.f_bool_2 == 0 && m.f_int32_2 == 7 && m.f_string_2.len == 1 && m.f_string_2.ptr[0] == 'z',
              "gen msg tail");
        CHECK(kiln_asm_encode_gen_message(&m, buf, sizeof(buf), NULL, &res) == KILN_OK, "gen encode msg");
        CHECK(res.bytes == 37 && memcmp(buf, g_msg, 37) == 0, "gen msg byte-exact match");

        kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
        kiln_read_opts_t owned = {0, 0, 0, KILN_OPT_OWNED};
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_gen_message(g_msg, glen, &m, &arena, &owned, &res) == KILN_OK, "gen decode msg owned");
        CHECK(kiln_arena_used(&arena) == 3, "gen msg owned arena == 3 B");
        CHECK(memcmp(m.f_string.ptr, "hi", 2) == 0 && m.f_string_2.ptr[0] == 'z', "gen msg owned strings");
        free(g_msg);
    }

    uint8_t *g_mf = read_all("testdata/golden/message.frame.kiln", &glen);
    CHECK(g_mf != NULL && glen == 53, "load message.frame.kiln");
    if (g_mf) {
        gen_message_t m;
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_gen_message_framed(g_mf, glen, &m, NULL, NULL, &res) == KILN_OK,
              "gen decode message.frame.kiln");
        CHECK(res.bytes == 53 && res.hash == KILN_HASH_MESSAGE, "gen framed msg hash");
        CHECK(kiln_asm_encode_gen_message_framed(&m, buf, sizeof(buf), NULL, &res) == KILN_OK,
              "gen encode message framed");
        CHECK(res.bytes == 53 && memcmp(buf, g_mf, 53) == 0, "gen framed msg byte-exact match");
        free(g_mf);
    }

    /* Batch[100] parity against hand-written kiln_asm_encode_batch */
    gen_message_t gbatch[100];
    kiln_message_t hbatch[100];
    for (int i = 0; i < 100; i++) {
        gbatch[i].f_bool = (uint8_t)(i & 1);
        gbatch[i].f_int32 = i - 50;
        gbatch[i].f_int64 = (int64_t)i * 1000;
        gbatch[i].f_float64 = 1.5;
        gbatch[i].f_string.ptr = (const uint8_t *)"hello";
        gbatch[i].f_string.len = 5;
        gbatch[i].f_bool_2 = 0;
        gbatch[i].f_int32_2 = 7;
        gbatch[i].f_string_2.ptr = (const uint8_t *)"world";
        gbatch[i].f_string_2.len = 5;

        hbatch[i].f_bool = gbatch[i].f_bool;
        hbatch[i].f_int32 = gbatch[i].f_int32;
        hbatch[i].f_int64 = gbatch[i].f_int64;
        hbatch[i].f_float64 = gbatch[i].f_float64;
        hbatch[i].f_string = gbatch[i].f_string;
        hbatch[i].f_bool_2 = gbatch[i].f_bool_2;
        hbatch[i].f_int32_2 = gbatch[i].f_int32_2;
        hbatch[i].f_string_2 = gbatch[i].f_string_2;
    }
    uint8_t buf_hand[8192];
    kiln_result_t res_hand;
    CHECK(kiln_asm_encode_gen_message_batch(gbatch, 100, buf, sizeof(buf), NULL, &res) == KILN_OK,
          "gen encode batch[100]");
    CHECK(kiln_asm_encode_batch(hbatch, 100, buf_hand, sizeof(buf_hand), NULL, &res_hand) == KILN_OK,
          "hand encode batch[100]");
    CHECK(res.bytes == 4404 && res.bytes == res_hand.bytes && memcmp(buf, buf_hand, 4404) == 0,
          "gen batch[100] byte-exact match with hand-written asm");

    gen_message_t *dec_batch = NULL;
    size_t dec_count = 0;
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    kiln_read_opts_t owned = {0, 0, 0, KILN_OPT_OWNED};
    CHECK(kiln_asm_decode_gen_message_batch(buf, 4404, &dec_batch, &dec_count, &arena, &owned, &res) == KILN_OK,
          "gen decode batch[100] owned");
    CHECK(dec_count == 100 && dec_batch[99].f_int64 == 99000 &&
          dec_batch[99].f_string_2.len == 5 && memcmp(dec_batch[99].f_string_2.ptr, "world", 5) == 0,
          "gen decode batch[100] values");

    /* Hostile batch pre-allocation reject (0 arena bytes allocated!) */
    uint8_t hostile_batch[4] = {0x00, 0x00, 0x00, 0x01}; /* count = 16,777,216, 0 trailing */
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_gen_message_batch(hostile_batch, 4, &dec_batch, &dec_count, &arena, NULL, &res) == KILN_ERR_EOF,
          "hostile gen batch -> EOF");
    CHECK(kiln_arena_used(&arena) == 0, "hostile gen batch allocates 0 arena bytes");

    /* 3. IdTensors parity against hand-written kiln_asm_encode_id_tensors_framed */
    float f32_vals[2] = {1.0f, -2.0f};
    kiln_tensor_t t0;
    kiln_tensor_init(&t0);
    t0.dtype = 2;
    t0.rank = 1;
    t0.shape[0] = 2;
    t0.data = (const uint8_t *)f32_vals;
    t0.data_len = sizeof(f32_vals);

    gen_id_tensors_t git = { .id = 7, .batch = { &t0, 1, 0, 0, 2 } };
    kiln_id_tensors_t hit = { .id = 7, .batch = { &t0, 1, 0, 0, 2 } };
    CHECK(kiln_asm_encode_gen_id_tensors_framed(&git, buf, sizeof(buf), NULL, &res) == KILN_OK,
          "gen encode id_tensors framed");
    CHECK(kiln_asm_encode_id_tensors_framed(&hit, buf_hand, sizeof(buf_hand), NULL, &res_hand) == KILN_OK,
          "hand encode id_tensors framed");
    CHECK(res.bytes == res_hand.bytes && memcmp(buf, buf_hand, (size_t)res.bytes) == 0,
          "gen id_tensors framed byte-exact match");

    gen_id_tensors_t git_out;
    memset(&git_out, 0, sizeof(git_out));
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_gen_id_tensors_framed(buf, (size_t)res.bytes, &git_out, &arena, NULL, &res) == KILN_OK,
          "gen decode id_tensors framed");
    CHECK(res.hash == KILN_HASH_ID_TENSORS && git_out.id == 7 && git_out.batch.count == 1 &&
          git_out.batch.items[0].dtype == 2 && git_out.batch.items[0].data_len == 8,
          "gen decode id_tensors framed values");
}

static void test_complex_record(void) {
    uint8_t wire[65536];
    uint8_t arena_mem[131072];
    kiln_arena_t arena;
    kiln_result_t res;

    /* Prepare test data covering EVERY scalar, string length tier, raw non-UTF-8 bytes,
     * optional present/absent, POD list, AVX2 bool list, u8 list, nested list<list<i32>>,
     * dicts of i64/str/struct, and embedded KLNT v2 tensors. */
    const char *long_utf8 = "0123456789abcdef0123456789abcdef_hello_\xE2\x82\xAC_\xF0\x9F\x98\x80";
    const uint8_t raw_non_utf8[5] = {0xFF, 0x00, 0xFE, 0x80, 0x42};
    double opt_nums_arr[2] = {-0.0, 42.25};
    double nums_arr[4] = {1.0, -0.0, 3.5, 0.0};
    /* Put a quiet NaN with payload 1 into nums_arr[3] to verify bit preservation */
    uint64_t qnan_bits = 0x7FF8000000000001ULL;
    memcpy(&nums_arr[3], &qnan_bits, 8);

    uint8_t flags_arr[65];
    for (int i = 0; i < 65; i++) flags_arr[i] = (uint8_t)(i & 1); /* > 32 B exercises AVX2! */
    uint8_t u8_arr_vals[4] = {0x00, 0x01, 0x02, 0xFF}; /* >= 2 valid for u8, invalid for bool */

    kiln_str_t tags_arr[4] = {
        {(const uint8_t *)"", 0},
        {(const uint8_t *)"a", 1},
        {(const uint8_t *)"hello", 5},
        {(const uint8_t *)long_utf8, strlen(long_utf8)},
    };
    kiln_bytes_t blobs_arr[2] = {
        {raw_non_utf8, sizeof(raw_non_utf8)},
        {(const uint8_t *)"", 0},
    };
    gen_complex_record_item_t items_arr[2] = {
        {{(const uint8_t *)"sku-1", 5}, 10, 12.5f},
        {{(const uint8_t *)"sku-2-long-name", 15}, 20, -0.5f},
    };
    int32_t row0[3] = {1, -2, 3};
    int32_t row1[2] = {40, -50};
    gen_complex_record_list_i32_t matrix_rows[2] = {
        {row0, 3},
        {row1, 2},
    };
    gen_complex_record_dict_i64_entry_t counters_arr[3] = {
        {{(const uint8_t *)"a", 1}, 100},
        {{(const uint8_t *)"beta", 4}, -200},
        {{(const uint8_t *)"gamma_long_key_12345", 20}, 300},
    };
    gen_complex_record_dict_str_entry_t labels_arr[2] = {
        {{(const uint8_t *)"env", 3}, {(const uint8_t *)"prod", 4}},
        {{(const uint8_t *)"region", 6}, {(const uint8_t *)"us-west-2", 9}},
    };
    gen_complex_record_dict_item_entry_t by_key_arr[2] = {
        {{(const uint8_t *)"k1", 2}, items_arr[0]},
        {{(const uint8_t *)"k2", 2}, items_arr[1]},
    };

    int64_t tok_ids[4] = {101, 202, 303, 404};
    kiln_tensor_t pt0;
    kiln_tensor_init(&pt0);
    pt0.name = (const uint8_t *)"input_ids";
    pt0.name_len = 9;
    pt0.dtype = 14; /* i64 */
    pt0.rank = 2;
    pt0.shape[0] = 2;
    pt0.shape[1] = 2;
    pt0.data = (const uint8_t *)tok_ids;
    pt0.data_len = sizeof(tok_ids);

    gen_complex_record_t in;
    memset(&in, 0, sizeof(in));
    in.v_bool = 1;
    in.v_i8 = -128;
    in.v_u8 = 255;
    in.v_i16 = -32000;
    in.v_u16 = 65000;
    in.v_i32 = -123456789;
    in.v_u32 = 3000000000U;
    in.v_f32 = -1.25f;
    in.v_i64 = -9000000000000LL;
    in.v_u64 = 18000000000000000000ULL;
    in.v_int = -777;
    in.v_uint = 888;
    in.v_f64 = 3.141592653589793;
    in.text.ptr = (const uint8_t *)long_utf8;
    in.text.len = strlen(long_utf8);
    in.raw.ptr = raw_non_utf8;
    in.raw.len = sizeof(raw_non_utf8);
    /* Optionals: mix of present and absent */
    in.opt_i32.present = 1;
    in.opt_i32.value = -42;
    in.opt_str.present = 0; /* absent! */
    in.opt_item.present = 1;
    in.opt_item.value = items_arr[0];
    in.opt_nums.present = 1;
    in.opt_nums.value.items = opt_nums_arr;
    in.opt_nums.value.count = 2;
    in.nums.items = nums_arr;
    in.nums.count = 4;
    in.flags.items = flags_arr;
    in.flags.count = 65;
    in.u8_arr.items = u8_arr_vals;
    in.u8_arr.count = 4;
    in.tags.items = tags_arr;
    in.tags.count = 4;
    in.blobs.items = blobs_arr;
    in.blobs.count = 2;
    in.items.items = items_arr;
    in.items.count = 2;
    in.matrix.items = matrix_rows;
    in.matrix.count = 2;
    in.counters.entries = counters_arr;
    in.counters.count = 3;
    in.labels.entries = labels_arr;
    in.labels.count = 2;
    in.by_key.entries = by_key_arr;
    in.by_key.count = 2;
    in.prompt.items = &pt0;
    in.prompt.count = 1;

    /* Encode framed */
    CHECK(kiln_asm_encode_gen_complex_record_framed(&in, wire, sizeof(wire), NULL, &res) == KILN_OK,
          "encode complex_record framed");
    size_t wlen = (size_t)res.bytes;
    CHECK(wlen > 200, "complex_record non-trivial wire length");

    /* Decode framed (view + owned) */
    for (int mode = 0; mode < 2; mode++) {
        gen_complex_record_t out;
        memset(&out, 0xAA, sizeof(out)); /* poison memory to verify opt absent zeroing! */
        kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
        kiln_read_opts_t opts = {0, 0, 0, mode ? KILN_OPT_OWNED : 0};
        CHECK(kiln_asm_decode_gen_complex_record_framed(wire, wlen, &out, &arena, &opts, &res) == KILN_OK,
              mode ? "decode complex_record owned" : "decode complex_record view");
        CHECK(res.bytes == wlen && res.hash == GEN_HASH_COMPLEX_RECORD, "complex_record hash & len");
        CHECK(out.v_bool == 1 && out.v_i8 == -128 && out.v_u8 == 255 &&
              out.v_i16 == -32000 && out.v_u16 == 65000 &&
              out.v_i32 == -123456789 && out.v_u32 == 3000000000U &&
              out.v_f32 == -1.25f && out.v_i64 == -9000000000000LL &&
              out.v_u64 == 18000000000000000000ULL &&
              out.v_int == -777 && out.v_uint == 888 &&
              out.v_f64 == 3.141592653589793, "all 13 scalars exact");
        CHECK(out.text.len == in.text.len && memcmp(out.text.ptr, long_utf8, in.text.len) == 0, "long utf8 text");
        CHECK(out.raw.len == 5 && memcmp(out.raw.ptr, raw_non_utf8, 5) == 0, "raw non-utf8 bytes");
        CHECK(out.opt_i32.present == 1 && out.opt_i32.value == -42, "opt_i32 present");
        CHECK(out.opt_str.present == 0 && out.opt_str.value.ptr == NULL && out.opt_str.value.len == 0,
              "opt_str absent & zeroed");
        CHECK(out.opt_item.present == 1 && out.opt_item.value.qty == 10 && out.opt_item.value.price == 12.5f,
              "opt_item present");
        CHECK(out.opt_nums.present == 1 && out.opt_nums.value.count == 2 &&
              out.opt_nums.value.items[1] == 42.25, "opt_nums present");
        uint64_t got_neg0 = 0, got_qnan = 0;
        memcpy(&got_neg0, &out.nums.items[1], 8);
        memcpy(&got_qnan, &out.nums.items[3], 8);
        CHECK(out.nums.count == 4 && got_neg0 == 0x8000000000000000ULL && got_qnan == qnan_bits,
              "list<f64> preserves -0.0 and NaN payload");
        CHECK(out.flags.count == 65 && out.flags.items[64] == 0 && out.flags.items[63] == 1, "list<bool> 65B");
        CHECK(out.u8_arr.count == 4 && out.u8_arr.items[3] == 0xFF, "list<u8> preserves 0xFF");
        CHECK(out.tags.count == 4 && out.tags.items[0].len == 0 &&
              out.tags.items[2].len == 5 && memcmp(out.tags.items[2].ptr, "hello", 5) == 0 &&
              out.tags.items[3].len == strlen(long_utf8), "list<str>");
        CHECK(out.blobs.count == 2 && out.blobs.items[0].len == 5 &&
              memcmp(out.blobs.items[0].ptr, raw_non_utf8, 5) == 0 && out.blobs.items[1].len == 0,
              "list<bytes>");
        CHECK(out.items.count == 2 && out.items.items[1].qty == 20 && out.items.items[1].price == -0.5f,
              "list<Item>");
        CHECK(out.matrix.count == 2 && out.matrix.items[0].count == 3 && out.matrix.items[0].items[1] == -2 &&
              out.matrix.items[1].count == 2 && out.matrix.items[1].items[1] == -50, "list<list<i32>>");
        CHECK(out.counters.count == 3 && out.counters.entries[1].val == -200 &&
              out.counters.entries[2].val == 300, "dict<str,i64>");
        CHECK(out.labels.count == 2 && out.labels.entries[1].val.len == 9 &&
              memcmp(out.labels.entries[1].val.ptr, "us-west-2", 9) == 0, "dict<str,str>");
        CHECK(out.by_key.count == 2 && out.by_key.entries[1].val.qty == 20, "dict<str,Item>");
        CHECK(out.prompt.count == 1 && out.prompt.items[0].dtype == 14 &&
              out.prompt.items[0].name_len == 9 &&
              memcmp(out.prompt.items[0].name, "input_ids", 9) == 0 &&
              memcmp(out.prompt.items[0].data, tok_ids, sizeof(tok_ids)) == 0,
              "embedded KLNT v2 prompt tensor");

        /* Re-encode decoded struct and assert byte-exact round-trip */
        uint8_t wire2[65536];
        kiln_result_t res2;
        CHECK(kiln_asm_encode_gen_complex_record_framed(&out, wire2, sizeof(wire2), NULL, &res2) == KILN_OK,
              "re-encode complex_record");
        CHECK(res2.bytes == wlen && memcmp(wire, wire2, wlen) == 0, "complex_record byte-exact round-trip");
    }

    /* Negative tests on ComplexRecord */
    /* 1. Unsorted dict on encode -> TYPE */
    gen_complex_record_dict_i64_entry_t bad_counters[2] = { counters_arr[1], counters_arr[0] };
    gen_complex_record_t bad_in = in;
    bad_in.counters.entries = bad_counters;
    bad_in.counters.count = 2;
    CHECK(kiln_asm_encode_gen_complex_record(&bad_in, wire, sizeof(wire), NULL, &res) == KILN_ERR_TYPE,
          "unsorted dict encode -> TYPE");

    /* 2. Corrupt bool byte in 65-element list<bool> -> TYPE (AVX2 path!) */
    CHECK(kiln_asm_encode_gen_complex_record(&in, wire, sizeof(wire), NULL, &res) == KILN_OK,
          "encode unframed complex_record");
    size_t ulen = (size_t)res.bytes;
    /* Find the 65-byte flags pattern: u32(65) followed by 0,1,0,1,... */
    size_t flags_pos = 0;
    for (size_t p = 0; p + 69 <= ulen; p++) {
        uint32_t cnt;
        memcpy(&cnt, wire + p, 4);
        if (cnt == 65 && wire[p + 4] == 0 && wire[p + 5] == 1 && wire[p + 6] == 0 && wire[p + 7] == 1) {
            flags_pos = p + 4;
            break;
        }
    }
    CHECK(flags_pos > 0, "locate list<bool> payload");
    if (flags_pos > 0) {
        wire[flags_pos + 40] = 2; /* inside second AVX2 32B chunk! */
        gen_complex_record_t out;
        kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
        CHECK(kiln_asm_decode_gen_complex_record(wire, ulen, &out, &arena, NULL, &res) == KILN_ERR_TYPE,
              "corrupt AVX2 list<bool> -> TYPE");
        wire[flags_pos + 40] = 0;
    }

    /* 3. Trailing byte -> TRAILING */
    wire[ulen] = 0x00;
    gen_complex_record_t out;
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_gen_complex_record(wire, ulen + 1, &out, &arena, NULL, &res) == KILN_ERR_TRAILING,
          "complex_record trailing -> TRAILING");

    /* 4. Depth limit -> DEPTH */
    kiln_read_opts_t shallow = {0, 0, 2, 0};
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_gen_complex_record(wire, ulen, &out, &arena, &shallow, &res) == KILN_ERR_DEPTH,
          "complex_record max_depth=2 -> DEPTH");

    /* 5. Corrupt opt tag (0x02) -> TYPE */
    uint8_t opt_bad_wire[65536];
    /* First 13 scalars = 1+1+1+2+2+4+4+4+8+8+8+8+8 = 59 B, then text (4+len), raw (4+5), empty (0), then opt_i32 tag! */
    size_t opt_tag_off = 59 + (4 + strlen(long_utf8)) + (4 + 5);
    CHECK(wire[opt_tag_off] == 1, "verify opt_i32 tag offset");
    memcpy(opt_bad_wire, wire, ulen);
    opt_bad_wire[opt_tag_off] = 2;
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_gen_complex_record(opt_bad_wire, ulen, &out, &arena, NULL, &res) == KILN_ERR_TYPE,
          "bad opt tag 0x02 -> TYPE");
}

int main(void) {
    test_golden_parity();
    test_complex_record();

    if (g_failures == 0) {
        printf("ALL gld-kilngen-asm codegen tests PASSED (golden parity + ComplexRecord + errors).\n");
        return 0;
    }
    fprintf(stderr, "%d codegen test failures.\n", g_failures);
    return 1;
}
