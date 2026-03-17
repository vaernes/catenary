.section .text
.global _low_level_start
_low_level_start:
    cli
    /* Simple serial out 'A' for early debug if needed */
    mov $0x3F8, %dx
    mov $0x41, %al
    out %al, %dx

    /* Enable SSE before calling Zig code (compiler may emit XMM ops) */
    mov %cr0, %rax
    and $~(1 << 2), %rax       /* Clear CR0.EM (x87 emulation off) */
    or  $(1 << 1), %rax        /* Set CR0.MP (monitor coprocessor) */
    mov %rax, %cr0

    mov %cr4, %rax
    or  $((1 << 9) | (1 << 10)), %rax  /* Set OSFXSR + OSXMMEXCPT */
    mov %rax, %cr4

    /* Initialize FPU/x87 for userspace (essential for float ops) */
    finit

    /* Call Zig entry */
    and $-16, %rsp
    call _kernel_main
    hlt
1:  jmp 1b
