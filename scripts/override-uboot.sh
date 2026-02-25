#!/bin/bash
set -e
UBOOT_IMAGE_DIR="/u-boot-mainline/VIM3L"
if [ -z "$UBOOT_IMAGE_DIR" ]; then
    echo "ERROR: UBOOT_IMAGE_DIR is not set"
    exit 1
fi

CUSTOM_UBOOT="$(pwd)/custom/uboot/u-boot.bin"

if [ ! -f "$CUSTOM_UBOOT" ]; then
    echo "ERROR: Custom u-boot.bin not found at $CUSTOM_UBOOT"
    exit 1
fi

echo ">>> Overriding eMMC u-boot.bin"
echo "    Source : $CUSTOM_UBOOT"
echo "    Target : build/u-boot-mainline-v2024.10/u-boot.bin"

cp -f "$CUSTOM_UBOOT" "$UBOOT_IMAGE_DIR/u-boot.bin"
sync