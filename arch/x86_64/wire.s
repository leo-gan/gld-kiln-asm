.intel_syntax noprefix
.include "defs.inc"

.text

# ------------------------------------------------------------------------------
# kiln_core_memcpy_fast
#   Safe, non-overlapping memory copy with branchless small-size buckets (1..32B)
#   and hardware ERMS/FSRM rep movsb for > 32 B. Never reads/writes past len.
#   Inputs:  rdi = dst, rsi = src, rdx = len
#   Preserves: rbx, rbp, r12, r13, r14, r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_memcpy_fast
.type kiln_core_memcpy_fast, @function
kiln_core_memcpy_fast:
    test    rdx, rdx
    jz      .Lmc_done
    cmp     rdx, 32
    ja      .Lmc_large
    cmp     rdx, 16
    ja      .Lmc_17_32
    cmp     rdx, 8
    ja      .Lmc_9_16
    cmp     rdx, 4
    jae     .Lmc_4_8
    cmp     rdx, 2
    jae     .Lmc_2_3
    movzx   eax, BYTE PTR [rsi]
    mov     BYTE PTR [rdi], al
    ret

.Lmc_2_3:
    movzx   eax, WORD PTR [rsi]
    movzx   ecx, WORD PTR [rsi + rdx - 2]
    mov     WORD PTR [rdi], ax
    mov     WORD PTR [rdi + rdx - 2], cx
    ret

.Lmc_4_8:
    mov     eax, DWORD PTR [rsi]
    mov     ecx, DWORD PTR [rsi + rdx - 4]
    mov     DWORD PTR [rdi], eax
    mov     DWORD PTR [rdi + rdx - 4], ecx
    ret

.Lmc_9_16:
    mov     rax, QWORD PTR [rsi]
    mov     rcx, QWORD PTR [rsi + rdx - 8]
    mov     QWORD PTR [rdi], rax
    mov     QWORD PTR [rdi + rdx - 8], rcx
    ret

.Lmc_17_32:
    vmovdqu xmm0, XMMWORD PTR [rsi]
    vmovdqu xmm1, XMMWORD PTR [rsi + rdx - 16]
    vmovdqu XMMWORD PTR [rdi], xmm0
    vmovdqu XMMWORD PTR [rdi + rdx - 16], xmm1
    ret

.Lmc_large:
    mov     rcx, rdx
    rep movsb
.Lmc_done:
    ret
.size kiln_core_memcpy_fast, .-kiln_core_memcpy_fast

# ------------------------------------------------------------------------------
# kiln_core_memcpy_avx2 / kiln_core_memcpy_nt / kiln_core_memcpy_bulk
#   A/B bulk copy kernels for KLNT tensor payloads (ERMS vs AVX2 vs vmovntdq).
#   Inputs: rdi = dst, rsi = src, rdx = len
#   Preserves: rbx, rbp, r12..r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_memcpy_avx2
.type kiln_core_memcpy_avx2, @function
kiln_core_memcpy_avx2:
    cmp     rdx, 128
    jb      kiln_core_memcpy_fast
.p2align 5
.Lmca_loop:
    vmovdqu ymm0, YMMWORD PTR [rsi]
    vmovdqu ymm1, YMMWORD PTR [rsi + 32]
    vmovdqu ymm2, YMMWORD PTR [rsi + 64]
    vmovdqu ymm3, YMMWORD PTR [rsi + 96]
    vmovdqu YMMWORD PTR [rdi], ymm0
    vmovdqu YMMWORD PTR [rdi + 32], ymm1
    vmovdqu YMMWORD PTR [rdi + 64], ymm2
    vmovdqu YMMWORD PTR [rdi + 96], ymm3
    add     rsi, 128
    add     rdi, 128
    sub     rdx, 128
    cmp     rdx, 128
    jae     .Lmca_loop
    vzeroupper
    jmp     kiln_core_memcpy_fast
.size kiln_core_memcpy_avx2, .-kiln_core_memcpy_avx2

