.intel_syntax noprefix
.include "defs.inc"

.section .rodata

# Standard dtype byte-length class (index 0..19):
#   0 = 1 byte/elem   (f8e4m3, f8e5m2, bool, i8, u8, e8m0)
#   1 = 2 bytes/elem  (f16, bf16, i16, u16)
#   2 = 4 bytes/elem  (f32, i32, u32)
#   3 = 8 bytes/elem  (f64, i64, u64)
#   4 = packed 4-bit  (i4, u4, e2m1 -> ceil(n / 2))
# 255 = invalid (0)
.Ldtype_class:
    .byte 255           #  0 invalid
    .byte 3             #  1 f64
    .byte 2             #  2 f32
    .byte 1             #  3 f16
    .byte 1             #  4 bf16
    .byte 0             #  5 f8e4m3
    .byte 0             #  6 f8e5m2
    .byte 0             #  7 bool
    .byte 0             #  8 i8
    .byte 0             #  9 u8
    .byte 1             # 10 i16
    .byte 1             # 11 u16
    .byte 2             # 12 i32
    .byte 2             # 13 u32
    .byte 3             # 14 i64
    .byte 3             # 15 u64
    .byte 4             # 16 i4
    .byte 4             # 17 u4
    .byte 4             # 18 e2m1
    .byte 0             # 19 e8m0

.p2align 5
.Lmask_fe32:
    .fill 32, 1, 0xFE

.text

# ------------------------------------------------------------------------------
# .Lcheck_zero: verify all bytes in [rdi, rdi + rsi) are 0x00.
#   Returns: CF=0 if all zero, CF=1 if any byte nonzero.
#   Preserves: rbx, rbp, r12..r15
# ------------------------------------------------------------------------------
.p2align 4
.Lcheck_zero:
    xor     rcx, rcx
.Lcz_qloop:
    mov     rax, rsi
    sub     rax, rcx
    cmp     rax, 8
    jb      .Lcz_bloop
    cmp     QWORD PTR [rdi + rcx], 0
    jne     .Lcz_bad
    add     rcx, 8
    jmp     .Lcz_qloop
.Lcz_bloop:
    cmp     rcx, rsi
    jae     .Lcz_ok
    cmp     BYTE PTR [rdi + rcx], 0
    jne     .Lcz_bad
    inc     rcx
    jmp     .Lcz_bloop
.Lcz_ok:
    clc
    ret
.Lcz_bad:
    stc
    ret

# ------------------------------------------------------------------------------
# .Lzero_fill: fill [rdi, rdi + rsi) with 0x00.
#   Preserves: rbx, rbp, r12..r15
# ------------------------------------------------------------------------------
.p2align 4
.Lzero_fill:
    test    rsi, rsi
    jz      .Lzf_done
    xor     eax, eax
    mov     rcx, rsi
    rep stosb
.Lzf_done:
    ret

# ------------------------------------------------------------------------------
# .Lcheck_bool_bytes: verify every byte in [rdi, rdi + rsi) is 0x00 or 0x01.
#   Returns: CF=0 if valid, CF=1 if any byte >= 2.
#   Preserves: rbx, rbp, r12..r15
# ------------------------------------------------------------------------------
.p2align 4
.Lcheck_bool_bytes:
    xor     rcx, rcx
    cmp     rsi, 32
    jb      .Lcb_qloop
    vmovdqa ymm1, YMMWORD PTR [rip + .Lmask_fe32]
.Lcb_avx:
    vmovdqu ymm0, YMMWORD PTR [rdi + rcx]
    vptest  ymm0, ymm1
    jnz     .Lcb_bad_avx
    add     rcx, 32
    mov     rax, rsi
    sub     rax, rcx
    cmp     rax, 32
    jae     .Lcb_avx
    vzeroupper
.Lcb_qloop:
    movabs  r8, 0xFEFEFEFEFEFEFEFE
.Lcb_qloop_iter:
    mov     rax, rsi
    sub     rax, rcx
    cmp     rax, 8
    jb      .Lcb_bloop
    test    QWORD PTR [rdi + rcx], r8
    jnz     .Lcb_bad
    add     rcx, 8
    jmp     .Lcb_qloop_iter
.Lcb_bloop:
    cmp     rcx, rsi
    jae     .Lcb_ok
    test    BYTE PTR [rdi + rcx], 0xFE
    jnz     .Lcb_bad
    inc     rcx
    jmp     .Lcb_bloop
.Lcb_ok:
    clc
    ret
.Lcb_bad_avx:
    vzeroupper
.Lcb_bad:
    stc
    ret

# ------------------------------------------------------------------------------
# .Ldtype_expected_bytes
#   Inputs:  edi = standard dtype (1..19), rsi = elem_count (n)
#   Outputs: CF=0, rax = expected byte_length; CF=1 on u64 overflow (LIMIT)
#   Preserves: rbx, rbp, r12..r15
# ------------------------------------------------------------------------------
.p2align 4
.Ldtype_expected_bytes:
    lea     rcx, [rip + .Ldtype_class]
    movzx   eax, BYTE PTR [rcx + rdi]
    cmp     eax, 0
    je      .Ldeb_w1
    cmp     eax, 1
    je      .Ldeb_w2
    cmp     eax, 2
    je      .Ldeb_w4
    cmp     eax, 3
    je      .Ldeb_w8
    # class 4: packed 4-bit => (n >> 1) + (n & 1)
    mov     rax, rsi
    shr     rax, 1
    mov     rcx, rsi
    and     rcx, 1
    add     rax, rcx
    clc
    ret
.Ldeb_w1:
    mov     rax, rsi
    clc
    ret
.Ldeb_w2:
    movabs  rcx, 0x7FFFFFFFFFFFFFFF
    cmp     rsi, rcx
    ja      .Ldeb_ovf
    lea     rax, [rsi * 2]
    clc
    ret
.Ldeb_w4:
    movabs  rcx, 0x3FFFFFFFFFFFFFFF
    cmp     rsi, rcx
    ja      .Ldeb_ovf
    lea     rax, [rsi * 4]
    clc
    ret
.Ldeb_w8:
    movabs  rcx, 0x1FFFFFFFFFFFFFFF
    cmp     rsi, rcx
    ja      .Ldeb_ovf
    lea     rax, [rsi * 8]
    clc
    ret
.Ldeb_ovf:
    stc
    ret

