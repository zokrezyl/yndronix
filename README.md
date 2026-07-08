# yndronix

**A real Linux userland on Android — running natively, with no root, no VM, and
no `ptrace`/`proot` syscall emulation.**

yndronix was written to provide *yet another* OS-like runtime environment — this
one on **Android** — for [yetty](https://github.com/zokrezyl/yetty) (a
GPU-accelerated terminal and rich-content runtime) and for the apps that run on
top of the yetty terminal. It is one such runtime; **YOS** is another.

yndronix puts a full, self-contained Linux command line on your phone or tablet:
a proper shell, the standard GNU/BSD tools you already know, an on-device SSH
server, and a package set built straight from [nixpkgs](https://github.com/NixOS/nixpkgs).
Everything lives in the app's own private storage, needs no root, and uninstalls
cleanly.

> ### 📱 In testing on Google Play — we're looking for testers
>
> yndronix is available as a testing release on Google Play, and we'd love your
> help shaping it. Join the testing program, try it on your device, and share
> feedback in the
> **[testers discussion (#10)](https://github.com/zokrezyl/yndronix/discussions/10)**.

---

## Why yndronix instead of Termux or Andronix?

The short version: **yndronix runs ordinary Linux processes at native speed,
using only the syscalls Android already allows — no tracer sits in the loop.**

Most ways of getting Linux onto an unrooted Android device fall into two camps,
and both pay a price yndronix does not:

| | How it runs userland | Cost |
|---|---|---|
| **Andronix** (and "install a distro" apps) | A full glibc distro under **`proot`** — a userspace `chroot`/syscall interceptor built on **`ptrace`**. | Every filesystem-touching syscall is trapped, rewritten, and re-issued by a tracer process. Two extra context switches per traced syscall; measurably slower, and fragile around newer syscalls. Usually needs Termux underneath. |
| **Termux** | Native **bionic**-linked binaries from a *custom* package repo, `patchelf`'d to Termux's own non-standard prefix. | Fast, but it is its own ecosystem — not a standard FHS, not stock distro packages. To run a "real" glibc distro you fall back to `proot-distro` and inherit the cost above. |
| **yndronix** | Stock **nixpkgs** packages cross-compiled to **aarch64-musl**, run as plain app-uid processes directly on the Android kernel. | None of the above. Native `execve` + native syscalls. No tracer, no root, no VM. |

### The core idea: musl, not glibc, not bionic

An Android app runs under the kernel's `untrusted_app` **seccomp filter**, which
kills a blocked syscall with `SIGSYS`. Modern **glibc** issues newer syscalls
(`rseq`, `statx`, `faccessat2`, …) that this filter rejects — so a stock glibc
userland cannot even start inside the sandbox. That is *why* Andronix reaches for
`proot`: to fake up an environment glibc will tolerate.

yndronix builds its entire userland against **musl** instead. musl issues only
the conservative, long-established syscalls that Android permits, so the binaries
run **directly** — no interception layer required. (Verified the hard way: a
static-musl binary runs in the app sandbox where the glibc equivalent is
`SIGSYS`-killed on startup.)

### The only "shims" are libc interposition, not syscall tracing

A couple of Android-specific rough edges remain, and yndronix smooths them with
tiny `LD_PRELOAD` libraries — **not** a tracer:

- **`ynss`** answers `getpwnam`/`getpwuid`/`getgr*` from app-owned files (musl
  reads `/etc/passwd` directly and Android gives us no writable `/etc`), and
  substitutes an *allowed* syscall for a *blocked* one at the libc boundary
  (e.g. musl routes effective-id access checks through `faccessat2`, which the
  filter kills — `ynss` reroutes them to the plain `faccessat` Android allows;
  likewise `accept` → `accept4`). This is **function interposition**: a single
  `if` at the call site, with **zero per-syscall overhead**. It is the opposite
  of `proot`, where a tracer mediates every syscall.
- **`sigsyscatch`** is a diagnostic preload that turns an otherwise-silent
  seccomp `SIGSYS` kill into a printed syscall number + call site.

The result is a standard Linux command line that behaves like Linux, built from
a mainstream package tree, running as fast as the hardware allows.

---

## What you get

- **A genuine shell environment** — `bash` and `zsh`, `coreutils`, `findutils`,
  `grep`, `sed`, `less`, `which`, `file`, `tree`, `tmux`.
- **Real developer tools** — `neovim`, `git`, `clang` (LLVM), `ripgrep`, `fd`,
  `fzf`, `jq`, `curl`, `wget`, `htop`, `procps`, `tar`/`gzip`, `dnsutils`.
- **`nix` itself** — the package manager runs on-device, so the environment is
  extensible from the same source of truth it was built from.
- **An on-device SSH server** (`openssh`, pubkey auth) supervised by `runit`, so
  you can drop into a session from a laptop on your own network and type on a
  real keyboard.
- **No accounts, no ads, no tracking.** The network is used only for package
  downloads and SSH connections *you* initiate. See [docs/PRIVACY.md](docs/PRIVACY.md).

---

## How it works

- **Reproducible closures.** The whole userland is a Nix closure — declarative,
  content-addressed, and free of imperative package-database drift — cross-built
  to aarch64-musl.
- **Relocated Nix store.** Every store-path hash is baked with the on-device
  store prefix, so the tree is fully self-contained and needs no `nix` daemon to
  *run*. It ships inside the app and unpacks into the app's private storage.
- **Launched through a musl loader.** Android 10+ forbids `execve()` of files in
  the app data dir, so store binaries are started through a musl loader shipped
  in `nativeLibraryDir`, which `mmap`s them instead. `ynss` then transparently
  reroutes any further data-dir `exec` back through the loader.
- **Supervised services.** A `runit` control plane supervises `sshd`; a
  first-launch `init` synthesizes the user database, generates host keys, and
  installs the baked `authorized_keys`.

---

## Privacy

yndronix collects no personal data — no analytics, no ads, no accounts. All
state lives in the app's private storage and is removed on uninstall. Full
policy: [docs/PRIVACY.md](docs/PRIVACY.md).

## License

yndronix is licensed under the **Business Source License 1.1** — the same
license as [yetty](https://github.com/zokrezyl/yetty). Non-production use is
free; production use requires a commercial license, and the license converts to
GPL v2-or-later on the Change Date. Bundled third-party components (the
nixpkgs-built userland) keep their own upstream licenses. See [LICENSE](LICENSE).
