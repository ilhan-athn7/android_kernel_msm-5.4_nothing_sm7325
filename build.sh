#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Nothing Phone 1 (Spacewar / SM7325 Snapdragon 778G+ 5G) Kernel Build Script
# Builds kernel with NOMOUNT support
#
# Usage:
#   ./build.sh              — full build
#   ./build.sh clean        — remove out/ directory
#   ./build.sh defconfig    — only regenerate defconfig, no build
#   ./build.sh modules      — only build modules
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# COLORS & LOGGING
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GRN}[BUILD]${NC} $*"; }
info() { echo -e "${CYN}[INFO ]${NC} $*"; }
warn() { echo -e "${YLW}[WARN ]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# PATHS
# ──────────────────────────────────────────────────────────────────────────────
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$WORK_DIR/android_kernel_msm-5.4_nothing_sm7325"
OUT_DIR="$WORK_DIR/out"
MODULES_OUT="$WORK_DIR/modules_out"

CLANG_PATH="$WORK_DIR/prebuilts/clang/host/linux-x86/clang-r383902c/bin"
MKBOOTIMG="$WORK_DIR/tools/mkbootimg/mkbootimg.py"
MKDTBOIMG="$WORK_DIR/tools/mkdtboimg/mkdtboimg.py"
UNPACKBOOTIMG="$WORK_DIR/tools/mkbootimg/unpack_bootimg.py"
BOOT_RAMDISK="$WORK_DIR/boot_unpack/ramdisk"
VENDOR_RAMDISK="$WORK_DIR/vendor_boot_unpack/vendor_ramdisk"
STOCK_BOOT_IMG="$WORK_DIR/stock_blobs/boot.img"
STOCK_VENDOR_BOOT_IMG="$WORK_DIR/stock_blobs/vendor_boot.img"
BOOT_IMG="$WORK_DIR/boot.img"
VENDOR_BOOT_IMG="$WORK_DIR/vendor_boot.img"
DTB_IMG="$WORK_DIR/dtb"
DTBO_IMG="$WORK_DIR/dtbo.img"
DTS_DIR="$OUT_DIR/arch/arm64/boot/dts/vendor/qcom"

# ──────────────────────────────────────────────────────────────────────────────
# SUBCOMMANDS
# ──────────────────────────────────────────────────────────────────────────────
DEFCONFIG_ONLY=0
MODULES_ONLY=0

case "${1:-}" in
    clean)
        log "Removing $OUT_DIR and $MODULES_OUT ..."
        rm -rf "$OUT_DIR" "$MODULES_OUT"
        log "Done."
        exit 0
        ;;
    defconfig)  DEFCONFIG_ONLY=1 ;;
    modules)    MODULES_ONLY=1   ;;
    "")                          ;;
    *)
        die "Unknown command '$1'. Use: clean | defconfig | modules | (empty for full build)"
        ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — Download & verify toolchain
# ──────────────────────────────────────────────────────────────────────────────
log "Setting up Clang toolchain..."
mkdir -p "$WORK_DIR/prebuilts/clang/host/linux-x86/clang-r383902c/"
curl -L "https://android.googlesource.com/platform//prebuilts/clang/host/linux-x86/+archive/4c6fbc28d3b078a5308894fc175f962bb26a5718/clang-r383902c.tar.gz" \
    --output clang-r383902c.tar.gz
tar -xzf "clang-r383902c.tar.gz" -C "$WORK_DIR/prebuilts/clang/host/linux-x86/clang-r383902c/"

PATH="$CLANG_PATH:$PATH"

command -v "$CLANG_PATH/clang"   >/dev/null 2>&1 || die "clang not found at $CLANG_PATH"
command -v "$CLANG_PATH/ld.lld"  >/dev/null 2>&1 || die "ld.lld not found at $CLANG_PATH"
command -v "$CLANG_PATH/llvm-nm" >/dev/null 2>&1 || die "llvm-nm not found at $CLANG_PATH"