.p2align 4
.globl kiln_core_memcpy_nt
.type kiln_core_memcpy_nt, @function
kiln_core_memcpy_nt:
    cmp     rdx, 256
    jb      kiln_core_memcpy_fast
    # Align dst (rdi) to 32-byte boundary for vmovntdq
    mov     rcx, rdi
    and     rcx, 31
    jz      .Lmcn_aligned
    mov     rax, 32
    sub     rax, rcx
    mov     rcx, rax
    sub     rdx, rax
    rep movsb
.Lmcn_aligned:
    cmp     rdx, 128
    jb      .Lmcn_tail
.p2align 5
.Lmcn_loop:
    vmovdqu  ymm0, YMMWORD PTR [rsi]
    vmovdqu  ymm1, YMMWORD PTR [rsi + 32]
    vmovdqu  ymm2, YMMWORD PTR [rsi + 64]
    vmovdqu  ymm3, YMMWORD PTR [rsi + 96]
    vmovntdq YMMWORD PTR [rdi], ymm0
    vmovntdq YMMWORD PTR [rdi + 32], ymm1
    vmovntdq YMMWORD PTR [rdi + 64], ymm2
    vmovntdq YMMWORD PTR [rdi + 96], ymm3
    add     rsi, 128
    add     rdi, 128
    sub     rdx, 128
    cmp     rdx, 128
    jae     .Lmcn_loop
    sfence
    vzeroupper
.Lmcn_tail:
    jmp     kiln_core_memcpy_fast
.size kiln_core_memcpy_nt, .-kiln_core_memcpy_nt

.p2align 4
.globl kiln_core_memcpy_bulk
.type kiln_core_memcpy_bulk, @function
kiln_core_memcpy_bulk:
    test    r15, FLAG_COPY_NT
    jnz     kiln_core_memcpy_nt
    test    r15, FLAG_COPY_AVX2
    jnz     kiln_core_memcpy_avx2
    jmp     kiln_core_memcpy_fast
.size kiln_core_memcpy_bulk, .-kiln_core_memcpy_bulk

# ------------------------------------------------------------------------------
# kiln_core_cmp_bytes
#   Unsigned lexicographic comparison of byte slices A[rdi, rsi) vs B[rdx, rcx).
#   Returns: eax = -1 (A < B), 0 (A == B), +1 (A > B)
#   Preserves: rbx, rbp, r12, r13, r14, r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_cmp_bytes
.type kiln_core_cmp_bytes, @function
kiln_core_cmp_bytes:
    mov     r8, rsi
    cmp     r8, rcx
    cmova   r8, rcx                 # r8 = min(lenA, lenB)
    xor     r9, r9
.Lcmp_loop:
    cmp     r9, r8
    jae     .Lcmp_len
    movzx   eax, BYTE PTR [rdi + r9]
    movzx   r10d, BYTE PTR [rdx + r9]
    cmp     eax, r10d
    jb      .Lcmp_lt
    ja      .Lcmp_gt
    inc     r9
    jmp     .Lcmp_loop
.Lcmp_len:
    cmp     rsi, rcx
    jb      .Lcmp_lt
    ja      .Lcmp_gt
    xor     eax, eax
    ret
.Lcmp_lt:
    mov     eax, -1
    ret
.Lcmp_gt:
    mov     eax, 1
    ret
.size kiln_core_cmp_bytes, .-kiln_core_cmp_bytes

# ------------------------------------------------------------------------------
# kiln_core_fnv1a_mix_token
#   Normative Kiln v2 §5.3 FNV-1a-64 token mixer (includes trailing 0x00 sep).
#   Inputs:  rdi = current hash, rsi = token bytes, rdx = token len
#   Returns: rax = updated hash
#   Preserves: rbx, rbp, r12, r13, r14, r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_fnv1a_mix_token
.type kiln_core_fnv1a_mix_token, @function
kiln_core_fnv1a_mix_token:
    mov     rax, rdi
    movabs  r8, FNV1A_PRIME
    test    rdx, rdx
    jz      .Lfnv_sep
.p2align 4
.Lfnv_loop:
    movzx   ecx, BYTE PTR [rsi]
    xor     rax, rcx
    imul    rax, r8
    inc     rsi
    dec     rdx
    jnz     .Lfnv_loop
.Lfnv_sep:
    imul    rax, r8
    ret
