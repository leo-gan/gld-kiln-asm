#include "kiln_asm.h"

#include <ctype.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Compile-time ABI layout verification against arch/x86_64/defs.inc */
_Static_assert(offsetof(kiln_arena_t, base) == 0, "arena.base");
_Static_assert(offsetof(kiln_arena_t, cur)  == 8, "arena.cur");
_Static_assert(offsetof(kiln_arena_t, end)  == 16, "arena.end");

_Static_assert(offsetof(kiln_read_opts_t, max_count) == 0, "opts.max_count");
_Static_assert(offsetof(kiln_read_opts_t, max_bytes) == 8, "opts.max_bytes");
_Static_assert(offsetof(kiln_read_opts_t, max_depth) == 16, "opts.max_depth");
_Static_assert(offsetof(kiln_read_opts_t, flags)     == 20, "opts.flags");

_Static_assert(offsetof(kiln_result_t, bytes) == 0, "res.bytes");
_Static_assert(offsetof(kiln_result_t, hash)  == 8, "res.hash");

_Static_assert(offsetof(kiln_str_t, ptr) == 0, "str.ptr");
_Static_assert(offsetof(kiln_str_t, len) == 8, "str.len");
_Static_assert(sizeof(kiln_str_t) == 16, "sizeof(str)");

_Static_assert(offsetof(kiln_point_t, x) == 0, "point.x");
_Static_assert(offsetof(kiln_point_t, y) == 4, "point.y");
_Static_assert(sizeof(kiln_point_t) == 8, "sizeof(point)");

_Static_assert(offsetof(kiln_message_t, f_int64)    == 0,  "msg.f_int64");
_Static_assert(offsetof(kiln_message_t, f_float64)  == 8,  "msg.f_float64");
_Static_assert(offsetof(kiln_message_t, f_string)   == 16, "msg.f_string");
_Static_assert(offsetof(kiln_message_t, f_string_2) == 32, "msg.f_string_2");
_Static_assert(offsetof(kiln_message_t, f_int32)    == 48, "msg.f_int32");
_Static_assert(offsetof(kiln_message_t, f_int32_2)  == 52, "msg.f_int32_2");
_Static_assert(offsetof(kiln_message_t, f_bool)     == 56, "msg.f_bool");
_Static_assert(offsetof(kiln_message_t, f_bool_2)   == 57, "msg.f_bool_2");
_Static_assert(sizeof(kiln_message_t) == 64, "sizeof(msg)");

_Static_assert(offsetof(kiln_dict_entry_t, key) == 0,  "dict.key");
_Static_assert(offsetof(kiln_dict_entry_t, val) == 16, "dict.val");
_Static_assert(sizeof(kiln_dict_entry_t) == 24, "sizeof(dict_entry)");

_Static_assert(offsetof(kiln_tensor_t, name)         == 0,   "tens.name");
_Static_assert(offsetof(kiln_tensor_t, name_len)     == 8,   "tens.name_len");
_Static_assert(offsetof(kiln_tensor_t, layout)       == 16,  "tens.layout");
_Static_assert(offsetof(kiln_tensor_t, layout_len)   == 24,  "tens.layout_len");
_Static_assert(offsetof(kiln_tensor_t, data)         == 32,  "tens.data");
_Static_assert(offsetof(kiln_tensor_t, data_len)     == 40,  "tens.data_len");
_Static_assert(offsetof(kiln_tensor_t, shape)        == 48,  "tens.shape");
_Static_assert(offsetof(kiln_tensor_t, dtype)        == 112, "tens.dtype");
_Static_assert(offsetof(kiln_tensor_t, rank)         == 114, "tens.rank");
_Static_assert(offsetof(kiln_tensor_t, quant_scheme) == 116, "tens.quant_scheme");
_Static_assert(offsetof(kiln_tensor_t, quant_axis)   == 118, "tens.quant_axis");
_Static_assert(offsetof(kiln_tensor_t, group_size)   == 120, "tens.group_size");
_Static_assert(offsetof(kiln_tensor_t, scale_index)  == 124, "tens.scale_index");
_Static_assert(offsetof(kiln_tensor_t, outer_index)  == 128, "tens.outer_index");
_Static_assert(offsetof(kiln_tensor_t, block_size)   == 132, "tens.block_size");
_Static_assert(offsetof(kiln_tensor_t, elem_count)   == 136, "tens.elem_count");
_Static_assert(sizeof(kiln_tensor_t) == 144, "sizeof(tensor)");

_Static_assert(offsetof(kiln_tensor_dir_t, items)        == 0,  "tdir.items");
_Static_assert(offsetof(kiln_tensor_dir_t, count)        == 8,  "tdir.count");
_Static_assert(offsetof(kiln_tensor_dir_t, block_length) == 16, "tdir.block_length");
_Static_assert(offsetof(kiln_tensor_dir_t, flags)        == 24, "tdir.flags");
_Static_assert(offsetof(kiln_tensor_dir_t, version)      == 28, "tdir.version");
_Static_assert(sizeof(kiln_tensor_dir_t) == 32, "sizeof(tensor_dir)");

_Static_assert(offsetof(kiln_id_tensors_t, id)    == 0,  "idten.id");
_Static_assert(offsetof(kiln_id_tensors_t, batch) == 8,  "idten.batch");
_Static_assert(sizeof(kiln_id_tensors_t) == 40, "sizeof(id_tensors)");

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__, (msg)); \
        g_failures++; \
    } \
} while (0)

static uint8_t *read_all(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    buf[n] = 0;
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

/* ========================================================================== */
/* Minimal zero-dependency JSON parser for testdata/kiln-v2-cases.json        */
/* ========================================================================== */
typedef enum jkind_t { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } jkind_t;

typedef struct jval_t jval_t;
struct jval_t {
    jkind_t kind;
    int     b;
    char   *str;
    size_t  slen;
    char  **keys;
    jval_t *vals;
    size_t  n;
};

typedef struct jparser_t {
    const char *p;
    const char *end;
} jparser_t;

static void jskip(jparser_t *jp) {
    while (jp->p < jp->end && (*jp->p == ' ' || *jp->p == '\t' || *jp->p == '\n' || *jp->p == '\r')) {
        jp->p++;
    }
}

static void jfree(jval_t *v) {
    if (!v) return;
    free(v->str);
    for (size_t i = 0; i < v->n; i++) {
        if (v->keys) free(v->keys[i]);
        jfree(&v->vals[i]);
    }
    free(v->keys);
    free(v->vals);
}

static int jparse_str(jparser_t *jp, char **out, size_t *out_len) {
    if (jp->p >= jp->end || *jp->p != '"') return 0;
    jp->p++;
    size_t cap = 64, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return 0;
    while (jp->p < jp->end) {
        char c = *jp->p++;
        if (c == '"') {
            buf[len] = 0;
            *out = buf;
            if (out_len) *out_len = len;
            return 1;
        }
        if (c == '\\') {
            if (jp->p >= jp->end) { free(buf); return 0; }
            char e = *jp->p++;
            switch (e) {
            case '"': case '\\': case '/': c = e; break;
            case 'n': c = '\n'; break;
            case 'r': c = '\r'; break;
            case 't': c = '\t'; break;
            default: c = e; break;
            }
        }
        if (len + 2 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); return 0; }
            buf = nb;
        }
        buf[len++] = c;
    }
    free(buf);
    return 0;
}