# ------------------------------------------------------------------------------
# kiln_core_dec_tensors
#   Full 12-step normative KLNT v2 validator & decoder (spec §7.2).
#   Inputs:  rdi = kiln_tensor_dir_t *out
#   Outputs: CF=0 (r12 advanced by block_end, *out populated); CF=1 on error
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_dec_tensors
.type kiln_core_dec_tensors, @function
kiln_core_dec_tensors:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 144
    # Stack frame:
    #   [rbp -   8] = out_dir*
    #   [rbp -  16] = dir_base (r12 at entry)
    #   [rbp -  24] = desc_base (dir_base + 64)
    #   [rbp -  32] = heap_base (dir_base + 64 + count * 128)
    #   [rbp -  40] = payload_ptr (dir_base + payload_base)
    #   [rbp -  48] = count (tensor_count)
    #   [rbp -  56] = name_bytes
    #   [rbp -  64] = payload_bytes
    #   [rbp -  72] = block_end
    #   [rbp -  80] = flags (u64)
    #   [rbp -  88] = items* (kiln_tensor_t* in arena)
    #   [rbp -  96] = idx (i)
    #   [rbp - 104] = heap_pos / cur_end
    #   [rbp - 112] = inner idx (j)
    #   [rbp - 120] = scratch1
    #   [rbp - 128] = scratch2
    mov     QWORD PTR [rbp - 8], rdi
    mov     QWORD PTR [rbp - 16], r12

    call    kiln_core_depth_enter
    jc      .Ldt_ret_nodec

    # ---- Step 1: Magic & header length ----
    mov     rcx, r13
    sub     rcx, r12                # rem
    cmp     rcx, 4
    jb      .Ldt_eof
    cmp     DWORD PTR [r12], KILN_MAGIC_KLNT
    jne     .Ldt_frame
    cmp     rcx, KLNT_HDR_SIZE
    jb      .Ldt_eof

    # ---- Step 2: Header envelope ----
    cmp     BYTE PTR [r12 + 4], KLNT_VERSION
    jne     .Ldt_frame
    movzx   eax, BYTE PTR [r12 + 5] # flags
    test    eax, ~0x03
    jnz     .Ldt_frame
    test    eax, KLNT_FLAG_LE
    jz      .Ldt_frame
    cmp     WORD PTR [r12 + 6], 0   # reserved0
    jne     .Ldt_frame
    mov     QWORD PTR [rbp - 80], rax
    # Check 32 reserved header bytes [32..63] with AVX2
    vmovdqu ymm0, YMMWORD PTR [r12 + 32]
    vptest  ymm0, ymm0
    vzeroupper
    jnz     .Ldt_frame

    # ---- Step 3: Header caps ----
    mov     eax, DWORD PTR [r12 + 8]  # tensor_count (u32 -> u64)
    mov     edx, DWORD PTR [r12 + 12] # name_bytes (u32 -> u64)
    mov     r8, QWORD PTR [r12 + 16]  # payload_bytes
    mov     r9, QWORD PTR [r12 + 24]  # directory_bytes
    mov     r10, QWORD PTR [rbx + CTX_MAX_COUNT]
    cmp     rax, r10
    ja      .Ldt_limit
    cmp     rdx, r10
    ja      .Ldt_limit
    mov     QWORD PTR [rbp - 48], rax
    mov     QWORD PTR [rbp - 56], rdx
    mov     QWORD PTR [rbp - 64], r8

    # ---- Step 4: Directory arithmetic ----
    # tensor_count * 128 + name_bytes == directory_bytes
    mov     r10, rax
    shl     r10, 7                  # u32 * 128 cannot overflow u64
    add     r10, rdx
    jc      .Ldt_limit
    cmp     r10, r9
    jne     .Ldt_type

    # ---- Step 5: Directory fit (pre-allocation) ----
    mov     r10, r9
    add     r10, KLNT_HDR_SIZE      # after_dir = 64 + directory_bytes
    jc      .Ldt_limit
    cmp     r10, rcx                # after_dir > rem => EOF (zero alloc!)
    ja      .Ldt_eof

    # ---- Step 6: Block fit (pre-allocation) ----
    mov     r11, r10
    add     r11, 63
    jc      .Ldt_limit
    and     r11, -64                # payload_base = align64(after_dir)
    mov     rax, r11
    add     rax, r8                 # block_end = payload_base + payload_bytes
    jc      .Ldt_limit
    cmp     rax, rcx                # block_end > rem => EOF (zero alloc!)
    ja      .Ldt_eof
    mov     QWORD PTR [rbp - 72], rax

    # Compute section pointers
    lea     rax, [r12 + KLNT_HDR_SIZE]
    mov     QWORD PTR [rbp - 24], rax # desc_base
    mov     rdx, QWORD PTR [rbp - 48]
    shl     rdx, 7
    add     rax, rdx
    mov     QWORD PTR [rbp - 32], rax # heap_base
    lea     rax, [r12 + r11]
    mov     QWORD PTR [rbp - 40], rax # payload_ptr

    # ---- Step 7: Header-to-payload alignment padding zeros ----
    mov     rsi, r11
    sub     rsi, r10                # pad_len = payload_base - after_dir
    lea     rdi, [r12 + r10]
    call    .Lcheck_zero
    jc      .Ldt_type

    # ---- Step 8: Descriptor reserved bytes & names ----
    mov     rax, QWORD PTR [rbp - 48] # count
    test    rax, rax
    jnz     .Ldt_nonempty

    # Empty directory (count == 0): FLAG_NAME must be clear, name_bytes == 0, payload_bytes == 0
    test    QWORD PTR [rbp - 80], KLNT_FLAG_NAME
    jnz     .Ldt_type
    cmp     QWORD PTR [rbp - 56], 0
    jne     .Ldt_type
    cmp     QWORD PTR [rbp - 64], 0
    jne     .Ldt_type
    mov     QWORD PTR [rbp - 88], 0
    jmp     .Ldt_step12

.Ldt_nonempty:
    # Step 8a: Verify reserved bytes in every descriptor BEFORE allocating
    xor     rcx, rcx
    mov     rdx, QWORD PTR [rbp - 24]
.Ldt_s8a_loop:
    cmp     rcx, QWORD PTR [rbp - 48]
    jae     .Ldt_s8a_done
    cmp     BYTE PTR [rdx + WDESC_RES0], 0
    jne     .Ldt_frame
    movdqu  xmm0, XMMWORD PTR [rdx + WDESC_RES1]
    ptest   xmm0, xmm0
    jnz     .Ldt_frame
    add     rdx, KLNT_DESC_SIZE
    inc     rcx
    jmp     .Ldt_s8a_loop
.Ldt_s8a_done:

    # Allocate out items array in arena (count * TENS_SIZE, align 8)
    imul    rdi, QWORD PTR [rbp - 48], TENS_SIZE
    mov     rsi, 8
    call    kiln_core_arena_alloc
    jc      .Ldt_leave_err
    mov     QWORD PTR [rbp - 88], rax

    # Step 8b: Tensor names (gapless from heap_pos = 0)
    mov     QWORD PTR [rbp - 104], 0  # heap_pos = 0
    mov     QWORD PTR [rbp - 96], 0   # i = 0