.size kiln_core_fnv1a_mix_token, .-kiln_core_fnv1a_mix_token

# ------------------------------------------------------------------------------
# kiln_core_arena_alloc
#   Bump-allocates rdi bytes aligned to rsi (power of 2 >= 1) from r14.
#   Outputs: CF=0, rax = allocated pointer (r14 updated); CF=1, KILN_ERR_LIMIT
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_arena_alloc
.type kiln_core_arena_alloc, @function
kiln_core_arena_alloc:
    lea     rcx, [rsi - 1]
    mov     rax, r14
    add     rax, rcx
    jc      .Laa_limit
    not     rcx
    and     rax, rcx
    mov     rdx, QWORD PTR [rbx + CTX_ARENA_END]
    cmp     rax, rdx
    ja      .Laa_limit
    sub     rdx, rax
    cmp     rdx, rdi
    jb      .Laa_limit
    lea     r14, [rax + rdi]
    clc
    ret
.Laa_limit:
    KILN_FAIL KILN_ERR_LIMIT
.size kiln_core_arena_alloc, .-kiln_core_arena_alloc

# ------------------------------------------------------------------------------
# Nesting depth guard (max_depth default 64)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_depth_enter
.type kiln_core_depth_enter, @function
kiln_core_depth_enter:
    movzx   eax, r15b
    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]
    jae     .Ldepth_err
    inc     r15
    KILN_OK_RET
.Ldepth_err:
    KILN_FAIL KILN_ERR_DEPTH
.size kiln_core_depth_enter, .-kiln_core_depth_enter

.p2align 4
.globl kiln_core_depth_leave
.type kiln_core_depth_leave, @function
kiln_core_depth_leave:
    dec     r15
    KILN_OK_RET
.size kiln_core_depth_leave, .-kiln_core_depth_leave

# ------------------------------------------------------------------------------
# Trailing bytes check (standalone mode only)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_check_trailing
.type kiln_core_check_trailing, @function
kiln_core_check_trailing:
    test    r15, FLAG_EMBEDDED
    jnz     .Lct_ok
    cmp     r12, r13
    jne     .Lct_err
.Lct_ok:
    KILN_OK_RET
.Lct_err:
    KILN_FAIL KILN_ERR_TRAILING
.size kiln_core_check_trailing, .-kiln_core_check_trailing

# ------------------------------------------------------------------------------
# Frozen scalar encode primitives
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_bool
.type kiln_core_enc_bool, @function
kiln_core_enc_bool:
    cmp     r12, r13
    jae     .Lew_limit
    test    dil, dil
    setne   al
    mov     BYTE PTR [r12], al
    inc     r12
    KILN_OK_RET
.Lew_limit:
    KILN_FAIL KILN_ERR_LIMIT
.size kiln_core_enc_bool, .-kiln_core_enc_bool

.p2align 4
.globl kiln_core_enc_u8
.type kiln_core_enc_u8, @function
kiln_core_enc_u8:
    cmp     r12, r13
    jae     .Lew_limit
    mov     BYTE PTR [r12], dil
    inc     r12
    KILN_OK_RET
.size kiln_core_enc_u8, .-kiln_core_enc_u8

.p2align 4
.globl kiln_core_enc_u16
.type kiln_core_enc_u16, @function
kiln_core_enc_u16:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 2
    jb      .Lew_limit
    mov     WORD PTR [r12], di
    add     r12, 2
    KILN_OK_RET
.size kiln_core_enc_u16, .-kiln_core_enc_u16

.p2align 4
.globl kiln_core_enc_u32
.type kiln_core_enc_u32, @function
kiln_core_enc_u32:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 4
    jb      .Lew_limit
    mov     DWORD PTR [r12], edi
    add     r12, 4
    KILN_OK_RET
.size kiln_core_enc_u32, .-kiln_core_enc_u32

.p2align 4
.globl kiln_core_enc_u64
.type kiln_core_enc_u64, @function
kiln_core_enc_u64:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 8
    jb      .Lew_limit
    mov     QWORD PTR [r12], rdi
    add     r12, 8
    KILN_OK_RET
.size kiln_core_enc_u64, .-kiln_core_enc_u64

