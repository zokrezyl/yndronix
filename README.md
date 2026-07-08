# yndronix

**A real Linux userland on Android — running natively, with no root, no VM, and
no `ptrace`/`proot` syscall emulation.**

yndronix puts a full, self-contained Linux command line on your phone or tablet:
a proper shell, the standard GNU/BSD tools you already know, an on-device SSH
server, and a package set built straight from [nixpkgs](https://github.com/NixOS/nixpkgs).
Everything lives in the app's own private storage, needs no root, and uninstalls
cleanly.

It is also a basic OS-like environment for **yetty OS (YOS)** — the platform for
distributing **"build once, run everywhere"** apps built on the
[yetty](https://github.com/zokrezyl/yetty) terminal's features. See
[yndronix and yetty OS](#yndronix-and-yetty-os) below.

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

1. **Reproducible closures.** The whole userland is a Nix closure —
   declarative, content-addressed, and free of imperative package-database
   drift. `bootstrap/docker/build.nix` defines the package set and the handful
   of overlays needed to cross-compile it cleanly to aarch64-musl.

2. **Relocated Nix store.** Packages are built with the on-device store prefix
   `/data/data/com.yndronix/nix` baked into every store-path hash, so the tree
   is fully self-contained and needs no `nix` daemon to *run*. The store ships
   as an app asset and unpacks into the app's private directory.

3. **Cross-compiled off-device.** An x86_64 host builds the aarch64-musl closure
   inside a Docker container via `nixpkgs` `pkgsCross`
   (`build-tools/build-package --android <attr>`).

4. **Launched through a musl loader.** Android 10+ forbids `execve()` of files in
   the app data dir, so store binaries are started through a musl loader shipped
   in `nativeLibraryDir` (`libyndld.so`), which `mmap`s them instead. `ynss` then
   transparently reroutes any further data-dir `exec` back through the loader.

5. **Supervised services.** A `runit` control plane (built by
   `build-tools/make-service-bundle`) supervises `sshd`; a first-launch `init`
   synthesizes the user database, generates host keys, and installs the baked
   `authorized_keys`.

---

## yndronix and yetty OS

yndronix is a **basic OS-like environment for yetty OS (YOS)**.

YOS was written to distribute **"build once, run everywhere" apps** —
applications built on the yetty terminal's features, packaged so they run
anywhere yetty runs, from a single build. To make that work, YOS provides a
basic, self-contained OS-like environment underneath those apps in each place it
runs — including **yetty in the browser**.

yndronix is that environment on Android: the self-contained Linux userland a
yetty app can rely on being present, delivered without root, without a VM, and
without syscall emulation. It is the substrate YOS apps run *in*, not something
layered on top of yetty.

---

## Repository layout

```
bootstrap/
  docker/build.nix       package set + cross-compile overlays (the source of truth)
  docker/Dockerfile      the nix build container
  ynss/ynss.c            LD_PRELOAD: NSS lookups + Android/musl seccomp compat shims
  sigsyscatch/           LD_PRELOAD: report seccomp-blocked syscalls (diagnostic)
  dnstest/               getaddrinfo() exerciser for the ynss DNS path (diagnostic)
build-tools/
  build-package          build one nixpkgs attr (native or --android) into ./nixroot
  make-service-bundle    extract the runtime closure + generate the runit control plane
  make-apk-assets        pack the store + loader into the Android app assets
  build-release-aab.sh   assemble and sign the Play Store bundle
android/                 the thin Android wrapper app (store extraction, launcher, UI)
docs/                    listing description and privacy policy
```

## Building

Prerequisites: Docker (for the reproducible nix build container).

```sh
# 1. Build the nix build image (once).
docker build -t yndronix-build bootstrap/docker

# 2. Build packages for the phone (aarch64-musl), e.g.:
build-tools/build-package --android bash
build-tools/build-package --android openssh

# 3. Assemble the on-device bundle (runtime closure + runit control plane).
build-tools/make-service-bundle

# 4. Pack the app assets and build the signed release bundle.
build-tools/make-apk-assets
build-tools/build-release-aab.sh
```

Built store paths land under `./nixroot/store`, with convenience symlinks in
`./out`. See the comments at the top of each script for the details.

---

## Privacy

yndronix collects no personal data — no analytics, no ads, no accounts. All
state lives in the app's private storage and is removed on uninstall. Full
policy: [docs/PRIVACY.md](docs/PRIVACY.md).