.Ldt_s8_names:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_s8_layouts_init
    mov     r9, r8
    shl     r9, 7
    add     r9, QWORD PTR [rbp - 24]  # desc
    imul    r10, r8, TENS_SIZE
    add     r10, QWORD PTR [rbp - 88] # out[i]

    movzx   eax, WORD PTR [r9 + WDESC_NAME_OFF]
    movzx   ecx, WORD PTR [r9 + WDESC_NAME_LEN]
    test    QWORD PTR [rbp - 80], KLNT_FLAG_NAME
    jnz     .Ldt_s8_named

    # Unnamed directory: name_len == 0 && name_off == 0xFFFF
    test    ecx, ecx
    jnz     .Ldt_type
    cmp     eax, 0xFFFF
    jne     .Ldt_type
    mov     QWORD PTR [r10 + TENS_NAME_PTR], 0
    mov     QWORD PTR [r10 + TENS_NAME_LEN], 0
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s8_names

.Ldt_s8_named:
    test    ecx, ecx
    jz      .Ldt_type
    cmp     eax, 0xFFFF
    je      .Ldt_type
    mov     rdx, QWORD PTR [rbp - 104] # heap_pos
    cmp     rax, rdx
    jne     .Ldt_type
    lea     r11, [rdx + rcx]
    cmp     r11, QWORD PTR [rbp - 56]  # <= name_bytes
    ja      .Ldt_type

    mov     QWORD PTR [rbp - 120], r10 # save out[i]
    mov     QWORD PTR [rbp - 128], rcx # save name_len
    mov     rsi, QWORD PTR [rbp - 32]
    add     rsi, rdx                   # name_ptr = heap_base + heap_pos
    mov     QWORD PTR [r10 + TENS_NAME_PTR], rsi
    mov     QWORD PTR [r10 + TENS_NAME_LEN], rcx
    mov     QWORD PTR [rbp - 104], r11 # advance heap_pos

    # Validate UTF-8 (unless trusted)
    test    r15, FLAG_CHECK_UTF8
    jz      .Ldt_s8_dup_chk
    mov     rdi, rsi
    mov     rsi, rcx
    call    kiln_core_utf8_validate
    jc      .Ldt_utf8

.Ldt_s8_dup_chk:
    # Check uniqueness against out[0 .. i-1]
    mov     QWORD PTR [rbp - 112], 0   # j = 0
.Ldt_s8_dup_loop:
    mov     r8, QWORD PTR [rbp - 112]
    cmp     r8, QWORD PTR [rbp - 96]
    jae     .Ldt_s8_name_next
    imul    r9, r8, TENS_SIZE
    add     r9, QWORD PTR [rbp - 88]   # out[j]
    mov     r10, QWORD PTR [rbp - 120] # out[i]
    mov     rsi, QWORD PTR [r9 + TENS_NAME_LEN]
    mov     rcx, QWORD PTR [r10 + TENS_NAME_LEN]
    cmp     rsi, rcx
    jne     .Ldt_s8_dup_inc
    mov     rdi, QWORD PTR [r9 + TENS_NAME_PTR]
    mov     rdx, QWORD PTR [r10 + TENS_NAME_PTR]
    call    kiln_core_cmp_bytes
    test    eax, eax
    jz      .Ldt_type                  # duplicate tensor name!
.Ldt_s8_dup_inc:
    inc     QWORD PTR [rbp - 112]
    jmp     .Ldt_s8_dup_loop

.Ldt_s8_name_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s8_names

.Ldt_s8_layouts_init:
    # Step 8c: Layout names (gapless after tensor names)
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Ldt_s8_layouts:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_s8_heap_end
    mov     r9, r8
    shl     r9, 7
    add     r9, QWORD PTR [rbp - 24]   # desc
    imul    r10, r8, TENS_SIZE
    add     r10, QWORD PTR [rbp - 88]  # out[i]

    movzx   eax, WORD PTR [r9 + WDESC_LAYOUT_OFF]
    movzx   ecx, WORD PTR [r9 + WDESC_LAYOUT_LEN]
    test    ecx, ecx
    jnz     .Ldt_s8_has_layout

    cmp     eax, 0xFFFF
    jne     .Ldt_type
    mov     QWORD PTR [r10 + TENS_LAYOUT_PTR], 0
    mov     QWORD PTR [r10 + TENS_LAYOUT_LEN], 0
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s8_layouts

.Ldt_s8_has_layout:
    cmp     eax, 0xFFFF
    je      .Ldt_type
    mov     rdx, QWORD PTR [rbp - 104] # heap_pos
    cmp     rax, rdx
    jne     .Ldt_type
    lea     r11, [rdx + rcx]
    cmp     r11, QWORD PTR [rbp - 56]  # <= name_bytes
    ja      .Ldt_type

    mov     rsi, QWORD PTR [rbp - 32]
    add     rsi, rdx
    mov     QWORD PTR [r10 + TENS_LAYOUT_PTR], rsi
    mov     QWORD PTR [r10 + TENS_LAYOUT_LEN], rcx
    mov     QWORD PTR [rbp - 104], r11

    test    r15, FLAG_CHECK_UTF8
    jz      .Ldt_s8_layout_next
    mov     rdi, rsi
    mov     rsi, rcx
    call    kiln_core_utf8_validate
    jc      .Ldt_utf8

.Ldt_s8_layout_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s8_layouts

.Ldt_s8_heap_end:
    mov     rax, QWORD PTR [rbp - 104]
    cmp     rax, QWORD PTR [rbp - 56]  # heap_pos == name_bytes
    jne     .Ldt_type

    # ---- Step 9: Per-tensor metadata, shape product, dtype width, range bounds ----
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Ldt_s9_loop:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_s10_init
    mov     r9, r8
    shl     r9, 7
    add     r9, QWORD PTR [rbp - 24]   # desc
    imul    r10, r8, TENS_SIZE
    add     r10, QWORD PTR [rbp - 88]  # out[i]

    # Payload range: byte_offset + byte_length <= payload_bytes
    mov     rax, QWORD PTR [r9 + WDESC_BYTE_OFF]
    mov     rcx, QWORD PTR [r9 + WDESC_BYTE_LEN]
    mov     rdx, rax
    add     rdx, rcx
    jc      .Ldt_limit
    cmp     rdx, QWORD PTR [rbp - 64]
    ja      .Ldt_type

    # Store data view pointer & length
    mov     rsi, QWORD PTR [rbp - 40]  # payload_ptr
    add     rsi, rax
    mov     QWORD PTR [r10 + TENS_DATA_PTR], rsi
    mov     QWORD PTR [r10 + TENS_DATA_LEN], rcx

    # Rank <= 8
    movzx   edx, BYTE PTR [r9 + WDESC_RANK]
    cmp     edx, 8
    ja      .Ldt_type
    mov     BYTE PTR [r10 + TENS_RANK], dl

    # Copy shape[0..7] and verify unused tail [rank..7] == 0
    # Compute element count n = (rank == 0) ? 1 : prod(shape[0..rank-1])
    mov     rax, 1                     # n = 1
    xor     ecx, ecx                   # d = 0
