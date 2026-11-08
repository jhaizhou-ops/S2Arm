ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00100000;
    .text : { *(.text .text.*) } :text

    . = 0x00200000;
    .rodata : { *(.note.gnu.build-id) *(.rodata .rodata.*) } :rodata

    . = 0x00300000;
    .data : { *(.data .data.*) } :data
    .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) } :data
}
