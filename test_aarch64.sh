#!/bin/bash
qemu-system-aarch64     -M virt     -cpu cortex-a72     -nographic     -serial mon:stdio     -kernel zig-out/bin/kernel.elf