static int jparse_val(jparser_t *jp, jval_t *out);

static int jparse_arr(jparser_t *jp, jval_t *out) {
    jp->p++; /* '[' */
    memset(out, 0, sizeof(*out));
    out->kind = J_ARR;
    jskip(jp);
    if (jp->p < jp->end && *jp->p == ']') { jp->p++; return 1; }
    size_t cap = 8;
    out->vals = (jval_t *)calloc(cap, sizeof(jval_t));
    if (!out->vals) return 0;
    for (;;) {
        if (out->n == cap) {
            cap *= 2;
            jval_t *nv = (jval_t *)realloc(out->vals, cap * sizeof(jval_t));
            if (!nv) return 0;
            out->vals = nv;
        }
        if (!jparse_val(jp, &out->vals[out->n])) return 0;
        out->n++;
        jskip(jp);
        if (jp->p < jp->end && *jp->p == ',') { jp->p++; continue; }
        if (jp->p < jp->end && *jp->p == ']') { jp->p++; return 1; }
        return 0;
    }
}

static int jparse_obj(jparser_t *jp, jval_t *out) {
    jp->p++; /* '{' */
    memset(out, 0, sizeof(*out));
    out->kind = J_OBJ;
    jskip(jp);
    if (jp->p < jp->end && *jp->p == '}') { jp->p++; return 1; }
    size_t cap = 8;
    out->keys = (char **)calloc(cap, sizeof(char *));
    out->vals = (jval_t *)calloc(cap, sizeof(jval_t));
    if (!out->keys || !out->vals) return 0;
    for (;;) {
        jskip(jp);
        if (out->n == cap) {
            cap *= 2;
            char **nk = (char **)realloc(out->keys, cap * sizeof(char *));
            jval_t *nv = (jval_t *)realloc(out->vals, cap * sizeof(jval_t));
            if (!nk || !nv) return 0;
            out->keys = nk;
            out->vals = nv;
        }
        if (!jparse_str(jp, &out->keys[out->n], NULL)) return 0;
        jskip(jp);
        if (jp->p >= jp->end || *jp->p != ':') return 0;
        jp->p++;
        if (!jparse_val(jp, &out->vals[out->n])) return 0;
        out->n++;
        jskip(jp);
        if (jp->p < jp->end && *jp->p == ',') { jp->p++; continue; }
        if (jp->p < jp->end && *jp->p == '}') { jp->p++; return 1; }
        return 0;
    }
}

static int jparse_val(jparser_t *jp, jval_t *out) {
    memset(out, 0, sizeof(*out));
    jskip(jp);
    if (jp->p >= jp->end) return 0;
    char c = *jp->p;
    if (c == '{') return jparse_obj(jp, out);
    if (c == '[') return jparse_arr(jp, out);
    if (c == '"') {
        out->kind = J_STR;
        return jparse_str(jp, &out->str, &out->slen);
    }
    if (jp->end - jp->p >= 4 && memcmp(jp->p, "null", 4) == 0) {
        jp->p += 4; out->kind = J_NULL; return 1;
    }
    if (jp->end - jp->p >= 4 && memcmp(jp->p, "true", 4) == 0) {
        jp->p += 4; out->kind = J_BOOL; out->b = 1; return 1;
    }
    if (jp->end - jp->p >= 5 && memcmp(jp->p, "false", 5) == 0) {
        jp->p += 5; out->kind = J_BOOL; out->b = 0; return 1;
    }
    if (c == '-' || isdigit((unsigned char)c)) {
        const char *start = jp->p;
        if (*jp->p == '-') jp->p++;
        while (jp->p < jp->end && (isdigit((unsigned char)*jp->p) || *jp->p == '.' ||
               *jp->p == 'e' || *jp->p == 'E' || *jp->p == '+' || *jp->p == '-')) {
            jp->p++;
        }
        size_t n = (size_t)(jp->p - start);
        out->kind = J_NUM;
        out->str = (char *)malloc(n + 1);
        if (!out->str) return 0;
        memcpy(out->str, start, n);
        out->str[n] = 0;
        out->slen = n;
        return 1;
    }
    return 0;
}

static const jval_t *jget(const jval_t *obj, const char *key) {
    if (!obj || obj->kind != J_OBJ) return NULL;
    for (size_t i = 0; i < obj->n; i++) {
        if (strcmp(obj->keys[i], key) == 0) return &obj->vals[i];
    }
    return NULL;
}

static int ju64(const jval_t *v, uint64_t *out) {
    if (!v || v->kind != J_NUM || v->str[0] == '-') return 0;
    char *end = NULL;
    errno = 0;
    unsigned long long x = strtoull(v->str, &end, 10);
    if (errno || !end || *end) return 0;
    *out = (uint64_t)x;
    return 1;
}

static int ji64(const jval_t *v, int64_t *out) {
    if (!v || v->kind != J_NUM) return 0;
    char *end = NULL;
    errno = 0;
    long long x = strtoll(v->str, &end, 10);
    if (errno || !end || *end) return 0;
    *out = (int64_t)x;
    return 1;
}

static int jf64(const jval_t *v, double *out) {
    if (!v || v->kind != J_NUM) return 0;
    char *end = NULL;
    errno = 0;
    double x = strtod(v->str, &end);
    if (errno || !end || *end) return 0;
    *out = x;
    return 1;
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static uint8_t *hex_decode(const char *hex, size_t *out_len) {
    size_t n = strlen(hex);
    if (n % 2 != 0) return NULL;
    uint8_t *buf = (uint8_t *)malloc(n / 2 + 1);
    if (!buf) return NULL;
    for (size_t i = 0; i < n; i += 2) {
        int hi = hex_nibble(hex[i]), lo = hex_nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) { free(buf); return NULL; }
        buf[i / 2] = (uint8_t)((hi << 4) | lo);
    }
    *out_len = n / 2;
    return buf;
}

