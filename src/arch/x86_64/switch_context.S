.text
.global switchContext
.type switchContext, @function
switchContext:
    # SysV ABI: old_rsp in %rdi, new_rsp in %rsi
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, (%rdi)
    movq %rsi, %rsp

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    retq

.size switchContext, .-switchContext
