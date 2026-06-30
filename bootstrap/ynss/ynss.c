/*
 * ynss -- a tiny LD_PRELOAD that answers getpwnam/getpwuid/getgr* from app-owned
 * files, because musl reads /etc/passwd directly and Android gives us no writable
 * /etc. It replaces nss_wrapper (which assumes glibc's NSS module API and does not
 * build on musl). Files come from $NSS_WRAPPER_PASSWD / $NSS_WRAPPER_GROUP (the
 * same env names the bundle already sets), falling back to the on-device defaults.
 *
 * Only the lookups sshd and a basic shell need are implemented; everything is
 * read fresh from the file on each call (these are not hot paths).
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <pwd.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/fsuid.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <resolv.h>
#include <sys/time.h>
#include <strings.h>
#include <spawn.h>

#ifndef SYS_io_uring_setup
#define SYS_io_uring_setup 425
#endif
#ifndef SYS_io_uring_enter
#define SYS_io_uring_enter 426
#endif
#ifndef SYS_io_uring_register
#define SYS_io_uring_register 427
#endif

/* ---- Android/musl seccomp compat ----
 * Android's app (untrusted_app) seccomp filter kills faccessat2 (439) with
 * SIGSYS. musl routes the access-with-effective-ids checks (eaccess /
 * euidaccess, and faccessat with a flag like AT_EACCESS) to faccessat2 whenever
 * the real/effective ids differ -- which they do for an Android app. bash's
 * PATH-search executable check calls eaccess(), so every externally-resolved
 * command is killed. Critically, musl's eaccess calls its faccessat INTERNALLY
 * (not via the PLT), so overriding faccessat alone is bypassed -- we must
 * interpose eaccess/euidaccess themselves. We run as a single uid, so the
 * real-vs-effective distinction is moot; force the plain faccessat syscall (48),
 * which Android allows. Makes the whole musl userland usable, no musl rebuild.
 * musl's public syscall() already returns -1 and sets errno on failure. */
static int compat_access(int dirfd, const char *path, int mode)
{
    return (int)syscall(SYS_faccessat, dirfd, path, mode);
}

int faccessat(int dirfd, const char *path, int mode, int flag)
{
    (void)flag;
    return compat_access(dirfd, path, mode);
}

int eaccess(const char *path, int mode)
{
    return compat_access(AT_FDCWD, path, mode);
}

int euidaccess(const char *path, int mode)
{
    return compat_access(AT_FDCWD, path, mode);
}

/* Android's app seccomp blocks the legacy accept(2) syscall (only accept4 is
 * whitelisted), and musl's accept() issues accept(2) directly -- so sshd dies
 * with SIGSYS the moment a client connects. Route accept() through accept4(2),
 * which is equivalent with flags=0. */
int accept(int fd, struct sockaddr *addr, socklen_t *addrlen)
{
    return (int)syscall(SYS_accept4, fd, addr, addrlen, 0);
}

/* Android's app seccomp blocks setfsuid/setfsgid with SIGSYS. ncurses' safe
 * file open (_nc_safe_fopen, used when interactive bash loads terminfo) briefly
 * drops fs-privileges with these; a single-uid app has nothing to drop. No-op
 * them, returning the current id as the "previous" value the caller restores.
 * Without this, every interactive (PTY) ssh session dies on shell startup. */
int setfsuid(uid_t fsuid)
{
    (void)fsuid;
    return (int)getuid();
}

int setfsgid(gid_t fsgid)
{
    (void)fsgid;
    return (int)getgid();
}

/* libuv (used by neovim and others) issues io_uring_setup/enter/register via the
 * raw syscall() wrapper, which Android's app seccomp kills with SIGSYS. libuv
 * already falls back to epoll if io_uring is unavailable -- but only when the
 * call RETURNS an error; the seccomp kill never returns. Interpose syscall()
 * itself and report io_uring as -ENOSYS so the epoll fallback engages; forward
 * every other syscall unchanged to the real libc wrapper. */
long syscall(long number, ...)
{
    long args[6];
    va_list ap;
    va_start(ap, number);
    for (int i = 0; i < 6; i++)
        args[i] = va_arg(ap, long);
    va_end(ap);

    if (number == SYS_io_uring_setup || number == SYS_io_uring_enter ||
        number == SYS_io_uring_register) {
        errno = ENOSYS;
        return -1;
    }

    static long (*real_syscall)(long, long, long, long, long, long, long);
    if (!real_syscall)
        real_syscall = (long (*)(long, long, long, long, long, long, long))
            dlsym(RTLD_NEXT, "syscall");
    return real_syscall(number, args[0], args[1], args[2], args[3], args[4], args[5]);
}