static int hex_eq_bytes(const uint8_t *p, size_t n, const char *hex) {
    if (strlen(hex) != n * 2) return 0;
    for (size_t i = 0; i < n; i++) {
        int hi = hex_nibble(hex[i * 2]), lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0 || p[i] != (uint8_t)((hi << 4) | lo)) return 0;
    }
    return 1;
}

/* ========================================================================== */
/* Phase 1 tests: metadata, hashes, UTF-8, golden binaries, Frozen errors     */
/* ========================================================================== */
static uint64_t hash_tokens(const char *const *toks, size_t n) {
    uint64_t h = 0xCBF29CE484222325ULL;
    for (size_t i = 0; i < n; i++) {
        h = kiln_asm_fnv1a_mix_token(h, (const uint8_t *)toks[i], strlen(toks[i]));
    }
    return h;
}

static void test_metadata_and_hashes(void) {
    CHECK(strcmp(kiln_asm_version(), KILN_ASM_VERSION) == 0, "version string");
    CHECK(strcmp(kiln_asm_err_name(KILN_OK), "OK") == 0, "err OK");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_FRAME), "FRAME") == 0, "err FRAME");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_SCHEMA), "SCHEMA") == 0, "err SCHEMA");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_LIMIT), "LIMIT") == 0, "err LIMIT");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_EOF), "EOF") == 0, "err EOF");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_TYPE), "TYPE") == 0, "err TYPE");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_UTF8), "UTF8") == 0, "err UTF8");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_TRAILING), "TRAILING") == 0, "err TRAILING");
    CHECK(strcmp(kiln_asm_err_name(KILN_ERR_DEPTH), "DEPTH") == 0, "err DEPTH");

    CHECK(strcmp(kiln_asm_dtype_name(1), "f64") == 0, "dtype f64");
    CHECK(strcmp(kiln_asm_dtype_name(2), "f32") == 0, "dtype f32");
    CHECK(strcmp(kiln_asm_dtype_name(18), "e2m1") == 0, "dtype e2m1");
    CHECK(strcmp(kiln_asm_dtype_name(19), "e8m0") == 0, "dtype e8m0");
    CHECK(kiln_asm_dtype_name(0) == NULL && kiln_asm_dtype_name(20) == NULL, "dtype null");

    const char *pt_toks[] = {"struct{", "x", ":", "i32", ",", "y", ":", "i32", ",", "}"};
    CHECK(hash_tokens(pt_toks, 10) == KILN_HASH_POINT, "FNV-1a Point hash");

    const char *msg_toks[] = {
        "struct{",
        "f_bool", ":", "bool", ",",
        "f_int32", ":", "i32", ",",
        "f_int64", ":", "i64", ",",
        "f_float64", ":", "f64", ",",
        "f_string", ":", "str", ",",
        "f_bool_2", ":", "bool", ",",
        "f_int32_2", ":", "i32", ",",
        "f_string_2", ":", "str", ",",
        "}"
    };
    CHECK(hash_tokens(msg_toks, sizeof(msg_toks)/sizeof(msg_toks[0])) == KILN_HASH_MESSAGE,
          "FNV-1a Message hash");

    const char *ft_toks[] = {
        "struct{", "id", ":", "i64", ",", "batch", ":", "tensors", ",", "}"
    };
    CHECK(hash_tokens(ft_toks, 10) == KILN_HASH_ID_TENSORS, "FNV-1a id+tensors hash");
}

static void test_utf8(void) {
    CHECK(kiln_asm_utf8_ok((const uint8_t *)"", 0) == 1, "empty utf8");
    CHECK(kiln_asm_utf8_ok((const uint8_t *)"hello world", 11) == 1, "short ascii");

    uint8_t long_ascii[100];
    for (size_t i = 0; i < sizeof(long_ascii); i++) long_ascii[i] = (uint8_t)('a' + (i % 26));
    CHECK(kiln_asm_utf8_ok(long_ascii, sizeof(long_ascii)) == 1, "long AVX2 ascii");

    const uint8_t valid_mb[] = {
        'A', 0xC2, 0xA2, 0xE0, 0xA0, 0x80, 0xE2, 0x82, 0xAC,
        0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80,
        0xF0, 0x90, 0x80, 0x80, 0xF0, 0x9F, 0x98, 0x80, 0xF4, 0x8F, 0xBF, 0xBF
    };
    CHECK(kiln_asm_utf8_ok(valid_mb, sizeof(valid_mb)) == 1, "valid multi-byte UTF-8");

    long_ascii[40] = 0xFF;
    CHECK(kiln_asm_utf8_ok(long_ascii, sizeof(long_ascii)) == 0, "AVX2 tail invalid 0xFF");

    const uint8_t bad_cont[]       = {0x80};
    const uint8_t bad_overlong2[]  = {0xC0, 0xAF};
    const uint8_t bad_overlong2b[] = {0xC1, 0xBF};
    const uint8_t bad_overlong3[]  = {0xE0, 0x9F, 0xBF};
    const uint8_t bad_surr_lo[]    = {0xED, 0xA0, 0x80};
    const uint8_t bad_surr_hi[]    = {0xED, 0xBF, 0xBF};
    const uint8_t bad_overlong4[]  = {0xF0, 0x8F, 0xBF, 0xBF};
    const uint8_t bad_above_max[]  = {0xF4, 0x90, 0x80, 0x80};
    const uint8_t bad_f5[]         = {0xF5, 0x80, 0x80, 0x80};
    const uint8_t bad_trunc2[]     = {0xC2};
    const uint8_t bad_trunc3[]     = {0xE2, 0x82};
    const uint8_t bad_trunc4[]     = {0xF0, 0x9F, 0x98};

    CHECK(kiln_asm_utf8_ok(bad_cont, sizeof(bad_cont)) == 0, "stray cont");
    CHECK(kiln_asm_utf8_ok(bad_overlong2, sizeof(bad_overlong2)) == 0, "overlong C0");
    CHECK(kiln_asm_utf8_ok(bad_overlong2b, sizeof(bad_overlong2b)) == 0, "overlong C1");
    CHECK(kiln_asm_utf8_ok(bad_overlong3, sizeof(bad_overlong3)) == 0, "overlong E0");
    CHECK(kiln_asm_utf8_ok(bad_surr_lo, sizeof(bad_surr_lo)) == 0, "surrogate U+D800");
    CHECK(kiln_asm_utf8_ok(bad_surr_hi, sizeof(bad_surr_hi)) == 0, "surrogate U+DFFF");
    CHECK(kiln_asm_utf8_ok(bad_overlong4, sizeof(bad_overlong4)) == 0, "overlong F0");
    CHECK(kiln_asm_utf8_ok(bad_above_max, sizeof(bad_above_max)) == 0, "above U+10FFFF");
    CHECK(kiln_asm_utf8_ok(bad_f5, sizeof(bad_f5)) == 0, "lead byte F5");
    CHECK(kiln_asm_utf8_ok(bad_trunc2, sizeof(bad_trunc2)) == 0, "truncated 2-byte");
    CHECK(kiln_asm_utf8_ok(bad_trunc3, sizeof(bad_trunc3)) == 0, "truncated 3-byte");
    CHECK(kiln_asm_utf8_ok(bad_trunc4, sizeof(bad_trunc4)) == 0, "truncated 4-byte");
}