.Ldt_s9_shape:
    cmp     ecx, 8
    jae     .Ldt_s9_shape_done
    mov     r11, QWORD PTR [r9 + WDESC_SHAPE + rcx * 8]
    mov     QWORD PTR [r10 + TENS_SHAPE + rcx * 8], r11
    cmp     ecx, edx
    jae     .Ldt_s9_tail
    # Active dim: n *= shape[d], overflow => LIMIT
    push    rdx
    mul     r11                        # rdx:rax = n * shape[d]
    test    rdx, rdx
    pop     rdx
    jnz     .Ldt_limit
    inc     ecx
    jmp     .Ldt_s9_shape
.Ldt_s9_tail:
    test    r11, r11
    jnz     .Ldt_type                  # nonzero unused shape slot!
    inc     ecx
    jmp     .Ldt_s9_shape

.Ldt_s9_shape_done:
    mov     QWORD PTR [r10 + TENS_ELEM_COUNT], rax

    # Copy scalar metadata fields into out[i]
    movzx   edi, WORD PTR [r9 + WDESC_DTYPE]
    mov     WORD PTR [r10 + TENS_DTYPE], di
    movzx   ecx, WORD PTR [r9 + WDESC_QSCHEME]
    mov     WORD PTR [r10 + TENS_QSCHEME], cx
    movzx   ecx, WORD PTR [r9 + WDESC_QAXIS]
    mov     WORD PTR [r10 + TENS_QAXIS], cx
    mov     ecx, DWORD PTR [r9 + WDESC_GROUP_SIZE]
    mov     DWORD PTR [r10 + TENS_GROUP_SIZE], ecx
    mov     ecx, DWORD PTR [r9 + WDESC_SCALE_IDX]
    mov     DWORD PTR [r10 + TENS_SCALE_IDX], ecx
    mov     ecx, DWORD PTR [r9 + WDESC_OUTER_IDX]
    mov     DWORD PTR [r10 + TENS_OUTER_IDX], ecx
    mov     ecx, DWORD PTR [r9 + WDESC_BLOCK_SIZE]
    mov     DWORD PTR [r10 + TENS_BLOCK_SIZE], ecx

    # Validate dtype: standard 1..19 vs opaque 4096..32767
    test    edi, edi
    jz      .Ldt_type
    cmp     edi, 19
    jbe     .Ldt_s9_std_dtype
    cmp     edi, 4096
    jb      .Ldt_type
    cmp     edi, 32767
    ja      .Ldt_type

    # Opaque dtype (4096..32767): layout_len >= 1, block_size >= 1, byte_length % block_size == 0
    cmp     QWORD PTR [r10 + TENS_LAYOUT_LEN], 0
    je      .Ldt_type
    test    ecx, ecx                   # block_size
    jz      .Ldt_type
    mov     rax, QWORD PTR [r10 + TENS_DATA_LEN]
    xor     edx, edx
    div     rcx                        # rdx = byte_length % block_size
    test    rdx, rdx
    jnz     .Ldt_type
    jmp     .Ldt_s9_next

.Ldt_s9_std_dtype:
    # Standard dtype (1..19): block_size == 0, layout_len == 0, layout_off == 0xFFFF
    test    ecx, ecx
    jnz     .Ldt_type
    cmp     QWORD PTR [r10 + TENS_LAYOUT_LEN], 0
    jne     .Ldt_type
    cmp     WORD PTR [r9 + WDESC_LAYOUT_OFF], 0xFFFF
    jne     .Ldt_type

    mov     rsi, QWORD PTR [r10 + TENS_ELEM_COUNT]
    call    .Ldtype_expected_bytes     # rax = expected byte_length
    jc      .Ldt_limit
    cmp     rax, QWORD PTR [r10 + TENS_DATA_LEN]
    jne     .Ldt_type

.Ldt_s9_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s9_loop

    # ---- Step 10: Canonical greedy 64-byte placement & zero-filled gaps ----
.Ldt_s10_init:
    mov     QWORD PTR [rbp - 104], 0   # cur_end = 0
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Ldt_s10_loop:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_s10_done
    mov     r9, r8
    shl     r9, 7
    add     r9, QWORD PTR [rbp - 24]   # desc

    mov     rax, QWORD PTR [rbp - 104] # cur_end
    mov     rdx, rax
    add     rdx, 63
    jc      .Ldt_limit
    and     rdx, -64                   # expected_off = align64(cur_end)
    cmp     rdx, QWORD PTR [r9 + WDESC_BYTE_OFF]
    jne     .Ldt_type                  # unaligned or overlapping!

    # Verify zero gap [cur_end, expected_off)
    mov     rsi, rdx
    sub     rsi, rax                   # gap_len
    jz      .Ldt_s10_nogap
    mov     rdi, QWORD PTR [rbp - 40]
    add     rdi, rax
    mov     QWORD PTR [rbp - 120], rdx
    mov     QWORD PTR [rbp - 128], r9
    call    .Lcheck_zero
    jc      .Ldt_type
    mov     rdx, QWORD PTR [rbp - 120]
    mov     r9, QWORD PTR [rbp - 128]
.Ldt_s10_nogap:
    add     rdx, QWORD PTR [r9 + WDESC_BYTE_LEN]
    mov     QWORD PTR [rbp - 104], rdx
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s10_loop

.Ldt_s10_done:
    mov     rax, QWORD PTR [rbp - 104]
    cmp     rax, QWORD PTR [rbp - 64]  # final end == payload_bytes
    jne     .Ldt_type

    # ---- Step 11: Element bit domains & quantization links ----
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Ldt_s11_loop:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_s11_owned_copy
    imul    r10, r8, TENS_SIZE
    add     r10, QWORD PTR [rbp - 88]  # out[i]

    movzx   eax, WORD PTR [r10 + TENS_DTYPE]
    cmp     eax, 7                     # bool
    jne     .Ldt_s11_nibble
    mov     rdi, QWORD PTR [r10 + TENS_DATA_PTR]
    mov     rsi, QWORD PTR [r10 + TENS_DATA_LEN]
    mov     QWORD PTR [rbp - 120], r10
    call    .Lcheck_bool_bytes
    jc      .Ldt_type
    mov     r10, QWORD PTR [rbp - 120]
    jmp     .Ldt_s11_quant

.Ldt_s11_nibble:
    # Packed 4-bit dtypes 16 (i4), 17 (u4), 18 (e2m1): odd count => high nibble == 0
    cmp     eax, 16
    jb      .Ldt_s11_quant
    cmp     eax, 18
    ja      .Ldt_s11_quant
    test    QWORD PTR [r10 + TENS_ELEM_COUNT], 1
    jz      .Ldt_s11_quant
    mov     rdi, QWORD PTR [r10 + TENS_DATA_PTR]
    mov     rsi, QWORD PTR [r10 + TENS_DATA_LEN]
    test    BYTE PTR [rdi + rsi - 1], 0xF0
    jnz     .Ldt_type

