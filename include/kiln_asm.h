#ifndef KILN_ASM_H
#define KILN_ASM_H

/* Pure x86-64 Assembly Kiln Wire Format v2 library (MODE=cabi). ISO C11. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KILN_ASM_VERSION      "0.2.0"
#define KILN_CAP_DEFAULT      16777216ULL
#define KILN_DEPTH_DEFAULT    64U

#define KILN_HASH_POINT       0xE66AC0386103C72FULL
#define KILN_HASH_MESSAGE     0xD6646445F41CE803ULL
#define KILN_HASH_ID_TENSORS  0xE58AADC7552F0D82ULL

typedef enum kiln_err_t {
    KILN_OK           = 0,
    KILN_ERR_FRAME    = 1,
    KILN_ERR_SCHEMA   = 2,
    KILN_ERR_LIMIT    = 3,
    KILN_ERR_EOF      = 4,
    KILN_ERR_TYPE     = 5,
    KILN_ERR_UTF8     = 6,
    KILN_ERR_TRAILING = 7,
    KILN_ERR_DEPTH    = 8
} kiln_err_t;

enum kiln_opt_flags_t {
    KILN_OPT_TRUSTED   = 1U << 0, /* skip UTF-8 validation */
    KILN_OPT_OWNED     = 1U << 1, /* copy decoded strings/slices into bump arena */
    KILN_OPT_SLOP32    = 1U << 2, /* caller guarantees 32 B trailing slop on src/dst */
    KILN_OPT_EMBEDDED  = 1U << 3, /* do not reject unread trailing bytes */
    KILN_OPT_COPY_AVX2 = 1U << 4, /* bulk copy via unrolled AVX2 vmovdqu (128 B/iter) */
    KILN_OPT_COPY_NT   = 1U << 5  /* bulk copy via non-temporal vmovntdq + sfence */
};

typedef struct kiln_arena_t {
    uint8_t *base;
    uint8_t *cur;
    uint8_t *end;
} kiln_arena_t;

typedef struct kiln_read_opts_t {
    uint64_t max_count; /* 0 -> KILN_CAP_DEFAULT */
    uint64_t max_bytes; /* 0 -> KILN_CAP_DEFAULT */
    uint32_t max_depth; /* 0 -> KILN_DEPTH_DEFAULT */
    uint32_t flags;     /* bitmask of kiln_opt_flags_t */
} kiln_read_opts_t;

typedef struct kiln_result_t {
    uint64_t bytes; /* bytes written/consumed, or error byte offset on failure */
    uint64_t hash;  /* decoded KLN0 schema hash (0 for unframed calls) */
} kiln_result_t;

typedef struct kiln_str_t {
    const uint8_t *ptr;
    uint64_t len;
} kiln_str_t;

typedef kiln_str_t kiln_bytes_t;

typedef struct kiln_point_t {
    int32_t x;
    int32_t y;
} kiln_point_t;

typedef struct kiln_message_t {
    int64_t    f_int64;
    double     f_float64;
    kiln_str_t f_string;
    kiln_str_t f_string_2;
    int32_t    f_int32;
    int32_t    f_int32_2;
    uint8_t    f_bool;
    uint8_t    f_bool_2;
    uint8_t    _pad[6];
} kiln_message_t;

typedef struct kiln_dict_entry_t {
    kiln_str_t key;
    int64_t    val;
} kiln_dict_entry_t;

typedef struct kiln_tensor_t {
    const uint8_t *name;
    uint64_t       name_len;
    const uint8_t *layout;
    uint64_t       layout_len;
    const uint8_t *data;
    uint64_t       data_len;
    uint64_t       shape[8];
    uint16_t       dtype;
    uint8_t        rank;
    uint8_t        _pad0;
    uint16_t       quant_scheme;
    uint16_t       quant_axis;
    uint32_t       group_size;
    uint32_t       scale_index;
    uint32_t       outer_index;
    uint32_t       block_size;
    uint64_t       elem_count;
} kiln_tensor_t;

typedef struct kiln_tensor_dir_t {
    kiln_tensor_t *items;
    uint64_t       count;
    uint64_t       block_length;
    uint32_t       flags;
    uint32_t       version;
} kiln_tensor_dir_t;

typedef struct kiln_id_tensors_t {
    int64_t           id;
    kiln_tensor_dir_t batch;
} kiln_id_tensors_t;