static void test_golden_files(void) {
    size_t glen = 0;
    uint8_t out_buf[128];
    uint8_t arena_mem[4096];
    kiln_arena_t arena;
    kiln_result_t res;

    uint8_t *g_point = read_all("testdata/golden/point.kiln", &glen);
    CHECK(g_point != NULL && glen == 8, "load point.kiln");
    if (g_point) {
        kiln_point_t pt = {0, 0};
        CHECK(kiln_asm_decode_point(g_point, glen, &pt, NULL, &res) == KILN_OK, "decode point.kiln");
        CHECK(res.bytes == 8 && pt.x == 9 && pt.y == -4, "point values");
        CHECK(kiln_asm_encode_point(&pt, out_buf, sizeof(out_buf), NULL, &res) == KILN_OK, "encode point");
        CHECK(res.bytes == 8 && memcmp(out_buf, g_point, 8) == 0, "point byte-exact match");
        free(g_point);
    }

    uint8_t *g_msg = read_all("testdata/golden/message.kiln", &glen);
    CHECK(g_msg != NULL && glen == 37, "load message.kiln");
    if (g_msg) {
        kiln_message_t m;
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_message(g_msg, glen, &m, NULL, NULL, &res) == KILN_OK, "decode msg view");
        CHECK(res.bytes == 37, "msg bytes");
        CHECK(m.f_bool == 1 && m.f_int32 == -2 && m.f_int64 == 99 && m.f_float64 == 1.5, "msg scalars 1");
        CHECK(m.f_string.len == 2 && memcmp(m.f_string.ptr, "hi", 2) == 0, "msg str1");
        CHECK(m.f_string.ptr == g_msg + 25, "view borrows wire buffer");
        CHECK(m.f_bool_2 == 0 && m.f_int32_2 == 7, "msg scalars 2");
        CHECK(m.f_string_2.len == 1 && memcmp(m.f_string_2.ptr, "z", 1) == 0, "msg str2");
        CHECK(kiln_asm_encode_message(&m, out_buf, sizeof(out_buf), NULL, &res) == KILN_OK, "encode msg");
        CHECK(res.bytes == 37 && memcmp(out_buf, g_msg, 37) == 0, "msg byte-exact match");

        kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
        kiln_read_opts_t opts = {0, 0, 0, KILN_OPT_OWNED};
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_message(g_msg, glen, &m, &arena, &opts, &res) == KILN_OK, "decode msg owned");
        CHECK(kiln_arena_used(&arena) == 3, "owned arena used == 3 bytes");
        CHECK(memcmp(m.f_string.ptr, "hi", 2) == 0 && memcmp(m.f_string_2.ptr, "z", 1) == 0, "owned strings");
        free(g_msg);
    }

    uint8_t *g_frame = read_all("testdata/golden/message.frame.kiln", &glen);
    CHECK(g_frame != NULL && glen == 53, "load message.frame.kiln");
    if (g_frame) {
        kiln_message_t m;
        memset(&m, 0, sizeof(m));
        CHECK(kiln_asm_decode_message_framed(g_frame, glen, &m, NULL, NULL, &res) == KILN_OK,
              "decode message.frame.kiln");
        CHECK(res.bytes == 53 && res.hash == KILN_HASH_MESSAGE, "framed hash & bytes");
        CHECK(kiln_asm_encode_message_framed(&m, out_buf, sizeof(out_buf), NULL, &res) == KILN_OK,
              "encode message framed");
        CHECK(res.bytes == 53 && memcmp(out_buf, g_frame, 53) == 0, "framed byte-exact match");
        free(g_frame);
    }
}

