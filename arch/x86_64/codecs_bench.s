.intel_syntax noprefix
.include "defs.inc"

.text

# ------------------------------------------------------------------------------
# kiln_core_enc_point: Point { x: i32, y: i32 } (8 B)
#   Inputs: rdi = const kiln_point_t *in
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_point
.type kiln_core_enc_point, @function
kiln_core_enc_point:
    movzx   eax, r15b
    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]
    jae     .Lcb_depth
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 8
    jb      .Lcb_limit
    mov     rax, QWORD PTR [rdi]
    mov     QWORD PTR [r12], rax
    add     r12, 8
    KILN_OK_RET
.Lcb_depth:
    KILN_FAIL KILN_ERR_DEPTH
.Lcb_limit:
    KILN_FAIL KILN_ERR_LIMIT
.Lcb_eof:
    KILN_FAIL KILN_ERR_EOF
.Lcb_type:
    KILN_FAIL KILN_ERR_TYPE
.size kiln_core_enc_point, .-kiln_core_enc_point

# ------------------------------------------------------------------------------
# kiln_core_dec_point: Point { x: i32, y: i32 } (8 B)
#   Inputs: rdi = kiln_point_t *out
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_point
.type kiln_core_dec_point, @function
kiln_core_dec_point:
    movzx   eax, r15b
    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]
    jae     .Lcb_depth
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 8
    jb      .Lcb_eof
    mov     rax, QWORD PTR [r12]
    mov     QWORD PTR [rdi], rax
    add     r12, 8
    KILN_OK_RET
.size kiln_core_dec_point, .-kiln_core_dec_point

# ------------------------------------------------------------------------------
# kiln_core_enc_message
#   Pre-sized single-bounds-check Frozen encoder for the 8-field Message struct:
#   bool, i32, i64, f64, str, bool, i32, str.
#   Inputs: rdi = const kiln_message_t *in
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_message
.type kiln_core_enc_message, @function
kiln_core_enc_message:
    movzx   eax, r15b
    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]
    jae     .Lcb_depth

    mov     r8, QWORD PTR [rdi + MSG_F_STRING_LEN]
    mov     r9, QWORD PTR [rdi + MSG_F_STRING2_LEN]
    mov     rax, QWORD PTR [rbx + CTX_MAX_BYTES]
    cmp     r8, rax
    ja      .Lcb_limit
    cmp     r9, rax
    ja      .Lcb_limit
    mov     ecx, 0xFFFFFFFF
    cmp     r8, rcx
    ja      .Lcb_limit
    cmp     r9, rcx
    ja      .Lcb_limit

    # total wire size = 34 + len1 + len2 (guaranteed no u64 overflow)
    lea     rcx, [r8 + r9 + MSG_WIRE_MIN]
    mov     rax, r13
    sub     rax, r12
    cmp     rax, rcx
    jb      .Lcb_limit

    # Straight-line unaligned LE scalar stores (first 25 bytes)
    movzx   eax, BYTE PTR [rdi + MSG_F_BOOL]
    test    al, al
    setne   al
    mov     BYTE PTR [r12], al
    mov     eax, DWORD PTR [rdi + MSG_F_INT32]
    mov     DWORD PTR [r12 + 1], eax
    mov     rax, QWORD PTR [rdi + MSG_F_INT64]
    mov     QWORD PTR [r12 + 5], rax
    mov     rax, QWORD PTR [rdi + MSG_F_FLOAT64]
    mov     QWORD PTR [r12 + 13], rax
    mov     DWORD PTR [r12 + 21], r8d
    add     r12, 25

    # Copy f_string (r8 bytes)
    mov     rsi, QWORD PTR [rdi + MSG_F_STRING_PTR]
    test    r8, r8
    jz      .Lem_after_s1
    test    r15, FLAG_SLOP32
    jz      .Lem_s1_safe
    cmp     r8, 32
    ja      .Lem_s1_safe
    vmovdqu ymm0, YMMWORD PTR [rsi]
    vmovdqu YMMWORD PTR [r12], ymm0
    vzeroupper
    add     r12, r8
    jmp     .Lem_after_s1

