.intel_syntax noprefix
.include "defs.inc"

.section .rodata
.Lver_str:        .asciz "0.1.0"
.Lerr_ok:         .asciz "OK"
.Lerr_frame:      .asciz "FRAME"
.Lerr_schema:     .asciz "SCHEMA"
.Lerr_limit:      .asciz "LIMIT"
.Lerr_eof:        .asciz "EOF"
.Lerr_type:       .asciz "TYPE"
.Lerr_utf8:       .asciz "UTF8"
.Lerr_trailing:   .asciz "TRAILING"
.Lerr_depth:      .asciz "DEPTH"
.Lerr_unknown:    .asciz "UNKNOWN"

.p2align 2
.Lerr_table:
    .long .Lerr_ok - .Lerr_table
    .long .Lerr_frame - .Lerr_table
    .long .Lerr_schema - .Lerr_table
    .long .Lerr_limit - .Lerr_table
    .long .Lerr_eof - .Lerr_table
    .long .Lerr_type - .Lerr_table
    .long .Lerr_utf8 - .Lerr_table
    .long .Lerr_trailing - .Lerr_table
    .long .Lerr_depth - .Lerr_table

.Ldt_f64:    .asciz "f64"
.Ldt_f32:    .asciz "f32"
.Ldt_f16:    .asciz "f16"
.Ldt_bf16:   .asciz "bf16"
.Ldt_f8e4m3: .asciz "f8e4m3"
.Ldt_f8e5m2: .asciz "f8e5m2"
.Ldt_bool:   .asciz "bool"
.Ldt_i8:     .asciz "i8"
.Ldt_u8:     .asciz "u8"
.Ldt_i16:    .asciz "i16"
.Ldt_u16:    .asciz "u16"
.Ldt_i32:    .asciz "i32"
.Ldt_u32:    .asciz "u32"
.Ldt_i64:    .asciz "i64"
.Ldt_u64:    .asciz "u64"
.Ldt_i4:     .asciz "i4"
.Ldt_u4:     .asciz "u4"
.Ldt_e2m1:   .asciz "e2m1"
.Ldt_e8m0:   .asciz "e8m0"

.p2align 2
.Ldtype_table:
    .long 0
    .long .Ldt_f64 - .Ldtype_table
    .long .Ldt_f32 - .Ldtype_table
    .long .Ldt_f16 - .Ldtype_table
    .long .Ldt_bf16 - .Ldtype_table
    .long .Ldt_f8e4m3 - .Ldtype_table
    .long .Ldt_f8e5m2 - .Ldtype_table
    .long .Ldt_bool - .Ldtype_table
    .long .Ldt_i8 - .Ldtype_table
    .long .Ldt_u8 - .Ldtype_table
    .long .Ldt_i16 - .Ldtype_table
    .long .Ldt_u16 - .Ldtype_table
    .long .Ldt_i32 - .Ldtype_table
    .long .Ldt_u32 - .Ldtype_table
    .long .Ldt_i64 - .Ldtype_table
    .long .Ldt_u64 - .Ldtype_table
    .long .Ldt_i4 - .Ldtype_table
    .long .Ldt_u4 - .Ldtype_table
    .long .Ldt_e2m1 - .Ldtype_table
    .long .Ldt_e8m0 - .Ldtype_table

.text

# ------------------------------------------------------------------------------
# Metadata & direct primitives
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_version
.type kiln_asm_version, @function
kiln_asm_version:
    lea     rax, [rip + .Lver_str]
    ret
.size kiln_asm_version, .-kiln_asm_version

.p2align 4
.globl kiln_asm_err_name
.type kiln_asm_err_name, @function
kiln_asm_err_name:
    cmp     edi, KILN_ERR_DEPTH
    ja      .Len_unk
    mov     eax, edi
    lea     rcx, [rip + .Lerr_table]
    movsxd  rax, DWORD PTR [rcx + rax * 4]
    add     rax, rcx
    ret
