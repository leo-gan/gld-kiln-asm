.intel_syntax noprefix
.include "defs.inc"

.section .rodata

.Lgolden_point:
    .byte 0x09, 0x00, 0x00, 0x00, 0xfc, 0xff, 0xff, 0xff

.Lgolden_msg_frame:
    .byte 0x4b, 0x4c, 0x4e, 0x30, 0x00, 0x00, 0x00, 0x00
    .byte 0x03, 0xe8, 0x1c, 0xf4, 0x45, 0x64, 0x64, 0xd6
.Lgolden_msg:
    .byte 0x01, 0xfe, 0xff, 0xff, 0xff, 0x63, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0xf8, 0x3f, 0x02, 0x00, 0x00
    .byte 0x00, 0x68, 0x69, 0x00, 0x07, 0x00, 0x00, 0x00
    .byte 0x01, 0x00, 0x00, 0x00, 0x7a

.Lstr_hi:       .ascii "hi"
.Lstr_z:        .ascii "z"
.p2align 5
.Lstr_hello:    .ascii "hello"
                .fill 27, 1, 0      # 32-byte padded for slop32 A/B experiment
.p2align 5
.Lstr_world:    .ascii "world"
                .fill 27, 1, 0
.Lflag_selftest: .asciz "--self-test"

.Lmsg_pass:     .ascii "nolibc self-test PASSED (point 8B, message 37B, message.frame 53B, klnt_10k 80192B)\n"
.equ .Lmsg_pass_len, . - .Lmsg_pass

.Lmsg_fail:     .ascii "nolibc self-test FAILED\n"
.equ .Lmsg_fail_len, . - .Lmsg_fail

.Lhdr_bench:    .ascii "mode,workload,bytes,mean_ns,mean_cyc,sink\n"
.equ .Lhdr_bench_len, . - .Lhdr_bench

.Lcomma:        .ascii ","
.Ldot:          .ascii "."
.Lnl:           .ascii "\n"

# CSV row prefixes ("nolibc,<workload>,")
.macro DEF_ROW sym, text
\sym:           .ascii "nolibc,\text,"
.equ \sym\()_len, . - \sym
.endm

DEF_ROW .Lr_pt_enc,    "point_encode"
DEF_ROW .Lr_pt_dec,    "point_decode"
DEF_ROW .Lr_m_enc,     "msg_encode"
DEF_ROW .Lr_m_enc_s32, "msg_encode_slop32"
DEF_ROW .Lr_m_vchk,    "msg_decode_view_utf8"
DEF_ROW .Lr_m_vtr,     "msg_decode_view_trusted"
DEF_ROW .Lr_m_ochk,    "msg_decode_arena_utf8"
DEF_ROW .Lr_m_otr,     "msg_decode_arena_trusted"
DEF_ROW .Lr_b_enc,     "batch100_encode"
DEF_ROW .Lr_b_vchk,    "batch100_view_utf8"
DEF_ROW .Lr_b_vtr,     "batch100_view_trusted"
DEF_ROW .Lr_b_ochk,    "batch100_arena_utf8"
DEF_ROW .Lr_b_otr,     "batch100_arena_trusted"
DEF_ROW .Lr_t10k_enc,  "klnt_10k_f64_encode"
DEF_ROW .Lr_t10k_dec,  "klnt_10k_f64_decode_view"
DEF_ROW .Lr_t2m_erms,  "klnt_2m_f64_encode_erms"
DEF_ROW .Lr_t2m_avx2,  "klnt_2m_f64_encode_avx2"
DEF_ROW .Lr_t2m_nt,    "klnt_2m_f64_encode_nt"
DEF_ROW .Lr_t2m_decv,  "klnt_2m_f64_decode_view"
DEF_ROW .Lr_t2m_deca,  "klnt_2m_f64_decode_arena"

.section .bss
.p2align 6
.Lctx:          .skip CTX_SIZE
.Lts0:          .skip 16
.Lpt_in:        .skip POINT_SIZE
.Lpt_out:       .skip POINT_SIZE
.Lmsg_in:       .skip MSG_SIZE
.Lmsg_out:      .skip MSG_SIZE
.Lbatch_in:     .skip MSG_SIZE * 100
.Ltens_in:      .skip TENS_SIZE
.Ltdir_in:      .skip TDIR_SIZE
.Ltdir_out:     .skip TDIR_SIZE
.Lnum_buf:      .skip 32
.Lwire_base:    .skip 8
.Larena_base:   .skip 8
.Lsrc_f64:      .skip 8
.Lself_only:    .skip 8

