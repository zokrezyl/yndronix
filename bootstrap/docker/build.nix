# Build a nixpkgs attribute for the yndronix relocated store, optionally
# cross-compiled to aarch64 glibc (android).
#
# docbook overlay: docbook.org was archived in November 2025 and its DTD/
# catalog files moved to archive.docbook.org, so the URLs baked into nixpkgs'
# docbook derivations now 404. Normally cache.nixos.org serves that content by
# hash, but the relocated store cannot use the cache -- so we rewrite fetchurl
# URLs docbook.org -> archive.docbook.org. The content (and therefore the
# fixed-output hash) is identical, so no hashes change.
{ attr, android ? false }:

let
  docbookFix = self: super: {
    fetchurl = args:
      let
        urls0 = args.urls or (super.lib.optional (args ? url) args.url);
        hasDocbook = super.lib.any (super.lib.hasInfix "//docbook.org/") urls0;
        rewrite = url:
          super.lib.replaceStrings [ "//docbook.org/" ] [ "//archive.docbook.org/" ] url;
      in
        if hasDocbook then
          super.fetchurl ((builtins.removeAttrs args [ "url" ]) // {
            # try archive.docbook.org first (live), keep the original as fallback
            urls = (map rewrite urls0) ++ urls0;
          })
        else
          super.fetchurl args;
  };

  # tree-sitter (0.26.x) vendors rquickjs-sys, whose build.rs correctly passes
  # --target=$TARGET (aarch64 on the cross build) to bindgen. But tree-sitter
  # also pulls rustPlatform.bindgenHook, which appends BINDGEN_EXTRA_CLANG_ARGS
  # AFTER build.rs' clang_args -- and on this cross build the final --target
  # resolves to x86_64, so bindgen's clang parses the aarch64 glibc SVE header
  # (bits/math-vector.h: __SVFloat32_t, ...) as x86_64 and fails. Re-append the
  # host target last so it is the winning --target, matching the aarch64 includes
  # already on the search path. (Native build: host==build, so this is a no-op.)
  treeSitterCross = self: super: {
    tree-sitter = super.tree-sitter.overrideAttrs (old: {
      preBuild = (old.preBuild or "") + ''
        export BINDGEN_EXTRA_CLANG_ARGS="''${BINDGEN_EXTRA_CLANG_ARGS:-} --target=${self.stdenv.hostPlatform.config}"
      '';
    });
  };

  # neovim cross-compile: neovim builds `nlua0`, a native Lua C module used to
  # run its build-time codegen (api/*.generated.h, ui_events_call.generated.h,
  # ...). On a cross build that module is compiled for the target (aarch64), but
  # the codegen runs the BUILD-host luajit, which cannot load an aarch64 .so
  # ("cannot open shared object file"). LuaJIT also cannot execute under
  # qemu-user (its JIT/GC arena mmap fails), so the emulator route is a dead end.
  #
  # neovim's own CMake handles this: when CMAKE_CROSSCOMPILING and NLUA0_HOST_PRG
  # is set, the codegen loads NLUA0_HOST_PRG (a BUILD-platform nlua0) with the
  # build luajit -- natively, no emulator. nixpkgs just never sets it. So we
  # build a build-platform nlua0 (only that one CMake target of the native
  # neovim) and pass it as NLUA0_HOST_PRG. Generated headers are arch-independent.
  neovimCross = self: super: {
    neovim-unwrapped = super.neovim-unwrapped.overrideAttrs (
      old:
      self.lib.optionalAttrs (!self.stdenv.buildPlatform.canExecute self.stdenv.hostPlatform) (
        let
          # Build-platform neovim: provides a runnable host nvim (for helptags
          # codegen, NVIM_HOST_PRG) and the host nlua0 module (for api codegen,
          # NLUA0_HOST_PRG). neovim's CMake consumes both when CMAKE_CROSSCOMPILING;
          # nixpkgs sets neither, which is why the cross build tries to run target
          # binaries on the build host. The stock derivation does not install the
          # build-time libnlua0.so, so we add it.
          neovimOnBuild = self.buildPackages.neovim-unwrapped.overrideAttrs (native: {
            # We only need its nvim binary + build-time nlua0.so as cross codegen
            # tools, not a tested build. doCheck=true would pull nativeCheckInputs
            # (fish/nodejs/pyEnv) and run functionaltests; the native nodejs test
            # suite fails in this container, so skip checks entirely.
            doCheck = false;
            postInstall = (native.postInstall or "") + ''
              install -Dm755 "$(find "$NIX_BUILD_TOP" -type f -name libnlua0.so | head -1)" "$out/lib/libnlua0.so"
            '';
            disallowedRequisites = [ ];
          });
        in
        {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            (self.lib.cmakeFeature "NLUA0_HOST_PRG" "${neovimOnBuild}/lib/libnlua0.so")
            (self.lib.cmakeFeature "NVIM_HOST_PRG" "${neovimOnBuild}/bin/nvim")
            # The .mo translation step runs the TARGET nvim (no host hook) and so
            # can't run on the build host; skip translations for the cross build.
            (self.lib.cmakeBool "ENABLE_TRANSLATIONS" false)
          ];
        }
      )
    );

    # The wrapped `neovim` generates its remote-plugin manifest by RUNNING the
    # wrapped (target) nvim, which cannot execute on the build host -> "Exec
    # format error". manifestRc is hardcoded in the wrapper, so the step always
    # runs. For a config-less neovim the manifest is empty anyway (it is touched
    # empty at the end regardless), so short-circuit just that one invocation
    # when cross-compiling -- "if ! $out/bin/nvim-wrapper" is a unique anchor.
    neovim = super.neovim.overrideAttrs (
      old:
      self.lib.optionalAttrs (!self.stdenv.buildPlatform.canExecute self.stdenv.hostPlatform) {
        postBuild = builtins.replaceStrings
          [ "if ! $out/bin/nvim-wrapper" ]
          [ "if false && $out/bin/nvim-wrapper" ]
          old.postBuild;
      }
    );
  };

  # nss_wrapper's NSS-module shims use enum nss_status / NSS_STATUS, which only
  # exist behind <nss.h> (glibc). musl has no <nss.h>, so those (never-used-by-us)
  # functions fail to compile. Provide a fallback definition when neither nss.h
  # nor nss_common.h is present; harmless on glibc (the guard excludes it there).
  nssWrapperMusl = self: super: {
    nss_wrapper = super.nss_wrapper.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/nss_wrapper.c --replace-fail '#if defined(HAVE_NSS_H)
/* Linux and BSD */' '#if !defined(HAVE_NSS_H) && !defined(HAVE_NSS_COMMON_H)
enum nss_status { NSS_STATUS_TRYAGAIN = -2, NSS_STATUS_UNAVAIL = -1, NSS_STATUS_NOTFOUND = 0, NSS_STATUS_SUCCESS = 1, NSS_STATUS_RETURN = 2 };
typedef enum nss_status NSS_STATUS;
#endif
#if defined(HAVE_NSS_H)
/* Linux and BSD */'
      '';
    });
  };

  # zsh's Src/sort.c (strmetasort) ICEs GCC 15.2's object-size GIMPLE pass
  # (check_for_plus_in_loops, tree-object-size.cc:2158) at -O2 -- a compiler bug,
  # FORTIFY-independent (no _FORTIFY_SOURCE is even on the command). Compile just
  # that one file at -O0 (a file-scope optimize pragma) so the buggy pass is not
  # run; sort.c is not performance-critical for our use.
  zshSortFix = self: super: {
    zsh = super.zsh.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        sed -i '1i #pragma GCC optimize ("O0")' Src/sort.c
      '';
    });
  };

  # OpenSSH's privilege separation needs a chroot directory that exists AND is
  # owned by root and not group/world-writable. In a non-rooted Android app
  # sandbox we can neither create the default /var/empty nor own anything as
  # root, so sshd fatally exits at startup ("Missing privilege separation
  # directory"). Point the compiled privsep path at /system -- an always-present,
  # root-owned, 0755 directory that satisfies the check. sshd never chroots into
  # it when running non-root, so the directory is only stat()ed, never entered.
  opensshPrivsep = self: super: {
    openssh = super.openssh.overrideAttrs (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [ "--with-privsep-path=/system" ];
    });
  };

  # busybox's cgit patch URLs (git.busybox.net/busybox/patch/?id=...) now 404,
  # so its two baked archival-CVE patches fail to fetch -- and busybox is a nix
  # sandbox-shell dependency, so nix won't build. Those CVEs are tar/cpio/unzip
  # path-traversal fixes in busybox APPLETS, irrelevant to nix's internal
  # /bin/sh sandbox shell, so drop them; busybox builds cleanly without them.
  busyboxPatchFix = self: super: {
    busybox = super.busybox.overrideAttrs (old: {
      patches = super.lib.filter
        (p: !(super.lib.hasInfix "CVE-2023-39810" "${p}"
           || super.lib.hasInfix "CVE-2026-26157" "${p}"))
        (old.patches or [ ]);
    });
  };

  # nix (2.34) cross-built to aarch64-musl fails linking libnixexpr.so: the LTO
  # codegen pass tries to inline musl fortify-headers' always_inline vsnprintf
  # (pulled in via std::to_string) and dies -- "function body can be overwritten
  # at link time". fortify-headers only defines that always_inline wrapper when
  # _FORTIFY_SOURCE > 0, so drop the fortify hardening flag for every nix-*
  # component on this target -- the wrapper vanishes and the LTO link succeeds.
  # base.nix resolves through this nixVersions scope.
  nixLtoFix = self: super: {
    nixVersions = super.nixVersions.extend (finalV: prevV: {
      nixComponents_2_34 = prevV.nixComponents_2_34.overrideScope (finalC: prevC:
        super.lib.mapAttrs (n: v:
          if super.lib.isDerivation v && super.lib.hasPrefix "nix-" (v.pname or "")
          then v.overrideAttrs (o: {
                 hardeningDisable = (o.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];
               })
          else v) prevC);
    });
  };

  pkgs = import <nixpkgs> { overlays = [ docbookFix treeSitterCross neovimCross nssWrapperMusl zshSortFix opensshPrivsep busyboxPatchFix nixLtoFix ]; };
  # Android target: MUSL, not glibc. Modern glibc makes syscalls (rseq, statx,
  # ...) that Android's app seccomp filter kills with SIGSYS -- a glibc userland
  # cannot start inside a non-rooted app. musl uses the conservative syscalls
  # Android allows (verified: a static-musl binary runs in the app sandbox where
  # glibc dies), so it runs with no proot and no root.
  base = if android then pkgs.pkgsCross.aarch64-multiplatform-musl else pkgs;

  # ynss: our tiny musl-clean getpw*/getgr* LD_PRELOAD shim, compiled for the
  # target. Replaces nss_wrapper (which assumes glibc's NSS module API). Builds
  # with the cross stdenv's $CC, so it targets aarch64-musl like the rest.
  ynss = base.stdenv.mkDerivation {
    pname = "ynss";
    version = "1";
    src = ../ynss;
    dontConfigure = true;
    buildPhase = "$CC -shared -fPIC -O2 -o libynss.so ynss.c";
    installPhase = "install -Dm755 libynss.so $out/lib/libynss.so";
  };

  # sigsyscatch: diagnostic LD_PRELOAD that turns a silent seccomp SIGSYS into a
  # printed syscall number. Same one-file cross build as ynss.
  sigsyscatch = base.stdenv.mkDerivation {
    pname = "sigsyscatch";
    version = "1";
    src = ../sigsyscatch;
    dontConfigure = true;
    buildPhase = "$CC -shared -fPIC -O2 -o libsigsyscatch.so sigsyscatch.c";
    installPhase = "install -Dm755 libsigsyscatch.so $out/lib/libsigsyscatch.so";
  };

  # dnstest: tiny getaddrinfo()/freeaddrinfo() exerciser to verify the ynss DNS
  # shim on-device. Diagnostic only; not part of the bundle.
  dnstest = base.stdenv.mkDerivation {
    pname = "dnstest";
    version = "1";
    src = ../dnstest;
    dontConfigure = true;
    buildPhase = "$CC -O2 -o dnstest dnstest.c";
    installPhase = "install -Dm755 dnstest $out/bin/dnstest";
  };

  # yndronix-env: a single profile whose /bin symlinks every userland tool,
  # so the on-device session PATH is ONE entry instead of a colon-list of
  # store paths. Each tool is resolved by the SAME attr path build-package
  # uses, so the closure matches what the bundle already builds.
  yndronix-env = base.buildEnv {
    name = "yndronix-env";
    paths = map (n: pkgs.lib.getAttrFromPath (pkgs.lib.splitString "." n) base) [
      "coreutils" "bash" "openssh" "runit" "findutils" "gnugrep" "gnused"
      "less" "which" "tmux" "dnsutils" "neovim" "zsh" "clang"
      "fzf" "procps" "htop" "file" "tree" "jq" "curl" "wget" "gnutar" "gzip" "git" "ripgrep" "fd" "nix"
    ];
    pathsToLink = [ "/bin" "/libexec" ];
    ignoreCollisions = true;
  };
in
  if attr == "ynss" then ynss
  else if attr == "sigsyscatch" then sigsyscatch
  else if attr == "dnstest" then dnstest
  else if attr == "yndronix-env" then yndronix-env
  else pkgs.lib.getAttrFromPath (pkgs.lib.splitString "." attr) base