static void test_frozen_errors_and_containers(void) {
    uint8_t buf[8192];
    uint8_t arena_mem[16384];
    kiln_arena_t arena;
    kiln_result_t res;
    kiln_point_t pt = {1, 2};
    kiln_message_t m;

    uint8_t pt_extra[9] = {9, 0, 0, 0, 0xfc, 0xff, 0xff, 0xff, 0x00};
    CHECK(kiln_asm_decode_point(pt_extra, 9, &pt, NULL, &res) == KILN_ERR_TRAILING, "point TRAILING");
    CHECK(kiln_asm_decode_point(pt_extra, 7, &pt, NULL, &res) == KILN_ERR_EOF, "point EOF");

    kiln_message_t one = {
        .f_int64 = 1, .f_float64 = 2.0,
        .f_string = {(const uint8_t *)"a", 1},
        .f_string_2 = {(const uint8_t *)"b", 1},
        .f_int32 = 3, .f_int32_2 = 4, .f_bool = 1, .f_bool_2 = 0
    };
    CHECK(kiln_asm_encode_batch(&one, 1, buf, sizeof(buf), NULL, &res) == KILN_OK, "encode batch[1]");
    size_t blen = (size_t)res.bytes;
    kiln_read_opts_t depth1 = {0, 0, 1, 0};
    kiln_message_t *dec_items = NULL;
    size_t dec_cnt = 0;
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_batch(buf, blen, &dec_items, &dec_cnt, &arena, &depth1, &res) == KILN_ERR_DEPTH,
          "batch DEPTH error when max_depth=1");

    uint8_t frame_bad[53];
    CHECK(kiln_asm_encode_message_framed(&one, frame_bad, sizeof(frame_bad), NULL, &res) == KILN_OK, "enc framed");
    size_t flen = (size_t)res.bytes;
    CHECK(kiln_asm_decode_message_framed(frame_bad, 3, &m, NULL, NULL, &res) == KILN_ERR_EOF, "frame <4 EOF");
    frame_bad[0] = 'X';
    CHECK(kiln_asm_decode_message_framed(frame_bad, flen, &m, NULL, NULL, &res) == KILN_ERR_FRAME, "bad magic FRAME");
    frame_bad[0] = 'K';
    CHECK(kiln_asm_decode_message_framed(frame_bad, 10, &m, NULL, NULL, &res) == KILN_ERR_EOF, "frame <16 EOF");
    frame_bad[4] = 1;
    CHECK(kiln_asm_decode_message_framed(frame_bad, flen, &m, NULL, NULL, &res) == KILN_ERR_FRAME, "bad profile FRAME");
    frame_bad[4] = 0;
    frame_bad[8] ^= 1;
    CHECK(kiln_asm_decode_message_framed(frame_bad, flen, &m, NULL, NULL, &res) == KILN_ERR_SCHEMA, "bad hash SCHEMA");

    CHECK(kiln_asm_encode_message(&one, buf, sizeof(buf), NULL, &res) == KILN_OK, "enc msg");
    size_t mlen = (size_t)res.bytes;
    buf[0] = 2;
    CHECK(kiln_asm_decode_message(buf, mlen, &m, NULL, NULL, &res) == KILN_ERR_TYPE, "bad bool TYPE");
    buf[0] = 1;
    buf[25] = 0xFF;
    CHECK(kiln_asm_decode_message(buf, mlen, &m, NULL, NULL, &res) == KILN_ERR_UTF8, "bad str UTF8 view");
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    kiln_read_opts_t owned = {0, 0, 0, KILN_OPT_OWNED};
    CHECK(kiln_asm_decode_message(buf, mlen, &m, &arena, &owned, &res) == KILN_ERR_UTF8, "bad str UTF8 owned");
    CHECK(kiln_arena_used(&arena) == 0, "owned UTF8 reject leaves arena untouched");
    kiln_read_opts_t trusted = {0, 0, 0, KILN_OPT_TRUSTED};
    CHECK(kiln_asm_decode_message(buf, mlen, &m, NULL, &trusted, &res) == KILN_OK, "trusted skips UTF8");

    CHECK(kiln_asm_encode_point(&pt, buf, 7, NULL, &res) == KILN_ERR_LIMIT, "encode point capacity LIMIT");

    CHECK(kiln_asm_encode_opt_i32(0, 0, buf, sizeof(buf), &res) == KILN_OK && res.bytes == 1, "enc opt none");
    int pres = -1; int32_t ov = -1;
    CHECK(kiln_asm_decode_opt_i32(buf, 1, &pres, &ov, NULL, &res) == KILN_OK && pres == 0, "dec opt none");
    CHECK(kiln_asm_encode_opt_i32(1, -42, buf, sizeof(buf), &res) == KILN_OK && res.bytes == 5, "enc opt some");
    CHECK(kiln_asm_decode_opt_i32(buf, 5, &pres, &ov, NULL, &res) == KILN_OK && pres == 1 && ov == -42, "dec opt some");
    buf[0] = 2;
    CHECK(kiln_asm_decode_opt_i32(buf, 5, &pres, &ov, NULL, &res) == KILN_ERR_TYPE, "opt bad tag TYPE");

    kiln_dict_entry_t d_ok[2] = {
        {{(const uint8_t *)"alpha", 5}, 10},
        {{(const uint8_t *)"beta",  4}, 20},
    };
    CHECK(kiln_asm_encode_dict_i64(d_ok, 2, buf, sizeof(buf), NULL, &res) == KILN_OK, "enc sorted dict");
    size_t dlen = (size_t)res.bytes;
    kiln_dict_entry_t *d_out = NULL;
    size_t d_cnt = 0;
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_dict_i64(buf, dlen, &d_out, &d_cnt, &arena, &owned, &res) == KILN_OK, "dec sorted dict");
    CHECK(d_cnt == 2 && d_out[0].val == 10 && d_out[1].val == 20, "dict values");

    kiln_dict_entry_t d_unsorted[2] = { d_ok[1], d_ok[0] };
    CHECK(kiln_asm_encode_dict_i64(d_unsorted, 2, buf, sizeof(buf), NULL, &res) == KILN_ERR_TYPE,
          "enc unsorted dict TYPE");

    uint8_t bad_dict[] = {
        2, 0, 0, 0,
        1, 0, 0, 0, 'b', 1, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 'a', 2, 0, 0, 0, 0, 0, 0, 0
    };
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_dict_i64(bad_dict, sizeof(bad_dict), &d_out, &d_cnt, &arena, NULL, &res) == KILN_ERR_TYPE,
          "dec unsorted dict TYPE");
    bad_dict[21] = 'b';
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_dict_i64(bad_dict, sizeof(bad_dict), &d_out, &d_cnt, &arena, NULL, &res) == KILN_ERR_TYPE,
          "dec duplicate dict TYPE");

    kiln_message_t batch[100];
    for (int i = 0; i < 100; i++) {
        batch[i].f_bool = (uint8_t)(i & 1);
        batch[i].f_int32 = i - 50;
        batch[i].f_int64 = (int64_t)i * 1000;
        batch[i].f_float64 = 1.5;
        batch[i].f_string.ptr = (const uint8_t *)"hello";
        batch[i].f_string.len = 5;
        batch[i].f_bool_2 = 0;
        batch[i].f_int32_2 = 7;
        batch[i].f_string_2.ptr = (const uint8_t *)"world";
        batch[i].f_string_2.len = 5;
    }
    CHECK(kiln_asm_encode_batch(batch, 100, buf, sizeof(buf), NULL, &res) == KILN_OK, "enc batch[100]");
    CHECK(res.bytes == 4404, "batch[100] wire size == 4404");
    kiln_arena_init(&arena, arena_mem, sizeof(arena_mem));
    CHECK(kiln_asm_decode_batch(buf, 4404, &dec_items, &dec_cnt, &arena, &owned, &res) == KILN_OK,
          "dec batch[100] owned");
    CHECK(dec_cnt == 100 && dec_items[99].f_int64 == 99000 &&
          memcmp(dec_items[99].f_string_2.ptr, "world", 5) == 0, "batch[100] values");
}