.text

# ------------------------------------------------------------------------------
# Raw Linux syscall & timer helpers (preserve rbx, rbp, r12..r15)
# ------------------------------------------------------------------------------
.p2align 4
.Lsys_write:
    mov     eax, SYS_WRITE
    syscall
    ret

.p2align 4
.Lsys_mmap_anon:
    mov     rsi, rdi
    xor     edi, edi
    mov     edx, 3                  # PROT_READ | PROT_WRITE
    mov     r10d, 0x22              # MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    ret

.p2align 4
.Lnow_ns:
    lea     rsi, [rip + .Lts0]
    mov     edi, CLOCK_MONOTONIC
    mov     eax, SYS_CLOCK_GETTIME
    syscall
    mov     rax, QWORD PTR [rip + .Lts0]
    imul    rax, rax, 1000000000
    add     rax, QWORD PTR [rip + .Lts0 + 8]
    ret

.p2align 4
.Lnow_tsc:
    lfence
    rdtscp
    shl     rdx, 32
    or      rax, rdx
    ret

.p2align 4
.Lexit_code:
    mov     eax, SYS_EXIT_GROUP
    syscall

# ------------------------------------------------------------------------------
# Formatting helpers (stdout fd=1)
# ------------------------------------------------------------------------------
.p2align 4
.Lprint_u64:
    lea     rsi, [rip + .Lnum_buf + 31]
    mov     rax, rdi
    mov     rcx, 10
    xor     r8d, r8d
    test    rax, rax
    jnz     .Lpu_loop
    mov     BYTE PTR [rsi], '0'
    mov     r8d, 1
    jmp     .Lpu_emit
.Lpu_loop:
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     BYTE PTR [rsi], dl
    dec     rsi
    inc     r8d
    test    rax, rax
    jnz     .Lpu_loop
    inc     rsi
.Lpu_emit:
    mov     edi, 1
    mov     rdx, r8
    jmp     .Lsys_write

.p2align 4
.Lprint_tenths:
    mov     rax, rdi
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    push    rdx
    mov     rdi, rax
    call    .Lprint_u64
    mov     edi, 1
    lea     rsi, [rip + .Ldot]
    mov     edx, 1
    call    .Lsys_write
    pop     rdi
    jmp     .Lprint_u64

# Print CSV row using [rbp-8]=t0_ns, [rbp-16]=c0_cyc, [rbp-24]=sink, [rbp-32]=iters
# Inputs: rdi = label_ptr, rsi = label_len, rdx = wire_bytes
.p2align 4
.Lemit_bench_row:
    push    rdx
    push    rsi
    push    rdi
    call    .Lnow_tsc
    sub     rax, QWORD PTR [rbp - 16]
    imul    rax, rax, 10
    xor     edx, edx
    div     QWORD PTR [rbp - 32]
    push    rax                     # cyc_x10
    call    .Lnow_ns
    sub     rax, QWORD PTR [rbp - 8]
    imul    rax, rax, 10
    xor     edx, edx
    div     QWORD PTR [rbp - 32]
    push    rax                     # ns_x10

    # Stack: [rsp]=ns_x10, [rsp+8]=cyc_x10, [rsp+16]=lbl_ptr, [rsp+24]=lbl_len, [rsp+32]=bytes
    mov     edi, 1
    mov     rsi, QWORD PTR [rsp + 16]
    mov     rdx, QWORD PTR [rsp + 24]
    call    .Lsys_write

    mov     rdi, QWORD PTR [rsp + 32] # bytes
    call    .Lprint_u64
    mov     edi, 1
    lea     rsi, [rip + .Lcomma]
    mov     edx, 1
    call    .Lsys_write

    pop     rdi                     # ns_x10
    call    .Lprint_tenths
    mov     edi, 1
    lea     rsi, [rip + .Lcomma]
    mov     edx, 1
    call    .Lsys_write

    pop     rdi                     # cyc_x10
    call    .Lprint_tenths
    mov     edi, 1
    lea     rsi, [rip + .Lcomma]
    mov     edx, 1
    call    .Lsys_write

    mov     rdi, QWORD PTR [rbp - 24] # sink
    call    .Lprint_u64
    mov     edi, 1
    lea     rsi, [rip + .Lnl]
    mov     edx, 1
    call    .Lsys_write
    add     rsp, 24                 # pop lbl_ptr, lbl_len, bytes
    ret