.Lem_s1_safe:
    cmp     r8, 8
    ja      .Lem_s1_call
    cmp     r8, 4
    jb      .Lem_s1_small
    mov     eax, DWORD PTR [rsi]
    mov     ecx, DWORD PTR [rsi + r8 - 4]
    mov     DWORD PTR [r12], eax
    mov     DWORD PTR [r12 + r8 - 4], ecx
    add     r12, r8
    jmp     .Lem_after_s1
.Lem_s1_small:
    cmp     r8, 2
    jb      .Lem_s1_one
    movzx   eax, WORD PTR [rsi]
    movzx   ecx, WORD PTR [rsi + r8 - 2]
    mov     WORD PTR [r12], ax
    mov     WORD PTR [r12 + r8 - 2], cx
    add     r12, r8
    jmp     .Lem_after_s1
.Lem_s1_one:
    movzx   eax, BYTE PTR [rsi]
    mov     BYTE PTR [r12], al
    inc     r12
    jmp     .Lem_after_s1
.Lem_s1_call:
    push    rdi
    push    r9
    mov     rdx, r8
    mov     rdi, r12
    add     r12, r8
    call    kiln_core_memcpy_fast
    pop     r9
    pop     rdi

.Lem_after_s1:
    # Second scalar group (9 bytes: bool + i32 + u32 len2)
    movzx   eax, BYTE PTR [rdi + MSG_F_BOOL_2]
    test    al, al
    setne   al
    mov     BYTE PTR [r12], al
    mov     eax, DWORD PTR [rdi + MSG_F_INT32_2]
    mov     DWORD PTR [r12 + 1], eax
    mov     DWORD PTR [r12 + 5], r9d
    add     r12, 9

    # Copy f_string_2 (r9 bytes)
    mov     rsi, QWORD PTR [rdi + MSG_F_STRING2_PTR]
    test    r9, r9
    jz      .Lem_done
    test    r15, FLAG_SLOP32
    jz      .Lem_s2_safe
    cmp     r9, 32
    ja      .Lem_s2_safe
    vmovdqu ymm0, YMMWORD PTR [rsi]
    vmovdqu YMMWORD PTR [r12], ymm0
    vzeroupper
    add     r12, r9
    jmp     .Lem_done

.Lem_s2_safe:
    cmp     r9, 8
    ja      .Lem_s2_call
    cmp     r9, 4
    jb      .Lem_s2_small
    mov     eax, DWORD PTR [rsi]
    mov     ecx, DWORD PTR [rsi + r9 - 4]
    mov     DWORD PTR [r12], eax
    mov     DWORD PTR [r12 + r9 - 4], ecx
    add     r12, r9
    jmp     .Lem_done
.Lem_s2_small:
    cmp     r9, 2
    jb      .Lem_s2_one
    movzx   eax, WORD PTR [rsi]
    movzx   ecx, WORD PTR [rsi + r9 - 2]
    mov     WORD PTR [r12], ax
    mov     WORD PTR [r12 + r9 - 2], cx
    add     r12, r9
    jmp     .Lem_done
.Lem_s2_one:
    movzx   eax, BYTE PTR [rsi]
    mov     BYTE PTR [r12], al
    inc     r12
    jmp     .Lem_done
.Lem_s2_call:
    mov     rdx, r9
    mov     rdi, r12
    add     r12, r9
    call    kiln_core_memcpy_fast

.Lem_done:
    KILN_OK_RET
.size kiln_core_enc_message, .-kiln_core_enc_message