/* ---- exec routing: system-linker execution for targetSdk >= 29 ----
 * Android 10+ denies execve() of files in the app's writable data dir
 * (/data/data/com.yndronix/...) for apps that target API 29+ (the W^X rule;
 * SELinux execute_no_trans on app_data_file). The dynamic linker may still
 * LOAD such a file (mmap PROT_EXEC from a read-only fd), so we route every exec
 * of a data-dir binary through the musl loader that the app ships in its
 * nativeLibraryDir (an execve-allowed location):
 *
 *     execve("/data/.../bin/foo", argv)
 *       -> execve($YND_LINKER, [loader, "--argv0", argv[0],
 *                               "/data/.../bin/foo", argv[1..]])
 *
 * For "#!" scripts the kernel's shebang expansion is bypassed (we are not
 * execve-ing the script itself), so we read and emulate the interpreter line.
 *
 * $YND_LINKER is exported by the Android launcher as
 * <nativeLibraryDir>/libyndld.so. When it is unset -- a targetSdk <= 28 build,
 * or any non-Android host -- every interposer falls through to the real libc
 * function unchanged, so this shim is a no-op off-device.
 *
 * Known limitation: /proc/self/exe reads as the loader, not the real program.
 * The binaries in the bundle (bash, coreutils, sshd, runit, tmux, neovim) pass
 * absolute argv[0]s and do not rely on it; --argv0 preserves a custom argv[0]
 * (e.g. a login shell's "-bash"). Static binaries cannot be loader-run, but the
 * closure is dynamically linked musl throughout.
 */

static const char *yndexec_data_dir(void)
{
    return "/data/data/com.yndronix";
}

/* True only for an absolute path inside the app data dir; /system and /apex
 * (bionic) targets and relative paths are left to the real libc. */
static int yndexec_under_data_dir(const char *path)
{
    if (path == NULL || path[0] != '/')
        return 0;
    const char *prefix = yndexec_data_dir();
    return strncmp(path, prefix, strlen(prefix)) == 0;
}

static size_t yndexec_argv_count(char *const argv[])
{
    size_t count = 0;
    if (argv != NULL)
        while (argv[count] != NULL)
            count++;
    return count;
}

/* If 'path' starts with "#!", copy its interpreter token into 'interp' and the
 * single optional argument (the trimmed remainder of the line) into 'argument'.
 * Returns 1 when a shebang was parsed, 0 otherwise. */
static int yndexec_read_shebang(const char *path, char *interp, size_t interp_size,
                                char *argument, size_t argument_size)
{
    interp[0] = '\0';
    argument[0] = '\0';
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    char line[512];
    ssize_t got = read(fd, line, sizeof line - 1);
    close(fd);
    if (got < 2 || line[0] != '#' || line[1] != '!')
        return 0;
    line[got] = '\0';
    char *newline = strchr(line, '\n');
    if (newline != NULL)
        *newline = '\0';

    char *cursor = line + 2;
    while (*cursor == ' ' || *cursor == '\t')
        cursor++;
    char *interp_start = cursor;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t')
        cursor++;
    size_t interp_length = (size_t)(cursor - interp_start);
    if (interp_length == 0 || interp_length + 1 > interp_size)
        return 0;
    memcpy(interp, interp_start, interp_length);
    interp[interp_length] = '\0';

    while (*cursor == ' ' || *cursor == '\t')
        cursor++;
    if (*cursor != '\0') {
        strncpy(argument, cursor, argument_size - 1);
        argument[argument_size - 1] = '\0';
    }
    return 1;
}

/* Fill 'rewritten' (capacity >= original argc + 8) with the argv that runs the
 * data-dir target 'path' through the loader, and return the program to exec
 * (the loader, or a /system interpreter for a bionic shebang). 'interp' and
 * 'argument' are caller-owned scratch buffers that the returned argv points
 * into, so they must outlive the exec call. */
