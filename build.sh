#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Nothing Phone 1 (Spacewar / SM7325 Snapdragon 778G+ 5G) Kernel Build Script
# Builds kernel with DroidSpaces, Docker, NetHunter HID, and container support
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
$CONFIG \
    --set-str LOCALVERSION "-droidspace" \
    --disable  LOCALVERSION_AUTO

# -- Module loading ---------------------------------------------------------------
$CONFIG \
    --enable  MODULES               \
    --enable  MODULE_FORCE_LOAD     \
    --enable  MODULE_FORCE_UNLOAD   \
    --enable  MODULE_SRCVERSION_ALL \
    --enable  MODULE_EXTRA_VERSIONS \
    --enable  MODULE_COMPRESS       \
    --enable  MODULE_COMPRESS_GZIP

# -- Preemption (mutually exclusive — use PREEMPT only) ---------------------------
$CONFIG \
    --enable  PREEMPT           \
    --disable PREEMPT_VOLUNTARY

# -- IPC & namespaces -------------------------------------------------------------
log "Enabling DroidSpaces container support..."
$CONFIG \
    --enable SYSCTL         \
    --enable SYSVIPC        \
    --enable POSIX_MQUEUE   \
    --enable NAMESPACES     \
    --enable PID_NS         \
    --enable UTS_NS         \
    --enable IPC_NS         \
    --enable USER_NS        \
    --enable NET_NS

# -- Seccomp ----------------------------------------------------------------------
$CONFIG \
    --enable SECCOMP        \
    --enable SECCOMP_FILTER

# -- Control groups ---------------------------------------------------------------
# NOTE: CFS_BANDWIDTH depends on !SCHED_WALT; skipped — Qualcomm sets SCHED_WALT=y
$CONFIG \
    --enable CGROUPS            \
    --enable CGROUP_DEVICE      \
    --enable CGROUP_PIDS        \
    --enable MEMCG              \
    --enable CGROUP_SCHED       \
    --enable FAIR_GROUP_SCHED   \
    --enable CGROUP_FREEZER     \
    --enable CGROUP_NET_PRIO

# -- Filesystems & devices --------------------------------------------------------
$CONFIG \
    --enable DEVTMPFS           \
    --enable DEVTMPFS_MOUNT     \
    --enable OVERLAY_FS         \
    --enable OVERLAY_FS_METACOPY\
    --enable FUSE_FS            \
    --enable FW_LOADER          \
    --enable FW_LOADER_USER_HELPER \
    --enable FW_LOADER_COMPRESS \
    --enable BLK_DEV_THROTTLING

# -- Networking: virtual interfaces -----------------------------------------------
log "Enabling networking features..."
$CONFIG \
    --enable VETH       \
    --enable MACVLAN    \
    --enable VXLAN      \
    --enable IPVLAN     \
    --enable IP_SCTP    \
    --enable TUN

# -- Networking: bridge -----------------------------------------------------------
# NOTE: BRIDGE_VLAN_FILTERING disabled — causes boot crash
$CONFIG \
    --enable  BRIDGE                \
    --disable BRIDGE_VLAN_FILTERING \
    --enable  BRIDGE_NETFILTER      \
    --disable ANDROID_PARANOID_NETWORK

# -- Netfilter / iptables / NAT ---------------------------------------------------
$CONFIG \
    --enable NETFILTER                          \
    --enable NETFILTER_ADVANCED                 \
    --enable NETFILTER_XTABLES                  \
    --enable NETFILTER_XT_TARGET_MASQUERADE     \
    --enable NETFILTER_XT_TARGET_TCPMSS         \
    --enable NETFILTER_XT_MATCH_ADDRTYPE        \
    --enable NETFILTER_XT_MATCH_IPVS            \
    --enable NF_CONNTRACK                       \
    --enable NF_CONNTRACK_IPV4                  \
    --enable NF_CONNTRACK_NETLINK               \
    --enable NF_NAT                             \
    --enable NF_NAT_IPV4                        \
    --enable NF_NAT_REDIRECT                    \
    --enable IP_NF_IPTABLES                     \
    --enable IP_NF_FILTER                       \
    --enable IP_NF_NAT                          \
    --enable IP_NF_TARGET_MASQUERADE            \
    --enable IP6_NF_NAT                         \
    --enable IP6_NF_TARGET_MASQUERADE

# -- nftables ---------------------------------------------------------------------
$CONFIG \
    --enable NF_TABLES          \
    --enable NF_TABLES_IPV4     \
    --enable NF_TABLES_IPV6     \
    --enable NFT_NAT            \
    --enable NFT_MASQ           \
    --enable NFT_CT             \
    --enable NFT_FIB            \
    --enable NFT_FIB_IPV4       \
    --enable NFT_FIB_IPV6

