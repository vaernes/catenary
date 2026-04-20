#include <stdio.h>
#include <string.h>
#include <unistd.h>

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

static int run_init(void) {
    printf("guest_rootfs: init started\n");
    printf("guest_rootfs: running from embedded OCI rootfs\n");
    print_os_release();

    for (;;) {
        sleep(30);
        printf("guest_rootfs: heartbeat\n");
    }
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

    return run_init();
}