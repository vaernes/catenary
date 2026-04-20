const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const arch = target.result.cpu.arch;

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const opts = b.addOptions();
    const guest_image_blob = b.createModule(.{
        .root_source_file = b.path("assets/guest/guest_image_blob.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    const guest_initramfs_blob = b.createModule(.{
        .root_source_file = b.path("assets/guest/guest_initramfs_blob.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    // Unified OS Version & Metadata
    opts.addOption([]const u8, "os_version_str", b.option([]const u8, "os_version_str", "Override OS version string") orelse "0.1.0");
    const commit_id = b.run(&[_][]const u8{ "git", "rev-parse", "--short", "HEAD" });
    opts.addOption([]const u8, "commit_id", std.mem.trim(u8, commit_id, " \n\r"));

    // Unified OS Service & VMM Options
    opts.addOption(bool, "services_active", b.option(bool, "services_active", "Enable Ring-3 service manager and auto-launch") orelse true);
    opts.addOption(bool, "vmm_active", b.option(bool, "vmm_active", "Enable VMX/HVM hypervisor subsystem") orelse false);
    const vmm_launch_val = b.option(bool, "vmm_launch_linux", "Launch Linux guest on boot") orelse false;
    opts.addOption(bool, "vmm_launch_linux", vmm_launch_val);
    opts.addOption(bool, "serial_syscall_keepalive", b.option(bool, "serial_syscall_keepalive", "Emit per-syscall UART keepalive for QEMU serial-file backends") orelse false);

    const exe = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .kernel,
        }),
    });

    exe.root_module.addOptions("build_options", opts);
    exe.root_module.addImport("guest_image_blob", guest_image_blob);
    exe.root_module.addImport("guest_initramfs_blob", guest_initramfs_blob);

    if (arch == .x86_64) {
        exe.root_module.single_threaded = true;
        exe.root_module.strip = false;
        exe.use_llvm = true;
        exe.use_lld = true;
        exe.entry = .{ .symbol_name = "_low_level_start" };
        exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/entry.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/switch_context.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/user_enter.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/tables.S"));
        exe.setLinkerScript(b.path("linker.ld"));
    } else if (arch == .aarch64) {
        exe.root_module.addAssemblyFile(b.path("src/arch/aarch64/entry.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/aarch64/exceptions.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/aarch64/switch_context.S"));
        exe.root_module.addAssemblyFile(b.path("src/arch/aarch64/user_enter.S"));
        exe.setLinkerScript(b.path("src/arch/aarch64/linker.ld"));
    }

    exe.linkage = .static;
    exe.pie = false;

    b.installArtifact(exe);

    // --- User-Space Binaries (Phase 13/15) ---
    const user_names = .{ "netd", "storaged", "dashd", "containerd", "clusterd", "inputd", "windowd", "configd" };
    inline for (user_names) |name| {
        const user_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/user/{s}.zig", .{name})),
                .target = kernel_target,
                .optimize = optimize,
            }),
        });
        user_exe.linkage = .static;
        user_exe.pie = false;
        if (arch == .x86_64) {
            user_exe.entry = .{ .symbol_name = "_user_start" };
        }

        b.installArtifact(user_exe);
    }
    // --------------------------------------

    const kernel_tests = b.addTest(.{
        .name = "kernel_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kernel_tests.root_module.addOptions("build_options", opts);

    if (arch == .x86_64) {
        kernel_tests.use_llvm = true;
        kernel_tests.use_lld = true;
        kernel_tests.root_module.addAssemblyFile(b.path("src/arch/x86_64/switch_context.S"));
    }

    const run_kernel_tests = b.addRunArtifact(kernel_tests);
    const test_kernel_step = b.step("test-kernel", "Run kernel unit tests");
    test_kernel_step.dependOn(&run_kernel_tests.step);
}
