# syntax=docker/dockerfile:1

# Reproducible build environment for relocated-store Nix builds.
#
# The SAME image is used for the from-source bootstrap of the store AND for
# every later package build, so the toolchain is byte-identical on each run.
#
# Why a non-/nix store: on Android the only writable, exec-capable,
# deterministic location is the app's private data dir, whose path is derived
# from the package id. We relocate the whole Nix store there and build
# everything from source, because the store directory is hashed into every
# output path -- so the upstream binary cache (signed for /nix/store) cannot
# be used. Building here with the EXACT on-device path means the resulting
# closures run natively on the phone, no proot/ptrace, no patching.

ARG NIX_VERSION=2.24.9
FROM nixos/nix:${NIX_VERSION}

# Single source of truth for the Android package id. This string is hashed
# into every output path, so it is effectively PERMANENT once a binary cache
# exists. Keep it short -- a long prefix eats into the shebang length budget.
ARG ANDROID_PACKAGE=com.yndronix

# The relocated /nix, at the EXACT absolute path the app owns on device.
# Placed directly under the data-dir root (Context.getDataDir(), API 24+),
# NOT under files/, to keep the prefix short -- every char counts against the
# shebang-line limit. Android does not require files/; the app owns its
# data-dir root and may create its own subdir there.
#   /data/data/<package>/nix
ENV YNDRONIX_PREFIX=/data/data/${ANDROID_PACKAGE}/nix
ENV NIX_STORE_DIR=${YNDRONIX_PREFIX}/store
ENV NIX_STATE_DIR=${YNDRONIX_PREFIX}/var
ENV NIX_LOG_DIR=${YNDRONIX_PREFIX}/var/log/nix
# Operate the local store directly; the daemon only understands /nix/store.
ENV NIX_REMOTE=

# nixpkgs is PINNED to an exact commit (nixos-26.05 @ 2026-06-11), NOT the
# moving branch -- reproducible release builds and audits need a fixed revision,
# and the relocated store cannot use the binary cache (every path hash differs),
# so an unpinned branch would silently change the whole closure. The canonical
# pin lives in nix/nixpkgs.nix, which the package eval reads directly; the
# NIX_PATH below is kept in sync only so an interactive `<nixpkgs>` in the
# container matches. Keep this ARG equal to the rev in nix/nixpkgs.nix.
#
# 26.05's stdenv uses the FULL-SOURCE bootstrap, whose seed (stage0-posix /
# make-minimal-bootstrap-sources) is a fixed-output derivation. With the
# relocated store the binary cache is unusable -- FOD substitution is path-keyed
# and store-dir-dependent (verified: even with cache.nixos.org enabled, FODs do
# not substitute into a relocated store). So the seed is INJECTED out-of-band
# (built where the cache works, then `nix-store --add-fixed` into the relocated
# store); after that the full-source bootstrap compiles the toolchain from source.
ARG NIXPKGS_REF=a0374025a863d007d98e3297f6aa46cc3141c2f0
ENV NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/${NIXPKGS_REF}.tar.gz

# No extra host tooling needed: the base image already has nix, a shell and
# curl, and the stdenv bootstrap is self-contained (it fetches its own
# bootstrap-tools). Nixpkgs is fetched as a tarball (NIX_PATH above), so no
# git is required for the build either.

# Create the relocated tree. A named volume mounted here at runtime is seeded
# from these dirs, so the store survives across container runs.
RUN mkdir -p /etc/nix "${NIX_STORE_DIR}" "${NIX_STATE_DIR}" "${NIX_LOG_DIR}"

# Unprivileged build users. nix runs as root in the container but drops to
# these for the actual builds, so packages that refuse to ./configure as root
# (gnutar, coreutils, ...) build correctly. The base image usually already
# ships nixbld1-32; only create them (no shadow utils, so append directly) if
# the group is absent. 32 users => up to 32 concurrent jobs.
RUN set -eu; if ! grep -q '^nixbld:' /etc/group; then \
        mkdir -p /var/empty; members=""; i=1; \
        while [ "$i" -le 32 ]; do \
            echo "nixbld$i:x:$((30000+i)):30000:Nix build user $i:/var/empty:/noshell" >> /etc/passwd; \
            members="${members:+$members,}nixbld$i"; \
            i=$((i+1)); \
        done; \
        echo "nixbld:x:30000:$members" >> /etc/group; \
    fi

# Nix configuration for the relocated, single-user, from-source store.
# printf (not a heredoc) so this does not depend on BuildKit RUN-heredoc
# support; "%s\n" expands ${NIX_STORE_DIR} from the ENV above.
# Note: the logical store directory is set via the NIX_STORE_DIR env var above
# (the nix.conf "store-dir" key is not recognised at runtime and only warns).
RUN printf '%s\n' \
    'experimental-features = nix-command flakes' \
    '# Keep the fetched nixpkgs channel cached (with a persisted ~/.cache) for a' \
    '# year, so the branch tarball is not re-fetched/re-unpacked every run.' \
    'tarball-ttl = 31536000' \
    '# Upstream cache is signed for /nix/store -- every hash differs here, so' \
    '# it is useless. Build from source; later, point this at our OWN cache.' \
    'substituters =' \
    'trusted-substituters =' \
    '# User namespaces are awkward in plain Docker, so the bootstrap runs' \
    '# unsandboxed. For reproducible release builds, run --privileged and set' \
    '# sandbox = true below.' \
    'sandbox = false' \
    '# Drop to unprivileged nixbld users for builds (nix itself stays root).' \
    'build-users-group = nixbld' \
    'max-jobs = auto' \
    'cores = 0' \
    > /etc/nix/nix.conf

WORKDIR /work
CMD ["bash"]