# ------------------------------------------------------------------------------
# Macro: DEC_MSG_STR_FAST
#   Inlined zero-call fast path for 0..8 B ASCII strings inside kiln_core_dec_message.
#   Preserves rdi (kiln_message_t *out). Falls back to slow_lbl for len > 8 or non-ASCII
#   with r12 still pointing at the u32 length prefix.
# ------------------------------------------------------------------------------
.macro DEC_MSG_STR_FAST ptr_off, len_off, slow_lbl, done_lbl
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      .Lcb_eof
    mov     edx, DWORD PTR [r12]        # len
    cmp     rdx, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      .Lcb_limit
    sub     rcx, 4
    cmp     rdx, rcx
    ja      .Lcb_eof
    cmp     rdx, 8
    ja      \slow_lbl
    cmp     rdx, 4
    jb      1f

    # 4..8 B: overlapping 4 B loads, single-branch SWAR ASCII check, fused copy
    mov     eax, DWORD PTR [r12 + 4]
    mov     ecx, DWORD PTR [r12 + rdx]
    test    r15, FLAG_CHECK_UTF8
    jz      2f
    mov     r8d, eax
    or      r8d, ecx
    test    r8d, 0x80808080
    jnz     \slow_lbl
2:
    test    r15, FLAG_OWNED
    jnz     3f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \ptr_off], r8
    mov     QWORD PTR [rdi + \len_off], rdx
    lea     r12, [r8 + rdx]
    jmp     \done_lbl
3:
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      .Lcb_limit
    mov     DWORD PTR [r14], eax
    mov     DWORD PTR [r14 + rdx - 4], ecx
    mov     QWORD PTR [rdi + \ptr_off], r14
    mov     QWORD PTR [rdi + \len_off], rdx
    add     r14, rdx
    lea     r12, [r12 + rdx + 4]
    jmp     \done_lbl

1:
    test    rdx, rdx
    jnz     4f
    add     r12, 4
    mov     rax, r12
    test    r15, FLAG_OWNED
    cmovnz  rax, r14
    mov     QWORD PTR [rdi + \ptr_off], rax
    mov     QWORD PTR [rdi + \len_off], 0
    jmp     \done_lbl

4:
    cmp     rdx, 2
    jb      6f
    # 2..3 B: overlapping 2 B loads
    movzx   eax, WORD PTR [r12 + 4]
    movzx   ecx, WORD PTR [r12 + rdx + 2]
    test    r15, FLAG_CHECK_UTF8
    jz      5f
    mov     r8d, eax
    or      r8d, ecx
    test    r8d, 0x8080
    jnz     \slow_lbl
5:
    test    r15, FLAG_OWNED
    jnz     7f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \ptr_off], r8
    mov     QWORD PTR [rdi + \len_off], rdx
    lea     r12, [r8 + rdx]
    jmp     \done_lbl
7:
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      .Lcb_limit
    mov     WORD PTR [r14], ax
    mov     WORD PTR [r14 + rdx - 2], cx
    mov     QWORD PTR [rdi + \ptr_off], r14
    mov     QWORD PTR [rdi + \len_off], rdx
    add     r14, rdx
    lea     r12, [r12 + rdx + 4]
    jmp     \done_lbl

6:
    # 1 B
    movzx   eax, BYTE PTR [r12 + 4]
    test    r15, FLAG_CHECK_UTF8
    jz      8f
    test    al, 0x80
    jnz     \slow_lbl
8:
    test    r15, FLAG_OWNED
    jnz     9f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \ptr_off], r8
    mov     QWORD PTR [rdi + \len_off], 1
    add     r12, 5
    jmp     \done_lbl
9:
    cmp     r14, QWORD PTR [rbx + CTX_ARENA_END]
    jae     .Lcb_limit
    mov     BYTE PTR [r14], al
    mov     QWORD PTR [rdi + \ptr_off], r14
    mov     QWORD PTR [rdi + \len_off], 1
    inc     r14
    add     r12, 5
.endm

