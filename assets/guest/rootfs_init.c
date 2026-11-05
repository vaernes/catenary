#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static void print_os_release(void) {
    FILE *fp = fopen("/etc/os-release", "r");
    char line[256];

    if (!fp) {
        printf("guest_rootfs: /etc/os-release unavailable\n");
        return;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        fputs(line, stdout);
    }

    fclose(fp);
}

static void print_env(char **envp) {
    while (*envp) {
        puts(*envp);
        envp += 1;
    }
}

static int run_shell(char **envp) {
    char line[256];

    printf("guest_rootfs: shell ready\n");
    printf("guest_rootfs: builtins = help, env, os-release, exit\n");

    for (;;) {
        printf("guest-sh$ ");
        if (!fgets(line, sizeof(line), stdin)) {
            printf("guest_rootfs: shell EOF\n");
            return 0;
        }

        line[strcspn(line, "\r\n")] = '\0';
        if (strcmp(line, "") == 0) continue;
        if (strcmp(line, "help") == 0) {
            printf("help env os-release exit\n");
        } else if (strcmp(line, "env") == 0) {
            print_env(envp);
        } else if (strcmp(line, "os-release") == 0) {
            print_os_release();
        } else if (strcmp(line, "exit") == 0) {
            printf("guest_rootfs: shell exit\n");
            return 0;
        } else {
            printf("guest_rootfs: unknown command: %s\n", line);
        }
    }
}

static int run_init(char **envp) {
    printf("guest_rootfs: init started\n");
    printf("guest_rootfs: running from embedded OCI rootfs\n");
    print_os_release();

    const int serial_fd = open("/dev/ttyS0", O_RDWR | O_NOCTTY);
    if (serial_fd < 0) {
        printf("guest_rootfs: cannot open /dev/ttyS0\n");
        for (;;) sleep(60);
    }
    if (dup2(serial_fd, STDIN_FILENO) < 0) {
        printf("guest_rootfs: cannot connect /dev/ttyS0 to stdin\n");
        for (;;) sleep(60);
    }
    if (serial_fd > STDERR_FILENO) close(serial_fd);

    (void)run_shell(envp);
    for (;;) sleep(60);
}

int main(int argc, char **argv, char **envp) {
    const char *prog = base_name(argv[0]);
    (void)argc;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (strcmp(prog, "sh") == 0) {
        return run_shell(envp);
    }
    if (strcmp(prog, "env") == 0) {
        print_env(envp);
        return 0;
    }

    return run_init(envp);
}