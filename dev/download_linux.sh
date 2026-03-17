#!/usr/bin/env bash

# dev/download_linux.sh - Automate downloading a minimal Linux kernel for Catenary OS MicroVMs.
# Downloads the Alpine Linux 'virt' flavor (bzImage) which is slim and virtualization-friendly.

set -euo pipefail

# Configuration
KERNEL_VERSION="6.6.21"
ALPINE_VERSION="v3.19"
ARCH="x86_64"
OUTPUT_DIR="assets/guest"
OUTPUT_FILENAME="linux-bzImage"
OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_FILENAME}"

# Alpine Linux Mirrors often host the kernel files in main x86_64 packages or separate directories.
# We'll use the official CDN for the specific virt kernel.
DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/releases/${ARCH}/netboot/vmlinuz-virt"

echo "--- Catenary OS: Linux Image Downloader ---"
echo "Target: ${ARCH} ${KERNEL_VERSION} (Alpine ${ALPINE_VERSION} virt)"
echo "Destination: ${OUTPUT_PATH}"

# Ensure assets/guest exists
mkdir -p "${OUTPUT_DIR}"

# Check for existing kernel
if [ -f "${OUTPUT_PATH}" ]; then
    echo "Existing image found at ${OUTPUT_PATH}"
    read -p "Overwrite existing image? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Download cancelled."
        exit 0
    fi
fi

echo "Downloading ${DOWNLOAD_URL}..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o "${OUTPUT_PATH}" "${DOWNLOAD_URL}"
elif command -v wget >/dev/null 2>&1; then
    wget -O "${OUTPUT_PATH}" "${DOWNLOAD_URL}"
else
    echo "Error: Neither curl nor wget found. Please install one of them."
    exit 1
fi

# Verify the image is < 20MB (as per project requirements)
FILE_SIZE=$(stat -c%s "${OUTPUT_PATH}")
MAX_SIZE=$((20 * 1024 * 1024))

if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
    echo "Warning: Downloaded image is larger than 20MB ($(numfmt --to=iec-i --suffix=B "$FILE_SIZE"))."
else
    echo "Successfully downloaded Linux kernel image ($(numfmt --to=iec-i --suffix=B "$FILE_SIZE"))."
fi

# Basic file type check
if command -v file >/dev/null 2>&1; then
    echo "File info:"
    file "${OUTPUT_PATH}"
fi

echo "Done. You can now build Catenary OS with the embedded Linux guest."
