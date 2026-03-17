.section .text
.global _user_start
_user_start:
    # Milestone 'N' - confirms netd.S code execution
    movw $0x3F8, %dx
    movb $'N', %al
    outb %al, %dx
    
    # Manually call main
    movabsq $main, %rax
    call *%rax

    # Should not return
1:  hlt
    jmp 1b