.Ldt_s11_quant:
    movzx   eax, WORD PTR [r10 + TENS_QSCHEME]
    test    eax, eax
    jnz     .Ldt_s11_q12

    # Scheme 0: axis=0xFFFF, group_size=0, scale_idx=0xFFFFFFFF, outer_idx=0xFFFFFFFF
    cmp     WORD PTR [r10 + TENS_QAXIS], 0xFFFF
    jne     .Ldt_type
    cmp     DWORD PTR [r10 + TENS_GROUP_SIZE], 0
    jne     .Ldt_type
    cmp     DWORD PTR [r10 + TENS_SCALE_IDX], 0xFFFFFFFF
    jne     .Ldt_type
    cmp     DWORD PTR [r10 + TENS_OUTER_IDX], 0xFFFFFFFF
    jne     .Ldt_type
    jmp     .Ldt_s11_next

.Ldt_s11_q12:
    cmp     eax, 2
    ja      .Ldt_type
    # rank >= 1, quant_axis < rank, group_size >= 1
    movzx   ecx, BYTE PTR [r10 + TENS_RANK]
    test    ecx, ecx
    jz      .Ldt_type
    movzx   edx, WORD PTR [r10 + TENS_QAXIS]
    cmp     edx, ecx
    jae     .Ldt_type
    mov     r9d, DWORD PTR [r10 + TENS_GROUP_SIZE]
    test    r9d, r9d
    jz      .Ldt_type

    # scale_index < count, != i, scale.quant_scheme == 0
    mov     esi, DWORD PTR [r10 + TENS_SCALE_IDX]
    cmp     rsi, QWORD PTR [rbp - 48]
    jae     .Ldt_type
    cmp     rsi, QWORD PTR [rbp - 96]
    je      .Ldt_type
    imul    r11, rsi, TENS_SIZE
    add     r11, QWORD PTR [rbp - 88]  # scale tensor
    cmp     WORD PTR [r11 + TENS_QSCHEME], 0
    jne     .Ldt_type

    # n_scales = ceil(shape[a] / g) * prod_{j != a} shape[j]
    mov     rax, QWORD PTR [r10 + TENS_SHAPE + rdx * 8] # shape[a]
    test    rax, rax
    jz      .Ldt_s11_qprod_init        # ceil(0 / g) = 0
    dec     rax
    push    rdx
    xor     edx, edx
    div     r9                         # rax = (shape[a] - 1) / g
    pop     rdx
    inc     rax                        # rax = ceil(shape[a] / g)

.Ldt_s11_qprod_init:
    xor     edi, edi                   # j = 0
.Ldt_s11_qprod_loop:
    cmp     edi, ecx                   # j < rank
    jae     .Ldt_s11_qprod_done
    cmp     edi, edx                   # skip j == quant_axis
    je      .Ldt_s11_qprod_skip
    push    rdx
    mul     QWORD PTR [r10 + TENS_SHAPE + rdi * 8]
    test    rdx, rdx
    pop     rdx
    jnz     .Ldt_limit
.Ldt_s11_qprod_skip:
    inc     edi
    jmp     .Ldt_s11_qprod_loop

.Ldt_s11_qprod_done:
    cmp     rax, QWORD PTR [r11 + TENS_ELEM_COUNT]
    jne     .Ldt_type

    # Check outer_index (Scheme 1 vs Scheme 2)
    movzx   eax, WORD PTR [r10 + TENS_QSCHEME]
    cmp     eax, 1
    jne     .Ldt_s11_q2
    cmp     DWORD PTR [r10 + TENS_OUTER_IDX], 0xFFFFFFFF
    jne     .Ldt_type
    jmp     .Ldt_s11_next

.Ldt_s11_q2:
    mov     edi, DWORD PTR [r10 + TENS_OUTER_IDX]
    cmp     rdi, QWORD PTR [rbp - 48]
    jae     .Ldt_type
    cmp     rdi, QWORD PTR [rbp - 96]
    je      .Ldt_type
    cmp     edi, esi                   # outer_index != scale_index
    je      .Ldt_type
    imul    r11, rdi, TENS_SIZE
    add     r11, QWORD PTR [rbp - 88]  # outer tensor
    cmp     WORD PTR [r11 + TENS_QSCHEME], 0
    jne     .Ldt_type
    cmp     WORD PTR [r11 + TENS_DTYPE], 2   # f32
    jne     .Ldt_type
    cmp     QWORD PTR [r11 + TENS_ELEM_COUNT], 1
    jne     .Ldt_type

.Ldt_s11_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_s11_loop

    # Optional owned copy of names, layouts & payloads into arena (FLAG_OWNED)
.Ldt_s11_owned_copy:
    test    r15, FLAG_OWNED
    jz      .Ldt_step12
    mov     QWORD PTR [rbp - 96], 0
.Ldt_own_loop:
    mov     r8, QWORD PTR [rbp - 96]
    cmp     r8, QWORD PTR [rbp - 48]
    jae     .Ldt_step12
    imul    r10, r8, TENS_SIZE
    add     r10, QWORD PTR [rbp - 88]
    mov     QWORD PTR [rbp - 120], r10

    # Copy name if present
    mov     rdi, QWORD PTR [r10 + TENS_NAME_LEN]
    test    rdi, rdi
    jz      .Ldt_own_layout
    mov     rsi, 1
    call    kiln_core_arena_alloc
    jc      .Ldt_leave_err
    mov     r10, QWORD PTR [rbp - 120]
    mov     rsi, QWORD PTR [r10 + TENS_NAME_PTR]
    mov     rdx, QWORD PTR [r10 + TENS_NAME_LEN]
    mov     QWORD PTR [r10 + TENS_NAME_PTR], rax
    mov     rdi, rax
    call    kiln_core_memcpy_fast
    mov     r10, QWORD PTR [rbp - 120]

.Ldt_own_layout:
    mov     rdi, QWORD PTR [r10 + TENS_LAYOUT_LEN]
    test    rdi, rdi
    jz      .Ldt_own_data
    mov     rsi, 1
    call    kiln_core_arena_alloc
    jc      .Ldt_leave_err
    mov     r10, QWORD PTR [rbp - 120]
    mov     rsi, QWORD PTR [r10 + TENS_LAYOUT_PTR]
    mov     rdx, QWORD PTR [r10 + TENS_LAYOUT_LEN]
    mov     QWORD PTR [r10 + TENS_LAYOUT_PTR], rax
    mov     rdi, rax
    call    kiln_core_memcpy_fast
    mov     r10, QWORD PTR [rbp - 120]

.Ldt_own_data:
    mov     rdi, QWORD PTR [r10 + TENS_DATA_LEN]
    test    rdi, rdi
    jz      .Ldt_own_next
    mov     rsi, 64
    call    kiln_core_arena_alloc
    jc      .Ldt_leave_err
    mov     r10, QWORD PTR [rbp - 120]
    mov     rsi, QWORD PTR [r10 + TENS_DATA_PTR]
    mov     rdx, QWORD PTR [r10 + TENS_DATA_LEN]
    mov     QWORD PTR [r10 + TENS_DATA_PTR], rax
    mov     rdi, rax
    call    kiln_core_memcpy_bulk