.p2align 4
.Lbytes_eq:
    xor     rcx, rcx
.Lbe_loop:
    cmp     rcx, rdx
    jae     .Lbe_ok
    movzx   eax, BYTE PTR [rdi + rcx]
    cmp     al, BYTE PTR [rsi + rcx]
    jne     .Lbe_no
    inc     rcx
    jmp     .Lbe_loop
.Lbe_ok:
    mov     eax, 1
    ret
.Lbe_no:
    xor     eax, eax
    ret

.p2align 4
.Lcstr_eq:
.Lce_loop:
    movzx   eax, BYTE PTR [rdi]
    movzx   ecx, BYTE PTR [rsi]
    cmp     al, cl
    jne     .Lce_no
    test    al, al
    jz      .Lce_ok
    inc     rdi
    inc     rsi
    jmp     .Lce_loop
.Lce_ok:
    mov     eax, 1
    ret
.Lce_no:
    xor     eax, eax
    ret

# Initialize context block in rbx = .Lctx, wire base/cap in rdi/rsi, flags in rdx
.p2align 4
.Linit_ctx:
    lea     rbx, [rip + .Lctx]
    mov     r12, rdi
    lea     r13, [rdi + rsi]
    mov     QWORD PTR [rbx + CTX_BASE_PTR], rdi
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rax, [r14 + 4194304]    # 4 MiB arena
    mov     QWORD PTR [rbx + CTX_ARENA_END], rax
    mov     rax, KILN_CAP_DEFAULT
    mov     QWORD PTR [rbx + CTX_MAX_COUNT], rax
    mov     QWORD PTR [rbx + CTX_MAX_BYTES], rax
    mov     QWORD PTR [rbx + CTX_MAX_DEPTH], KILN_DEPTH_DEFAULT
    mov     r15, rdx
    ret

# Prepare single f64 tensor descriptor in .Ltens_in / .Ltdir_in for rdi elements
.p2align 4
.Lsetup_f64_tensor:
    # rdi = num_elements
    lea     rax, [rip + .Ltens_in]
    mov     QWORD PTR [rax + TENS_NAME_PTR], 0
    mov     QWORD PTR [rax + TENS_NAME_LEN], 0
    mov     QWORD PTR [rax + TENS_LAYOUT_PTR], 0
    mov     QWORD PTR [rax + TENS_LAYOUT_LEN], 0
    mov     rcx, QWORD PTR [rip + .Lsrc_f64]
    mov     QWORD PTR [rax + TENS_DATA_PTR], rcx
    lea     rdx, [rdi * 8]
    mov     QWORD PTR [rax + TENS_DATA_LEN], rdx
    mov     QWORD PTR [rax + TENS_SHAPE], rdi
    mov     QWORD PTR [rax + TENS_SHAPE + 8], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 16], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 24], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 32], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 40], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 48], 0
    mov     QWORD PTR [rax + TENS_SHAPE + 56], 0
    mov     WORD PTR [rax + TENS_DTYPE], 1      # f64
    mov     BYTE PTR [rax + TENS_RANK], 1
    mov     WORD PTR [rax + TENS_QSCHEME], 0
    mov     WORD PTR [rax + TENS_QAXIS], 0xFFFF
    mov     DWORD PTR [rax + TENS_GROUP_SIZE], 0
    mov     DWORD PTR [rax + TENS_SCALE_IDX], 0xFFFFFFFF
    mov     DWORD PTR [rax + TENS_OUTER_IDX], 0xFFFFFFFF
    mov     DWORD PTR [rax + TENS_BLOCK_SIZE], 0
    mov     QWORD PTR [rax + TENS_ELEM_COUNT], rdi

    lea     rcx, [rip + .Ltdir_in]
    mov     QWORD PTR [rcx + TDIR_ITEMS], rax
    mov     QWORD PTR [rcx + TDIR_COUNT], 1
    mov     QWORD PTR [rcx + TDIR_BLOCK_LEN], 0
    mov     DWORD PTR [rcx + TDIR_FLAGS], KLNT_FLAG_LE
    mov     DWORD PTR [rcx + TDIR_VERSION], KLNT_VERSION
    ret

