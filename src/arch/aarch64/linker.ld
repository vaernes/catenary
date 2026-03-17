ENTRY(_start)

SECTIONS
{
    /* QEMU 'virt' board loads kernel at 0x40000000 by default */
    . = 0x40000000;

    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }
}