# ------------------------------------------------------------------------------
# kiln_core_dec_message
#   Checked Frozen decoder for Message with zero-call inlined short-ASCII fast path.
#   Inputs: rdi = kiln_message_t *out
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_message
.type kiln_core_dec_message, @function
kiln_core_dec_message:
    movzx   eax, r15b
    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]
    jae     .Lcb_depth

    # Validate f_bool first for exact field-order error reporting (EOF vs TYPE)
    cmp     r12, r13
    jae     .Lcb_eof
    movzx   eax, BYTE PTR [r12]
    cmp     al, 1
    ja      .Lcb_type
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 21                 # bool(1) + i32(4) + i64(8) + f64(8)
    jb      .Lcb_eof

    mov     BYTE PTR [rdi + MSG_F_BOOL], al
    mov     eax, DWORD PTR [r12 + 1]
    mov     DWORD PTR [rdi + MSG_F_INT32], eax
    mov     rax, QWORD PTR [r12 + 5]
    mov     QWORD PTR [rdi + MSG_F_INT64], rax
    mov     rax, QWORD PTR [r12 + 13]
    mov     QWORD PTR [rdi + MSG_F_FLOAT64], rax
    add     r12, 21

    DEC_MSG_STR_FAST MSG_F_STRING_PTR, MSG_F_STRING_LEN, .Ldm_s1_slow, .Ldm_after_s1

.Ldm_after_s1:
    # f_bool_2 + f_int32_2
    cmp     r12, r13
    jae     .Lcb_eof
    movzx   eax, BYTE PTR [r12]
    cmp     al, 1
    ja      .Lcb_type
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 5
    jb      .Lcb_eof
    mov     BYTE PTR [rdi + MSG_F_BOOL_2], al
    mov     eax, DWORD PTR [r12 + 1]
    mov     DWORD PTR [rdi + MSG_F_INT32_2], eax
    add     r12, 5

    DEC_MSG_STR_FAST MSG_F_STRING2_PTR, MSG_F_STRING2_LEN, .Ldm_s2_slow, .Ldm_done

.Ldm_done:
    KILN_OK_RET

.Ldm_s1_slow:
    push    rdi
    call    kiln_core_dec_str
    pop     rdi
    jc      .Ldm_slow_err
    mov     QWORD PTR [rdi + MSG_F_STRING_PTR], rax
    mov     QWORD PTR [rdi + MSG_F_STRING_LEN], rdx
    jmp     .Ldm_after_s1

.Ldm_s2_slow:
    push    rdi
    call    kiln_core_dec_str
    pop     rdi
    jc      .Ldm_slow_err
    mov     QWORD PTR [rdi + MSG_F_STRING2_PTR], rax
    mov     QWORD PTR [rdi + MSG_F_STRING2_LEN], rdx
    KILN_OK_RET

.Ldm_slow_err:
    stc
    ret
.size kiln_core_dec_message, .-kiln_core_dec_message

# ------------------------------------------------------------------------------
# Framed Message (KLN0 + KILN_HASH_MESSAGE)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_message_framed
.type kiln_core_enc_message_framed, @function
kiln_core_enc_message_framed:
    push    rbp
    mov     rbp, rdi
    movabs  rdi, KILN_HASH_MESSAGE
    call    kiln_core_enc_frame_hdr
    jc      .Lemf_err
    mov     rdi, rbp
    call    kiln_core_enc_message
    pop     rbp
    ret
.Lemf_err:
    pop     rbp
    stc
    ret
.size kiln_core_enc_message_framed, .-kiln_core_enc_message_framed

.p2align 4
.globl kiln_core_dec_message_framed
.type kiln_core_dec_message_framed, @function
kiln_core_dec_message_framed:
    push    rbp
    mov     rbp, rdi
    movabs  rdi, KILN_HASH_MESSAGE
    call    kiln_core_dec_frame_hdr
    jc      .Ldmf_err
    push    rax                     # save hash
    mov     rdi, rbp
    call    kiln_core_dec_message
    jc      .Ldmf_err_pop
    call    kiln_core_check_trailing
    jc      .Ldmf_err_pop
    pop     rax                     # restore hash
    pop     rbp
    clc
    ret
