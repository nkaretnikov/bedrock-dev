# Standalone host kernel for a bare-metal machine.
#
# This is NOT the bedrock dev-VM kernel and NOT the guest kernel. It rebuilds
# the *nixpkgs* Linux 6.18 kernel - reusing its hardware-complete .config and
# source, so it boots real hardware - but with:
#   * the LLVM/clang toolchain, and
#   * the EXACT rustc the bedrock module is built with (stable 1.94.0, the same
#     rust-overlay revision the bedrock flake pins), and
#   * CONFIG_RUST=y and the in-tree KVM host disabled (bedrock owns VMX).
#
# Everything is pinned internally, so this derivation is byte-identical no
# matter who imports it. That is the whole point: it lets the out-of-tree
# bedrock.ko, built *separately* in `nix develop` against this kernel, actually
# load — same kernel build on both sides, and the same rustc on both sides.
#
# Use from /etc/nixos/configuration.nix:
#
#   { pkgs, lib, ... }:
#   let
#     hostKernel = import /home/nikita/bedrock-dev/host-kernel.nix { };
#   in {
#     boot.kernelPackages = pkgs.linuxPackagesFor hostKernel;
#     # bedrock disables KVM_INTEL; drop it from the hardware scan's defaults:
#     boot.kernelModules = lib.mkForce [ ];
#   }
#
# Then build + load the module (from the bedrock repo, after booting this):
#   cd ~/dev/bedrock && nix develop
#   ~/bedrock-dev/build-host-module.sh
#   sudo insmod ~/dev/bedrock/crates/bedrock/bedrock.ko

{ }:

let
  # Pinned so the result is reproducible and identical across every import
  # site (configuration.nix *and* build-host-module.sh).
  #
  # nixpkgs: the same revision as this machine's channel, so we reuse the
  #          Linux 6.18.34 source + config that already boots it.
  # rust-overlay: the same revision the bedrock flake pins, so this kernel's
  #          rustc is byte-identical to the one `nix develop` builds the
  #          module with (Rust's kernel ABI is keyed on the rustc version).
  nixpkgsRev     = "9b696460ac78b5ccfc17c854d8c976f20456e943";
  rustOverlayRev = "d8b1b209203665924c81eabf750492530754f27e";

  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz";
  }) {
    system = "x86_64-linux";
    overlays = [
      (import (builtins.fetchTarball {
        url = "https://github.com/oxalica/rust-overlay/archive/${rustOverlayRev}.tar.gz";
      }))
    ];
  };

  rustToolchain = pkgs.rust-bin.stable."1.94.0".default.override {
    extensions = [ "rust-src" "rustfmt" ];
  };

  llvmPackages = pkgs.llvmPackages;

  # The stock nixpkgs kernel whose hardware-complete source + config we reuse.
  base = pkgs.linuxPackages_6_18.kernel;

  # Take the nixpkgs .config (which already boots this machine: NVMe, btrfs,
  # ixgbe, tg3, AHCI, vfat/EFI, USB, ... mostly as modules, matching what the
  # NixOS initrd expects) and layer the bedrock requirements on top.
  configfile = pkgs.runCommand "host-linux-6.18-config" {
    nativeBuildInputs = [
      llvmPackages.clang
      llvmPackages.llvm
      llvmPackages.lld
      rustToolchain
      pkgs.rust-bindgen
      pkgs.python3
      pkgs.gnumake
      pkgs.flex
      pkgs.bison
      pkgs.bc
      pkgs.perl
      pkgs.elfutils
      pkgs.openssl
    ];
  } ''
    # base.src is a .tar.xz tarball (not an unpacked tree), so extract it.
    mkdir src
    tar -xf ${base.src} -C src --strip-components=1
    chmod -R u+w src
    cd src
    patchShebangs scripts/

    # Seed from the known-good nixpkgs config, then re-resolve under LLVM
    # (this flips CC_IS_CLANG, drops GCC-only options, etc.).
    cp ${base.configfile} .config
    make LLVM=1 ARCH=x86 olddefconfig

    # bedrock requirements on top of the working config.
    ./scripts/config --enable RUST
    ./scripts/config --enable VIRTUALIZATION
    ./scripts/config --disable KVM
    ./scripts/config --disable KVM_INTEL
    ./scripts/config --enable MODULES
    ./scripts/config --enable MODULE_UNLOAD
    ./scripts/config --enable MODULE_FORCE_LOAD
    ./scripts/config --enable MISC_DEVICES

    # The nixpkgs config references distro signing certs we don't carry here,
    # and would otherwise refuse to load an unsigned out-of-tree module.
    ./scripts/config --disable MODULE_SIG
    ./scripts/config --disable MODULE_SIG_FORCE
    ./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    ./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

    ./scripts/config --disable WERROR

    make LLVM=1 ARCH=x86 olddefconfig
    make LLVM=1 ARCH=x86 rustavailable

    # Fail the build (not the boot) on a regression: Rust on, KVM off, and the
    # root/boot drivers still present (=y or =m).
    grep -q '^CONFIG_RUST=y$' .config        || { echo "ERROR: CONFIG_RUST not enabled"; exit 1; }
    if grep -qE '^CONFIG_KVM=(y|m)$' .config; then echo "ERROR: KVM still enabled"; exit 1; fi
    for opt in BLK_DEV_NVME BTRFS_FS IXGBE TIGON3 SATA_AHCI VFAT_FS EFI; do
      grep -qE "^CONFIG_$opt=(y|m)\$" .config || { echo "ERROR: CONFIG_$opt missing"; grep "CONFIG_$opt" .config || true; exit 1; }
    done

    cp .config $out
  '';

  # Swap stdenv to LLVM so nixpkgs passes CC=clang / LD=ld.lld on the make line.
  hostKernel = (pkgs.linuxManualConfig {
    inherit (base) version modDirVersion src;
    inherit configfile;
    allowImportFromDerivation = true;
  }).override {
    stdenv = llvmPackages.stdenv;
  };

in
hostKernel.overrideAttrs (old: {
  # rustToolchain first, to shadow any default rustc nixpkgs adds for RUST=y.
  nativeBuildInputs = [
    rustToolchain
  ] ++ (old.nativeBuildInputs or []) ++ [
    pkgs.python3
    pkgs.elfutils
    pkgs.openssl
  ];

  # Force BOTH the compiler and the core/alloc source to OUR 1.94.0 toolchain.
  # nixpkgs (generic.nix) hard-sets env.RUST_LIB_SRC to the channel's 1.91.1
  # core source; compiling that with our 1.94.0 rustc fails rust/core.o with
  # a flood of E0658 errors. Pin RUSTC, RUSTFMT and RUST_LIB_SRC so the
  # compiler and the library source are the same version.
  env = (old.env or {}) // {
    RUST_LIB_SRC = "${rustToolchain}/lib/rustlib/src/rust/library";
  };
  makeFlags = (old.makeFlags or []) ++ [
    "RUSTC=${rustToolchain}/bin/rustc"
    "RUSTFMT=${rustToolchain}/bin/rustfmt"
  ];

  # LLVM=1 for the kernel's internal logic (integrated assembler, llvm-ar, ...).
  postPatch = (old.postPatch or "") + ''
    sed -i '2iLLVM=1' Makefile
  '';
})