log "Clang  : $($CLANG_PATH/clang --version | head -1)"
log "ld.lld : $($CLANG_PATH/ld.lld --version | head -1)"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — Build variables
# ──────────────────────────────────────────────────────────────────────────────
MAKE_FLAGS=(
    ARCH="arm64"
    CROSS_COMPILE="aarch64-linux-gnu-"
    CLANG_TRIPLE="aarch64-linux-gnu-"
    REAL_CC="$CLANG_PATH/clang"
    LD="$CLANG_PATH/ld.lld"
    NM="$CLANG_PATH/llvm-nm"
    OBJCOPY="$CLANG_PATH/llvm-objcopy"
    LLVM_IAS=1
    DISABLE_WRAPPER=1
    LOCALVERSION=""
    HOSTCC="gcc"
    HOSTLD="ld"
    HOSTAR="ar"
)

mkdir -p "$OUT_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — Load base defconfig
# ──────────────────────────────────────────────────────────────────────────────
PHONE_CONFIG="$KERNEL_DIR/arch/arm64/configs/spacewar_defconfig"
[ -f "$PHONE_CONFIG" ] || die "Config not found at $PHONE_CONFIG — extract from phone with: adb shell su -c 'cat /proc/config.gz' | gunzip > original_config.txt"

log "Loading config: $PHONE_CONFIG"
cp "$PHONE_CONFIG" "$OUT_DIR/.config"

[ "$DEFCONFIG_ONLY" -eq 1 ] && { log "defconfig-only mode — done."; exit 0; }

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — Patch config
# ──────────────────────────────────────────────────────────────────────────────
make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" olddefconfig

CONFIG="$KERNEL_DIR/scripts/config --file $OUT_DIR/.config"

# -- Enable DTBO building ---------------------------------------------------------
log "Enabling device tree compilation..."
$CONFIG \
    --enable BUILD_ARM64_DT_OVERLAY

# -- Disable broken audio drivers (require proprietary headers) -------------------
log "Disabling broken audio drivers..."
$CONFIG \
    --disable SND_SOC_WCD934X       \
    --disable SND_SOC_WCD934X_V2    \
    --disable WCD9XXX_CORE          \
    --disable SOUNDWIRE             \
    --disable PINCTRL_WCD           \
    --disable PINCTRL_LPI           \
    --disable SOUNDWIRE_WCD_CTRL    \
    --disable SOUNDWIRE_MSTR_CTRL   \
    --disable WCD_SPI_AC            \
    --disable SND_EVENT

# -- Kernel identity --------------------------------------------------------------
log "Configuring kernel identity & modules..."
cd $KERNEL_DIR
curl https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/master/kernel/setup.sh | bash -s master
cd $WORK_DIR

$CONFIG \
    --enable  LOCALVERSION_AUTO

make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" olddefconfig
log "Config ready."

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — Build kernel, dtb, dtbo images / modules
# ──────────────────────────────────────────────────────────────────────────────
export KBUILD_BUILD_USER=nothing
export KBUILD_BUILD_HOST=NTSV-J900D1VY
export KBUILD_BUILD_TIMESTAMP="Fri Feb 6 10:41:34 CST 2026"
export KBUILD_BUILD_VERSION=1
echo "-g49c0dcb3dc63" > $KERNEL_DIR/.scmversion

if [ "$MODULES_ONLY" -eq 1 ]; then
    log "Building modules only..."
    make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" -j"$(nproc)" modules
    make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" INSTALL_MOD_PATH="$MODULES_OUT" modules_install
    log "Modules built successfully!"
    exit 0
fi

log "Building kernel Image — $(nproc) parallel jobs..."
make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" -j"$(nproc)" Image dtbs
log "Kernel Image built successfully!"
info "Note: using vendor prebuilt modules from /vendor/lib/modules"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 6 — Download mkbootimg & stock boot.img, then pack
# ──────────────────────────────────────────────────────────────────────────────
log "Fetching mkbootimg..."
mkdir -p "$(dirname "$MKBOOTIMG")" "$(dirname "$MKDTBOIMG")" "$WORK_DIR/boot_unpack/" "$WORK_DIR/vendor_boot_unpack/" "$WORK_DIR/stock_blobs"
curl -L "https://android.googlesource.com/platform/system/tools/mkbootimg/+archive/refs/heads/main.tar.gz" \
    | tar -xz -C "$(dirname "$MKBOOTIMG")"
log "Fetching mkdtboimg..."
curl -L "https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main-kernel/utils/src/mkdtboimg.py?format=TEXT" | base64 -d > $MKDTBOIMG