# rdi = count
.p2align 4
.globl kiln_core_enc_count
.type kiln_core_enc_count, @function
kiln_core_enc_count:
    cmp     rdi, QWORD PTR [rbx + CTX_MAX_COUNT]
    ja      .Lew_limit
    mov     eax, 0xFFFFFFFF
    cmp     rdi, rax
    ja      .Lew_limit
    jmp     kiln_core_enc_u32
.size kiln_core_enc_count, .-kiln_core_enc_count

# rdi = ptr, rsi = len
.p2align 4
.globl kiln_core_enc_str
.type kiln_core_enc_str, @function
kiln_core_enc_str:
    cmp     rsi, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      .Lew_limit
    mov     eax, 0xFFFFFFFF
    cmp     rsi, rax
    ja      .Lew_limit
    lea     rcx, [rsi + 4]
    mov     rax, r13
    sub     rax, r12
    cmp     rax, rcx
    jb      .Lew_limit
    mov     DWORD PTR [r12], esi
    add     r12, 4
    test    rsi, rsi
    jz      .Les_done
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rdi, r12
    add     r12, rdx
    call    kiln_core_memcpy_fast
.Les_done:
    KILN_OK_RET
.size kiln_core_enc_str, .-kiln_core_enc_str

# rdi = schema_hash
.p2align 4
.globl kiln_core_enc_frame_hdr
.type kiln_core_enc_frame_hdr, @function
kiln_core_enc_frame_hdr:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 16
    jb      .Lew_limit
    mov     DWORD PTR [r12], KILN_MAGIC_KLN0
    mov     DWORD PTR [r12 + 4], 0
    mov     QWORD PTR [r12 + 8], rdi
    add     r12, 16
    KILN_OK_RET
.size kiln_core_enc_frame_hdr, .-kiln_core_enc_frame_hdr

# ------------------------------------------------------------------------------
# Frozen scalar & container decode primitives
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_bool
.type kiln_core_dec_bool, @function
kiln_core_dec_bool:
    cmp     r12, r13
    jae     .Ldr_eof
    movzx   eax, BYTE PTR [r12]
    cmp     al, 1
    ja      .Ldr_type
    inc     r12
    clc
    ret
.Ldr_eof:
    KILN_FAIL KILN_ERR_EOF
.Ldr_type:
    KILN_FAIL KILN_ERR_TYPE
.Ldr_limit:
    KILN_FAIL KILN_ERR_LIMIT
.size kiln_core_dec_bool, .-kiln_core_dec_bool

.p2align 4
.globl kiln_core_dec_u8
.type kiln_core_dec_u8, @function
kiln_core_dec_u8:
    cmp     r12, r13
    jae     .Ldr_eof
    movzx   eax, BYTE PTR [r12]
    inc     r12
    clc
    ret
.size kiln_core_dec_u8, .-kiln_core_dec_u8

.p2align 4
.globl kiln_core_dec_u16
.type kiln_core_dec_u16, @function
kiln_core_dec_u16:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 2
    jb      .Ldr_eof
    movzx   eax, WORD PTR [r12]
    add     r12, 2
    clc
    ret
.size kiln_core_dec_u16, .-kiln_core_dec_u16

.p2align 4
.globl kiln_core_dec_u32
.type kiln_core_dec_u32, @function
kiln_core_dec_u32:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 4
    jb      .Ldr_eof
    mov     eax, DWORD PTR [r12]
    add     r12, 4
    clc
    ret
.size kiln_core_dec_u32, .-kiln_core_dec_u32

.p2align 4
.globl kiln_core_dec_u64
.type kiln_core_dec_u64, @function
kiln_core_dec_u64:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, 8
    jb      .Ldr_eof
    mov     rax, QWORD PTR [r12]
    add     r12, 8
    clc
    ret
.size kiln_core_dec_u64, .-kiln_core_dec_u64

