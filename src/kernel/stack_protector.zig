/// Stack Smashing Protection (SSP) support for freestanding kernel.
///
/// Provides the two ABI symbols that the compiler-generated stack-canary
/// prologue/epilogue emit references to:
///
///   __stack_chk_guard  — the "canary" value placed between the local
///                        variables and the saved return address.
///   __stack_chk_fail   — called when the canary has been overwritten,
///                        indicating a stack buffer overflow.
///
/// The canary is seeded with boot-time entropy (RDTSC) so that its value
/// is unpredictable across reboots.  A deterministic fallback is used if
/// RDTSC returns zero (should never happen on real hardware).
const builtin = @import("builtin");

/// The actual canary value.  Initialised to a compile-time constant and
/// re-seeded at boot via `initCanary()`.
pub export var __stack_chk_guard: usize = 0x00000aff0a0d0000;

/// Called by compiler-inserted epilogue when the canary has been corrupted.
/// This is a noreturn function — the kernel halts immediately.
pub export fn __stack_chk_fail() callconv(.c) noreturn {
    // Write a panic message directly to the serial port so it survives
    // even if the rest of the kernel is corrupted.
    const msg = "\n!!! STACK SMASHING DETECTED !!!\n";
    if (comptime builtin.cpu.arch == .x86_64) {
        for (msg) |c| {
            asm volatile ("outb %al, %dx"
                :
                : [al] "{al}" (c),
                  [dx] "{dx}" (@as(u16, 0x3F8)),
            );
        }
    }
    // Halt the CPU.  There is no safe recovery from a stack-smash.
    while (true) {
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("cli");
            asm volatile ("hlt");
        }
    }
}

/// Re-seed the canary with hardware entropy.  Must be called once during
/// early boot, after RDTSC is functional.
pub fn initCanary() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile ("rdtsc"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );
        var seed: u64 = (@as(u64, high) << 32) | low;
        // Mix the bits (splitmix64-style) to increase diffusion.
        seed ^= seed >> 30;
        seed *%= 0xBF58_476D_1CE4_E5B9;
        seed ^= seed >> 27;
        seed *%= 0x94D0_49BB_1331_11EB;
        seed ^= seed >> 31;
        // Ensure the canary is never all-zero (a zero canary is trivially
        // guessable and also matches uninitialised stack memory).
        if (seed == 0) seed = 0xDEAD_BEEF_CAFE_BABE;
        __stack_chk_guard = @as(usize, @intCast(seed));
    }
}