# -- Policy routing ---------------------------------------------------------------
$CONFIG \
    --enable IP_ADVANCED_ROUTER \
    --enable IP_MULTIPLE_TABLES

# -- IP Virtual Server ------------------------------------------------------------
$CONFIG \
    --enable IP_VS              \
    --enable IP_VS_NFCT         \
    --enable IP_VS_PROTO_TCP    \
    --enable IP_VS_PROTO_UDP    \
    --enable IP_VS_RR

# -- KVM virtualization -----------------------------------------------------------
log "Enabling KVM & virtio..."
$CONFIG \
    --enable VIRTUALIZATION         \
    --enable KVM                    \
    --enable KVM_ARM_HOST           \
    --enable VHOST                  \
    --enable VHOST_NET              \
    --enable VHOST_VSOCK            \
    --enable VIRTIO_MMIO            \
    --enable VIRTIO_MMIO_CMDLINE_DEVICES \
    --enable VIRT_DRIVERS           \
    --enable HUGETLBFS              \
    --enable CGROUP_HUGETLB

# -- NetHunter: USB gadget --------------------------------------------------------
log "Enabling NetHunter HID support..."
$CONFIG \
    --enable USB                        \
    --enable USB_ARCH_HAS_HCD           \
    --enable USB_COMMON                 \
    --enable USB_DWC3                   \
    --enable USB_DWC3_DUAL_ROLE         \
    --disable USB_DWC3_GADGET           \
    --enable USB_GADGET                 \
    --enable USB_GADGET_DEBUG           \
    --enable USB_GADGET_DEBUG_FILES     \
    --enable USB_GADGET_DEBUG_VS_EVENT  \
    --enable USB_STORAGE                \
    --enable USB_GADGET_SERIAL          \
    --enable USB_GADGET_CDC_COMPOSITE   \
    --enable USB_GADGET_ETH             \
    --enable USB_GADGET_UAC1            \
    --enable USB_GADGET_UAC1_LEGACY     \
    --enable USB_GADGET_UAC2            \
    --enable USB_GADGET_MIDI            \
    --enable USB_GADGET_UVC

# -- NetHunter: USB ConfigFS ------------------------------------------------------
$CONFIG \
    --enable USB_CONFIGFS           \
    --enable USB_CONFIGFS_F_ACC     \
    --enable USB_CONFIGFS_F_AUDIO_SRC \
    --enable USB_CONFIGFS_F_ECM     \
    --enable USB_CONFIGFS_F_EEM     \
    --enable USB_CONFIGFS_F_FS      \
    --enable USB_CONFIGFS_F_HID     \
    --enable USB_CONFIGFS_F_MIDI    \
    --enable USB_CONFIGFS_F_MTP     \
    --enable USB_CONFIGFS_F_NCM     \
    --enable USB_CONFIGFS_F_PTP     \
    --enable USB_CONFIGFS_F_RNDIS   \
    --enable USB_CONFIGFS_F_SERIAL  \
    --enable USB_CONFIGFS_F_OBEX    \
    --enable USB_CONFIGFS_F_UAC1    \
    --enable USB_CONFIGFS_F_UAC1_LEGACY \
    --enable USB_CONFIGFS_F_UAC2    \
    --enable USB_CONFIGFS_F_VIDEO   \
    --enable USB_CONFIGFS_SERIAL    \
    --enable USB_CONFIGFS_ACM       \
    --enable USB_CONFIGFS_OBEX      \
    --enable USB_CONFIGFS_NCM       \
    --enable USB_CONFIGFS_ECM       \
    --enable USB_CONFIGFS_EEM       \
    --enable USB_CONFIGFS_RNDIS

# -- NetHunter: HID & input -------------------------------------------------------
$CONFIG \
    --enable HID                        \
    --enable HID_GENERIC                \
    --enable USB_HID                    \
    --enable USB_HIDDEV                 \
    --enable USB_F_HID                  \
    --enable USB_F_HID_CDC              \
    --enable INPUT_MOUSEDEV             \
    --enable INPUT_JOYDEV               \
    --enable INPUT_EVDEV                \
    --enable INPUT_SPARSEKMAP           \
    --enable INPUT_TOUCHSCREEN_SILEX    \
    --enable INPUT_TOUCHSCREEN

# -- NetHunter: UVC webcam --------------------------------------------------------
$CONFIG \
    --enable USB_VIDEO_CLASS                    \
    --enable USB_VIDEO_CLASS_INPUT_EVENT_DEVICE \
    --enable MEDIA_SUPPORT                      \
    --enable MEDIA_CAMERA_SUPPORT

# -- NetHunter: Bluetooth ---------------------------------------------------------
$CONFIG \
    --enable BT             \
    --enable BT_RFCOMM      \
    --enable BT_BNEP        \
    --enable BT_CMTP        \
    --enable BT_HIDP        \
    --enable BT_HCIUART     \
    --enable BT_MSM         \
    --enable BT_QCOM        \
    --enable NET_BLUETOOTH  \
    --enable BT_BREDR       \
    --enable BT_LE          \
    --enable RFKILL         \
    --enable RFKILL_INPUT

# -- NetHunter: NFC ---------------------------------------------------------------
$CONFIG \
    --enable NFC            \
    --enable NFC_HCI        \
    --enable NFC_DIGI       \
    --enable NFC_FSI        \
    --enable NFC_NXP_NCI    \
    --enable NFC_NXP_NCI_I2C \
    --enable NFC_PN544_I2C

# -- Extra Linux-like features: VPN & filesystems ---------------------------------
log "Enabling extra Linux features..."
$CONFIG \
    --enable WIREGUARD          \
    --enable CIFS               \
    --enable CIFS_XATTR         \
    --enable CIFS_POSIX         \
    --enable CIFS_UPCALL        \
    --enable CIFS_DEBUG         \
    --enable CIFS_DFS_UPCALL    \
    --enable NFS_FS             \
    --enable NFS_V2             \
    --enable NFS_V3             \
    --enable NFS_V4             \
    --enable NFS_V4_1           \
    --enable NFS_V4_2           \
    --enable NFSD               \
    --enable LOCKD              \
    --enable NFS_ACL_SUPPORT    \
    --enable GRACE_PERIOD       \
    --enable 9P_FS              \
    --enable 9P_FSCACHE         \
    --enable 9P_NET_PLUS        \
    --enable NET_9P             \
    --enable NET_9P_VIRTIO      \
    --enable F2FS_FS            \
    --enable F2FS_FS_XATTR      \
    --enable F2FS_FS_POSIX_ACL  \
    --enable F2FS_FS_SECURITY

# -- Extra Linux-like features: networking ----------------------------------------
$CONFIG \
    --enable OPENVSWITCH            \
    --enable OVS_VPORT              \
    --enable OVS_VPORT_GENEVE       \
    --enable OVS_VPORT_GRE          \
    --enable OVS_VPORT_VXLAN        \
    --enable BATMAN_ADV             \
    --enable BATMAN_ADV_DAT         \
    --enable BATMAN_ADV_NC          \
    --enable BATMAN_ADV_DEBUGFS     \
    --enable NET_TEAM               \
    --enable NET_TEAM_MODE_ROUNDROBIN \
    --enable NET_TEAM_MODE_BROADCAST \
    --enable NET_TEAM_MODE_ACTIVE_BACKUP \
    --enable NET_TEAM_MODE_LOADBALANCE

# -- CPU governors & I/O schedulers -----------------------------------------------
$CONFIG \
    --enable CPU_FREQ_GOV_PERFORMANCE   \
    --enable CPU_FREQ_GOV_POWERSAVE     \
    --enable CPU_FREQ_GOV_ONDEMAND      \
    --enable CPU_FREQ_GOV_CONSERVATIVE  \
    --enable CPU_FREQ_GOV_SCHEDUTIL     \
    --enable MQ_IOSCHED_DEADLINE        \
    --enable MQ_IOSCHED_KYBER           \
    --enable IOSCHED_BFQ                \
    --enable BFQ_GROUP_IOSCHED

# -- Misc kernel features ---------------------------------------------------------
$CONFIG \
    --enable IO_URING               \
    --enable KEXEC                  \
    --enable KEXEC_CORE             \
    --enable ELF_CORE               \
    --enable PROC_VMCORE            \
    --enable YAMA                   \
    --enable BPF_SYSCALL            \
    --enable BPF_JIT                \
    --enable BPF_UNPRIV_DEFAULT_OFF \
    --enable IKHEADERS              \
    --enable KALLSYMS               \
    --enable KALLSYMS_ALL

# -- Crypto -----------------------------------------------------------------------
$CONFIG \
    --enable CRYPTO_JITTERENTROPY       \
    --enable CRYPTO_CHACHA20POLY1305    \
    --enable CRYPTO_AEGIS128            \
    --enable CRYPTO_MD4                 \
    --enable CRYPTO_TWOFISH             \
    --enable CRYPTO_TWOFISH_NEON        \
    --enable CRYPTO_SEQIV

make -C "$KERNEL_DIR" "${MAKE_FLAGS[@]}" O="$OUT_DIR" olddefconfig
log "Config ready."

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — Build kernel, dtb, dtbo images / modules
# ──────────────────────────────────────────────────────────────────────────────
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
        --cmdline 'systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory cgroup_enable=cpuset cgroup_memory=1 swapaccount=1 namespace.unpriv_enable=1 user_namespace.enable=1' \
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