# ------------------------------------------------------------------------------
# kiln_core_dec_count
#   Normative §4.2 pre-allocation guard for list<T> / dict<str,V>.
#   Inputs:  rdi = min_elem_size (0 allowed for empty structs)
#   Outputs: CF=0, rax = u32 count (r12 += 4); CF=1 on EOF or LIMIT
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_count
.type kiln_core_dec_count, @function
kiln_core_dec_count:
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      .Ldr_eof
    mov     eax, DWORD PTR [r12]    # zero-extended count in rax
    cmp     rax, QWORD PTR [rbx + CTX_MAX_COUNT]
    ja      .Ldr_limit
    sub     rcx, 4                  # remaining bytes after count word
    test    rdi, rdi
    jz      .Ldc_ok
    mov     r8, rax
    mul     rdi                     # rdx:rax = count * min_elem_size
    test    rdx, rdx
    jnz     .Ldr_limit
    cmp     rax, rcx
    ja      .Ldr_eof
    mov     rax, r8
.Ldc_ok:
    add     r12, 4
    clc
    ret
.size kiln_core_dec_count, .-kiln_core_dec_count

# ------------------------------------------------------------------------------
# kiln_core_dec_str
#   Decodes u32-prefixed UTF-8 string. Enforces max_bytes & EOF before touching r14.
#   Honors FLAG_OWNED (fused AVX2 UTF-8 + copy into arena) and FLAG_CHECK_UTF8.
#   Outputs: CF=0, rax = ptr, rdx = len; CF=1 on EOF / LIMIT / UTF8
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_str
.type kiln_core_dec_str, @function
kiln_core_dec_str:
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      .Ldr_eof
    mov     edx, DWORD PTR [r12]    # len in rdx
    cmp     rdx, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      .Ldr_limit
    sub     rcx, 4
    cmp     rdx, rcx
    ja      .Ldr_eof

    lea     r8, [r12 + 4]           # body ptr
    test    r15, FLAG_OWNED
    jnz     .Lds_owned

    # Zero-copy view path
    test    r15, FLAG_CHECK_UTF8
    jz      .Lds_view_done
    test    rdx, rdx
    jz      .Lds_view_done
    push    r8
    push    rdx
    mov     rdi, r8
    mov     rsi, rdx
    call    kiln_core_utf8_validate
    pop     rdx
    pop     r8
    jc      .Lds_utf8_err
.Lds_view_done:
    lea     r12, [r8 + rdx]
    mov     rax, r8
    clc
    ret

.Lds_owned:
    # Check arena space (r14 stays untouched if UTF-8 fails)
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      .Ldr_limit

    test    rdx, rdx
    jz      .Lds_owned_empty

    test    r15, FLAG_CHECK_UTF8
    jz      .Lds_owned_unchecked

    # Fused single-pass AVX2/SWAR validate + copy
    push    r8
    push    rdx
    mov     rdi, r14
    mov     rsi, r8
    call    kiln_core_utf8_copy
    pop     rdx
    pop     r8
    jc      .Lds_utf8_err
    jmp     .Lds_owned_done

.Lds_owned_unchecked:
    push    r8
    push    rdx
    mov     rdi, r14
    mov     rsi, r8
    call    kiln_core_memcpy_fast
    pop     rdx
    pop     r8

.Lds_owned_done:
    mov     rax, r14
    add     r14, rdx
    lea     r12, [r8 + rdx]
    clc
    ret

.Lds_owned_empty:
    mov     rax, r14
    mov     r12, r8
    clc
    ret

.Lds_utf8_err:
    mov     r12, r8
    KILN_FAIL KILN_ERR_UTF8
.size kiln_core_dec_str, .-kiln_core_dec_str

# ------------------------------------------------------------------------------
# kiln_core_dec_bytes
#   Decodes u32-prefixed raw bytes (bytes / list<u8>). No UTF-8 validation.
#   Enforces max_bytes & EOF before touching r14; honors FLAG_OWNED.
#   Outputs: CF=0, rax = ptr, rdx = len; CF=1 on EOF / LIMIT
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_bytes
.type kiln_core_dec_bytes, @function
kiln_core_dec_bytes:
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      .Ldr_eof
    mov     edx, DWORD PTR [r12]    # len in rdx
    cmp     rdx, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      .Ldr_limit
    sub     rcx, 4
    cmp     rdx, rcx
    ja      .Ldr_eof

    lea     r8, [r12 + 4]           # body ptr
    test    r15, FLAG_OWNED
    jnz     .Ldb_owned

    lea     r12, [r8 + rdx]
    mov     rax, r8
    clc
    ret

