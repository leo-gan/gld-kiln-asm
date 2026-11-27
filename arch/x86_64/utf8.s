.intel_syntax noprefix
.include "defs.inc"

.text

# ------------------------------------------------------------------------------
# kiln_core_utf8_validate
#   Validates RFC 3629 UTF-8 over [rdi, rdi + rsi).
#   Inputs:  rdi = const uint8_t *ptr, rsi = size_t len
#   Outputs: eax = 1, CF = 0 if valid; eax = 0, CF = 1 if invalid
#   Preserves: rbx, rbp, r12, r13, r14, r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_utf8_validate
.type kiln_core_utf8_validate, @function
kiln_core_utf8_validate:
    test    rsi, rsi
    jz      .Lutf8_valid
    mov     rdx, rdi                # cur
    lea     rcx, [rdi + rsi]        # end

    cmp     rsi, 32
    jb      .Lutf8_swar8

.p2align 4
.Lutf8_avx_loop:
    vmovdqu ymm0, YMMWORD PTR [rdx]
    vpmovmskb eax, ymm0
    test    eax, eax
    jnz     .Lutf8_non_ascii_avx
    add     rdx, 32
    mov     rax, rcx
    sub     rax, rdx
    cmp     rax, 32
    jae     .Lutf8_avx_loop
    vzeroupper

.Lutf8_swar8:
    mov     r8, 0x8080808080808080
.Lutf8_swar8_loop:
    mov     rax, rcx
    sub     rax, rdx
    cmp     rax, 8
    jb      .Lutf8_byte_ascii
    mov     rax, QWORD PTR [rdx]
    test    rax, r8
    jnz     .Lutf8_scalar
    add     rdx, 8
    jmp     .Lutf8_swar8_loop

.Lutf8_byte_ascii:
    mov     rax, rcx
    sub     rax, rdx
    cmp     rax, 4
    jb      .Lutf8_byte_loop
    mov     eax, DWORD PTR [rdx]
    or      eax, DWORD PTR [rcx - 4]
    test    eax, 0x80808080
    jnz     .Lutf8_scalar
    jmp     .Lutf8_valid

.Lutf8_byte_loop:
    cmp     rdx, rcx
    jae     .Lutf8_valid
    movzx   eax, BYTE PTR [rdx]
    test    al, 0x80
    jnz     .Lutf8_scalar
    inc     rdx
    jmp     .Lutf8_byte_loop

.Lutf8_non_ascii_avx:
    vzeroupper

.p2align 4
.Lutf8_scalar:
    cmp     rdx, rcx
    jae     .Lutf8_valid
    movzx   eax, BYTE PTR [rdx]
    cmp     al, 0x80
    jae     .Lutf8_multibyte
    inc     rdx
    jmp     .Lutf8_scalar

.Lutf8_multibyte:
    cmp     al, 0xC2
    jb      .Lutf8_invalid
    cmp     al, 0xDF
    ja      .Lutf8_check_3byte

    # 2-byte sequence: [C2..DF] [80..BF]
    mov     r8, rcx
    sub     r8, rdx
    cmp     r8, 2
    jb      .Lutf8_invalid
    movzx   r8d, BYTE PTR [rdx + 1]
    and     r8d, 0xC0
    cmp     r8d, 0x80
    jne     .Lutf8_invalid
    add     rdx, 2
    jmp     .Lutf8_scalar

.Lutf8_check_3byte:
    cmp     al, 0xEF
    ja      .Lutf8_check_4byte

    # 3-byte sequence
    mov     r8, rcx
    sub     r8, rdx
    cmp     r8, 3
    jb      .Lutf8_invalid
    movzx   r8d, BYTE PTR [rdx + 1]
    movzx   r9d, BYTE PTR [rdx + 2]
    and     r9d, 0xC0
    cmp     r9d, 0x80
    jne     .Lutf8_invalid

    cmp     al, 0xE0
    je      .Lutf8_e0
    cmp     al, 0xED
    je      .Lutf8_ed
    and     r8d, 0xC0
    cmp     r8d, 0x80
    jne     .Lutf8_invalid
    add     rdx, 3
    jmp     .Lutf8_scalar

.Lutf8_e0:
    lea     r10d, [r8 - 0xA0]
    cmp     r10d, 0x1F
    ja      .Lutf8_invalid
    add     rdx, 3
    jmp     .Lutf8_scalar

.Lutf8_ed:
    lea     r10d, [r8 - 0x80]
    cmp     r10d, 0x1F
    ja      .Lutf8_invalid
    add     rdx, 3
    jmp     .Lutf8_scalar

