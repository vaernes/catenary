/* Catenary OS Linker Script */
ENTRY(_low_level_start)

KERNEL_VIRT_BASE = 0xffffffff80000000;
KERNEL_LOAD_BASE = 0x01000000;

PHDRS
{
    text            PT_LOAD FLAGS(5); /* Read + Execute */
    rodata          PT_LOAD FLAGS(4); /* Read-only */
    data            PT_LOAD FLAGS(6); /* Read + Write */
}

SECTIONS
{
    /* Map the kernel in the higher half while loading it in low physical memory. */
    . = KERNEL_VIRT_BASE + KERNEL_LOAD_BASE;


    . = ALIGN(0x1000);

    .text : AT(ADDR(.text) - KERNEL_VIRT_BASE) {
        *(.text .text.*)
    } :text

    . = ALIGN(0x1000);

    .rodata : AT(ADDR(.rodata) - KERNEL_VIRT_BASE) {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(0x1000);

    .data : AT(ADDR(.data) - KERNEL_VIRT_BASE) {
        *(.data .data.*)
    } :data

    .bss : AT(ADDR(.bss) - KERNEL_VIRT_BASE) {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.note .note.*)
    }
}