.Ldt_own_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Ldt_own_loop

    # ---- Step 12: Advance cursor & fill out_dir ----
.Ldt_step12:
    mov     rax, QWORD PTR [rbp - 16]  # dir_base
    mov     rcx, QWORD PTR [rbp - 72]  # block_end
    lea     r12, [rax + rcx]
    mov     rdi, QWORD PTR [rbp - 8]   # out_dir
    mov     rax, QWORD PTR [rbp - 88]
    mov     QWORD PTR [rdi + TDIR_ITEMS], rax
    mov     rax, QWORD PTR [rbp - 48]
    mov     QWORD PTR [rdi + TDIR_COUNT], rax
    mov     QWORD PTR [rdi + TDIR_BLOCK_LEN], rcx
    mov     eax, DWORD PTR [rbp - 80]
    mov     DWORD PTR [rdi + TDIR_FLAGS], eax
    mov     DWORD PTR [rdi + TDIR_VERSION], KLNT_VERSION
    dec     r15
    leave
    KILN_OK_RET

.Ldt_frame:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_FRAME
.Ldt_limit:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_LIMIT
.Ldt_eof:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_EOF
.Ldt_type:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_TYPE
.Ldt_utf8:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_UTF8
.Ldt_leave_err:
    dec     r15
.Ldt_ret_nodec:
    leave
    stc
    ret
.size kiln_core_dec_tensors, .-kiln_core_dec_tensors

# ------------------------------------------------------------------------------
# kiln_core_enc_tensors
#   Canonical KLNT v2 encoder (spec §6.8).
#   Inputs:  rdi = const kiln_tensor_dir_t *in
#   Outputs: CF=0 (r12 advanced by block_end); CF=1 on LIMIT/TYPE/DEPTH
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_tensors
.type kiln_core_enc_tensors, @function
kiln_core_enc_tensors:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 144
    # Stack frame:
    #   [rbp -   8] = in_dir*
    #   [rbp -  16] = items*
    #   [rbp -  24] = count
    #   [rbp -  32] = flags
    #   [rbp -  40] = name_bytes
    #   [rbp -  48] = directory_bytes
    #   [rbp -  56] = payload_base
    #   [rbp -  64] = payload_bytes
    #   [rbp -  72] = block_end
    #   [rbp -  80] = dir_base
    #   [rbp -  88] = sum_tensor_names
    #   [rbp -  96] = idx
    #   [rbp - 104] = name_cursor
    #   [rbp - 112] = layout_cursor
    #   [rbp - 120] = pay_cursor
    mov     QWORD PTR [rbp - 8], rdi
    mov     QWORD PTR [rbp - 80], r12

    call    kiln_core_depth_enter
    jc      .Let_ret_nodec

    mov     rax, QWORD PTR [rdi + TDIR_ITEMS]
    mov     rcx, QWORD PTR [rdi + TDIR_COUNT]
    mov     QWORD PTR [rbp - 16], rax
    mov     QWORD PTR [rbp - 24], rcx

    cmp     rcx, QWORD PTR [rbx + CTX_MAX_COUNT]
    ja      .Let_limit
    mov     edx, 0xFFFFFFFF
    cmp     rcx, rdx
    ja      .Let_limit

    test    rcx, rcx
    jnz     .Let_measure

    # Empty directory: 64-byte header
    mov     QWORD PTR [rbp - 32], KLNT_FLAG_LE
    mov     QWORD PTR [rbp - 40], 0
    mov     QWORD PTR [rbp - 48], 0
    mov     QWORD PTR [rbp - 56], KLNT_HDR_SIZE
    mov     QWORD PTR [rbp - 64], 0
    mov     QWORD PTR [rbp - 72], KLNT_HDR_SIZE
    mov     QWORD PTR [rbp - 88], 0
    jmp     .Let_check_cap

.Let_measure:
    # Determine all-or-none FLAG_NAME from items[0]
    mov     r8, QWORD PTR [rbp - 16]
    xor     eax, eax
    cmp     QWORD PTR [r8 + TENS_NAME_LEN], 0
    setne   al
    or      eax, KLNT_FLAG_LE
    mov     QWORD PTR [rbp - 32], rax

    xor     r9, r9                     # sum_names
    xor     r10, r10                   # sum_layouts
    xor     r11, r11                   # pay_end
    xor     rcx, rcx                   # i = 0
.Let_meas_loop:
    cmp     rcx, QWORD PTR [rbp - 24]
    jae     .Let_meas_done
    imul    r8, rcx, TENS_SIZE
    add     r8, QWORD PTR [rbp - 16]

    cmp     BYTE PTR [r8 + TENS_RANK], 8
    ja      .Let_type

    # All-or-none naming check
    mov     rax, QWORD PTR [r8 + TENS_NAME_LEN]
    test    QWORD PTR [rbp - 32], KLNT_FLAG_NAME
    jz      .Let_meas_unnamed
    test    rax, rax
    jz      .Let_type
    cmp     rax, 0xFFFE
    ja      .Let_limit
    add     r9, rax
    jc      .Let_limit
    jmp     .Let_meas_lay
.Let_meas_unnamed:
    test    rax, rax
    jnz     .Let_type
.Let_meas_lay:
    mov     rax, QWORD PTR [r8 + TENS_LAYOUT_LEN]
    cmp     rax, 0xFFFE
    ja      .Let_limit
    add     r10, rax
    jc      .Let_limit

    # Greedy 64-byte payload placement
    add     r11, 63
    jc      .Let_limit
    and     r11, -64
    add     r11, QWORD PTR [r8 + TENS_DATA_LEN]
    jc      .Let_limit

    inc     rcx
    jmp     .Let_meas_loop

.Let_meas_done:
    mov     QWORD PTR [rbp - 88], r9   # sum_tensor_names
    mov     rax, r9
    add     rax, r10                   # name_bytes
    jc      .Let_limit
    cmp     rax, 0xFFFF                # u16 offsets must fit < 0xFFFF
    ja      .Let_limit
    cmp     rax, QWORD PTR [rbx + CTX_MAX_COUNT]
    ja      .Let_limit
    mov     QWORD PTR [rbp - 40], rax  # name_bytes

    mov     rdx, QWORD PTR [rbp - 24]
    shl     rdx, 7                     # count * 128
    add     rdx, rax                   # directory_bytes
    jc      .Let_limit
    mov     QWORD PTR [rbp - 48], rdx

    add     rdx, KLNT_HDR_SIZE
    jc      .Let_limit
    add     rdx, 63
    jc      .Let_limit
    and     rdx, -64                   # payload_base
    mov     QWORD PTR [rbp - 56], rdx
    mov     QWORD PTR [rbp - 64], r11  # payload_bytes
    add     rdx, r11                   # block_end
    jc      .Let_limit
    mov     QWORD PTR [rbp - 72], rdx

