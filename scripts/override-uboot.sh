#!/bin/bash
##############################################################################
# override-uboot.sh - Script to repalce the system Built U-boot With Our Custom U-Boot of OKAS-SIG
#
# HOW IT WORKS:
#   Fenix builds U-Boot and places the result in:
#     build/images/u-boot-mainline/<BOARD>/u-boot.bin      (for eMMC)
#     build/images/u-boot-mainline/<BOARD>/u-boot.bin.sd.bin (for SD/USB)
#
#   The pack_image_platform() function in config/boards/VIM.inc reads from
#   $UBOOT_IMAGE_DIR and writes the bootloader into the final disk image.
#   For SD-USB: write_uboot_platform() uses u-boot.bin.sd.bin
#   For eMMC:   write_uboot_platform_ext() uses u-boot.bin
#
#   By replacing both files AFTER Fenix builds U-Boot but BEFORE image
#   packing, we inject our custom bootloader without changing any Fenix logic.
#
# Script Developed by Nitin.J - Miantic Development Team(Systems)
##############################################################################
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="${KHADAS_BOARD:-VIM3L}"
UBOOT_IMAGE_DIR="${ROOT}/build/images/u-boot-mainline/${BOARD}"
CUSTOM_UBOOT="${ROOT}/custom/uboot/u-boot.bin"

# Validate source
if [ ! -f "$CUSTOM_UBOOT" ]; then
    echo "ERROR: Custom u-boot.bin not found at $CUSTOM_UBOOT"
    exit 1
fi

# Validate target directory
if [ ! -d "$UBOOT_IMAGE_DIR" ]; then
    echo "ERROR: UBOOT_IMAGE_DIR does not exist: $UBOOT_IMAGE_DIR"
    echo "       Did you run 'make uboot' first?"
    exit 1
fi

echo ">>> Overriding U-Boot binaries for ${BOARD}"
echo "    Source : $CUSTOM_UBOOT ($(stat -c%s "$CUSTOM_UBOOT") bytes)"
echo "    Target : $UBOOT_IMAGE_DIR/"

# Replace u-boot.bin (used for eMMC flashing)
cp -f "$CUSTOM_UBOOT" "$UBOOT_IMAGE_DIR/u-boot.bin"

# For SD-USB images, u-boot.bin.sd.bin is the actual bootloader.
# On Amlogic, .sd.bin = u-boot.bin with 512-byte MBR header prepended.
# So instead of Using FIP Packaging I will create it by prepending 512 zero bytes to u-boot.bin.
echo "    Creating u-boot.bin.sd.bin (512-byte header + u-boot.bin)"
dd if=/dev/zero bs=442 count=1 2>/dev/null > "$UBOOT_IMAGE_DIR/u-boot.bin.sd.bin"
dd if=/dev/zero bs=70 count=1 2>/dev/null >> "$UBOOT_IMAGE_DIR/u-boot.bin.sd.bin"
cat "$CUSTOM_UBOOT" >> "$UBOOT_IMAGE_DIR/u-boot.bin.sd.bin"

sync

# Verify
echo ""
echo "    Verification:"
echo "    u-boot.bin     : $(sha256sum "$UBOOT_IMAGE_DIR/u-boot.bin" | cut -c1-16)..."
echo "    u-boot.bin.sd  : $(sha256sum "$UBOOT_IMAGE_DIR/u-boot.bin.sd.bin" | cut -c1-16)..."
echo "    custom source  : $(sha256sum "$CUSTOM_UBOOT" | cut -c1-16)..."
echo ""
echo ">>> Override complete. Proceed with 'make image'"