.Ldb_owned:
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      .Ldr_limit
    test    rdx, rdx
    jz      .Ldb_owned_empty
    push    r8
    push    rdx
    mov     rdi, r14
    mov     rsi, r8
    call    kiln_core_memcpy_fast
    pop     rdx
    pop     r8
    mov     rax, r14
    add     r14, rdx
    lea     r12, [r8 + rdx]
    clc
    ret

.Ldb_owned_empty:
    mov     rax, r14
    mov     r12, r8
    clc
    ret
.size kiln_core_dec_bytes, .-kiln_core_dec_bytes

# ------------------------------------------------------------------------------
# kiln_core_dec_frame_hdr
#   Normative §5.2 KLN0 header validation in exact check order.
#   Inputs:  rdi = expected_schema_hash
#   Outputs: CF=0, rax = actual_schema_hash (r12 += 16); CF=1 on EOF/FRAME/SCHEMA
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_frame_hdr
.type kiln_core_dec_frame_hdr, @function
kiln_core_dec_frame_hdr:
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      .Ldr_eof
    cmp     DWORD PTR [r12], KILN_MAGIC_KLN0
    jne     .Ldf_frame
    cmp     rcx, 16
    jb      .Ldr_eof
    cmp     DWORD PTR [r12 + 4], 0  # profile==0 && flags==0 && reserved==0
    jne     .Ldf_frame
    mov     rax, QWORD PTR [r12 + 8]
    cmp     rax, rdi
    jne     .Ldf_schema
    add     r12, 16
    clc
    ret
.Ldf_frame:
    KILN_FAIL KILN_ERR_FRAME
.Ldf_schema:
    KILN_FAIL KILN_ERR_SCHEMA
.size kiln_core_dec_frame_hdr, .-kiln_core_dec_frame_hdr

# ------------------------------------------------------------------------------
# kiln_core_enc_dict_i64
#   Encodes dict<str, i64>, enforcing strictly ascending UTF-8 key order (TYPE).
#   Inputs:  rdi = const kiln_dict_entry_t *entries, rsi = count
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_dict_i64
.type kiln_core_enc_dict_i64, @function
kiln_core_enc_dict_i64:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32                 # [rbp-8]=entries, [rbp-16]=count, [rbp-24]=idx
    mov     QWORD PTR [rbp - 8], rdi
    mov     QWORD PTR [rbp - 16], rsi

    call    kiln_core_depth_enter
    jc      .Led_ret

    # Verify strictly ascending lexicographic key order before writing
    mov     rax, QWORD PTR [rbp - 16]
    cmp     rax, 2
    jb      .Led_write_count
    mov     QWORD PTR [rbp - 24], 1
.Led_chk_loop:
    mov     r8, QWORD PTR [rbp - 24]
    cmp     r8, QWORD PTR [rbp - 16]
    jae     .Led_write_count
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8] # cur entry
    lea     r10, [r9 - DICT_ENTRY_SIZE] # prev entry
    mov     rdi, QWORD PTR [r10 + DICT_KEY_PTR]
    mov     rsi, QWORD PTR [r10 + DICT_KEY_LEN]
    mov     rdx, QWORD PTR [r9 + DICT_KEY_PTR]
    mov     rcx, QWORD PTR [r9 + DICT_KEY_LEN]
    call    kiln_core_cmp_bytes
    test    eax, eax
    jns     .Led_type_err           # must be < 0 (strictly ascending)
    inc     QWORD PTR [rbp - 24]
    jmp     .Led_chk_loop

.Led_write_count:
    mov     rdi, QWORD PTR [rbp - 16]
    call    kiln_core_enc_count
    jc      .Led_leave_err

    mov     QWORD PTR [rbp - 24], 0
.Led_write_loop:
    mov     r8, QWORD PTR [rbp - 24]
    cmp     r8, QWORD PTR [rbp - 16]
    jae     .Led_ok
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8]
    mov     rdi, QWORD PTR [r9 + DICT_KEY_PTR]
    mov     rsi, QWORD PTR [r9 + DICT_KEY_LEN]
    call    kiln_core_enc_str
    jc      .Led_leave_err
    mov     r8, QWORD PTR [rbp - 24]
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8]
    mov     rdi, QWORD PTR [r9 + DICT_VAL_I64]
    call    kiln_core_enc_u64
    jc      .Led_leave_err
    inc     QWORD PTR [rbp - 24]
    jmp     .Led_write_loop