# ------------------------------------------------------------------------------
# Self-verification against golden binaries + 10k f64 KLNT round-trip
# ------------------------------------------------------------------------------
.p2align 4
.Lrun_self_test:
    # 1. Point { 9, -4 } -> 8 B golden
    mov     DWORD PTR [rip + .Lpt_in + POINT_X], 9
    mov     DWORD PTR [rip + .Lpt_in + POINT_Y], -4
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Lpt_in]
    call    kiln_core_enc_point
    jc      .Lst_fail
    mov     rax, r12
    sub     rax, QWORD PTR [rip + .Lwire_base]
    cmp     rax, 8
    jne     .Lst_fail
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    lea     rsi, [rip + .Lgolden_point]
    mov     edx, 8
    call    .Lbytes_eq
    test    eax, eax
    jz      .Lst_fail

    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 8
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Lpt_out]
    call    kiln_core_dec_point
    jc      .Lst_fail
    call    kiln_core_check_trailing
    jc      .Lst_fail
    cmp     DWORD PTR [rip + .Lpt_out + POINT_X], 9
    jne     .Lst_fail
    cmp     DWORD PTR [rip + .Lpt_out + POINT_Y], -4
    jne     .Lst_fail

    # 2. Golden Message (37 B)
    mov     BYTE PTR [rip + .Lmsg_in + MSG_F_BOOL], 1
    mov     DWORD PTR [rip + .Lmsg_in + MSG_F_INT32], -2
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_INT64], 99
    movabs  rax, 0x3FF8000000000000
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_FLOAT64], rax
    lea     rax, [rip + .Lstr_hi]
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING_PTR], rax
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING_LEN], 2
    mov     BYTE PTR [rip + .Lmsg_in + MSG_F_BOOL_2], 0
    mov     DWORD PTR [rip + .Lmsg_in + MSG_F_INT32_2], 7
    lea     rax, [rip + .Lstr_z]
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING2_PTR], rax
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING2_LEN], 1

    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Lmsg_in]
    call    kiln_core_enc_message
    jc      .Lst_fail
    mov     rax, r12
    sub     rax, QWORD PTR [rip + .Lwire_base]
    cmp     rax, 37
    jne     .Lst_fail
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    lea     rsi, [rip + .Lgolden_msg]
    mov     edx, 37
    call    .Lbytes_eq
    test    eax, eax
    jz      .Lst_fail

    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 37
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_OWNED
    call    .Linit_ctx
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message
    jc      .Lst_fail
    call    kiln_core_check_trailing
    jc      .Lst_fail
    cmp     QWORD PTR [rip + .Lmsg_out + MSG_F_INT64], 99
    jne     .Lst_fail

    # 3. Framed Golden Message (53 B)
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Lmsg_in]
    call    kiln_core_enc_message_framed
    jc      .Lst_fail
    mov     rax, r12
    sub     rax, QWORD PTR [rip + .Lwire_base]
    cmp     rax, 53
    jne     .Lst_fail
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    lea     rsi, [rip + .Lgolden_msg_frame]
    mov     edx, 53
    call    .Lbytes_eq
    test    eax, eax
    jz      .Lst_fail

    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 53
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message_framed
    jc      .Lst_fail
    movabs  rcx, KILN_HASH_MESSAGE
    cmp     rax, rcx
    jne     .Lst_fail

    # 4. KLNT 10k f64 round-trip (80,192 B)
    mov     rdi, 10000
    call    .Lsetup_f64_tensor
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4194304
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    jc      .Lst_fail
    mov     rax, r12
    sub     rax, QWORD PTR [rip + .Lwire_base]
    cmp     rax, 80192
    jne     .Lst_fail
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 80192
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    lea     rdi, [rip + .Ltdir_out]
    call    kiln_core_dec_tensors
    jc      .Lst_fail
    call    kiln_core_check_trailing
    jc      .Lst_fail
    cmp     QWORD PTR [rip + .Ltdir_out + TDIR_BLOCK_LEN], 80192
    jne     .Lst_fail

    xor     eax, eax
    ret

