.section .text
.align 11 /* Vector table must be aligned to 2KB (2^11 bytes) */
.global exception_vector_table
exception_vector_table:
    /* Current EL with SP0 */
    .align 7
    b . /* Synchronous */
    .align 7
    b . /* IRQ */
    .align 7
    b . /* FIQ */
    .align 7
    b . /* SError */

    /* Current EL with SPx */
    .align 7
    b . /* Synchronous */
    .align 7
    b . /* IRQ */
    .align 7
    b . /* FIQ */
    .align 7
    b . /* SError */

    /* Lower EL using AArch64 */
    .align 7
    b . /* Synchronous */
    .align 7
    b . /* IRQ */
    .align 7
    b . /* FIQ */
    .align 7
    b . /* SError */

    /* Lower EL using AArch32 */
    .align 7
    b . /* Synchronous */
    .align 7
    b . /* IRQ */
    .align 7
    b . /* FIQ */
    .align 7
    b . /* SError */

.global exception_handler_default
exception_handler_default:
    /* Stub for now - eventually save context and call Zig */
    b .