.Len_unk:
    lea     rax, [rip + .Lerr_unknown]
    ret
.size kiln_asm_err_name, .-kiln_asm_err_name

.p2align 4
.globl kiln_asm_dtype_name
.type kiln_asm_dtype_name, @function
kiln_asm_dtype_name:
    movzx   eax, di
    test    eax, eax
    jz      .Ldtn_null
    cmp     eax, 19
    ja      .Ldtn_null
    lea     rcx, [rip + .Ldtype_table]
    movsxd  rax, DWORD PTR [rcx + rax * 4]
    add     rax, rcx
    ret
.Ldtn_null:
    xor     eax, eax
    ret
.size kiln_asm_dtype_name, .-kiln_asm_dtype_name

.p2align 4
.globl kiln_asm_utf8_ok
.type kiln_asm_utf8_ok, @function
kiln_asm_utf8_ok:
    jmp     kiln_core_utf8_validate
.size kiln_asm_utf8_ok, .-kiln_asm_utf8_ok

.p2align 4
.globl kiln_asm_fnv1a_mix_token
.type kiln_asm_fnv1a_mix_token, @function
kiln_asm_fnv1a_mix_token:
    jmp     kiln_core_fnv1a_mix_token
.size kiln_asm_fnv1a_mix_token, .-kiln_asm_fnv1a_mix_token

# ------------------------------------------------------------------------------
# Internal helper: .Lsetup_ctx
#   Inputs: rbx = ctx*, rdi = base, rsi = len, rdx = arena* (or 0), rcx = opts* (or 0)
#   Sets:   r12=base, r13=base+len, r14=arena_cur, r15=flags, populates *rbx
# ------------------------------------------------------------------------------
.p2align 4
.Lsetup_ctx:
    mov     r12, rdi
    lea     r13, [rdi + rsi]
    mov     QWORD PTR [rbx + CTX_BASE_PTR], rdi

    xor     r14, r14
    mov     QWORD PTR [rbx + CTX_ARENA_END], r14
    test    rdx, rdx
    jz      .Lsc_no_arena
    mov     r14, QWORD PTR [rdx + ARENA_CUR]
    mov     rax, QWORD PTR [rdx + ARENA_END]
    mov     QWORD PTR [rbx + CTX_ARENA_END], rax
.Lsc_no_arena:

    mov     rax, KILN_CAP_DEFAULT
    mov     QWORD PTR [rbx + CTX_MAX_COUNT], rax
    mov     QWORD PTR [rbx + CTX_MAX_BYTES], rax
    mov     QWORD PTR [rbx + CTX_MAX_DEPTH], KILN_DEPTH_DEFAULT
    mov     r15, FLAG_CHECK_UTF8

    test    rcx, rcx
    jz      .Lsc_done

    mov     rax, QWORD PTR [rcx + OPTS_MAX_COUNT]
    test    rax, rax
    jz      .Lsc_mc_def
    mov     QWORD PTR [rbx + CTX_MAX_COUNT], rax
.Lsc_mc_def:
    mov     rax, QWORD PTR [rcx + OPTS_MAX_BYTES]
    test    rax, rax
    jz      .Lsc_mb_def
    mov     QWORD PTR [rbx + CTX_MAX_BYTES], rax
.Lsc_mb_def:
    mov     eax, DWORD PTR [rcx + OPTS_MAX_DEPTH]
    test    eax, eax
    jz      .Lsc_md_def
    cmp     eax, 255
    jbe     .Lsc_md_ok
    mov     eax, 255
.Lsc_md_ok:
    mov     QWORD PTR [rbx + CTX_MAX_DEPTH], rax
.Lsc_md_def:
    mov     eax, DWORD PTR [rcx + OPTS_FLAGS]
    test    eax, KILN_OPT_TRUSTED
    jz      .Lsc_f_owned
    and     r15, ~FLAG_CHECK_UTF8