.Let_check_cap:
    mov     rax, r13
    sub     rax, r12
    cmp     rax, QWORD PTR [rbp - 72]
    jb      .Let_limit

    # ---- Emit 64-byte KLNT header ----
    mov     DWORD PTR [r12], KILN_MAGIC_KLNT
    mov     BYTE PTR [r12 + 4], KLNT_VERSION
    mov     al, BYTE PTR [rbp - 32]
    mov     BYTE PTR [r12 + 5], al
    mov     WORD PTR [r12 + 6], 0
    mov     eax, DWORD PTR [rbp - 24]
    mov     DWORD PTR [r12 + 8], eax
    mov     eax, DWORD PTR [rbp - 40]
    mov     DWORD PTR [r12 + 12], eax
    mov     rax, QWORD PTR [rbp - 64]
    mov     QWORD PTR [r12 + 16], rax
    mov     rax, QWORD PTR [rbp - 48]
    mov     QWORD PTR [r12 + 24], rax
    vpxor   ymm0, ymm0, ymm0
    vmovdqu YMMWORD PTR [r12 + 32], ymm0
    vzeroupper

    cmp     QWORD PTR [rbp - 24], 0
    je      .Let_done

    # ---- Emit count x 128-byte descriptors ----
    mov     QWORD PTR [rbp - 104], 0   # name_cursor
    mov     rax, QWORD PTR [rbp - 88]
    mov     QWORD PTR [rbp - 112], rax # layout_cursor = sum_tensor_names
    mov     QWORD PTR [rbp - 120], 0   # pay_cursor
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Let_desc_loop:
    mov     rcx, QWORD PTR [rbp - 96]
    cmp     rcx, QWORD PTR [rbp - 24]
    jae     .Let_heap_names_init
    imul    r8, rcx, TENS_SIZE
    add     r8, QWORD PTR [rbp - 16]   # in[i]
    mov     r9, rcx
    shl     r9, 7
    add     r9, r12
    add     r9, KLNT_HDR_SIZE          # dst descriptor

    # Zero 128 B descriptor in 4 AVX2 stores
    vpxor   ymm0, ymm0, ymm0
    vmovdqu YMMWORD PTR [r9], ymm0
    vmovdqu YMMWORD PTR [r9 + 32], ymm0
    vmovdqu YMMWORD PTR [r9 + 64], ymm0
    vmovdqu YMMWORD PTR [r9 + 96], ymm0
    vzeroupper

    movzx   eax, WORD PTR [r8 + TENS_DTYPE]
    mov     WORD PTR [r9 + WDESC_DTYPE], ax
    movzx   eax, BYTE PTR [r8 + TENS_RANK]
    mov     BYTE PTR [r9 + WDESC_RANK], al

    # name_off / name_len
    mov     rdx, QWORD PTR [r8 + TENS_NAME_LEN]
    test    rdx, rdx
    jz      .Let_d_noname
    mov     rax, QWORD PTR [rbp - 104]
    mov     WORD PTR [r9 + WDESC_NAME_OFF], ax
    mov     WORD PTR [r9 + WDESC_NAME_LEN], dx
    add     rax, rdx
    mov     QWORD PTR [rbp - 104], rax
    jmp     .Let_d_layout
.Let_d_noname:
    mov     WORD PTR [r9 + WDESC_NAME_OFF], 0xFFFF
    mov     WORD PTR [r9 + WDESC_NAME_LEN], 0

.Let_d_layout:
    mov     rdx, QWORD PTR [r8 + TENS_LAYOUT_LEN]
    test    rdx, rdx
    jz      .Let_d_nolay
    mov     rax, QWORD PTR [rbp - 112]
    mov     WORD PTR [r9 + WDESC_LAYOUT_OFF], ax
    mov     WORD PTR [r9 + WDESC_LAYOUT_LEN], dx
    add     rax, rdx
    mov     QWORD PTR [rbp - 112], rax
    jmp     .Let_d_meta
.Let_d_nolay:
    mov     WORD PTR [r9 + WDESC_LAYOUT_OFF], 0xFFFF
    mov     WORD PTR [r9 + WDESC_LAYOUT_LEN], 0

.Let_d_meta:
    mov     eax, DWORD PTR [r8 + TENS_BLOCK_SIZE]
    mov     DWORD PTR [r9 + WDESC_BLOCK_SIZE], eax
    movzx   eax, WORD PTR [r8 + TENS_QSCHEME]
    mov     WORD PTR [r9 + WDESC_QSCHEME], ax
    movzx   eax, WORD PTR [r8 + TENS_QAXIS]
    mov     WORD PTR [r9 + WDESC_QAXIS], ax
    mov     eax, DWORD PTR [r8 + TENS_GROUP_SIZE]
    mov     DWORD PTR [r9 + WDESC_GROUP_SIZE], eax
    mov     eax, DWORD PTR [r8 + TENS_SCALE_IDX]
    mov     DWORD PTR [r9 + WDESC_SCALE_IDX], eax
    mov     eax, DWORD PTR [r8 + TENS_OUTER_IDX]
    mov     DWORD PTR [r9 + WDESC_OUTER_IDX], eax

    # Canonical byte_offset = align64(pay_cursor)
    mov     rax, QWORD PTR [rbp - 120]
    add     rax, 63
    and     rax, -64
    mov     QWORD PTR [r9 + WDESC_BYTE_OFF], rax
    mov     rdx, QWORD PTR [r8 + TENS_DATA_LEN]
    mov     QWORD PTR [r9 + WDESC_BYTE_LEN], rdx
    add     rax, rdx
    mov     QWORD PTR [rbp - 120], rax

    # Copy active shape[0..rank-1] (tail already zeroed)
    movzx   edx, BYTE PTR [r8 + TENS_RANK]
    xor     eax, eax
.Let_d_shape:
    cmp     eax, edx
    jae     .Let_d_next
    mov     r10, QWORD PTR [r8 + TENS_SHAPE + rax * 8]
    mov     QWORD PTR [r9 + WDESC_SHAPE + rax * 8], r10
    inc     eax
    jmp     .Let_d_shape

.Let_d_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Let_desc_loop

    # ---- Emit gapless name heap (tensor names, then layout names) ----
.Let_heap_names_init:
    mov     rax, QWORD PTR [rbp - 24]
    shl     rax, 7
    lea     rax, [r12 + rax + KLNT_HDR_SIZE]
    mov     QWORD PTR [rbp - 104], rax # heap write ptr
    mov     QWORD PTR [rbp - 96], 0
.Let_heap_names:
    mov     rcx, QWORD PTR [rbp - 96]
    cmp     rcx, QWORD PTR [rbp - 24]
    jae     .Let_heap_layouts_init
    imul    r8, rcx, TENS_SIZE
    add     r8, QWORD PTR [rbp - 16]
    mov     rdx, QWORD PTR [r8 + TENS_NAME_LEN]
    test    rdx, rdx
    jz      .Let_hn_next
    mov     rdi, QWORD PTR [rbp - 104]
    mov     rsi, QWORD PTR [r8 + TENS_NAME_PTR]
    add     QWORD PTR [rbp - 104], rdx
    call    kiln_core_memcpy_fast
