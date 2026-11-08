/* SPDX-License-Identifier: 0BSD */
ENTRY(entry)
PHDRS {
    text PT_LOAD FLAGS(5);
    ro PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
    dynamic PT_DYNAMIC FLAGS(6);
}
SECTIONS {
    .text 0 : { *(.text) } :text
    .rodata 0x4000 : { *(.rodata) } :ro
    .dynsym : { *(.dynsym) } :ro
    .dynstr : { *(.dynstr) } :ro
    .hash : { *(.hash) } :ro
    .eh_frame_hdr : {
        __eh_frame_hdr = .;
        *(.eh_frame_hdr)
        __eh_frame_hdr_end = .;
    } :ro
    .eh_frame : { *(.eh_frame) } :ro
    .data 0x8000 : { *(.data) } :data
    .dynamic : { *(.dynamic) } :data :dynamic
    .bss (NOLOAD) : { __bss_start = .; *(.bss) __bss_end = .; } :data
    /DISCARD/ : { *(.comment) *(.note*) *(.gnu*) }
}