.Lst_fail:
    mov     edi, 2
    lea     rsi, [rip + .Lmsg_fail]
    mov     edx, .Lmsg_fail_len
    call    .Lsys_write
    mov     edi, 1
    call    .Lexit_code

# ------------------------------------------------------------------------------
# Populate benchmark inputs (44 B Message, 100-msg Batch, 2 MiB f64 tensor)
# ------------------------------------------------------------------------------
.p2align 4
.Linit_bench_data:
    mov     BYTE PTR [rip + .Lmsg_in + MSG_F_BOOL], 1
    mov     DWORD PTR [rip + .Lmsg_in + MSG_F_INT32], -2
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_INT64], 99
    movabs  rax, 0x3FF8000000000000
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_FLOAT64], rax
    lea     rax, [rip + .Lstr_hello]
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING_PTR], rax
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING_LEN], 5
    mov     BYTE PTR [rip + .Lmsg_in + MSG_F_BOOL_2], 0
    mov     DWORD PTR [rip + .Lmsg_in + MSG_F_INT32_2], 7
    lea     rax, [rip + .Lstr_world]
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING2_PTR], rax
    mov     QWORD PTR [rip + .Lmsg_in + MSG_F_STRING2_LEN], 5

    xor     rcx, rcx
    lea     rdx, [rip + .Lbatch_in]
.Libd_loop:
    cmp     rcx, 100
    jae     .Libd_f64
    mov     BYTE PTR [rdx + MSG_F_BOOL], 1
    lea     eax, [ecx - 50]
    mov     DWORD PTR [rdx + MSG_F_INT32], eax
    lea     rax, [rcx + 100]
    mov     QWORD PTR [rdx + MSG_F_INT64], rax
    movabs  rax, 0x3FF8000000000000
    mov     QWORD PTR [rdx + MSG_F_FLOAT64], rax
    lea     rax, [rip + .Lstr_hello]
    mov     QWORD PTR [rdx + MSG_F_STRING_PTR], rax
    mov     QWORD PTR [rdx + MSG_F_STRING_LEN], 5
    mov     BYTE PTR [rdx + MSG_F_BOOL_2], 0
    mov     DWORD PTR [rdx + MSG_F_INT32_2], 7
    lea     rax, [rip + .Lstr_world]
    mov     QWORD PTR [rdx + MSG_F_STRING2_PTR], rax
    mov     QWORD PTR [rdx + MSG_F_STRING2_LEN], 5
    add     rdx, MSG_SIZE
    inc     rcx
    jmp     .Libd_loop

.Libd_f64:
    # Touch all 262,144 f64 source elements (2 MiB) to fault in pages
    mov     rdi, QWORD PTR [rip + .Lsrc_f64]
    xor     rcx, rcx
    movabs  rax, 0x3FF8000000000000
.Libd_f64_loop:
    cmp     rcx, 262144
    jae     .Libd_done
    mov     QWORD PTR [rdi + rcx * 8], rax
    inc     rcx
    jmp     .Libd_f64_loop
.Libd_done:
    ret

# Helper to start timer (sets [rbp-32]=iters, [rbp-40]=iters, [rbp-24]=0, [rbp-8]=t0_ns, [rbp-16]=c0_cyc)
.p2align 4
.Lstart_timer:
    # rdi = iters
    mov     QWORD PTR [rbp - 32], rdi
    mov     QWORD PTR [rbp - 40], rdi
    mov     QWORD PTR [rbp - 24], 0
    call    .Lnow_ns
    mov     QWORD PTR [rbp - 8], rax
    call    .Lnow_tsc
    mov     QWORD PTR [rbp - 16], rax
    ret