static inline void kiln_tensor_init(kiln_tensor_t *t) {
    t->name         = NULL;
    t->name_len     = 0;
    t->layout       = NULL;
    t->layout_len   = 0;
    t->data         = NULL;
    t->data_len     = 0;
    for (int i = 0; i < 8; i++) t->shape[i] = 0;
    t->dtype        = 0;
    t->rank         = 0;
    t->_pad0        = 0;
    t->quant_scheme = 0;
    t->quant_axis   = 0xFFFFU;
    t->group_size   = 0;
    t->scale_index  = 0xFFFFFFFFU;
    t->outer_index  = 0xFFFFFFFFU;
    t->block_size   = 0;
    t->elem_count   = 0;
}

static inline void kiln_arena_init(kiln_arena_t *a, uint8_t *buf, size_t cap) {
    a->base = buf;
    a->cur  = buf;
    a->end  = buf + cap;
}

static inline void kiln_arena_reset(kiln_arena_t *a) {
    a->cur = a->base;
}

static inline size_t kiln_arena_used(const kiln_arena_t *a) {
    return (size_t)(a->cur - a->base);
}

/* Metadata helpers */
const char *kiln_asm_version(void);
const char *kiln_asm_err_name(kiln_err_t err);
const char *kiln_asm_dtype_name(uint16_t dtype);

/* Low-level primitives (implemented in pure x86-64 Assembly) */
int      kiln_asm_utf8_ok(const uint8_t *s, size_t n);
uint64_t kiln_asm_fnv1a_mix_token(uint64_t h, const uint8_t *tok, size_t len);

/* Specialized Frozen codecs: Point */
kiln_err_t kiln_asm_encode_point(
    const kiln_point_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_point(
    const uint8_t *src, size_t len, kiln_point_t *out,
    const kiln_read_opts_t *opts, kiln_result_t *res);

/* Specialized Frozen codecs: Message (unframed and KLN0 framed) */
kiln_err_t kiln_asm_encode_message(
    const kiln_message_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_message(
    const uint8_t *src, size_t len, kiln_message_t *out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_encode_message_framed(
    const kiln_message_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_message_framed(
    const uint8_t *src, size_t len, kiln_message_t *out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

/* Specialized Frozen codecs: Batch (list<Message>) */
kiln_err_t kiln_asm_encode_batch(
    const kiln_message_t *items, size_t count, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_batch(
    const uint8_t *src, size_t len, kiln_message_t **out_items, size_t *out_count,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

/* General Frozen primitives exposed for conformance & container testing */
kiln_err_t kiln_asm_encode_opt_i32(
    int present, int32_t val, uint8_t *dst, size_t cap, kiln_result_t *res);

kiln_err_t kiln_asm_decode_opt_i32(
    const uint8_t *src, size_t len, int *present_out, int32_t *val_out,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_encode_dict_i64(
    const kiln_dict_entry_t *entries, size_t count, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_dict_i64(
    const uint8_t *src, size_t len, kiln_dict_entry_t **out_entries, size_t *out_count,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

/* Frozen list codecs (used by kiln-v2-cases.json list vectors) */
kiln_err_t kiln_asm_encode_list_f32(
    const uint32_t *bits, size_t count, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_list_f32(
    const uint8_t *src, size_t len, const uint8_t **raw_out, size_t *count_out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_list_str(
    const uint8_t *src, size_t len, kiln_str_t **out_items, size_t *count_out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_list_i64_struct(
    const uint8_t *src, size_t len, const uint8_t **raw_out, size_t *count_out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

/* KLNT v2 Tensor Directory codecs (12-step normative validation + canonical encoder) */
kiln_err_t kiln_asm_encode_tensors(
    const kiln_tensor_dir_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_tensors(
    const uint8_t *src, size_t len, kiln_tensor_dir_t *out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

/* Embedded & KLN0-framed struct{id:i64,batch:tensors,} */
kiln_err_t kiln_asm_encode_id_tensors(
    const kiln_id_tensors_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_id_tensors(
    const uint8_t *src, size_t len, kiln_id_tensors_t *out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_encode_id_tensors_framed(
    const kiln_id_tensors_t *in, uint8_t *dst, size_t cap,
    const kiln_read_opts_t *opts, kiln_result_t *res);

kiln_err_t kiln_asm_decode_id_tensors_framed(
    const uint8_t *src, size_t len, kiln_id_tensors_t *out,
    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);

#ifdef __cplusplus
}
#endif

#endif /* KILN_ASM_H */