static const char *yndexec_build_rewrite(const char *loader, const char *path,
                                         char *const argv[], char **rewritten,
                                         char *interp, size_t interp_size,
                                         char *argument, size_t argument_size)
{
    size_t original_argc = yndexec_argv_count(argv);
    const char *argv0 = (original_argc > 0 && argv[0] != NULL) ? argv[0] : path;
    int have_shebang = yndexec_read_shebang(path, interp, interp_size,
                                            argument, argument_size);
    size_t index = 0;

    /* A /system or /apex interpreter is a bionic binary the kernel can exec
     * directly -- run it without the musl loader. */
    if (have_shebang && (strncmp(interp, "/system", 7) == 0 ||
                         strncmp(interp, "/apex", 5) == 0)) {
        rewritten[index++] = interp;
        if (argument[0] != '\0')
            rewritten[index++] = argument;
        rewritten[index++] = (char *)path;
        for (size_t arg = 1; arg < original_argc; arg++)
            rewritten[index++] = argv[arg];
        rewritten[index] = NULL;
        return interp;
    }

    rewritten[index++] = (char *)loader;
    rewritten[index++] = (char *)"--argv0";
    if (have_shebang) {
        rewritten[index++] = interp;        /* argv[0] for the interpreter */
        rewritten[index++] = interp;        /* program the loader runs */
        if (argument[0] != '\0')
            rewritten[index++] = argument;
        rewritten[index++] = (char *)path;  /* the script, as a script argument */
    } else {
        rewritten[index++] = (char *)argv0; /* preserve the original argv[0] */
        rewritten[index++] = (char *)path;  /* program the loader runs */
    }
    for (size_t arg = 1; arg < original_argc; arg++)
        rewritten[index++] = argv[arg];
    rewritten[index] = NULL;
    return loader;
}

/* PATH search using the Android-safe access check (compat_access avoids the
 * seccomp-killed faccessat2). Writes the first executable candidate to 'out'.
 * Prefers a PATH from the caller's envp, then the process environment. */
static int yndexec_path_find(const char *file, char *const envp[],
                             char *out, size_t out_size)
{
    const char *path_env = NULL;
    for (size_t i = 0; envp != NULL && envp[i] != NULL; i++) {
        if (strncmp(envp[i], "PATH=", 5) == 0) {
            path_env = envp[i] + 5;
            break;
        }
    }
    if (path_env == NULL)
        path_env = getenv("PATH");
    if (path_env == NULL)
        path_env = "/system/bin:/system/xbin";

    const char *segment = path_env;
    for (;;) {
        const char *colon = strchr(segment, ':');
        size_t dir_length = colon ? (size_t)(colon - segment) : strlen(segment);
        if (dir_length + 1 + strlen(file) + 1 <= out_size) {
            if (dir_length > 0) {
                memcpy(out, segment, dir_length);
                out[dir_length] = '/';
                strcpy(out + dir_length + 1, file);
            } else {
                strcpy(out, file); /* an empty PATH entry means the cwd */
            }
            if (compat_access(AT_FDCWD, out, X_OK) == 0)
                return 1;
        }
        if (colon == NULL)
            break;
        segment = colon + 1;
    }
    return 0;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*real)(const char *, char *const[], char *const[]);
    if (real == NULL)
        real = (int (*)(const char *, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "execve");

    const char *loader = getenv("YND_LINKER");
    if (loader == NULL || loader[0] == '\0' || !yndexec_under_data_dir(path) ||
        strcmp(path, loader) == 0)
        return real(path, argv, envp);

    char interp[512], argument[512];
    size_t capacity = yndexec_argv_count(argv) + 8;
    char **rewritten = (char **)calloc(capacity, sizeof *rewritten);
    if (rewritten == NULL)
        return real(path, argv, envp);
    const char *program = yndexec_build_rewrite(loader, path, argv, rewritten,
                                                interp, sizeof interp,
                                                argument, sizeof argument);
    int rc = real(program, rewritten, envp);
    free(rewritten);
    return rc;
}

int execv(const char *path, char *const argv[])
{
    return execve(path, argv, environ);
}

static int yndexec_execvpe(const char *file, char *const argv[], char *const envp[])
{
    if (strchr(file, '/') != NULL)
        return execve(file, argv, envp);
    char candidate[4096];
    if (yndexec_path_find(file, envp, candidate, sizeof candidate))
        return execve(candidate, argv, envp);
    errno = ENOENT;
    return -1;
}

int execvp(const char *file, char *const argv[])
{
    return yndexec_execvpe(file, argv, environ);
}