.Ldmf_err_pop:
    add     rsp, 8
.Ldmf_err:
    pop     rbp
    stc
    ret
.size kiln_core_dec_message_framed, .-kiln_core_dec_message_framed

# ------------------------------------------------------------------------------
# Batch: list<Message>
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_batch
.type kiln_core_enc_batch, @function
kiln_core_enc_batch:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                 # -8:items, -16:count, -24:idx
    mov     QWORD PTR [rbp - 8], rdi
    mov     QWORD PTR [rbp - 16], rsi

    call    kiln_core_depth_enter
    jc      .Leb_ret
    mov     rdi, QWORD PTR [rbp - 16]
    call    kiln_core_enc_count
    jc      .Leb_leave_err

    mov     rax, QWORD PTR [rbp - 16]
    shl     rax, 6
    add     rax, QWORD PTR [rbp - 8]
    mov     QWORD PTR [rbp - 24], rax # end_ptr
    mov     rax, QWORD PTR [rbp - 8]
    mov     QWORD PTR [rbp - 32], rax # cur_ptr
.p2align 5
.Leb_loop:
    mov     rdi, QWORD PTR [rbp - 32]
    cmp     rdi, QWORD PTR [rbp - 24]
    jae     .Leb_ok
    add     QWORD PTR [rbp - 32], MSG_SIZE
    call    kiln_core_enc_message
    jc      .Leb_leave_err
    jmp     .Leb_loop

.Leb_ok:
    dec     r15
    leave
    KILN_OK_RET
.Leb_leave_err:
    dec     r15
.Leb_ret:
    leave
    stc
    ret
.size kiln_core_enc_batch, .-kiln_core_enc_batch

.p2align 4
.globl kiln_core_dec_batch
.type kiln_core_dec_batch, @function
kiln_core_dec_batch:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                 # -8:out_arr, -16:count, -24:idx

    call    kiln_core_depth_enter
    jc      .Ldb_ret

    mov     rdi, MSG_WIRE_MIN       # 34 B minimum per Message
    call    kiln_core_dec_count
    jc      .Ldb_leave_err
    mov     QWORD PTR [rbp - 16], rax
    test    rax, rax
    jz      .Ldb_empty

    mov     rdi, rax
    shl     rdi, 6                  # count * 64
    mov     rsi, 8
    call    kiln_core_arena_alloc
    jc      .Ldb_leave_err
    mov     QWORD PTR [rbp - 8], rax
    mov     QWORD PTR [rbp - 32], rax # cur_ptr
    mov     rcx, QWORD PTR [rbp - 16]
    shl     rcx, 6
    add     rcx, rax
    mov     QWORD PTR [rbp - 24], rcx # end_ptr

.p2align 5
.Ldb_loop:
    mov     rdi, QWORD PTR [rbp - 32]
    cmp     rdi, QWORD PTR [rbp - 24]
    jae     .Ldb_done
    add     QWORD PTR [rbp - 32], MSG_SIZE
    call    kiln_core_dec_message
    jc      .Ldb_leave_err
    jmp     .Ldb_loop

.Ldb_empty:
    mov     QWORD PTR [rbp - 8], 0
.Ldb_done:
    dec     r15
    mov     rax, QWORD PTR [rbp - 8]
    mov     rdx, QWORD PTR [rbp - 16]
    leave
    clc
    ret
.Ldb_leave_err:
    dec     r15
.Ldb_ret:
    leave
    stc
    ret
.size kiln_core_dec_batch, .-kiln_core_dec_batch