.Led_ok:
    call    kiln_core_depth_leave
    leave
    KILN_OK_RET

.Led_type_err:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_TYPE

.Led_leave_err:
    dec     r15
.Led_ret:
    leave
    stc
    ret
.size kiln_core_enc_dict_i64, .-kiln_core_enc_dict_i64

# ------------------------------------------------------------------------------
# kiln_core_dec_dict_i64
#   Decodes dict<str, i64> into bump arena, enforcing pre-alloc guard and
#   strictly ascending unique UTF-8 keys (TYPE on unsorted/duplicate).
#   Outputs: CF=0, rax = kiln_dict_entry_t*, rdx = count
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_dict_i64
.type kiln_core_dec_dict_i64, @function
kiln_core_dec_dict_i64:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 48                 # -8:out_arr, -16:count, -24:idx, -32:prev_ptr, -40:prev_len

    call    kiln_core_depth_enter
    jc      .Ldd_ret

    # min entry = 4 (str len) + 8 (i64) = 12 bytes
    mov     rdi, 12
    call    kiln_core_dec_count
    jc      .Ldd_leave_err
    mov     QWORD PTR [rbp - 16], rax

    test    rax, rax
    jz      .Ldd_empty

    imul    rdi, rax, DICT_ENTRY_SIZE
    mov     rsi, 8
    call    kiln_core_arena_alloc
    jc      .Ldd_leave_err
    mov     QWORD PTR [rbp - 8], rax
    mov     QWORD PTR [rbp - 24], 0

.Ldd_loop:
    mov     r8, QWORD PTR [rbp - 24]
    cmp     r8, QWORD PTR [rbp - 16]
    jae     .Ldd_done

    call    kiln_core_dec_str       # rax=key_ptr, rdx=key_len
    jc      .Ldd_leave_err
    mov     r8, QWORD PTR [rbp - 24]
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8]
    mov     QWORD PTR [r9 + DICT_KEY_PTR], rax
    mov     QWORD PTR [r9 + DICT_KEY_LEN], rdx

    # Enforce strict ascending order against previous key
    test    r8, r8
    jz      .Ldd_save_prev
    mov     rdi, QWORD PTR [rbp - 32]
    mov     rsi, QWORD PTR [rbp - 40]
    mov     rcx, rdx
    mov     rdx, rax
    call    kiln_core_cmp_bytes
    test    eax, eax
    jns     .Ldd_type_err           # prev >= cur => unsorted or duplicate!
    mov     r8, QWORD PTR [rbp - 24]
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8]
    mov     rax, QWORD PTR [r9 + DICT_KEY_PTR]
    mov     rdx, QWORD PTR [r9 + DICT_KEY_LEN]

.Ldd_save_prev:
    mov     QWORD PTR [rbp - 32], rax
    mov     QWORD PTR [rbp - 40], rdx

    call    kiln_core_dec_u64
    jc      .Ldd_leave_err
    mov     r8, QWORD PTR [rbp - 24]
    imul    r9, r8, DICT_ENTRY_SIZE
    add     r9, QWORD PTR [rbp - 8]
    mov     QWORD PTR [r9 + DICT_VAL_I64], rax

    inc     QWORD PTR [rbp - 24]
    jmp     .Ldd_loop

.Ldd_empty:
    mov     QWORD PTR [rbp - 8], 0

.Ldd_done:
    call    kiln_core_depth_leave
    mov     rax, QWORD PTR [rbp - 8]
    mov     rdx, QWORD PTR [rbp - 16]
    leave
    clc
    ret

.Ldd_type_err:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_TYPE

.Ldd_leave_err:
    dec     r15
.Ldd_ret:
    leave
    stc
    ret
.size kiln_core_dec_dict_i64, .-kiln_core_dec_dict_i64

.section .note.GNU-stack,"",@progbits
