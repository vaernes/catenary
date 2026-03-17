.section .text
.global _user_start
_user_start:
    # Set up basic stack for debugging
    movq %rsp, %rbp
    
    # Pass bootstrap address (in rdi from trampoline) as first argument to _start
    # movq %rbx, %rdi
    call umain

    # Should not return
1:  pause
    jmp 1b