# ------------------------------------------------------------------------------
# opt<i32>
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_opt_i32
.type kiln_core_enc_opt_i32, @function
kiln_core_enc_opt_i32:
    # rdi = present (0/1), esi = val
    push    rsi
    push    rdi
    call    kiln_core_depth_enter
    pop     rdi
    pop     rsi
    jc      .Leo_ret
    test    dil, dil
    jz      .Leo_none
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 5
    jb      .Leo_limit
    mov     BYTE PTR [r12], 1
    mov     DWORD PTR [r12 + 1], esi
    add     r12, 5
    dec     r15
    KILN_OK_RET
.Leo_none:
    cmp     r12, r13
    jae     .Leo_limit
    mov     BYTE PTR [r12], 0
    inc     r12
    dec     r15
    KILN_OK_RET
.Leo_limit:
    dec     r15
    KILN_FAIL KILN_ERR_LIMIT
.Leo_ret:
    stc
    ret
.size kiln_core_enc_opt_i32, .-kiln_core_enc_opt_i32

.p2align 4
.globl kiln_core_dec_opt_i32
.type kiln_core_dec_opt_i32, @function
kiln_core_dec_opt_i32:
    # Outputs: CF=0, eax = present (0/1), edx = val (0 if absent)
    call    kiln_core_depth_enter
    jc      .Ldo_ret
    call    kiln_core_dec_bool      # tag 0/1, >= 2 => TYPE
    jc      .Ldo_leave_err
    test    eax, eax
    jz      .Ldo_none
    call    kiln_core_dec_u32
    jc      .Ldo_leave_err
    mov     edx, eax
    mov     eax, 1
    dec     r15
    clc
    ret
.Ldo_none:
    xor     edx, edx
    dec     r15
    clc
    ret
.Ldo_leave_err:
    dec     r15
.Ldo_ret:
    stc
    ret
.size kiln_core_dec_opt_i32, .-kiln_core_dec_opt_i32

# ------------------------------------------------------------------------------
# Frozen list codecs for kiln-v2-cases.json: list<f32>, list<str>, list<struct{a:i64}>
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_list_f32
.type kiln_core_enc_list_f32, @function
kiln_core_enc_list_f32:
    # rdi = const uint32_t *bits, rsi = count
    push    rdi
    push    rsi
    call    kiln_core_depth_enter
    pop     rsi
    pop     rdi
    jc      .Lelf_ret
    cmp     rsi, QWORD PTR [rbx + CTX_MAX_COUNT]
    ja      .Lelf_limit
    mov     eax, 0xFFFFFFFF
    cmp     rsi, rax
    ja      .Lelf_limit
    lea     rdx, [rsi * 4]
    lea     rcx, [rdx + 4]
    mov     rax, r13
    sub     rax, r12
    cmp     rax, rcx
    jb      .Lelf_limit
    mov     DWORD PTR [r12], esi
    add     r12, 4
    test    rdx, rdx
    jz      .Lelf_ok
    mov     rsi, rdi
    mov     rdi, r12
    add     r12, rdx
    call    kiln_core_memcpy_fast
.Lelf_ok:
    dec     r15
    KILN_OK_RET
.Lelf_limit:
    dec     r15
    KILN_FAIL KILN_ERR_LIMIT
.Lelf_ret:
    stc
    ret
.size kiln_core_enc_list_f32, .-kiln_core_enc_list_f32

.p2align 4
.globl kiln_core_dec_list_f32
.type kiln_core_dec_list_f32, @function
kiln_core_dec_list_f32:
    # Outputs: CF=0, rax = raw f32 ptr, rdx = count
    call    kiln_core_depth_enter
    jc      .Ldlf_ret
    mov     rdi, 4
    call    kiln_core_dec_count
    jc      .Ldlf_leave_err
    mov     r8, rax                 # count
    lea     r9, [rax * 4]           # nbytes
    test    r15, FLAG_OWNED
    jnz     .Ldlf_owned
    mov     rax, r12
    add     r12, r9
    mov     rdx, r8
    dec     r15
    clc
    ret