int execvpe(const char *file, char *const argv[], char *const envp[])
{
    return yndexec_execvpe(file, argv, envp);
}

/* Collect the variadic argument list (arg0, ..., NULL) into a heap argv. The
 * caller frees it; on the success path exec replaces the image and the small
 * allocation is reclaimed by the kernel. Sets *envp_out for the execle form. */
static char **yndexec_collect(const char *arg0, va_list ap, char *const **envp_out)
{
    va_list counting;
    va_copy(counting, ap);
    size_t count = (arg0 != NULL) ? 1 : 0;
    if (arg0 != NULL)
        while (va_arg(counting, char *) != NULL)
            count++;
    va_end(counting);

    char **argv = (char **)calloc(count + 1, sizeof *argv);
    if (argv == NULL)
        return NULL;
    size_t index = 0;
    if (arg0 != NULL) {
        argv[index++] = (char *)arg0;
        char *next;
        while ((next = va_arg(ap, char *)) != NULL)
            argv[index++] = next;
    }
    argv[index] = NULL;
    if (envp_out != NULL)
        *envp_out = va_arg(ap, char *const *);
    return argv;
}

int execl(const char *path, const char *arg0, ...)
{
    va_list ap;
    va_start(ap, arg0);
    char **argv = yndexec_collect(arg0, ap, NULL);
    va_end(ap);
    if (argv == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int rc = execve(path, argv, environ);
    free(argv);
    return rc;
}

int execlp(const char *file, const char *arg0, ...)
{
    va_list ap;
    va_start(ap, arg0);
    char **argv = yndexec_collect(arg0, ap, NULL);
    va_end(ap);
    if (argv == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int rc = yndexec_execvpe(file, argv, environ);
    free(argv);
    return rc;
}

int execle(const char *path, const char *arg0, ...)
{
    va_list ap;
    va_start(ap, arg0);
    char *const *envp = NULL;
    char **argv = yndexec_collect(arg0, ap, &envp);
    va_end(ap);
    if (argv == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int rc = execve(path, argv, envp);
    free(argv);
    return rc;
}

int fexecve(int fd, char *const argv[], char *const envp[])
{
    const char *loader = getenv("YND_LINKER");
    if (loader != NULL && loader[0] != '\0') {
        char link[64], target[4096];
        snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
        ssize_t length = readlink(link, target, sizeof target - 1);
        if (length > 0) {
            target[length] = '\0';
            if (yndexec_under_data_dir(target))
                return execve(target, argv, envp); /* reroute via the loader */
        }
    }
    static int (*real)(int, char *const[], char *const[]);
    if (real == NULL)
        real = (int (*)(int, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "fexecve");
    return real(fd, argv, envp);
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attributes,
                char *const argv[], char *const envp[])
{
    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (real == NULL)
        real = (int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "posix_spawn");

    const char *loader = getenv("YND_LINKER");
    if (loader == NULL || loader[0] == '\0' || !yndexec_under_data_dir(path) ||
        strcmp(path, loader) == 0)
        return real(pid, path, file_actions, attributes, argv, envp);

    char interp[512], argument[512];
    size_t capacity = yndexec_argv_count(argv) + 8;
    char **rewritten = (char **)calloc(capacity, sizeof *rewritten);
    if (rewritten == NULL)
        return real(pid, path, file_actions, attributes, argv, envp);
    const char *program = yndexec_build_rewrite(loader, path, argv, rewritten,
                                                interp, sizeof interp,
                                                argument, sizeof argument);
    int rc = real(pid, program, file_actions, attributes, rewritten, envp);
    free(rewritten);
    return rc;
}

int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *file_actions,
                 const posix_spawnattr_t *attributes,
                 char *const argv[], char *const envp[])
{
    if (strchr(file, '/') != NULL)
        return posix_spawn(pid, file, file_actions, attributes, argv, envp);

    char candidate[4096];
    if (yndexec_path_find(file, envp, candidate, sizeof candidate))
        return posix_spawn(pid, candidate, file_actions, attributes, argv, envp);

    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (real == NULL)
        real = (int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "posix_spawnp");
    return real(pid, file, file_actions, attributes, argv, envp);
}

/* ---- DNS resolution ----
 * musl reads its nameserver list from /etc/resolv.conf, which cannot exist on
 * Android (no writable /etc, no root) -- so its getaddrinfo() falls back to
 * 127.0.0.1 and fails for every hostname. We interpose getaddrinfo() and, for a
 * real hostname, do the A/AAAA query ourselves against a configured nameserver,
 * then hand the resulting NUMERIC address to the real getaddrinfo() so it builds
 * (and freeaddrinfo() frees) the result with the genuine musl layout. Numeric
 * hosts, NULL host, AI_NUMERICHOST and "localhost" go straight to the real one. */

static void ynss_nameserver(char *out, size_t size)
{
    /* default; overridable by writing 'nameserver <ip>' to this file */
    strncpy(out, "1.1.1.1", size - 1);
    out[size - 1] = '\0';
    const char *path = getenv("YNDRONIX_RESOLV_CONF");
    if (!path || !*path)
        path = "/data/data/com.yndronix/run/etc/resolv.conf";
    FILE *file = fopen(path, "re");
    if (file == NULL)
        return;
    char line[256];
    while (fgets(line, sizeof line, file) != NULL) {
        char address[64];
        if (sscanf(line, " nameserver %63s", address) == 1) {
            strncpy(out, address, size - 1);
            out[size - 1] = '\0';
            break;
        }
    }
    fclose(file);
}

/* Advance past one DNS name (handles a compression pointer, which terminates). */
static int dns_skip_name(const unsigned char *buffer, int length, int pos)
{
    while (pos < length) {
        unsigned label = buffer[pos];
        if (label == 0)
            return pos + 1;
        if ((label & 0xc0) == 0xc0)
            return pos + 2;
        pos += (int)label + 1;
    }
    return pos;
}

/* Resolve name to a single numeric address string. want_v6 picks AAAA over A.
 * Returns 1 on success (out filled), 0 otherwise. */
static int ynss_dns_lookup(const char *name, int want_v6, char *out, size_t out_size)
{
    int record_type = want_v6 ? 28 /* AAAA */ : 1 /* A */;
    unsigned char query[512];
    int query_len = res_mkquery(0, name, 1 /* C_IN */, record_type,
                                NULL, 0, NULL, query, sizeof query);
    if (query_len <= 0)
        return 0;

    char nameserver[64];
    ynss_nameserver(nameserver, sizeof nameserver);

    struct sockaddr_in server;
    memset(&server, 0, sizeof server);
    server.sin_family = AF_INET;
    server.sin_port = htons(53);
    if (inet_pton(AF_INET, nameserver, &server.sin_addr) != 1)
        return 0;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return 0;
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);

    int found = 0;
    unsigned char answer[1500];
    if (connect(fd, (struct sockaddr *)&server, sizeof server) == 0 &&
        send(fd, query, (size_t)query_len, 0) == query_len) {
        int answer_len = (int)recv(fd, answer, sizeof answer, 0);
        if (answer_len > 12) {
            int question_count = (answer[4] << 8) | answer[5];
            int answer_count = (answer[6] << 8) | answer[7];
            int pos = 12;
            for (int i = 0; i < question_count && pos < answer_len; i++)
                pos = dns_skip_name(answer, answer_len, pos) + 4;
            for (int i = 0; i < answer_count && pos < answer_len && !found; i++) {
                pos = dns_skip_name(answer, answer_len, pos);
                if (pos + 10 > answer_len)
                    break;
                int type = (answer[pos] << 8) | answer[pos + 1];
                int rdlength = (answer[pos + 8] << 8) | answer[pos + 9];
                pos += 10;
                if (pos + rdlength > answer_len)
                    break;
                if (type == 1 && rdlength == 4 && !want_v6) {
                    inet_ntop(AF_INET, answer + pos, out, (socklen_t)out_size);
                    found = 1;
                } else if (type == 28 && rdlength == 16 && want_v6) {
                    inet_ntop(AF_INET6, answer + pos, out, (socklen_t)out_size);
                    found = 1;
                }
                pos += rdlength;
            }
        }
    }
    close(fd);
    return found;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    static int (*real)(const char *, const char *,
                       const struct addrinfo *, struct addrinfo **);
    if (!real)
        real = (int (*)(const char *, const char *, const struct addrinfo *,
                        struct addrinfo **))dlsym(RTLD_NEXT, "getaddrinfo");

    int flags = hints ? hints->ai_flags : 0;
    int family = hints ? hints->ai_family : AF_UNSPEC;
    struct in6_addr probe;

    /* Cases the real resolver already handles without /etc/resolv.conf. */
    if (node == NULL || (flags & AI_NUMERICHOST) ||
        inet_pton(AF_INET, node, &probe) == 1 ||
        inet_pton(AF_INET6, node, &probe) == 1 ||
        strcasecmp(node, "localhost") == 0)
        return real(node, service, hints, res);

    /* Real hostname: resolve ourselves, then let the real getaddrinfo build the
     * addrinfo from the numeric address (so freeaddrinfo stays compatible). */
    char address[64];
    int want_v6 = (family == AF_INET6);
    if (ynss_dns_lookup(node, want_v6, address, sizeof address) ||
        (family == AF_UNSPEC && ynss_dns_lookup(node, 1, address, sizeof address))) {
        struct addrinfo numeric_hints;
        if (hints)
            numeric_hints = *hints;
        else
            memset(&numeric_hints, 0, sizeof numeric_hints);
        numeric_hints.ai_flags |= AI_NUMERICHOST;
        return real(address, service, &numeric_hints, res);
    }

    /* Couldn't resolve -- let the real resolver return the proper error. */
    return real(node, service, hints, res);
}

static const char *passwd_file(void)
{
    const char *path = getenv("NSS_WRAPPER_PASSWD");
    return (path && *path) ? path : "/data/data/com.yndronix/run/etc/passwd";
}

static const char *group_file(void)
{
    const char *path = getenv("NSS_WRAPPER_GROUP");
    return (path && *path) ? path : "/data/data/com.yndronix/run/etc/group";
}

/* Split a NUL-terminated string in place on ':' into up to max fields. */
static int split_fields(char *line, char *fields[], int max)
{
    int count = 0;
    char *cursor = line;
    while (count < max) {
        fields[count++] = cursor;
        char *colon = strchr(cursor, ':');
        if (colon == NULL)
            break;
        *colon = '\0';
        cursor = colon + 1;
    }
    return count;
}

static void strip_newline(char *line)
{
    char *newline = strchr(line, '\n');
    if (newline != NULL)
        *newline = '\0';
}

/* ---- passwd ---- */

static int fill_passwd(struct passwd *entry, const char *line,
                       char *buffer, size_t buflen)
{
    size_t length = strlen(line);
    if (length + 1 > buflen)
        return ERANGE;
    memcpy(buffer, line, length + 1);
    strip_newline(buffer);

    char *fields[7];
    if (split_fields(buffer, fields, 7) < 7)
        return -1;

    entry->pw_name = fields[0];
    entry->pw_passwd = fields[1];
    entry->pw_uid = (uid_t)strtoul(fields[2], NULL, 10);
    entry->pw_gid = (gid_t)strtoul(fields[3], NULL, 10);
    entry->pw_gecos = fields[4];
    entry->pw_dir = fields[5];
    entry->pw_shell = fields[6];
    return 0;
}

static int lookup_passwd(const char *name, uid_t uid, int by_name,
                         struct passwd *entry, char *buffer, size_t buflen,
                         struct passwd **result)
{
    *result = NULL;
    FILE *file = fopen(passwd_file(), "re");
    if (file == NULL)
        return 0;

    char line[2048];
    int rc = 0;
    while (fgets(line, sizeof line, file) != NULL) {
        if (line[0] == '#' || line[0] == '\n')
            continue;
        char probe[2048];
        strncpy(probe, line, sizeof probe - 1);
        probe[sizeof probe - 1] = '\0';
        strip_newline(probe);

        char *fields[7];
        if (split_fields(probe, fields, 7) < 7)
            continue;

        int matched = by_name
            ? (strcmp(fields[0], name) == 0)
            : ((uid_t)strtoul(fields[2], NULL, 10) == uid);
        if (!matched)
            continue;

        rc = fill_passwd(entry, line, buffer, buflen);
        if (rc == 0)
            *result = entry;
        break;
    }
    fclose(file);
    return (rc == ERANGE) ? ERANGE : 0;
}

int getpwnam_r(const char *name, struct passwd *entry, char *buffer,
               size_t buflen, struct passwd **result)
{
    return lookup_passwd(name, 0, 1, entry, buffer, buflen, result);
}

int getpwuid_r(uid_t uid, struct passwd *entry, char *buffer,
               size_t buflen, struct passwd **result)
{
    return lookup_passwd(NULL, uid, 0, entry, buffer, buflen, result);
}

struct passwd *getpwnam(const char *name)
{
    static struct passwd entry;
    static char buffer[2048];
    struct passwd *result;
    getpwnam_r(name, &entry, buffer, sizeof buffer, &result);
    return result;
}

struct passwd *getpwuid(uid_t uid)
{
    static struct passwd entry;
    static char buffer[2048];
    struct passwd *result;
    getpwuid_r(uid, &entry, buffer, sizeof buffer, &result);
    return result;
}

/* ---- group ---- */

static int fill_group(struct group *entry, const char *line,
                      char *buffer, size_t buflen)
{
    /* Layout in caller buffer: [ char *members[1] ][ string data ].
     * We do not parse the member list (our groups have none), so members is an
     * empty, NULL-terminated array. */
    if (buflen < sizeof(char *))
        return ERANGE;
    char **members = (char **)buffer;
    members[0] = NULL;

    char *strings = buffer + sizeof(char *);
    size_t avail = buflen - sizeof(char *);
    size_t length = strlen(line);
    if (length + 1 > avail)
        return ERANGE;
    memcpy(strings, line, length + 1);
    strip_newline(strings);

    char *fields[4];
    if (split_fields(strings, fields, 4) < 3)
        return -1;

    entry->gr_name = fields[0];
    entry->gr_passwd = fields[1];
    entry->gr_gid = (gid_t)strtoul(fields[2], NULL, 10);
    entry->gr_mem = members;
    return 0;
}

static int lookup_group(const char *name, gid_t gid, int by_name,
                        struct group *entry, char *buffer, size_t buflen,
                        struct group **result)
{
    *result = NULL;
    FILE *file = fopen(group_file(), "re");
    if (file == NULL)
        return 0;

    char line[2048];
    int rc = 0;
    while (fgets(line, sizeof line, file) != NULL) {
        if (line[0] == '#' || line[0] == '\n')
            continue;
        char probe[2048];
        strncpy(probe, line, sizeof probe - 1);
        probe[sizeof probe - 1] = '\0';
        strip_newline(probe);

        char *fields[4];
        if (split_fields(probe, fields, 4) < 3)
            continue;

        int matched = by_name
            ? (strcmp(fields[0], name) == 0)
            : ((gid_t)strtoul(fields[2], NULL, 10) == gid);
        if (!matched)
            continue;

        rc = fill_group(entry, line, buffer, buflen);
        if (rc == 0)
            *result = entry;
        break;
    }
    fclose(file);
    return (rc == ERANGE) ? ERANGE : 0;
}

int getgrnam_r(const char *name, struct group *entry, char *buffer,
               size_t buflen, struct group **result)
{
    return lookup_group(name, 0, 1, entry, buffer, buflen, result);
}

int getgrgid_r(gid_t gid, struct group *entry, char *buffer,
               size_t buflen, struct group **result)
{
    return lookup_group(NULL, gid, 0, entry, buffer, buflen, result);
}

struct group *getgrnam(const char *name)
{
    static struct group entry;
    static char buffer[2048];
    struct group *result;
    getgrnam_r(name, &entry, buffer, sizeof buffer, &result);
    return result;
}

struct group *getgrgid(gid_t gid)
{
    static struct group entry;
    static char buffer[2048];
    struct group *result;
    getgrgid_r(gid, &entry, buffer, sizeof buffer, &result);
    return result;
}

/* sshd/login call these to set up supplementary groups. We run as a single
 * unprivileged uid with no extra groups, so report just the caller's gid and
 * make initgroups a successful no-op. */
int getgrouplist(const char *user, gid_t group, gid_t *groups, int *ngroups)
{
    (void)user;
    if (*ngroups >= 1 && groups != NULL) {
        groups[0] = group;
        *ngroups = 1;
        return 1;
    }
    *ngroups = 1;
    return -1;
}

int initgroups(const char *user, gid_t group)
{
    (void)user;
    (void)group;
    return 0;
}

/* Android's app seccomp blocks setgroups(2) with SIGSYS, and a sandboxed app
 * cannot change its group set anyway. sshd clears its supplemental groups at
 * startup (setgroups(0, NULL)) right after parsing config -- without this shim
 * that call kills the daemon before it ever binds. Make it a no-op success. */
int setgroups(size_t count, const gid_t *groups)
{
    (void)count;
    (void)groups;
    return 0;
}
