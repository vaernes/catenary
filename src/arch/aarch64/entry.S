.section .text
.global _start

_start:
    /* Disable interrupts */
    msr daifset, #2

    /* Setup stack pointer */
    /* Limine provides stack for us if using limine protocol, but for now we define a local one */
    ldr x0, =stack_top
    mov sp, x0

    /* Jump to Zig kernel_main */
    bl _kernel_main

    /* Loop forever if kernel returns */
1:  wfi
    b 1b

.section .bss
.align 16
stack_bottom:
    .skip 4096 * 4
stack_top:
