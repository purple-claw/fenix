#!/bin/bash
##############################################################################
# assemble-image.sh — Create a bootable SD-USB image from pre-built components,
# because at the time of developing this Linux Image I have no access to the Linux Native Machine, 
# So i was unable to Run the loosetup Part and unabkle to complete the Image, this script along with the 
# Prebuilt Container tarball should run in a Native Linux Machine With x86_64 setup and work Load.
#
#   This script takes all pre-built components (rootfs tarball, custom U-Boot,
#   kernel + boot files) and assembles them into a flashable SD card image.
#
# WHAT IT CREATES:
#   A disk image with:
#     - MBR partition table
#     - Partition 1: FAT32 boot partition (240MB) with kernel + U-Boot scripts
#     - Partition 2: ext4 rootfs partition (~1.3GB) with Debian 12 minimal
#     - U-Boot written to raw sectors at the start of the image
#
# THE BOOT CHAIN:
#   1. Amlogic ROM reads U-Boot from fixed offset at start of SD card
#   2. U-Boot initializes DRAM, loads kernel + DTB + initrd from boot partition
#   3. Kernel boots, mounts rootfs partition, starts systemd
#   4. systemd targets multi-user.target (headless, serial console)
#
# USAGE:
#   sudo ./scripts/assemble-image.sh
#
# PREREQUISITES:
#   Run on a machine with: losetup, mkfs.vfat, mkfs.ext4, parted
#   All components built by Fenix first (make uboot, make kernel, etc.)
# Developed by Nithin.J For [OKAS] - Miantic AV Distribution (Systems)
# Updated on : 24-02-2026
##############################################################################
set -e -o pipefail

# Configuration
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="VIM3L"
IMAGE_NAME="vim3l-debian-12-minimal-custom-uboot-sd.img"
IMAGE_SIZE_MB=1700         # Total image size in MB
BOOT_SIZE_MB=240           # Boot partition size
BOOT_START_SECTOR=32768    # Sector where boot partition starts (16MB offset)
ROOTFS_TARBALL="${ROOT}/build/images/rootfs-vim3l-bookworm-minimal.tar.gz"
UBOOT_SD="${ROOT}/build/images/u-boot-mainline/${BOARD}/u-boot.bin.sd.bin"
BUILD_IMAGES="${ROOT}/build/images"
OUTPUT="${BUILD_IMAGES}/${IMAGE_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
teach() { echo -e "${CYAN}[LEARN]${NC} $*"; }

# Must be root
[[ $EUID -eq 0 ]] || error "This script requires root. Run: sudo $0"

##############################################################################
# STEP 1: Validate inputs
##############################################################################
info "=== Step 1: Validating components ==="
teach "We check that all build artifacts exist before touching any disk."

[ -f "$ROOTFS_TARBALL" ] || error "Rootfs tarball not found: $ROOTFS_TARBALL"
[ -f "$UBOOT_SD" ]       || error "U-Boot SD binary not found: $UBOOT_SD"

info "  Rootfs tarball : $(du -sh "$ROOTFS_TARBALL" | cut -f1)"
info "  U-Boot SD bin  : $(du -sh "$UBOOT_SD" | cut -f1)"
info "  Output image   : $OUTPUT"

##############################################################################
# STEP 2: Create empty image file
##############################################################################
info "=== Step 2: Creating ${IMAGE_SIZE_MB}MB empty image ==="
teach "We create a sparse file — it takes almost no disk space initially."
teach "The actual bytes are only written when we put data in them."

dd if=/dev/zero of="$OUTPUT" bs=1M count=0 seek=${IMAGE_SIZE_MB} status=none
info "  Image created: $(ls -lh "$OUTPUT" | awk '{print $5}')"

##############################################################################
# STEP 3: Partition the image
##############################################################################
info "=== Step 3: Creating MBR partition table ==="
teach "MBR (Master Boot Record) is the classic partition scheme."
teach "For Amlogic boards, U-Boot sits BEFORE partition 1, in the raw"
teach "sectors 1-32767. That's why boot partition starts at sector 32768 (16MB)."

# Calculate rootfs start (after boot partition)
BOOT_END_SECTOR=$(( BOOT_START_SECTOR + BOOT_SIZE_MB * 2048 - 1 ))
ROOTFS_START_SECTOR=$(( BOOT_END_SECTOR + 1 ))

fdisk "$OUTPUT" <<EOF >/dev/null 2>&1
o
n
p
1
${BOOT_START_SECTOR}
${BOOT_END_SECTOR}
a
t
b
n
p
2
${ROOTFS_START_SECTOR}

w
EOF

info "  Partition 1 (boot/FAT32): sectors ${BOOT_START_SECTOR}-${BOOT_END_SECTOR} (${BOOT_SIZE_MB}MB)"
info "  Partition 2 (rootfs/ext4): sector ${ROOTFS_START_SECTOR} to end"

##############################################################################
# STEP 4: Write U-Boot to raw sectors
##############################################################################
info "=== Step 4: Writing custom U-Boot to image ==="
teach "Amlogic ROM reads the bootloader from raw sectors 1+ of the SD card."
teach "u-boot.bin.sd.bin has a special 512-byte header that aligns it correctly."
teach "We write the first 442 bytes (to preserve MBR signature), then the rest"
teach "starting at sector 1 (byte offset 512)."