.Let_hn_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Let_heap_names

.Let_heap_layouts_init:
    mov     QWORD PTR [rbp - 96], 0
.Let_heap_layouts:
    mov     rcx, QWORD PTR [rbp - 96]
    cmp     rcx, QWORD PTR [rbp - 24]
    jae     .Let_pad_zero
    imul    r8, rcx, TENS_SIZE
    add     r8, QWORD PTR [rbp - 16]
    mov     rdx, QWORD PTR [r8 + TENS_LAYOUT_LEN]
    test    rdx, rdx
    jz      .Let_hl_next
    mov     rdi, QWORD PTR [rbp - 104]
    mov     rsi, QWORD PTR [r8 + TENS_LAYOUT_PTR]
    add     QWORD PTR [rbp - 104], rdx
    call    kiln_core_memcpy_fast
.Let_hl_next:
    inc     QWORD PTR [rbp - 96]
    jmp     .Let_heap_layouts

    # ---- Emit zero alignment padding to payload_base ----
.Let_pad_zero:
    mov     rax, QWORD PTR [rbp - 48]  # directory_bytes
    add     rax, KLNT_HDR_SIZE         # after_dir
    mov     rsi, QWORD PTR [rbp - 56]  # payload_base
    sub     rsi, rax                   # pad_len
    lea     rdi, [r12 + rax]
    call    .Lzero_fill

    # ---- Emit payloads with zero-filled alignment gaps ----
    mov     QWORD PTR [rbp - 120], 0   # pay_cursor = 0
    mov     QWORD PTR [rbp - 96], 0    # i = 0
.Let_pay_loop:
    mov     rcx, QWORD PTR [rbp - 96]
    cmp     rcx, QWORD PTR [rbp - 24]
    jae     .Let_done
    imul    r8, rcx, TENS_SIZE
    add     r8, QWORD PTR [rbp - 16]

    mov     rax, QWORD PTR [rbp - 120] # old end
    mov     rdx, rax
    add     rdx, 63
    and     rdx, -64                   # aligned off
    mov     rsi, rdx
    sub     rsi, rax                   # gap_len
    jz      .Let_pay_copy
    mov     rdi, QWORD PTR [rbp - 56]  # payload_base
    add     rdi, r12
    add     rdi, rax
    push    r8
    push    rdx
    call    .Lzero_fill
    pop     rdx
    pop     r8

.Let_pay_copy:
    mov     rax, QWORD PTR [r8 + TENS_DATA_LEN]
    test    rax, rax
    jz      .Let_pay_adv
    mov     rdi, QWORD PTR [rbp - 56]
    add     rdi, r12
    add     rdi, rdx
    mov     rsi, QWORD PTR [r8 + TENS_DATA_PTR]
    push    rdx
    push    rax
    mov     rdx, rax
    call    kiln_core_memcpy_bulk
    pop     rax
    pop     rdx
.Let_pay_adv:
    add     rdx, rax
    mov     QWORD PTR [rbp - 120], rdx
    inc     QWORD PTR [rbp - 96]
    jmp     .Let_pay_loop

.Let_done:
    mov     rax, QWORD PTR [rbp - 80]
    add     rax, QWORD PTR [rbp - 72]
    mov     r12, rax
    dec     r15
    leave
    KILN_OK_RET

.Let_limit:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_LIMIT
.Let_type:
    dec     r15
    leave
    KILN_FAIL KILN_ERR_TYPE
.Let_ret_nodec:
    leave
    stc
    ret
.size kiln_core_enc_tensors, .-kiln_core_enc_tensors

# ------------------------------------------------------------------------------
# Embedded struct{id:i64,batch:tensors,} (unframed and KLN0 framed)
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_enc_id_tensors
.type kiln_core_enc_id_tensors, @function
kiln_core_enc_id_tensors:
    push    rbp
    mov     rbp, rdi
    call    kiln_core_depth_enter
    jc      .Leit_ret
    mov     rdi, QWORD PTR [rbp + IDTEN_ID]
    call    kiln_core_enc_u64
    jc      .Leit_err
    lea     rdi, [rbp + IDTEN_BATCH]
    call    kiln_core_enc_tensors
    jc      .Leit_err
    dec     r15
    pop     rbp
    KILN_OK_RET
.Leit_err:
    dec     r15
.Leit_ret:
    pop     rbp
    stc
    ret
.size kiln_core_enc_id_tensors, .-kiln_core_enc_id_tensors

.p2align 4
.globl kiln_core_dec_id_tensors
.type kiln_core_dec_id_tensors, @function
kiln_core_dec_id_tensors:
    push    rbp
    mov     rbp, rdi
    call    kiln_core_depth_enter
    jc      .Ldit_ret
    call    kiln_core_dec_u64
    jc      .Ldit_err
    mov     QWORD PTR [rbp + IDTEN_ID], rax
    # Inner tensors is embedded inside struct; outer caller checks trailing.
    lea     rdi, [rbp + IDTEN_BATCH]
    call    kiln_core_dec_tensors
    jc      .Ldit_err
    dec     r15
    pop     rbp
    KILN_OK_RET
.Ldit_err:
    dec     r15
.Ldit_ret:
    pop     rbp
    stc
    ret
.size kiln_core_dec_id_tensors, .-kiln_core_dec_id_tensors

.p2align 4
.globl kiln_core_enc_id_tensors_framed
.type kiln_core_enc_id_tensors_framed, @function
kiln_core_enc_id_tensors_framed:
    push    rbp
    mov     rbp, rdi
    movabs  rdi, KILN_HASH_ID_TENSORS
    call    kiln_core_enc_frame_hdr
    jc      .Leitf_err
    mov     rdi, rbp
    call    kiln_core_enc_id_tensors
    pop     rbp
    ret
.Leitf_err:
    pop     rbp
    stc
    ret
.size kiln_core_enc_id_tensors_framed, .-kiln_core_enc_id_tensors_framed

.p2align 4
.globl kiln_core_dec_id_tensors_framed
.type kiln_core_dec_id_tensors_framed, @function
kiln_core_dec_id_tensors_framed:
    push    rbp
    mov     rbp, rdi
    movabs  rdi, KILN_HASH_ID_TENSORS
    call    kiln_core_dec_frame_hdr
    jc      .Lditf_err
    push    rax                     # save hash
    mov     rdi, rbp
    call    kiln_core_dec_id_tensors
    jc      .Lditf_err_pop
    call    kiln_core_check_trailing
    jc      .Lditf_err_pop
    pop     rax
    pop     rbp
    clc
    ret
.Lditf_err_pop:
    add     rsp, 8
.Lditf_err:
    pop     rbp
    stc
    ret
.size kiln_core_dec_id_tensors_framed, .-kiln_core_dec_id_tensors_framed

.section .note.GNU-stack,"",@progbits
