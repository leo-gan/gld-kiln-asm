# Common constants, struct offsets, and internal ABI macros for gld-kiln-asm (x86-64).
#
# Internal register-pinned kernel contract:
#   r12 = wire cursor (src on decode, dst on encode)
#   r13 = wire end (src_end on decode, dst_end on encode)
#   r14 = bump arena cursor (decode)
#   r15 = packed state:
#           bits  0..7 : nesting depth (u8)
#           bit      8 : FLAG_CHECK_UTF8 (1 = validate RFC 3629 UTF-8)
#           bit      9 : FLAG_SLOP32     (1 = 32 B trailing slop on dst/arena)
#           bit     10 : FLAG_OWNED      (1 = copy decoded slices into arena)
#           bit     11 : FLAG_EMBEDDED   (1 = suppress standalone TRAILING check)
#   rbx = pointer to kiln_ctx_t
#
# Return contract:
#   Success : CF = 0, eax = KILN_OK (0)
#   Failure : CF = 1, eax = kiln_err_t (1..8), rdx = byte offset (r12 - ctx.base_ptr)

.equ KILN_OK,            0
.equ KILN_ERR_FRAME,     1
.equ KILN_ERR_SCHEMA,    2
.equ KILN_ERR_LIMIT,     3
.equ KILN_ERR_EOF,       4
.equ KILN_ERR_TYPE,      5
.equ KILN_ERR_UTF8,      6
.equ KILN_ERR_TRAILING,  7
.equ KILN_ERR_DEPTH,     8

.equ KILN_CAP_DEFAULT,   16777216
.equ KILN_DEPTH_DEFAULT, 64

# Wire magic constants (little-endian u32)
.equ KILN_MAGIC_KLN0,    0x304E4C4B   # "KLN0"
.equ KILN_MAGIC_KLNT,    0x544E4C4B   # "KLNT"

# FNV-1a-64 constants and normative schema hashes
.equ FNV1A_OFFSET,       0xCBF29CE484222325
.equ FNV1A_PRIME,        0x00000100000001B3
.equ KILN_HASH_POINT,      0xE66AC0386103C72F
.equ KILN_HASH_MESSAGE,    0xD6646445F41CE803
.equ KILN_HASH_ID_TENSORS, 0xE58AADC7552F0D82

# Internal r15 flags
.equ FLAG_CHECK_UTF8,    0x100
.equ FLAG_SLOP32,        0x200
.equ FLAG_OWNED,         0x400
.equ FLAG_EMBEDDED,      0x800
.equ FLAG_COPY_AVX2,     0x1000
.equ FLAG_COPY_NT,       0x2000

# Public kiln_read_opts_t.flags bits
.equ KILN_OPT_TRUSTED,   0x01
.equ KILN_OPT_OWNED,     0x02
.equ KILN_OPT_SLOP32,    0x04
.equ KILN_OPT_EMBEDDED,  0x08
.equ KILN_OPT_COPY_AVX2, 0x10
.equ KILN_OPT_COPY_NT,   0x20

# kiln_ctx_t offsets (40 bytes)
.equ CTX_BASE_PTR,       0
.equ CTX_ARENA_END,      8
.equ CTX_MAX_COUNT,      16
.equ CTX_MAX_BYTES,      24
.equ CTX_MAX_DEPTH,      32
.equ CTX_SIZE,           40

# kiln_arena_t offsets (24 bytes)
.equ ARENA_BASE,         0
.equ ARENA_CUR,          8
.equ ARENA_END,          16

# kiln_read_opts_t offsets (24 bytes)
.equ OPTS_MAX_COUNT,     0
.equ OPTS_MAX_BYTES,     8
.equ OPTS_MAX_DEPTH,     16
.equ OPTS_FLAGS,         20

# kiln_result_t offsets (16 bytes)
.equ RES_BYTES,          0
.equ RES_HASH,           8

# kiln_str_t offsets (16 bytes)
.equ STR_PTR,            0
.equ STR_LEN,            8
.equ STR_SIZE,           16

# kiln_point_t offsets (8 bytes)
.equ POINT_X,            0
.equ POINT_Y,            4
.equ POINT_SIZE,         8