/* ========================================================================== */
/* Phase 2 tests: All 46/46 normative vectors in testdata/kiln-v2-cases.json  */
/* ========================================================================== */
static int is_hostile_case(const char *id) {
    return strcmp(id, "kiln-v2-directory-eof") == 0 ||
           strcmp(id, "kiln-v2-count-cap") == 0 ||
           strcmp(id, "kiln-v2-payload-overflow") == 0 ||
           strcmp(id, "kiln-list-struct-hostile") == 0 ||
           strcmp(id, "kiln-list-struct-short") == 0 ||
           strcmp(id, "kiln-list-str-short") == 0 ||
           strcmp(id, "kiln-pod-list-short") == 0;
}

static const char *match_tensor_dir(const kiln_tensor_dir_t *dir, const jval_t *j) {
    uint64_t num = 0;
    const jval_t *version = jget(j, "version");
    const jval_t *flags   = jget(j, "flags");
    const jval_t *tensors = jget(j, "tensors");
    const jval_t *blen    = jget(j, "block_length");

    if (!version || !ju64(version, &num) || num != dir->version) return "version";
    if (!blen || !ju64(blen, &num) || num != dir->block_length) return "block_length";
    if (!flags || flags->kind != J_ARR) return "flags";
    if (dir->flags & 1U) {
        if (flags->n != 2 || strcmp(flags->vals[0].str, "names") != 0 ||
            strcmp(flags->vals[1].str, "le") != 0) return "flags names";
    } else {
        if (flags->n != 1 || strcmp(flags->vals[0].str, "le") != 0) return "flags le";
    }
    if (!tensors || tensors->kind != J_ARR || tensors->n != dir->count) return "tensor count";

    for (size_t i = 0; i < dir->count; i++) {
        const kiln_tensor_t *t = &dir->items[i];
        const jval_t *item = &tensors->vals[i];
        const jval_t *name  = jget(item, "name");
        const jval_t *dtype = jget(item, "dtype");
        const jval_t *shape = jget(item, "shape");
        const jval_t *quant = jget(item, "quant_scheme");
        const jval_t *data  = jget(item, "data_hex");
        if (!name || !dtype || !shape || !quant || !data) return "missing field";

        if (t->name_len == 0) {
            if (name->kind != J_NULL) return "expected null name";
        } else {
            if (name->kind != J_STR || name->slen != t->name_len ||
                memcmp(name->str, t->name, t->name_len) != 0) return "name mismatch";
        }

        const char *dname = kiln_asm_dtype_name(t->dtype);
        if (dtype->kind == J_STR) {
            if (!dname || strcmp(dtype->str, dname) != 0) return "dtype name";
        } else if (!ju64(dtype, &num) || num != t->dtype) {
            return "dtype code";
        }

        if (shape->kind != J_ARR || shape->n != t->rank) return "rank/shape";
        for (size_t d = 0; d < t->rank; d++) {
            if (!ju64(&shape->vals[d], &num) || num != t->shape[d]) return "shape dim";
        }
        if (!ju64(quant, &num) || num != t->quant_scheme) return "quant_scheme";
        if (data->kind != J_STR || !hex_eq_bytes(t->data, t->data_len, data->str)) return "data_hex";
    }
    return NULL;
}

