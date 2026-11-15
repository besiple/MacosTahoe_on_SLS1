#!/usr/bin/env bash
set -e

# Sync OpenCore configuration and kexts from repository to EFI partition
# Target: Microsoft Surface Laptop Studio (1st Gen)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
EFI_OC_SRC="$REPO_DIR/efi-oc"
EFI_BOOT_SRC="$REPO_DIR/efi-boot"

echo "=== macOS Tahoe OpenCore EFI Deployer ==="
echo "Source: $EFI_OC_SRC"

# 1. Check if EFI partition is mounted
MOUNT_POINT=""
if [ -d "/Volumes/EFI/EFI" ]; then
    MOUNT_POINT="/Volumes/EFI"
elif [ -d "/Volumes/NO NAME/EFI" ]; then
    MOUNT_POINT="/Volumes/NO NAME"
else
    echo "Searching for EFI partition (disk0s1)..."
    if diskutil info /dev/disk0s1 >/dev/null 2>&1; then
        diskutil mount /dev/disk0s1 || sudo diskutil mount /dev/disk0s1
        if [ -d "/Volumes/EFI/EFI" ]; then
            MOUNT_POINT="/Volumes/EFI"
        elif [ -d "/Volumes/NO NAME/EFI" ]; then
            MOUNT_POINT="/Volumes/NO NAME"
        fi
    fi
fi

if [ -z "$MOUNT_POINT" ]; then
    echo "ERROR: Could not locate or mount EFI partition!"
    echo "Please mount your EFI partition manually, e.g.: sudo diskutil mount /dev/disk0s1"
    exit 1
fi

echo "Target EFI mounted at: $MOUNT_POINT"

# 2. Backup existing config if present
if [ -f "$MOUNT_POINT/EFI/OC/config.plist" ]; then
    echo "Backing up existing config.plist -> config.plist.backup..."
    cp "$MOUNT_POINT/EFI/OC/config.plist" "$MOUNT_POINT/EFI/OC/config.plist.backup"
fi

# 3. Synchronize EFI/OC
echo "Syncing efi-oc -> $MOUNT_POINT/EFI/OC..."
mkdir -p "$MOUNT_POINT/EFI/OC"
rsync -av --delete --exclude='*.bak*' "$EFI_OC_SRC/" "$MOUNT_POINT/EFI/OC/"

# 4. Synchronize BOOT if requested / available
if [ -d "$EFI_BOOT_SRC" ] && [ -f "$EFI_BOOT_SRC/BOOTX64.EFI" ]; then
    echo "Ensuring EFI/BOOT/BOOTX64.EFI exists..."
    mkdir -p "$MOUNT_POINT/EFI/BOOT"
    if [ ! -f "$MOUNT_POINT/EFI/BOOT/BOOTX64.EFI" ]; then
        cp "$EFI_BOOT_SRC/BOOTX64.EFI" "$MOUNT_POINT/EFI/BOOT/BOOTX64.EFI"
    fi
fi

echo "Setting startup disk in NVRAM to macOS..."
sudo systemsetup -setstartupdisk /System/Library/CoreServices 2>/dev/null || true

echo "=== EFI Sync Complete! ==="
echo "You can now reboot. OpenCore will automatically boot macOS in 3 seconds."