.Lutf8_check_4byte:
    cmp     al, 0xF4
    ja      .Lutf8_invalid

    # 4-byte sequence
    mov     r8, rcx
    sub     r8, rdx
    cmp     r8, 4
    jb      .Lutf8_invalid
    movzx   r8d, BYTE PTR [rdx + 1]
    movzx   r9d, BYTE PTR [rdx + 2]
    movzx   r10d, BYTE PTR [rdx + 3]
    and     r9d, 0xC0
    cmp     r9d, 0x80
    jne     .Lutf8_invalid
    and     r10d, 0xC0
    cmp     r10d, 0x80
    jne     .Lutf8_invalid

    cmp     al, 0xF0
    je      .Lutf8_f0
    cmp     al, 0xF4
    je      .Lutf8_f4
    and     r8d, 0xC0
    cmp     r8d, 0x80
    jne     .Lutf8_invalid
    add     rdx, 4
    jmp     .Lutf8_scalar

.Lutf8_f0:
    lea     r11d, [r8 - 0x90]
    cmp     r11d, 0x2F
    ja      .Lutf8_invalid
    add     rdx, 4
    jmp     .Lutf8_scalar

.Lutf8_f4:
    lea     r11d, [r8 - 0x80]
    cmp     r11d, 0x0F
    ja      .Lutf8_invalid
    add     rdx, 4
    jmp     .Lutf8_scalar

.Lutf8_valid:
    mov     eax, 1
    clc
    ret

.Lutf8_invalid:
    xor     eax, eax
    stc
    ret
.size kiln_core_utf8_validate, .-kiln_core_utf8_validate

# ------------------------------------------------------------------------------
# kiln_core_utf8_copy
#   Fused single-pass AVX2/SWAR ASCII validate + copy from src to dst.
#   Falls back to kiln_core_utf8_validate + copy on non-ASCII bytes.
#   Inputs:  rdi = uint8_t *dst, rsi = const uint8_t *src, rdx = size_t len
#   Outputs: eax = 1, CF = 0 on valid; eax = 0, CF = 1 on invalid UTF-8
#   Preserves: rbx, rbp, r12, r13, r14, r15
# ------------------------------------------------------------------------------
.p2align 4
.globl kiln_core_utf8_copy
.type kiln_core_utf8_copy, @function
kiln_core_utf8_copy:
    test    rdx, rdx
    jz      .Luc_valid
    xor     rcx, rcx                # i = 0

    cmp     rdx, 32
    jb      .Luc_swar8

.p2align 4
.Luc_avx_loop:
    vmovdqu ymm0, YMMWORD PTR [rsi + rcx]
    vpmovmskb eax, ymm0
    test    eax, eax
    jnz     .Luc_non_ascii_avx
    vmovdqu YMMWORD PTR [rdi + rcx], ymm0
    add     rcx, 32
    mov     rax, rdx
    sub     rax, rcx
    cmp     rax, 32
    jae     .Luc_avx_loop
    vzeroupper

.Luc_swar8:
    mov     r8, 0x8080808080808080
.Luc_swar8_loop:
    mov     rax, rdx
    sub     rax, rcx
    cmp     rax, 8
    jb      .Luc_tail_bytes
    mov     rax, QWORD PTR [rsi + rcx]
    test    rax, r8
    jnz     .Luc_non_ascii
    mov     QWORD PTR [rdi + rcx], rax
    add     rcx, 8
    jmp     .Luc_swar8_loop

.Luc_tail_bytes:
    mov     rax, rdx
    sub     rax, rcx
    cmp     rax, 4
    jb      .Luc_tail_loop
    mov     r9d, DWORD PTR [rsi + rcx]
    mov     r10d, DWORD PTR [rsi + rdx - 4]
    mov     eax, r9d
    or      eax, r10d
    test    eax, 0x80808080
    jnz     .Luc_non_ascii
    mov     DWORD PTR [rdi + rcx], r9d
    mov     DWORD PTR [rdi + rdx - 4], r10d
    jmp     .Luc_valid

.Luc_tail_loop:
    cmp     rcx, rdx
    jae     .Luc_valid
    movzx   eax, BYTE PTR [rsi + rcx]
    test    al, 0x80
    jnz     .Luc_non_ascii
    mov     BYTE PTR [rdi + rcx], al
    inc     rcx
    jmp     .Luc_tail_loop

.Luc_non_ascii_avx:
    vzeroupper

.Luc_non_ascii:
    # Validate remaining tail [rsi + rcx, rsi + rdx), then copy if valid
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    lea     rdi, [rsi + rcx]
    mov     rsi, rdx
    sub     rsi, rcx
    call    kiln_core_utf8_validate
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    jc      .Luc_invalid

    sub     rdx, rcx
    add     rdi, rcx
    add     rsi, rcx
    mov     rcx, rdx
    rep movsb
.Luc_valid:
    mov     eax, 1
    clc
    ret

.Luc_invalid:
    xor     eax, eax
    stc
    ret
.size kiln_core_utf8_copy, .-kiln_core_utf8_copy

.section .note.GNU-stack,"",@progbits