static void test_v2_cases_46(void) {
    size_t jlen = 0;
    uint8_t *jraw = read_all("testdata/kiln-v2-cases.json", &jlen);
    CHECK(jraw != NULL, "read testdata/kiln-v2-cases.json");
    if (!jraw) return;

    jparser_t jp = {(const char *)jraw, (const char *)jraw + jlen};
    jval_t root;
    if (!jparse_val(&jp, &root)) {
        CHECK(0, "parse kiln-v2-cases.json");
        free(jraw);
        return;
    }

    const jval_t *cases = jget(&root, "cases");
    CHECK(cases != NULL && cases->kind == J_ARR && cases->n == 46, "expected exactly 46 cases");
    if (!cases || cases->kind != J_ARR) { jfree(&root); free(jraw); return; }

    uint8_t *arena_mem = (uint8_t *)malloc(262144);
    uint8_t *enc_buf   = (uint8_t *)malloc(262144);
    kiln_read_opts_t opts = {16777216ULL, 16777216ULL, 64U, 0U};
    kiln_read_opts_t opts_owned = {16777216ULL, 16777216ULL, 64U, KILN_OPT_OWNED};

    int passed = 0;
    for (size_t i = 0; i < cases->n; i++) {
        const jval_t *cs = &cases->vals[i];
        const char *id     = jget(cs, "id")->str;
        const char *expect = jget(cs, "expect")->str;
        const char *input  = jget(cs, "input")->str;
        const jval_t *schema  = jget(cs, "schema");
        const jval_t *decoded = jget(cs, "decoded");
        const jval_t *want_err = jget(cs, "error");

        size_t blen = 0;
        uint8_t *buf = hex_decode(input, &blen);
        if (!buf) {
            fprintf(stderr, "FAIL %s: invalid hex\n", id);
            g_failures++;
            continue;
        }

        kiln_arena_t arena;
        kiln_arena_init(&arena, arena_mem, 262144);
        kiln_result_t res = {0, 0};
        kiln_err_t err = KILN_OK;
        int case_ok = 1;

        if (schema->kind == J_STR && strcmp(schema->str, "tensor-v2") == 0) {
            kiln_tensor_dir_t dir;
            memset(&dir, 0, sizeof(dir));
            err = kiln_asm_decode_tensors(buf, blen, &dir, &arena, &opts, &res);

            if (is_hostile_case(id) && kiln_arena_used(&arena) != 0) {
                fprintf(stderr, "FAIL %s: allocated %zu bytes on hostile reject\n",
                        id, kiln_arena_used(&arena));
                case_ok = 0;
            }
            if (strcmp(expect, "reject") == 0) {
                if (err == KILN_OK || strcmp(kiln_asm_err_name(err), want_err->str) != 0) {
                    fprintf(stderr, "FAIL %s: got %s, want %s\n",
                            id, kiln_asm_err_name(err), want_err->str);
                    case_ok = 0;
                }
            } else {
                if (err != KILN_OK) {
                    fprintf(stderr, "FAIL %s: decode error %s (offset %llu)\n",
                            id, kiln_asm_err_name(err), (unsigned long long)res.bytes);
                    case_ok = 0;
                } else {
                    const char *why = match_tensor_dir(&dir, decoded);
                    if (why) {
                        fprintf(stderr, "FAIL %s: decoded mismatch: %s\n", id, why);
                        case_ok = 0;
                    }
                    /* Verify canonical byte-exact re-encode */
                    kiln_result_t eres = {0, 0};
                    kiln_err_t eerr = kiln_asm_encode_tensors(&dir, enc_buf, 262144, &opts, &eres);
                    if (eerr != KILN_OK || eres.bytes != blen || memcmp(enc_buf, buf, blen) != 0) {
                        fprintf(stderr, "FAIL %s: re-encode mismatch (err=%s len=%llu vs %zu)\n",
                                id, kiln_asm_err_name(eerr), (unsigned long long)eres.bytes, blen);
                        case_ok = 0;
                    }
                    /* Also verify OWNED decode mode */
                    kiln_arena_init(&arena, arena_mem, 262144);
                    kiln_tensor_dir_t odir;
                    memset(&odir, 0, sizeof(odir));
                    if (kiln_asm_decode_tensors(buf, blen, &odir, &arena, &opts_owned, &res) != KILN_OK ||
                        match_tensor_dir(&odir, decoded) != NULL) {
                        fprintf(stderr, "FAIL %s: owned decode mismatch\n", id);
                        case_ok = 0;
                    }
                }
            }
        } else if (schema->kind == J_STR && strcmp(schema->str, "frame") == 0) {
            kiln_id_tensors_t st;
            memset(&st, 0, sizeof(st));
            err = kiln_asm_decode_id_tensors_framed(buf, blen, &st, &arena, &opts, &res);
            if (err != KILN_OK) {
                fprintf(stderr, "FAIL %s: decode framed error %s\n", id, kiln_asm_err_name(err));
                case_ok = 0;
            } else {
                uint64_t whash = 0;
                int64_t wid = 0;
                if (!ju64(jget(decoded, "hash"), &whash) || res.hash != whash ||
                    !ji64(jget(decoded, "id"), &wid) || st.id != wid) {
                    fprintf(stderr, "FAIL %s: hash/id mismatch\n", id);
                    case_ok = 0;
                }
                const char *why = match_tensor_dir(&st.batch, jget(decoded, "batch"));
                if (why) { fprintf(stderr, "FAIL %s: batch %s\n", id, why); case_ok = 0; }
                kiln_result_t eres = {0, 0};
                if (kiln_asm_encode_id_tensors_framed(&st, enc_buf, 262144, &opts, &eres) != KILN_OK ||
                    eres.bytes != blen || memcmp(enc_buf, buf, blen) != 0) {
                    fprintf(stderr, "FAIL %s: framed re-encode mismatch\n", id);
                    case_ok = 0;
                }
            }
        } else if (schema->kind == J_OBJ && strcmp(jget(schema, "type")->str, "struct") == 0) {
            kiln_id_tensors_t st;
            memset(&st, 0, sizeof(st));
            err = kiln_asm_decode_id_tensors(buf, blen, &st, &arena, &opts, &res);
            if (err != KILN_OK) {
                fprintf(stderr, "FAIL %s: decode struct error %s\n", id, kiln_asm_err_name(err));
                case_ok = 0;
            } else {
                int64_t wid = 0;
                if (!ji64(jget(decoded, "id"), &wid) || st.id != wid) {
                    fprintf(stderr, "FAIL %s: id mismatch\n", id);
                    case_ok = 0;
                }
                const char *why = match_tensor_dir(&st.batch, jget(decoded, "batch"));
                if (why) { fprintf(stderr, "FAIL %s: batch %s\n", id, why); case_ok = 0; }
                kiln_result_t eres = {0, 0};
                if (kiln_asm_encode_id_tensors(&st, enc_buf, 262144, &opts, &eres) != KILN_OK ||
                    eres.bytes != blen || memcmp(enc_buf, buf, blen) != 0) {
                    fprintf(stderr, "FAIL %s: struct re-encode mismatch\n", id);
                    case_ok = 0;
                }
            }
        } else if (schema->kind == J_OBJ && strcmp(jget(schema, "type")->str, "list") == 0) {
            const char *elem = jget(schema, "element")->str;
            size_t cnt = 0;
            if (strcmp(elem, "f32") == 0) {
                const uint8_t *raw = NULL;
                err = kiln_asm_decode_list_f32(buf, blen, &raw, &cnt, &arena, &opts_owned, &res);
                if (is_hostile_case(id) && kiln_arena_used(&arena) != 0) {
                    fprintf(stderr, "FAIL %s: hostile alloc %zu\n", id, kiln_arena_used(&arena));
                    case_ok = 0;
                }
                if (strcmp(expect, "reject") == 0) {
                    if (strcmp(kiln_asm_err_name(err), want_err->str) != 0) {
                        fprintf(stderr, "FAIL %s: got %s want %s\n", id, kiln_asm_err_name(err), want_err->str);
                        case_ok = 0;
                    }
                } else {
                    if (err != KILN_OK || cnt != decoded->n) {
                        fprintf(stderr, "FAIL %s: list<f32> decode\n", id);
                        case_ok = 0;
                    } else {
                        for (size_t k = 0; k < cnt; k++) {
                            float f = 0.0f;
                            double want = 0.0;
                            memcpy(&f, raw + k * 4, 4);
                            if (!jf64(&decoded->vals[k], &want) || (double)f != want) {
                                fprintf(stderr, "FAIL %s: list<f32>[%zu]\n", id, k);
                                case_ok = 0;
                            }
                        }
                        kiln_result_t eres = {0, 0};
                        if (kiln_asm_encode_list_f32((const uint32_t *)raw, cnt, enc_buf, 262144, &opts, &eres) != KILN_OK ||
                            eres.bytes != blen || memcmp(enc_buf, buf, blen) != 0) {
                            fprintf(stderr, "FAIL %s: list<f32> re-encode\n", id);
                            case_ok = 0;
                        }
                    }
                }
            } else if (strcmp(elem, "str") == 0) {
                kiln_str_t *items = NULL;
                err = kiln_asm_decode_list_str(buf, blen, &items, &cnt, &arena, &opts_owned, &res);
                if (is_hostile_case(id) && kiln_arena_used(&arena) != 0) {
                    fprintf(stderr, "FAIL %s: hostile alloc %zu\n", id, kiln_arena_used(&arena));
                    case_ok = 0;
                }
                if (strcmp(kiln_asm_err_name(err), want_err->str) != 0) {
                    fprintf(stderr, "FAIL %s: got %s want %s\n", id, kiln_asm_err_name(err), want_err->str);
                    case_ok = 0;
                }
            } else if (strcmp(elem, "struct{a:i64}") == 0) {
                const uint8_t *raw = NULL;
                err = kiln_asm_decode_list_i64_struct(buf, blen, &raw, &cnt, &arena, &opts_owned, &res);
                if (is_hostile_case(id) && kiln_arena_used(&arena) != 0) {
                    fprintf(stderr, "FAIL %s: hostile alloc %zu\n", id, kiln_arena_used(&arena));
                    case_ok = 0;
                }
                if (strcmp(kiln_asm_err_name(err), want_err->str) != 0) {
                    fprintf(stderr, "FAIL %s: got %s want %s\n", id, kiln_asm_err_name(err), want_err->str);
                    case_ok = 0;
                }
            } else {
                fprintf(stderr, "FAIL %s: unknown list element %s\n", id, elem);
                case_ok = 0;
            }
        } else {
            fprintf(stderr, "FAIL %s: unhandled schema\n", id);
            case_ok = 0;
        }

        if (case_ok) passed++;
        else g_failures++;
        free(buf);
    }

    free(enc_buf);
    free(arena_mem);
    jfree(&root);
    free(jraw);
    printf("v2 conformance suite: %d/46 cases passed\n", passed);
}

