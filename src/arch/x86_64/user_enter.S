.text
.global enterUserMode
.type enterUserMode, @function
enterUserMode:
    # SysV ABI: rdi=rip, rsi=rsp, rdx=arg0, rcx=cs, r8=ss
    # The caller provides 0x18 (CS) and 0x20 (SS). We MUST add 0x3 for RPL 3.
    orq $3, %rcx
    orq $3, %r8

    # Save kernel rsp for jump back from usermode
    pushq %rdi
    movq %rsp, %rdi
    call setKernelSavedRsp
    popq %rdi

    # Sync I/O port for milestones
    movw $0x3F8, %dx

    # Align stack to 16 bytes for user mode entry
    andq $-16, %rsi

    # Set data segment registers to User Data (RPL 3)
    movw %r8w, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs

    # Prepare IRETQ stack frame
    pushq %r8         # SS
    pushq %rsi        # RSP
    # pushq $0x0202     # RFLAGS (IF=1, IOPL=0) - for production
    pushq $0x3202     # RFLAGS (IF=1, IOPL=3) - allow Ring-3 I/O for debug stubs
    pushq %rcx        # CS
    pushq %rdi        # RIP

    # Pass arg0 to usermode (usually handle or bootstrap)
    movq %rdx, %rdi   
    
    iretq