log "Fetching latest stock boot.img from nothing_archive..."
LATEST_TAG=$(
    curl -s "https://api.github.com/repos/spike0en/nothing_archive/releases" \
    | grep -oP '"tag_name": "\KSpacewar_[^"]+' \
    | sort -t'-' -k2 -rn \
    | head -n 1
)
curl -L "https://github.com/spike0en/nothing_archive/releases/download/${LATEST_TAG}/${LATEST_TAG}-image-boot.7z" \
    -o image-boot.7z
7z e image-boot.7z -o"$WORK_DIR/stock_blobs" -y boot.img vendor_boot.img

if ls "$DTS_DIR"/*.dtb >/dev/null 2>&1; then
    find "$DTS_DIR" -name "*.dtb" | sort | xargs cat > "$DTB_IMG"
else
    warn "No .dtb files found in $DTS_DIR — skipping DTB concatenation"
fi
if ls "$DTS_DIR"/*.dtbo >/dev/null 2>&1; then
    log "Packing dtbo.img from $(ls "$DTS_DIR"/*.dtbo | wc -l) overlays..."
    python3 "$MKDTBOIMG" create "$DTBO_IMG" --page_size=4096 "$DTS_DIR"/*.dtbo
    log "dtbo.img : $DTBO_IMG ($(du -sh "$DTBO_IMG" | cut -f1))"
else
    warn "No .dtbo files found in $DTS_DIR — skipping dtbo.img"
    warn "Make sure CONFIG_BUILD_ARM64_DT_OVERLAY=y is set in your defconfig"
fi

python3 "$UNPACKBOOTIMG" --boot_img "$STOCK_BOOT_IMG" --out "$WORK_DIR/boot_unpack/"
python3 "$UNPACKBOOTIMG" --boot_img "$STOCK_VENDOR_BOOT_IMG" --out "$WORK_DIR/vendor_boot_unpack/"

[ -f "$MKBOOTIMG" ] || die "mkbootimg not found at $MKBOOTIMG"

if [ -f "$BOOT_RAMDISK" ]; then
    log "Packing boot.img..."
    python3 "$MKBOOTIMG" \
        --header_version 3                 \
        --os_version     11.0.0            \
        --os_patch_level 2025-05           \
        --kernel  "$OUT_DIR/arch/arm64/boot/Image" \
        --ramdisk "$BOOT_RAMDISK"          \
        --cmdline '' \
        --output  "$BOOT_IMG"
    log "boot.img : $BOOT_IMG ($(du -sh "$BOOT_IMG" | cut -f1))"
else
    warn "Ramdisk not found at $BOOT_RAMDISK — skipping boot.img packing"
    warn "Unpack manually: python3 \$UNPACKBOOTIMG --boot_img boot.img --out boot_unpack"
fi

if [ -f "$VENDOR_RAMDISK" ] && [ -f "$DTB_IMG" ]; then
    log "Packing vendor_boot.img..."
    python3 "$MKBOOTIMG"                   \
        --header_version 3                 \
        --pagesize 0x00001000              \
        --base 0x00000000                  \
        --kernel_offset 0x00008000         \
        --ramdisk_offset 0x01000000        \
        --tags_offset 0x00000100           \
        --dtb_offset 0x0000000001f00000    \
        --vendor_cmdline 'androidboot.hardware=qcom androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=0 loop.max_part=7 cgroup.memory=nokmem,nosocket pcie_ports=compat loop.max_part=7 iptable_raw.raw_before_defrag=1 ip6table_raw.raw_before_defrag=1 buildvariant=user' \
        --board ''                         \
        --dtb "$DTB_IMG"                   \
        --vendor_ramdisk "$VENDOR_RAMDISK" \
        --vendor_boot  "$VENDOR_BOOT_IMG"
    log "vendor_boot.img : $VENDOR_BOOT_IMG ($(du -sh "$VENDOR_BOOT_IMG" | cut -f1))"
else
    warn "Vendor ramdisk not found at $VENDOR_RAMDISK — skipping vendor_boot.img packing"
    warn "Unpack manually: python3 \$UNPACKBOOTIMG --boot_img vendor_boot.img --out vendor_boot_unpack"
fi

# ──────────────────────────────────────────────────────────────────────────────
# DONE
# ──────────────────────────────────────────────────────────────────────────────
log "════════════════════════════════════════════════"
log "              BUILD COMPLETE"
log "════════════════════════════════════════════════"
