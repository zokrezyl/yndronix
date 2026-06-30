/*
 * sigsyscatch -- LD_PRELOAD that reports a seccomp-blocked syscall (number +
 * calling location) instead of letting it silently SIGSYS-kill the process.
 * musl binaries do not install Android's debuggerd handler, so a seccomp kill
 * otherwise leaves nothing in logcat.
 *
 * Some daemons (sshd) reset every signal handler to default at startup, which
 * would clobber ours before the offending syscall runs. So we also interpose
 * sigaction()/signal() and quietly ignore attempts to change SIGSYS, keeping
 * our reporter installed.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <ucontext.h>

static void describe(char *buf, size_t cap, int *len, const char *label, void *addr)
{
    Dl_info info;
    if (dladdr(addr, &info) && info.dli_fname) {
        const char *sym = info.dli_sname ? info.dli_sname : "(no-sym)";
        long sym_off = info.dli_saddr ? (long)((char *)addr - (char *)info.dli_saddr) : 0;
        long base_off = (long)((char *)addr - (char *)info.dli_fbase);
        *len += snprintf(buf + *len, cap - *len, "  %s %p  %s+0x%lx  [%s @+0x%lx]\n",
                         label, addr, sym, sym_off, info.dli_fname, base_off);
    } else {
        *len += snprintf(buf + *len, cap - *len, "  %s %p  (unresolved)\n", label, addr);
    }
}

static void on_sigsys(int sig, siginfo_t *info, void *ucontext)
{
    (void)sig;
    char buf[640];
    int len = snprintf(buf, sizeof buf,
                       "\n[sigsyscatch] SIGSYS blocked syscall=%d arch=0x%x\n",
                       info->si_syscall, (unsigned)info->si_arch);
    ucontext_t *uc = (ucontext_t *)ucontext;
    void *pc = (void *)uc->uc_mcontext.pc;
    void *lr = (void *)uc->uc_mcontext.regs[30];
    describe(buf, sizeof buf, &len, "pc", pc);
    describe(buf, sizeof buf, &len, "lr", lr);
    write(2, buf, (size_t)len);
    /* Also append to a file, so the report survives even when the process has
     * redirected/closed stderr (sshd) or re-exec'd. Path from env, with a
     * fallback under the app's run dir. */
    const char *logpath = getenv("SIGSYSCATCH_LOG");
    if (!logpath || !*logpath)
        logpath = "/data/data/com.yndronix/run/sigsys.txt";
    int fd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        write(fd, buf, (size_t)len);
        close(fd);
    }
    _exit(89);
}

static void install_reporter(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = on_sigsys;
    action.sa_flags = SA_SIGINFO;
    /* call the real sigaction so we don't recurse into our own override */
    int (*real)(int, const struct sigaction *, struct sigaction *) =
        (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(RTLD_NEXT, "sigaction");
    if (real)
        real(SIGSYS, &action, NULL);
}

int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact)
{
    int (*real)(int, const struct sigaction *, struct sigaction *) =
        (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(RTLD_NEXT, "sigaction");
    if (signum == SIGSYS) {
        /* keep our reporter; pretend the caller succeeded */
        if (oldact)
            memset(oldact, 0, sizeof *oldact);
        return 0;
    }
    return real ? real(signum, act, oldact) : -1;
}

void (*signal(int signum, void (*handler)(int)))(int)
{
    void (*(*real)(int, void (*)(int)))(int) =
        (void (*(*)(int, void (*)(int)))(int))dlsym(RTLD_NEXT, "signal");
    if (signum == SIGSYS)
        return SIG_DFL; /* ignore; keep our reporter */
    return real ? real(signum, handler) : SIG_ERR;
}

static void log_load(void)
{
    const char *logpath = getenv("SIGSYSCATCH_LOAD_LOG");
    if (!logpath || !*logpath)
        return;
    char cmd[256] = {0};
    int cfd = open("/proc/self/cmdline", O_RDONLY);
    int n = 0;
    if (cfd >= 0) {
        n = (int)read(cfd, cmd, sizeof cmd - 1);
        close(cfd);
        for (int i = 0; i < n; i++)
            if (cmd[i] == '\0')
                cmd[i] = ' ';
    }
    char line[320];
    int len = snprintf(line, sizeof line, "[loaded] pid=%d cmd=%.*s\n",
                       (int)getpid(), n > 0 ? n : 0, cmd);
    int fd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        write(fd, line, (size_t)len);
        close(fd);
    }
}

__attribute__((constructor)) static void init_catcher(void)
{
    log_load();
    install_reporter();
}
