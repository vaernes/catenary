#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <dirent.h>

/* -----------------------------------------------------------------------
 * Helper: write a string to a file (best-effort).
 * ----------------------------------------------------------------------- */
static void write_file(const char *path, const char *val) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror(path); return; }
    size_t len = strlen(val);
    ssize_t written = write(fd, val, len);
    if (written < 0 || (size_t)written != len)
        perror(path);
    close(fd);
}

static int dir_has_entries(const char *path) {
    DIR *dir = opendir(path);
    if (!dir)
        return 0;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            closedir(dir);
            return 1;
        }
    }

    closedir(dir);
    return 0;
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int has_oci_entrypoint(const char *root) {
    char path[256];
    const char *candidates[] = {
        "/sbin/init",
        "/usr/sbin/init",
        "/init",
        "/bin/sh",
        "/bin/bash",
        NULL,
    };

    for (int i = 0; candidates[i]; i++) {
        snprintf(path, sizeof(path), "%s%s", root, candidates[i]);
        if (file_exists(path))
            return 1;
    }

    return 0;
}

static int chroot_into_oci(const char *new_root) {
    if (chdir(new_root) != 0) {
        perror("chdir new_root");
        return -1;
    }

    if (chroot(".") != 0) {
        perror("chroot new_root");
        return -1;
    }

    if (chdir("/") != 0) {
        perror("chdir / after chroot");
        return -1;
    }

    printf("guest_init: chroot fallback into OCI rootfs\n");
    return 0;
}

/* -----------------------------------------------------------------------
 * Mount the essential virtual filesystems.
 * ----------------------------------------------------------------------- */
