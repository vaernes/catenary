.global _user_start
.extern umain

.section .text
_user_start:
    /* Ring-3 entry point */
    /* SysV ABI requires stack to be 16-byte aligned before call */
    andq $-16, %rsp
    call umain
    /* If main returns, loop forever */
1:  pause
    jmp 1b