# kiln_message_t offsets (64 bytes, 1 cache line)
.equ MSG_F_INT64,        0
.equ MSG_F_FLOAT64,      8
.equ MSG_F_STRING_PTR,   16
.equ MSG_F_STRING_LEN,   24
.equ MSG_F_STRING2_PTR,  32
.equ MSG_F_STRING2_LEN,  40
.equ MSG_F_INT32,        48
.equ MSG_F_INT32_2,      52
.equ MSG_F_BOOL,         56
.equ MSG_F_BOOL_2,       57
.equ MSG_SIZE,           64
.equ MSG_WIRE_MIN,       34

# kiln_dict_entry_t offsets (24 bytes)
.equ DICT_KEY_PTR,       0
.equ DICT_KEY_LEN,       8
.equ DICT_VAL_I64,       16
.equ DICT_ENTRY_SIZE,    24

# KLNT v2 wire constants
.equ KLNT_HDR_SIZE,      64
.equ KLNT_DESC_SIZE,     128
.equ KLNT_VERSION,       2
.equ KLNT_FLAG_NAME,     0x01
.equ KLNT_FLAG_LE,       0x02

# KLNT v2 wire descriptor offsets (128 bytes)
.equ WDESC_DTYPE,        0
.equ WDESC_RANK,         2
.equ WDESC_RES0,         3
.equ WDESC_NAME_OFF,     4
.equ WDESC_NAME_LEN,     6
.equ WDESC_LAYOUT_OFF,   8
.equ WDESC_LAYOUT_LEN,   10
.equ WDESC_BLOCK_SIZE,   12
.equ WDESC_QSCHEME,      16
.equ WDESC_QAXIS,        18
.equ WDESC_GROUP_SIZE,   20
.equ WDESC_SCALE_IDX,    24
.equ WDESC_OUTER_IDX,    28
.equ WDESC_BYTE_OFF,     32
.equ WDESC_BYTE_LEN,     40
.equ WDESC_SHAPE,        48
.equ WDESC_RES1,         112

# kiln_tensor_t offsets (144 bytes)
.equ TENS_NAME_PTR,      0
.equ TENS_NAME_LEN,      8
.equ TENS_LAYOUT_PTR,    16
.equ TENS_LAYOUT_LEN,    24
.equ TENS_DATA_PTR,      32
.equ TENS_DATA_LEN,      40
.equ TENS_SHAPE,         48
.equ TENS_DTYPE,         112
.equ TENS_RANK,          114
.equ TENS_QSCHEME,       116
.equ TENS_QAXIS,         118
.equ TENS_GROUP_SIZE,    120
.equ TENS_SCALE_IDX,     124
.equ TENS_OUTER_IDX,     128
.equ TENS_BLOCK_SIZE,    132
.equ TENS_ELEM_COUNT,    136
.equ TENS_SIZE,          144

# kiln_tensor_dir_t offsets (32 bytes)
.equ TDIR_ITEMS,         0
.equ TDIR_COUNT,         8
.equ TDIR_BLOCK_LEN,     16
.equ TDIR_FLAGS,         24
.equ TDIR_VERSION,       28
.equ TDIR_SIZE,          32

# kiln_id_tensors_t offsets (40 bytes)
.equ IDTEN_ID,           0
.equ IDTEN_BATCH,        8
.equ IDTEN_SIZE,         40

# Linux x86-64 syscall numbers (MODE=nolibc)
.equ SYS_WRITE,          1
.equ SYS_MMAP,           9
.equ SYS_CLOCK_GETTIME,  228
.equ SYS_EXIT_GROUP,     231
.equ CLOCK_MONOTONIC,    1

# Return failure with CF=1, eax=err_code, rdx=r12-ctx.base_ptr
.macro KILN_FAIL code
    mov     eax, \code
    mov     rdx, r12
    sub     rdx, QWORD PTR [rbx + CTX_BASE_PTR]
    stc
    ret
.endm

# Return success with CF=0, eax=0
.macro KILN_OK_RET
    xor     eax, eax
    ret
.endm