.Lsc_f_owned:
    test    eax, KILN_OPT_OWNED
    jz      .Lsc_f_slop
    or      r15, FLAG_OWNED
.Lsc_f_slop:
    test    eax, KILN_OPT_SLOP32
    jz      .Lsc_f_emb
    or      r15, FLAG_SLOP32
.Lsc_f_emb:
    test    eax, KILN_OPT_EMBEDDED
    jz      .Lsc_f_avx2
    or      r15, FLAG_EMBEDDED
.Lsc_f_avx2:
    test    eax, KILN_OPT_COPY_AVX2
    jz      .Lsc_f_nt
    or      r15, FLAG_COPY_AVX2
.Lsc_f_nt:
    test    eax, KILN_OPT_COPY_NT
    jz      .Lsc_done
    or      r15, FLAG_COPY_NT
.Lsc_done:
    ret

# Frame prologue/epilogue macros for System V AMD64 wrappers:
#   [rbp - 40 .. rbp - 8]  : saved rbx, r12..r15
#   [rbp - 80 .. rbp - 41] : kiln_ctx_t (40 B)
#   [rbp - 88], [rbp - 96], [rbp - 104], [rbp - 112] : 4 local spill slots
#   [rbp + 16]             : 7th C argument (if present)
.macro ABI_PROLOGUE
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72                 # 5*8 + 72 = 112 (16-byte aligned)
    lea     rbx, [rbp - 80]
.endm

.macro ABI_EPILOGUE
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
.endm

# Helper to store res (rdi = res*, rsi = hash, eax = err, rdx = err_off, CF = err_flag)
.p2align 4
.Lfinish_res_nohash:
    mov     esi, 0                  # mov preserves CF!
.Lfinish_res:
    jc      .Lfr_err
    test    rdi, rdi
    jz      .Lfr_ok_ret
    mov     rcx, r12
    sub     rcx, QWORD PTR [rbx + CTX_BASE_PTR]
    mov     QWORD PTR [rdi + RES_BYTES], rcx
    mov     QWORD PTR [rdi + RES_HASH], rsi
.Lfr_ok_ret:
    xor     eax, eax
    ret
.Lfr_err:
    test    rdi, rdi
    jz      .Lfr_err_ret
    mov     QWORD PTR [rdi + RES_BYTES], rdx
    mov     QWORD PTR [rdi + RES_HASH], 0
.Lfr_err_ret:
    ret

# ------------------------------------------------------------------------------
# kiln_asm_encode_point(in, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_point
.type kiln_asm_encode_point, @function
kiln_asm_encode_point:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # in
    mov     QWORD PTR [rbp - 96], r8    # res
    mov     rdi, rsi                    # dst
    mov     rsi, rdx                    # cap
    xor     rdx, rdx                    # no arena
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_point
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_point, .-kiln_asm_encode_point

# ------------------------------------------------------------------------------
# kiln_asm_decode_point(src, len, out, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_point
.type kiln_asm_decode_point, @function
kiln_asm_decode_point:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # out
    mov     QWORD PTR [rbp - 96], r8    # res
    xor     rdx, rdx                    # no arena
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_point
    jc      .Ldp_fin
    call    kiln_core_check_trailing
.Ldp_fin:
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_decode_point, .-kiln_asm_decode_point

# ------------------------------------------------------------------------------
# kiln_asm_encode_message(in, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_message
.type kiln_asm_encode_message, @function
kiln_asm_encode_message:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # in
    mov     QWORD PTR [rbp - 96], r8    # res
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_message
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_message, .-kiln_asm_encode_message