dd if="$UBOOT_SD" of="$OUTPUT" conv=fsync,notrunc bs=442 count=1 status=none
dd if="$UBOOT_SD" of="$OUTPUT" conv=fsync,notrunc bs=512 skip=1 seek=1 status=none

info "  U-Boot written ($(du -sh "$UBOOT_SD" | cut -f1))"

##############################################################################
# STEP 5: Set up loop device with partition scanning
##############################################################################
info "=== Step 5: Mounting image via loop device ==="
teach "A loop device makes a file appear as a block device (like /dev/sda)."
teach "--partscan tells the kernel to scan for partitions inside the image."
teach "This gives us /dev/loopXp1 and /dev/loopXp2 for each partition."

LOOP=$(losetup --find --show --partscan "$OUTPUT")
info "  Loop device: $LOOP"

# Wait for partition devices to appear
sleep 1
[ -b "${LOOP}p1" ] || error "Boot partition device ${LOOP}p1 not found"
[ -b "${LOOP}p2" ] || error "Rootfs partition device ${LOOP}p2 not found"

# Cleanup trap
cleanup() {
    info "Cleaning up..."
    umount /tmp/fenix-assemble/boot 2>/dev/null || true
    umount /tmp/fenix-assemble/root 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
    rm -rf /tmp/fenix-assemble
}
trap cleanup EXIT

##############################################################################
# STEP 6: Create filesystems
##############################################################################
info "=== Step 6: Creating filesystems ==="
teach "Boot partition uses FAT32 — U-Boot can read FAT natively."
teach "Root partition uses ext4 — the standard Linux filesystem."

mkfs.vfat -F 32 -n BOOT "${LOOP}p1" >/dev/null
mkfs.ext4 -F -q -L ROOTFS "${LOOP}p2"

info "  Boot  (FAT32): ${LOOP}p1"
info "  Rootfs (ext4): ${LOOP}p2"

##############################################################################
# STEP 7: Mount partitions
##############################################################################
info "=== Step 7: Mounting partitions ==="
mkdir -p /tmp/fenix-assemble/{boot,root}
mount "${LOOP}p1" /tmp/fenix-assemble/boot
mount "${LOOP}p2" /tmp/fenix-assemble/root

##############################################################################
# STEP 8: Extract rootfs
##############################################################################
info "=== Step 8: Extracting rootfs (this takes a while) ==="
teach "The rootfs tarball contains the entire Debian filesystem — about 344MB"
teach "compressed, ~1GB extracted. It includes the kernel, initramfs, systemd,"
teach "network tools, and all base packages for a headless system."

tar -xzf "$ROOTFS_TARBALL" -C /tmp/fenix-assemble/root
info "  Rootfs extracted: $(du -sh /tmp/fenix-assemble/root | cut -f1)"

##############################################################################
# STEP 9: Populate boot partition
##############################################################################
info "=== Step 9: Populating boot partition ==="
teach "The boot partition contains files U-Boot reads at power-on:"
teach "  - kernel image (zImage/Image)"
teach "  - initrd (initial ramdisk)"
teach "  - DTB (device tree blob describing hardware)"
teach "  - boot scripts (tell U-Boot what to load and how)"
teach "These are copied from /boot in the rootfs."

BOOT_SRC="/tmp/fenix-assemble/root/boot"
BOOT_DST="/tmp/fenix-assemble/boot"

# Copy kernel + initrd + DTB + boot scripts
for f in "$BOOT_SRC"/*; do
    fname=$(basename "$f")
    if [ -f "$f" ]; then
        cp "$f" "$BOOT_DST/"
        info "  Copied: $fname"
    elif [ -d "$f" ]; then
        cp -r "$f" "$BOOT_DST/"
        info "  Copied dir: $fname/"
    fi
done

# Ensure DTB symlink is resolved
if [ -L "$BOOT_SRC/dtb.img" ]; then
    cp -L "$BOOT_SRC/dtb.img" "$BOOT_DST/dtb.img"
fi

info "  Boot partition: $(du -sh "$BOOT_DST" | cut -f1)"

##############################################################################
# STEP 10: Sync and unmount
##############################################################################
info "=== Step 10: Syncing and unmounting ==="
teach "sync forces all cached writes to disk. Without it, data could be lost"
teach "if you remove the SD card too quickly."

sync
umount /tmp/fenix-assemble/boot
umount /tmp/fenix-assemble/root

##############################################################################
# STEP 11: Detach loop device
##############################################################################
losetup -d "$LOOP"
trap - EXIT
rm -rf /tmp/fenix-assemble

##############################################################################
# STEP 12: Final verification
##############################################################################
info "=== Step 12: Verification ==="
info "  Image file: $OUTPUT"
info "  Image size: $(du -sh "$OUTPUT" | cut -f1)"
info "  SHA256:     $(sha256sum "$OUTPUT" | cut -c1-16)..."

echo ""
info "============================================"
info "  IMAGE READY: $IMAGE_NAME"
info "============================================"
echo ""
teach "To flash to SD card:"
teach "  sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
teach "  (replace /dev/sdX with your actual SD card device)"
echo ""
teach "To verify with serial console (UART):"
teach "  Baud rate: 115200"
teach "  Serial device: ttyAML0"
teach "  You should see your custom U-Boot banner first."
echo ""
