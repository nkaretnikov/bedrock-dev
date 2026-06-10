#!/usr/bin/env bash
#
# Build bedrock.ko against the standalone bare-metal host kernel
# (host-kernel.nix, sitting next to this script) - the kernel you boot via
# configuration.nix.
#
# Why this exists: building the module against the dev-VM kernel produces a .ko
# whose .config and version won't match a bare-metal host. This script instead
# points KDIR at the *exact* kernel host-kernel.nix builds, using this shell's
# rustc — which is pinned to the same 1.94.0 that kernel uses. Same kernel build
# + same rustc on both sides ⇒ the module loads.
#
# Prerequisites:
#   * Run from inside the bedrock repo's `nix develop` (needs rustc 1.94.0,
#     clang, lld, bindgen). The module source is taken from that repo.
#   * You should already be booted on the host-kernel.nix kernel; if not, the
#     script warns and the resulting .ko won't load until you are.
#
# Layout assumed:
#   ~/bedrock-dev/host-kernel.nix       (kernel; next to this script)
#   ~/bedrock-dev/build-host-module.sh  (this script)
#   ~/dev/bedrock/crates/bedrock/       (module source; override with BEDROCK_REPO)
#
# Usage:
#   cd ~/dev/bedrock && nix develop
#   ~/bedrock-dev/build-host-module.sh [kernel_log]
#       kernel_log  any non-empty value enables pr_* logging (KERNEL_LOG=1)

set -euo pipefail

# host-kernel.nix lives next to this script.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
host_kernel_nix="$script_dir/host-kernel.nix"

# The module source lives in the bedrock repo (override with BEDROCK_REPO).
bedrock_repo="${BEDROCK_REPO:-$HOME/dev/bedrock}"

if [ ! -f "$host_kernel_nix" ]; then
    echo "error: $host_kernel_nix not found" >&2
    exit 1
fi
if [ ! -d "$bedrock_repo/crates/bedrock" ]; then
    echo "error: bedrock module source not found at $bedrock_repo/crates/bedrock" >&2
    echo "       set BEDROCK_REPO=/path/to/bedrock if it lives elsewhere" >&2
    exit 1
fi

echo ">> realising host kernel dev tree ($host_kernel_nix)"
kdev=$(nix-build --no-out-link -E "(import $host_kernel_nix {}).dev")
ver=$(nix-instantiate --eval --strict -E "(import $host_kernel_nix {}).modDirVersion" | tr -d '"')
kdir="$kdev/lib/modules/$ver/build"

if [ ! -d "$kdir" ]; then
    echo "error: kernel build tree not found at $kdir" >&2
    exit 1
fi

if [ "$ver" != "$(uname -r)" ]; then
    echo "WARNING: host kernel is '$ver' but the running kernel is '$(uname -r)'." >&2
    echo "         Boot the host kernel first, or the module will not load." >&2
fi

echo ">> building bedrock.ko"
echo ">>   KDIR=$kdir"
echo ">>   module=$bedrock_repo/crates/bedrock"
echo ">>   rustc=$(rustc --version 2>/dev/null || echo '??? (are you in nix develop?)')"

make_args=(KDIR="$kdir" LLVM=1)
if [ -n "${1:-}" ]; then
    make_args+=(KERNEL_LOG=1)
fi

make -C "$bedrock_repo/crates/bedrock" "${make_args[@]}"

echo ">> done: $bedrock_repo/crates/bedrock/bedrock.ko"
echo ">> load it with: sudo insmod $bedrock_repo/crates/bedrock/bedrock.ko"