# ------------------------------------------------------------------------------
# kiln_asm_decode_message(src, len, out, arena, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_message
.type kiln_asm_decode_message, @function
kiln_asm_decode_message:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # out
    mov     QWORD PTR [rbp - 96], rcx   # arena
    mov     QWORD PTR [rbp - 104], r9   # res
    mov     rdx, rcx                    # arena
    mov     rcx, r8                     # opts
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_message
    jc      .Ldm_c_err
    call    kiln_core_check_trailing
    jc      .Ldm_c_err
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldm_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldm_c_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldm_c_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldm_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldm_c_err_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_message, .-kiln_asm_decode_message

# ------------------------------------------------------------------------------
# kiln_asm_encode_message_framed(in, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_message_framed
.type kiln_asm_encode_message_framed, @function
kiln_asm_encode_message_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], r8
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_message_framed
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_message_framed, .-kiln_asm_encode_message_framed

# ------------------------------------------------------------------------------
# kiln_asm_decode_message_framed(src, len, out, arena, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_message_framed
.type kiln_asm_decode_message_framed, @function
kiln_asm_decode_message_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # out
    mov     QWORD PTR [rbp - 96], rcx   # arena
    mov     QWORD PTR [rbp - 104], r9   # res
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_message_framed
    jc      .Ldmf_c_err
    mov     rsi, rax                    # decoded schema hash
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldmf_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldmf_c_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldmf_c_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldmf_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldmf_c_err_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_message_framed, .-kiln_asm_decode_message_framed

# ------------------------------------------------------------------------------
# kiln_asm_encode_batch(items, count, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_batch
.type kiln_asm_encode_batch, @function
kiln_asm_encode_batch:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # items
    mov     QWORD PTR [rbp - 96], rsi   # count
    mov     QWORD PTR [rbp - 104], r9   # res
    mov     rdi, rdx                    # dst
    mov     rsi, rcx                    # cap
    xor     rdx, rdx
    mov     rcx, r8                     # opts
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    mov     rsi, QWORD PTR [rbp - 96]
    call    kiln_core_enc_batch
    mov     rdi, QWORD PTR [rbp - 104]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_batch, .-kiln_asm_encode_batch

# ------------------------------------------------------------------------------
# kiln_asm_decode_batch(src, len, out_items, out_count, arena, opts, res=[rbp+16])
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_batch
.type kiln_asm_decode_batch, @function
kiln_asm_decode_batch:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # out_items
    mov     QWORD PTR [rbp - 96], rcx   # out_count
    mov     QWORD PTR [rbp - 104], r8   # arena
    mov     rdx, r8                     # arena
    mov     rcx, r9                     # opts
    call    .Lsetup_ctx
    call    kiln_core_dec_batch         # rax=items, rdx=count
    jc      .Ldb_c_err
    mov     QWORD PTR [rbp - 112], rax
    push    rdx
    call    kiln_core_check_trailing
    pop     r9                          # count
    jc      .Ldb_c_err
    mov     rcx, QWORD PTR [rbp - 88]
    mov     r8, QWORD PTR [rbp - 112]
    mov     QWORD PTR [rcx], r8
    mov     rcx, QWORD PTR [rbp - 96]
    mov     QWORD PTR [rcx], r9
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldb_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldb_c_ok:
    mov     rdi, QWORD PTR [rbp + 16]   # res
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldb_c_err:
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldb_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldb_c_err_fin:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_batch, .-kiln_asm_decode_batch

# ------------------------------------------------------------------------------
# kiln_asm_encode_opt_i32(present, val, dst, cap, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_opt_i32
.type kiln_asm_encode_opt_i32, @function
kiln_asm_encode_opt_i32:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # present
    mov     QWORD PTR [rbp - 96], rsi   # val
    mov     QWORD PTR [rbp - 104], r8   # res
    mov     rdi, rdx                    # dst
    mov     rsi, rcx                    # cap
    xor     rdx, rdx
    xor     rcx, rcx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    mov     rsi, QWORD PTR [rbp - 96]
    call    kiln_core_enc_opt_i32
    mov     rdi, QWORD PTR [rbp - 104]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_opt_i32, .-kiln_asm_encode_opt_i32

