#!/bin/bash
set -euo pipefail

# Installer for SurfaceTouch.kext into /Library/Extensions and AuxiliaryKC
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_DIR="$ROOT/SurfaceTouch"
BUILD_DIR="$DRIVER_DIR/build"
KEXT="$BUILD_DIR/SurfaceTouch.kext"
DEST_EXT="/Library/Extensions/SurfaceTouch.kext"
KC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
KB="/System/Library/KernelCollections/BootKernelExtensions.kc"
KS="/System/Library/KernelCollections/SystemKernelExtensions.kc"
BACKUP_DIR="/Library/SurfaceTouchBackup"

usage() {
    echo "Usage: $0 [install|uninstall|status]"
    exit 1
}

[ $# -ge 1 ] || usage
ACTION="$1"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root (or via sudo)." >&2
        exit 1
    fi
}

do_install() {
    check_root
    echo "==> Building SurfaceTouch.kext..."
    python3 "$DRIVER_DIR/build.py"

    [ -d "$KEXT" ] || { echo "Error: $KEXT not found after build!" >&2; exit 1; }

    echo "==> Creating backup in $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    if [ -f "$KC" ]; then
        cp -p "$KC" "$BACKUP_DIR/AuxiliaryKernelExtensions.kc.bak"
    fi

    echo "==> Installing SurfaceTouch.kext to /Library/Extensions..."
    rm -rf "$DEST_EXT"
    cp -R "$KEXT" "$DEST_EXT"
    chown -R root:wheel "$DEST_EXT"
    chmod -R 755 "$DEST_EXT"

    echo "==> Registering in KextPolicy database..."
    sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy \
        "INSERT OR REPLACE INTO kext_policy (team_id, bundle_id, allowed, developer_name, flags) VALUES ('', 'org.besiple.SurfaceTouch', 1, 'Besiple - SurfaceTouch', 4);" || true

    echo "==> Rebuilding Auxiliary Kernel Collection..."
    NEWKC="$KC.surfacetouch-new"
    rm -f "$NEWKC"
    kmutil create -n aux --volume-root / --allow-missing-kdk \
        -B "$KB" -S "$KS" --repository /Library/Extensions -A "$NEWKC" -z

    echo "==> Verifying new Kernel Collection..."
    INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null || true)
    if ! echo "$INS" | grep -q "org.besiple.SurfaceTouch"; then
        echo "Error: org.besiple.SurfaceTouch missing from built Kernel Collection!" >&2
        rm -f "$NEWKC"
        exit 1
    fi

    mv -f "$NEWKC" "$KC"
    echo "==> Successfully installed SurfaceTouch.kext into Auxiliary Kernel Collection!"
    echo "    On next reboot, macOS Tahoe will load SurfaceTouch automatically."
}

do_uninstall() {
    check_root
    echo "==> Removing SurfaceTouch.kext from /Library/Extensions..."
    rm -rf "$DEST_EXT"

    sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy \
        "DELETE FROM kext_policy WHERE bundle_id = 'org.besiple.SurfaceTouch';" || true

    echo "==> Rebuilding Auxiliary Kernel Collection without SurfaceTouch..."
    NEWKC="$KC.surfacetouch-new"
    rm -f "$NEWKC"
    kmutil create -n aux --volume-root / --allow-missing-kdk \
        -B "$KB" -S "$KS" --repository /Library/Extensions -A "$NEWKC" -z

    mv -f "$NEWKC" "$KC"
    echo "==> SurfaceTouch successfully removed."
}

do_status() {
    echo "--- SurfaceTouch Status ---"
    if [ -d "$DEST_EXT" ]; then
        echo "Installed in /Library/Extensions: YES"
    else
        echo "Installed in /Library/Extensions: NO"
    fi

    if [ -f "$KC" ]; then
        if kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | grep -q "org.besiple.SurfaceTouch"; then
            echo "Present in AuxiliaryKC: YES"
        else
            echo "Present in AuxiliaryKC: NO"
        fi
    fi

    if kmutil showloaded 2>/dev/null | grep -q "org.besiple.SurfaceTouch"; then
        echo "Currently Loaded in Kernel: YES"
    else
        echo "Currently Loaded in Kernel: NO (requires reboot or kmutil load)"
    fi

    echo ""
    echo "THC PCI Device:"
    ioreg -r -c IOPCIDevice -n "THC0" | grep -E "name|device-id|vendor-id" || true

    echo ""
    echo "SurfaceTouch IORegistry:"
    ioreg -r -c SurfaceTouch -l | grep -E "SurfaceTouchState|failStep" || echo "  (Driver not currently active in IORegistry)"
}

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
    *) usage ;;
esac