.Ldlf_owned:
    push    r8
    push    r9
    mov     rdi, r9
    mov     rsi, 4
    call    kiln_core_arena_alloc
    pop     r9
    pop     r8
    jc      .Ldlf_leave_err
    push    rax
    push    r8
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, r9
    add     r12, r9
    call    kiln_core_memcpy_fast
    pop     rdx
    pop     rax
    dec     r15
    clc
    ret
.Ldlf_leave_err:
    dec     r15
.Ldlf_ret:
    stc
    ret
.size kiln_core_dec_list_f32, .-kiln_core_dec_list_f32

.p2align 4
.globl kiln_core_dec_list_str
.type kiln_core_dec_list_str, @function
kiln_core_dec_list_str:
    # Outputs: CF=0, rax = kiln_str_t*, rdx = count
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                 # -8:arr, -16:count, -24:idx
    call    kiln_core_depth_enter
    jc      .Ldls_ret
    mov     rdi, 4                  # min(str) = 4
    call    kiln_core_dec_count
    jc      .Ldls_leave_err
    mov     QWORD PTR [rbp - 16], rax
    test    rax, rax
    jz      .Ldls_empty
    mov     rdi, rax
    shl     rdi, 4                  # count * 16
    mov     rsi, 8
    call    kiln_core_arena_alloc
    jc      .Ldls_leave_err
    mov     QWORD PTR [rbp - 8], rax
    mov     QWORD PTR [rbp - 24], 0
.Ldls_loop:
    mov     rax, QWORD PTR [rbp - 24]
    cmp     rax, QWORD PTR [rbp - 16]
    jae     .Ldls_done
    call    kiln_core_dec_str
    jc      .Ldls_leave_err
    mov     r8, QWORD PTR [rbp - 24]
    shl     r8, 4
    add     r8, QWORD PTR [rbp - 8]
    mov     QWORD PTR [r8 + STR_PTR], rax
    mov     QWORD PTR [r8 + STR_LEN], rdx
    inc     QWORD PTR [rbp - 24]
    jmp     .Ldls_loop
.Ldls_empty:
    mov     QWORD PTR [rbp - 8], 0
.Ldls_done:
    dec     r15
    mov     rax, QWORD PTR [rbp - 8]
    mov     rdx, QWORD PTR [rbp - 16]
    leave
    clc
    ret
.Ldls_leave_err:
    dec     r15
.Ldls_ret:
    leave
    stc
    ret
.size kiln_core_dec_list_str, .-kiln_core_dec_list_str

.p2align 4
.globl kiln_core_dec_list_i64_struct
.type kiln_core_dec_list_i64_struct, @function
kiln_core_dec_list_i64_struct:
    # Outputs: CF=0, rax = raw i64 ptr, rdx = count
    call    kiln_core_depth_enter
    jc      .Ldli_ret
    mov     rdi, 8                  # min(struct{a:i64}) = 8
    call    kiln_core_dec_count
    jc      .Ldli_leave_err
    mov     r8, rax                 # count
    lea     r9, [rax * 8]           # nbytes
    test    r15, FLAG_OWNED
    jnz     .Ldli_owned
    mov     rax, r12
    add     r12, r9
    mov     rdx, r8
    dec     r15
    clc
    ret
.Ldli_owned:
    push    r8
    push    r9
    mov     rdi, r9
    mov     rsi, 8
    call    kiln_core_arena_alloc
    pop     r9
    pop     r8
    jc      .Ldli_leave_err
    push    rax
    push    r8
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, r9
    add     r12, r9
    call    kiln_core_memcpy_fast
    pop     rdx
    pop     rax
    dec     r15
    clc
    ret
.Ldli_leave_err:
    dec     r15
.Ldli_ret:
    stc
    ret
.size kiln_core_dec_list_i64_struct, .-kiln_core_dec_list_i64_struct

.section .note.GNU-stack,"",@progbits
