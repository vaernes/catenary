.section .text
.global catenary_lgdt
.global catenary_lidt
.global catenary_sgdt
.global catenary_sidt

catenary_lgdt:
    lgdt (%rdi)
    ret

catenary_lidt:
    lidt (%rdi)
    ret

catenary_sgdt:
    sgdt (%rdi)
    ret

catenary_sidt:
    sidt (%rdi)
    ret

.global catenary_ltr
catenary_ltr:
    ltr %di
    ret