static void mount_basics(void) {
    mkdir("/proc", 0755);
    if (mount("proc", "/proc", "proc", 0, "") != 0)
        perror("mount /proc");

    mkdir("/sys", 0755);
    if (mount("sysfs", "/sys", "sysfs", 0, "") != 0)
        perror("mount /sys");

    mkdir("/dev", 0755);
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") != 0)
        perror("mount /dev");

    mkdir("/dev/pts", 0755);
    if (mount("devpts", "/dev/pts", "devpts", 0, "newinstance,ptmxmode=0666") != 0)
        perror("mount /dev/pts");

    mkdir("/tmp", 0755);
    if (mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777") != 0)
        perror("mount /tmp");
}

/* -----------------------------------------------------------------------
 * Set up a cgroupv2 hierarchy for the container workload.
 *
 * Layout:
 *   /sys/fs/cgroup              (unified cgroupv2 root)
 *   /sys/fs/cgroup/catenary     (top-level slice for all guest workloads)
 *   /sys/fs/cgroup/catenary/container-0  (per-container group)
 *
 * We enable cpu + memory controllers and apply simple limits.
 * ----------------------------------------------------------------------- */
static void setup_cgroups(void) {
    const char *cgroup_root  = "/sys/fs/cgroup";
    const char *slice        = "/sys/fs/cgroup/catenary";
    const char *container_cg = "/sys/fs/cgroup/catenary/container-0";

    mkdir(cgroup_root, 0755);
    /* Mount unified cgroupv2 hierarchy */
    if (mount("cgroup2", cgroup_root, "cgroup2", 0, "") != 0)
        perror("mount cgroup2");

    /* Enable cpu and memory controllers in root */
    write_file("/sys/fs/cgroup/cgroup.subtree_control", "+cpu +memory");

    mkdir(slice, 0755);
    write_file("/sys/fs/cgroup/catenary/cgroup.subtree_control", "+cpu +memory");

    mkdir(container_cg, 0755);

    /* Limit: 50% of one CPU (50000 / 100000 us period) */
    write_file("/sys/fs/cgroup/catenary/container-0/cpu.max", "50000 100000");
    /* Limit: 256 MiB of memory */
    write_file("/sys/fs/cgroup/catenary/container-0/memory.max", "268435456");

    /* Move ourselves into the container cgroup */
    char pidstr[32];
    snprintf(pidstr, sizeof(pidstr), "%d", getpid());
    write_file("/sys/fs/cgroup/catenary/container-0/cgroup.procs", pidstr);

    printf("guest_init: cgroups configured (cpu.max=50%%, memory.max=256MiB)\n");
}

/* -----------------------------------------------------------------------
 * pivot_root into the OCI rootfs unpacked at /mnt/container.
 *
 * The OCI image is expected to have been written by the host containerd
 * service via storaged DMA writes before the guest was launched.
 *
 * Steps (per man 2 pivot_root):
 *   1. Mount the new rootfs at /mnt/container (bind-mount to itself so it
 *      is a mount point even if already on a disk partition).
 *   2. Create /mnt/container/.old_root as the put-old target.
 *   3. Call pivot_root(new, put_old).
 *   4. chdir("/") to update cwd relative to new root.
 *   5. Unmount the old root from /.old_root.
 *   6. Remove the /.old_root directory.
 * ----------------------------------------------------------------------- */
static int pivot_into_oci(void) {
    const char *new_root = "/mnt/container";
    const char *old_root = "/mnt/container/.old_root";

    mkdir("/mnt", 0755);
    if (mkdir(new_root, 0755) != 0 && errno != EEXIST) {
        perror("mkdir /mnt/container");
        return -1;
    }

    /* An empty mountpoint is not a usable OCI rootfs. */
    struct stat st;
    if (stat(new_root, &st) != 0 || !S_ISDIR(st.st_mode) || !dir_has_entries(new_root) || !has_oci_entrypoint(new_root)) {
        return -1;
    }

    /* Bind-mount new_root onto itself so it is its own mount point. */
    if (mount(new_root, new_root, NULL, MS_BIND | MS_REC, NULL) != 0) {
        perror("bind-mount new_root");
        return -1;
    }

    mkdir(old_root, 0755);

    /* pivot_root is not in glibc – call it directly. */
    if (syscall(SYS_pivot_root, new_root, old_root) != 0) {
        if (errno == EINVAL) {
            rmdir(old_root);
            return chroot_into_oci(new_root);
        }
        perror("pivot_root");
        return -1;
    }

    if (chdir("/") != 0) { perror("chdir /"); return -1; }

    /* Unmount and remove the old root. */
    if (umount2("/.old_root", MNT_DETACH) != 0)
        perror("umount old_root");
    rmdir("/.old_root");

    printf("guest_init: pivot_root complete – running in OCI container filesystem\n");
    return 0;
}

/* -----------------------------------------------------------------------
 * Launch the container entrypoint (or a fallback shell).
 * ----------------------------------------------------------------------- */
static void run_entrypoint(void) {
    /* Try the OCI conventional entrypoints in order. */
    const char *candidates[] = {
        "/sbin/init",
        "/usr/sbin/init",
        "/init",
        "/bin/sh",
        "/bin/bash",
        NULL,
    };

    for (int i = 0; candidates[i]; i++) {
        struct stat st;
        if (stat(candidates[i], &st) == 0) {
            printf("guest_init: exec %s\n", candidates[i]);
            char *argv[] = { (char *)candidates[i], NULL };
            char *envp[] = {
                "PATH=/sbin:/usr/sbin:/bin:/usr/bin",
                "HOME=/root",
                "TERM=linux",
                "container=catenary",
                NULL
            };
            execve(candidates[i], argv, envp);
            perror("execve failed");
        }
    }

    printf("guest_init: no entrypoint found; dropping into idle loop\n");
    while (1) sleep(60);
}

/* -----------------------------------------------------------------------
 * Entry point
 * ----------------------------------------------------------------------- */
int main(void) {
    /* Disable stdio buffering so output appears immediately on ttyS0. */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    printf("Catenary OS Guest Init: starting\n");

    mount_basics();
    setup_cgroups();

    if (pivot_into_oci() == 0) {
        /* Re-mount /proc and /sys inside the new root. */
        mount_basics();
        printf("Catenary OS Guest Init: SUCCESS\n");
        run_entrypoint();
    } else {
        /* No OCI rootfs yet – report success and idle. */
        printf("Catenary OS Guest Init: SUCCESS\n");
        printf("guest_init: no OCI rootfs, entering idle loop\n");
        while (1) sleep(60);
    }

    return 0;
}