# ------------------------------------------------------------------------------
# Entry point: _start (zero libc!)
# ------------------------------------------------------------------------------
.p2align 4
.globl _start
.type _start, @function
_start:
    mov     rax, QWORD PTR [rsp]
    mov     QWORD PTR [rip + .Lself_only], 0
    cmp     rax, 2
    jb      .Largs_done
    mov     rdi, QWORD PTR [rsp + 16]
    lea     rsi, [rip + .Lflag_selftest]
    call    .Lcstr_eq
    mov     QWORD PTR [rip + .Lself_only], rax
.Largs_done:
    and     rsp, -16

    # Allocate 12 MiB workspace: [0..4M) wire, [4M..8M) arena, [8M..12M) src_f64
    mov     rdi, 12582912
    call    .Lsys_mmap_anon
    test    rax, rax
    js      .Lst_fail
    mov     QWORD PTR [rip + .Lwire_base], rax
    lea     rcx, [rax + 4194304]
    mov     QWORD PTR [rip + .Larena_base], rcx
    lea     rcx, [rax + 8388608]
    mov     QWORD PTR [rip + .Lsrc_f64], rcx

    call    .Lrun_self_test

    cmp     QWORD PTR [rip + .Lself_only], 0
    je      .Lrun_benchmarks
    mov     edi, 1
    lea     rsi, [rip + .Lmsg_pass]
    mov     edx, .Lmsg_pass_len
    call    .Lsys_write
    xor     edi, edi
    call    .Lexit_code

.Lrun_benchmarks:
    call    .Linit_bench_data

    mov     edi, 1
    lea     rsi, [rip + .Lhdr_bench]
    mov     edx, .Lhdr_bench_len
    call    .Lsys_write

    push    rbp
    mov     rbp, rsp
    sub     rsp, 48

    # ---- 1. point_encode (500,000 iters, 5,000 warmup) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     QWORD PTR [rbp - 40], 5000
.Lw_pt_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lpt_in]
    call    kiln_core_enc_point
    dec     QWORD PTR [rbp - 40]
    jnz     .Lw_pt_enc
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_pt_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lpt_in]
    call    kiln_core_enc_point
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_pt_enc
    lea     rdi, [rip + .Lr_pt_enc]
    mov     rsi, .Lr_pt_enc_len
    mov     edx, 8
    call    .Lemit_bench_row

    # ---- 2. point_decode (500,000 iters) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 8
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_pt_dec:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lpt_out]
    call    kiln_core_dec_point
    movsxd  rax, DWORD PTR [rip + .Lpt_out + POINT_X]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_pt_dec
    lea     rdi, [rip + .Lr_pt_dec]
    mov     rsi, .Lr_pt_dec_len
    mov     edx, 8
    call    .Lemit_bench_row

    # ---- 3. msg_encode (500,000 iters, safe overlapping copy) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     QWORD PTR [rbp - 40], 5000
.Lw_m_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lmsg_in]
    call    kiln_core_enc_message
    dec     QWORD PTR [rbp - 40]
    jnz     .Lw_m_enc
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lmsg_in]
    call    kiln_core_enc_message
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_enc
    lea     rdi, [rip + .Lr_m_enc]
    mov     rsi, .Lr_m_enc_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 4. msg_encode_slop32 (500,000 iters, A/B Opt #1: FLAG_SLOP32) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4096
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_SLOP32
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_enc_s32:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lmsg_in]
    call    kiln_core_enc_message
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_enc_s32
    lea     rdi, [rip + .Lr_m_enc_s32]
    mov     rsi, .Lr_m_enc_s32_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 5. msg_decode_view_utf8 ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 44
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_vchk:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message
    mov     rax, QWORD PTR [rip + .Lmsg_out + MSG_F_INT64]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_vchk
    lea     rdi, [rip + .Lr_m_vchk]
    mov     rsi, .Lr_m_vchk_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 6. msg_decode_view_trusted ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 44
    xor     edx, edx
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_vtr:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message
    mov     rax, QWORD PTR [rip + .Lmsg_out + MSG_F_INT64]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_vtr
    lea     rdi, [rip + .Lr_m_vtr]
    mov     rsi, .Lr_m_vtr_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 7. msg_decode_arena_utf8 ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 44
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_OWNED
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_ochk:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message
    mov     rax, QWORD PTR [rip + .Lmsg_out + MSG_F_INT64]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_ochk
    lea     rdi, [rip + .Lr_m_ochk]
    mov     rsi, .Lr_m_ochk_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 8. msg_decode_arena_trusted ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 44
    mov     rdx, FLAG_OWNED
    call    .Linit_ctx
    mov     edi, 500000
    call    .Lstart_timer