# ------------------------------------------------------------------------------
# kiln_asm_decode_opt_i32(src, len, present_out, val_out, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_opt_i32
.type kiln_asm_decode_opt_i32, @function
kiln_asm_decode_opt_i32:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # present_out
    mov     QWORD PTR [rbp - 96], rcx   # val_out
    mov     QWORD PTR [rbp - 104], r9   # res
    xor     rdx, rdx
    mov     rcx, r8                     # opts
    call    .Lsetup_ctx
    call    kiln_core_dec_opt_i32       # eax=present, edx=val
    jc      .Ldo_c_err
    mov     DWORD PTR [rbp - 108], eax
    mov     DWORD PTR [rbp - 112], edx
    call    kiln_core_check_trailing
    jc      .Ldo_c_err
    mov     rcx, QWORD PTR [rbp - 88]
    mov     eax, DWORD PTR [rbp - 108]
    mov     DWORD PTR [rcx], eax
    mov     rcx, QWORD PTR [rbp - 96]
    mov     edx, DWORD PTR [rbp - 112]
    mov     DWORD PTR [rcx], edx
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldo_c_err:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_opt_i32, .-kiln_asm_decode_opt_i32

# ------------------------------------------------------------------------------
# kiln_asm_encode_dict_i64(entries, count, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_dict_i64
.type kiln_asm_encode_dict_i64, @function
kiln_asm_encode_dict_i64:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], rsi
    mov     QWORD PTR [rbp - 104], r9
    mov     rdi, rdx
    mov     rsi, rcx
    xor     rdx, rdx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    mov     rsi, QWORD PTR [rbp - 96]
    call    kiln_core_enc_dict_i64
    mov     rdi, QWORD PTR [rbp - 104]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_dict_i64, .-kiln_asm_encode_dict_i64

# ------------------------------------------------------------------------------
# kiln_asm_decode_dict_i64(src, len, out_entries, out_count, arena, opts, res=[rbp+16])
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_decode_dict_i64
.type kiln_asm_decode_dict_i64, @function
kiln_asm_decode_dict_i64:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r8
    mov     rdx, r8
    mov     rcx, r9
    call    .Lsetup_ctx
    call    kiln_core_dec_dict_i64
    jc      .Ldd_c_err
    mov     QWORD PTR [rbp - 112], rax
    push    rdx
    call    kiln_core_check_trailing
    pop     r9
    jc      .Ldd_c_err
    mov     rcx, QWORD PTR [rbp - 88]
    mov     r8, QWORD PTR [rbp - 112]
    mov     QWORD PTR [rcx], r8
    mov     rcx, QWORD PTR [rbp - 96]
    mov     QWORD PTR [rcx], r9
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldd_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldd_c_ok:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldd_c_err:
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldd_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldd_c_err_fin:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_dict_i64, .-kiln_asm_decode_dict_i64

# ------------------------------------------------------------------------------
# kiln_asm_encode_list_f32(bits, count, dst, cap, opts, res)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_list_f32
.type kiln_asm_encode_list_f32, @function
kiln_asm_encode_list_f32:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], rsi
    mov     QWORD PTR [rbp - 104], r9
    mov     rdi, rdx
    mov     rsi, rcx
    xor     rdx, rdx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    mov     rsi, QWORD PTR [rbp - 96]
    call    kiln_core_enc_list_f32
    mov     rdi, QWORD PTR [rbp - 104]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_list_f32, .-kiln_asm_encode_list_f32