static void test_tensor_edge_cases(void) {
    uint8_t *wire  = (uint8_t *)malloc(131072);
    uint8_t *arena_mem = (uint8_t *)malloc(131072);
    kiln_arena_t arena;
    kiln_result_t res;

    /* 1. 65-byte AVX2 bool tensor (valid, then corrupt byte 35 -> TYPE) */
    uint8_t bdata[65];
    for (int i = 0; i < 65; i++) bdata[i] = (uint8_t)(i & 1);
    kiln_tensor_t bt;
    kiln_tensor_init(&bt);
    bt.dtype = 7; bt.rank = 1; bt.shape[0] = 65; bt.data = bdata; bt.data_len = 65;
    kiln_tensor_dir_t dir = { &bt, 1, 0, 0, 2 };
    CHECK(kiln_asm_encode_tensors(&dir, wire, 131072, NULL, &res) == KILN_OK && res.bytes == 64 + 128 + 65,
          "encode 65B bool tensor");
    kiln_tensor_dir_t out;
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, (size_t)res.bytes, &out, &arena, NULL, &res) == KILN_OK,
          "decode 65B AVX2 bool tensor");
    wire[64 + 128 + 35] = 2; /* corrupt byte inside 2nd AVX2 vector */
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, 64 + 128 + 65, &out, &arena, NULL, &res) == KILN_ERR_TYPE,
          "decode 65B AVX2 bool bad byte -> TYPE");

    /* 2. Descriptor reserved0 and reserved1 nonzero -> FRAME */
    wire[64 + 128 + 35] = 1;
    wire[64 + 3] = 1;
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, 64 + 128 + 65, &out, &arena, NULL, &res) == KILN_ERR_FRAME,
          "descriptor reserved0 -> FRAME");
    wire[64 + 3] = 0;
    wire[64 + 120] = 1;
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, 64 + 128 + 65, &out, &arena, NULL, &res) == KILN_ERR_FRAME,
          "descriptor reserved1 -> FRAME");

    /* 3. Nonzero byte in inter-payload alignment gap -> TYPE */
    uint8_t pair_a[1] = {0x38}, pair_b[1] = {0x3C};
    kiln_tensor_t pair[2];
    kiln_tensor_init(&pair[0]); kiln_tensor_init(&pair[1]);
    pair[0].dtype = 5; pair[0].rank = 1; pair[0].shape[0] = 1; pair[0].data = pair_a; pair[0].data_len = 1;
    pair[1].dtype = 6; pair[1].rank = 1; pair[1].shape[0] = 1; pair[1].data = pair_b; pair[1].data_len = 1;
    kiln_tensor_dir_t pdir = { pair, 2, 0, 0, 2 };
    CHECK(kiln_asm_encode_tensors(&pdir, wire, 131072, NULL, &res) == KILN_OK && res.bytes == 385,
          "encode f8 pair");
    wire[64 + 256 + 17] = 0xAA; /* corrupt zero gap between payload 0 and payload 1 */
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, 385, &out, &arena, NULL, &res) == KILN_ERR_TYPE,
          "inter-payload nonzero gap -> TYPE");

    /* 4. 10k f64 benchmark workload exact size (80,192 B) round-trip */
    double *f64s = (double *)malloc(10000 * sizeof(double));
    for (int i = 0; i < 10000; i++) f64s[i] = (double)i * 0.25;
    kiln_tensor_t ft;
    kiln_tensor_init(&ft);
    ft.dtype = 1; ft.rank = 1; ft.shape[0] = 10000;
    ft.data = (const uint8_t *)f64s; ft.data_len = 80000;
    kiln_tensor_dir_t fdir = { &ft, 1, 0, 0, 2 };
    CHECK(kiln_asm_encode_tensors(&fdir, wire, 131072, NULL, &res) == KILN_OK && res.bytes == 80192,
          "encode 10k f64 KLNT == 80,192 B");
    kiln_arena_init(&arena, arena_mem, 131072);
    CHECK(kiln_asm_decode_tensors(wire, 80192, &out, &arena, NULL, &res) == KILN_OK &&
          out.count == 1 && out.items[0].elem_count == 10000 &&
          memcmp(out.items[0].data, f64s, 80000) == 0,
          "decode 10k f64 KLNT bit-exact");

    /* 5. Encoder rejects rank > 8 with TYPE */
    bt.rank = 9;
    CHECK(kiln_asm_encode_tensors(&dir, wire, 131072, NULL, &res) == KILN_ERR_TYPE,
          "encode rank>8 -> TYPE");

    free(f64s);
    free(arena_mem);
    free(wire);
}

int main(void) {
    test_metadata_and_hashes();
    test_utf8();
    test_golden_files();
    test_frozen_errors_and_containers();
    test_v2_cases_46();
    test_tensor_edge_cases();
    if (g_failures > 0) {
        fprintf(stderr, "%d test failure(s)\n", g_failures);
        return 1;
    }
    printf("ALL conformance tests PASSED (golden 3/3 + Frozen errors + 46/46 kiln-v2-cases.json + KLNT edge cases)\n");
    return 0;
}