.p2align 5
.Lb_m_otr:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rdi, [rip + .Lmsg_out]
    call    kiln_core_dec_message
    mov     rax, QWORD PTR [rip + .Lmsg_out + MSG_F_INT64]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_m_otr
    lea     rdi, [rip + .Lr_m_otr]
    mov     rsi, .Lr_m_otr_len
    mov     edx, 44
    call    .Lemit_bench_row

    # ---- 9. batch100_encode (20,000 iters) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 16384
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     QWORD PTR [rbp - 40], 500
.Lw_b_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lbatch_in]
    mov     esi, 100
    call    kiln_core_enc_batch
    dec     QWORD PTR [rbp - 40]
    jnz     .Lw_b_enc
    mov     edi, 20000
    call    .Lstart_timer
.p2align 5
.Lb_b_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Lbatch_in]
    mov     esi, 100
    call    kiln_core_enc_batch
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_b_enc
    lea     rdi, [rip + .Lr_b_enc]
    mov     rsi, .Lr_b_enc_len
    mov     edx, 4404
    call    .Lemit_bench_row

    # ---- 10. batch100_view_utf8 ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4404
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     edi, 20000
    call    .Lstart_timer
.p2align 5
.Lb_b_vchk:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    call    kiln_core_dec_batch
    add     QWORD PTR [rbp - 24], rdx
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_b_vchk
    lea     rdi, [rip + .Lr_b_vchk]
    mov     rsi, .Lr_b_vchk_len
    mov     edx, 4404
    call    .Lemit_bench_row

    # ---- 11. batch100_view_trusted ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4404
    xor     edx, edx
    call    .Linit_ctx
    mov     edi, 20000
    call    .Lstart_timer
.p2align 5
.Lb_b_vtr:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    call    kiln_core_dec_batch
    add     QWORD PTR [rbp - 24], rdx
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_b_vtr
    lea     rdi, [rip + .Lr_b_vtr]
    mov     rsi, .Lr_b_vtr_len
    mov     edx, 4404
    call    .Lemit_bench_row

    # ---- 12. batch100_arena_utf8 ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4404
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_OWNED
    call    .Linit_ctx
    mov     edi, 20000
    call    .Lstart_timer
.p2align 5
.Lb_b_ochk:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    call    kiln_core_dec_batch
    add     QWORD PTR [rbp - 24], rdx
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_b_ochk
    lea     rdi, [rip + .Lr_b_ochk]
    mov     rsi, .Lr_b_ochk_len
    mov     edx, 4404
    call    .Lemit_bench_row

    # ---- 13. batch100_arena_trusted ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4404
    mov     rdx, FLAG_OWNED
    call    .Linit_ctx
    mov     edi, 20000
    call    .Lstart_timer
.p2align 5
.Lb_b_otr:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    call    kiln_core_dec_batch
    add     QWORD PTR [rbp - 24], rdx
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_b_otr
    lea     rdi, [rip + .Lr_b_otr]
    mov     rsi, .Lr_b_otr_len
    mov     edx, 4404
    call    .Lemit_bench_row

    # ---- 14. klnt_10k_f64_encode (80,192 B, 5,000 iters) ----
    mov     rdi, 10000
    call    .Lsetup_f64_tensor
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4194304
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     QWORD PTR [rbp - 40], 200
.Lw_t10k:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    dec     QWORD PTR [rbp - 40]
    jnz     .Lw_t10k
    mov     edi, 5000
    call    .Lstart_timer
.p2align 5
.Lb_t10k_enc:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax + 192]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t10k_enc
    lea     rdi, [rip + .Lr_t10k_enc]
    mov     rsi, .Lr_t10k_enc_len
    mov     edx, 80192
    call    .Lemit_bench_row

    # ---- 15. klnt_10k_f64_decode_view (5,000 iters) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 80192
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     edi, 5000
    call    .Lstart_timer