# ------------------------------------------------------------------------------
# Shared wrapper macro for 7-arg list decoders:
#   fn(src, len, ptr_out, count_out, arena, opts, res=[rbp+16])
# ------------------------------------------------------------------------------
.macro DEFINE_LIST_DEC_WRAPPER name, core_fn
.p2align 4
.globl \name
.type \name, @function
\name:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r8
    mov     rdx, r8
    mov     rcx, r9
    call    .Lsetup_ctx
    call    \core_fn
    jc      1f
    mov     QWORD PTR [rbp - 112], rax
    push    rdx
    call    kiln_core_check_trailing
    pop     r9
    jc      1f
    mov     rcx, QWORD PTR [rbp - 88]
    mov     r8, QWORD PTR [rbp - 112]
    mov     QWORD PTR [rcx], r8
    mov     rcx, QWORD PTR [rbp - 96]
    mov     QWORD PTR [rcx], r9
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      2f
    mov     QWORD PTR [rcx + ARENA_CUR], r14
2:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
1:
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      3f
    mov     QWORD PTR [rcx + ARENA_CUR], r14
3:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size \name, .-\name
.endm

DEFINE_LIST_DEC_WRAPPER kiln_asm_decode_list_f32,        kiln_core_dec_list_f32
DEFINE_LIST_DEC_WRAPPER kiln_asm_decode_list_str,        kiln_core_dec_list_str
DEFINE_LIST_DEC_WRAPPER kiln_asm_decode_list_i64_struct, kiln_core_dec_list_i64_struct

# ------------------------------------------------------------------------------
# KLNT v2 Tensor Directory & struct{id:i64,batch:tensors,} C ABI wrappers
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_asm_encode_tensors
.type kiln_asm_encode_tensors, @function
kiln_asm_encode_tensors:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # in
    mov     QWORD PTR [rbp - 96], r8    # res
    mov     rdi, rsi                    # dst
    mov     rsi, rdx                    # cap
    xor     rdx, rdx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_tensors
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_tensors, .-kiln_asm_encode_tensors

.p2align 4
.globl kiln_asm_decode_tensors
.type kiln_asm_decode_tensors, @function
kiln_asm_decode_tensors:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx   # out
    mov     QWORD PTR [rbp - 96], rcx   # arena
    mov     QWORD PTR [rbp - 104], r9   # res
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_tensors
    jc      .Ldt_c_err
    call    kiln_core_check_trailing
    jc      .Ldt_c_err
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldt_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldt_c_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldt_c_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldt_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldt_c_err_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_tensors, .-kiln_asm_decode_tensors

.p2align 4
.globl kiln_asm_encode_id_tensors
.type kiln_asm_encode_id_tensors, @function
kiln_asm_encode_id_tensors:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], r8
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_id_tensors
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_id_tensors, .-kiln_asm_encode_id_tensors

.p2align 4
.globl kiln_asm_decode_id_tensors
.type kiln_asm_decode_id_tensors, @function
kiln_asm_decode_id_tensors:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r9
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_id_tensors
    jc      .Ldit_c_err
    call    kiln_core_check_trailing
    jc      .Ldit_c_err
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldit_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldit_c_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Ldit_c_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldit_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldit_c_err_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_id_tensors, .-kiln_asm_decode_id_tensors

.p2align 4
.globl kiln_asm_encode_id_tensors_framed
.type kiln_asm_encode_id_tensors_framed, @function
kiln_asm_encode_id_tensors_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], r8
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_id_tensors_framed
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lfinish_res_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_id_tensors_framed, .-kiln_asm_encode_id_tensors_framed

.p2align 4
.globl kiln_asm_decode_id_tensors_framed
.type kiln_asm_decode_id_tensors_framed, @function
kiln_asm_decode_id_tensors_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r9
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lsetup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_id_tensors_framed
    jc      .Lditf_c_err
    mov     rsi, rax                    # decoded hash
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Lditf_c_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Lditf_c_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    clc
    call    .Lfinish_res
    ABI_EPILOGUE
.Lditf_c_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Lditf_c_err_fin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Lditf_c_err_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lfinish_res
    ABI_EPILOGUE
.size kiln_asm_decode_id_tensors_framed, .-kiln_asm_decode_id_tensors_framed

.section .note.GNU-stack,"",@progbits