.p2align 5
.Lb_t10k_dec:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rdi, [rip + .Ltdir_out]
    call    kiln_core_dec_tensors
    mov     rax, QWORD PTR [rip + .Ltdir_out + TDIR_BLOCK_LEN]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t10k_dec
    lea     rdi, [rip + .Lr_t10k_dec]
    mov     rsi, .Lr_t10k_dec_len
    mov     edx, 80192
    call    .Lemit_bench_row

    # ---- 16. klnt_2m_f64_encode_erms (2,097,344 B, 500 iters) ----
    mov     rdi, 262144
    call    .Lsetup_f64_tensor
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4194304
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     QWORD PTR [rbp - 40], 20
.Lw_t2m:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    dec     QWORD PTR [rbp - 40]
    jnz     .Lw_t2m
    mov     edi, 500
    call    .Lstart_timer
.p2align 5
.Lb_t2m_erms:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax + 192]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t2m_erms
    lea     rdi, [rip + .Lr_t2m_erms]
    mov     rsi, .Lr_t2m_erms_len
    mov     edx, 2097344
    call    .Lemit_bench_row

    # ---- 17. klnt_2m_f64_encode_avx2 (unrolled 128 B/iter vmovdqu) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4194304
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_COPY_AVX2
    call    .Linit_ctx
    mov     edi, 500
    call    .Lstart_timer
.p2align 5
.Lb_t2m_avx2:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax + 192]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t2m_avx2
    lea     rdi, [rip + .Lr_t2m_avx2]
    mov     rsi, .Lr_t2m_avx2_len
    mov     edx, 2097344
    call    .Lemit_bench_row

    # ---- 18. klnt_2m_f64_encode_nt (non-temporal vmovntdq + sfence) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 4194304
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_COPY_NT
    call    .Linit_ctx
    mov     edi, 500
    call    .Lstart_timer
.p2align 5
.Lb_t2m_nt:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    lea     rdi, [rip + .Ltdir_in]
    call    kiln_core_enc_tensors
    mov     rax, QWORD PTR [rip + .Lwire_base]
    movzx   eax, BYTE PTR [rax + 192]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t2m_nt
    lea     rdi, [rip + .Lr_t2m_nt]
    mov     rsi, .Lr_t2m_nt_len
    mov     edx, 2097344
    call    .Lemit_bench_row

    # ---- 19. klnt_2m_f64_decode_view ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 2097344
    mov     rdx, FLAG_CHECK_UTF8
    call    .Linit_ctx
    mov     edi, 500
    call    .Lstart_timer
.p2align 5
.Lb_t2m_decv:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rdi, [rip + .Ltdir_out]
    call    kiln_core_dec_tensors
    mov     rax, QWORD PTR [rip + .Ltdir_out + TDIR_BLOCK_LEN]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t2m_decv
    lea     rdi, [rip + .Lr_t2m_decv]
    mov     rsi, .Lr_t2m_decv_len
    mov     edx, 2097344
    call    .Lemit_bench_row

    # ---- 20. klnt_2m_f64_decode_arena (owned 2 MiB payload copy) ----
    mov     rdi, QWORD PTR [rip + .Lwire_base]
    mov     rsi, 2097344
    mov     rdx, FLAG_CHECK_UTF8 | FLAG_OWNED
    call    .Linit_ctx
    mov     edi, 500
    call    .Lstart_timer
.p2align 5
.Lb_t2m_deca:
    mov     r12, QWORD PTR [rip + .Lwire_base]
    mov     r14, QWORD PTR [rip + .Larena_base]
    lea     rdi, [rip + .Ltdir_out]
    call    kiln_core_dec_tensors
    mov     rax, QWORD PTR [rip + .Ltdir_out + TDIR_BLOCK_LEN]
    add     QWORD PTR [rbp - 24], rax
    dec     QWORD PTR [rbp - 40]
    jnz     .Lb_t2m_deca
    lea     rdi, [rip + .Lr_t2m_deca]
    mov     rsi, .Lr_t2m_deca_len
    mov     edx, 2097344
    call    .Lemit_bench_row

    leave
    xor     edi, edi
    call    .Lexit_code
.size _start, .-_start

.section .note.GNU-stack,"",@progbits
