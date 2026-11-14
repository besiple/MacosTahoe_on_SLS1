#!/bin/bash
set -e

MODE="$1"

if [ "$MODE" = "A" ] || [ "$MODE" = "a" ]; then
    rm -f /tmp/NVMTL_NO_HALF_WORDS
    echo "========================================================"
    echo "  Roblox set to Mode A (Baseline):"
    echo "  - NVMTL_NO_HALF_WORDS: UNSET"
    echo "  - libnvshim.dylib: ACTIVE (NVIDIA RTX 3050 Ti)"
    echo "========================================================"
elif [ "$MODE" = "B" ] || [ "$MODE" = "b" ]; then
    touch /tmp/NVMTL_NO_HALF_WORDS
    echo "========================================================"
    echo "  Roblox set to Mode B (Experimental fix):"
    echo "  - NVMTL_NO_HALF_WORDS: 1"
    echo "  - libnvshim.dylib: ACTIVE (NVIDIA RTX 3050 Ti)"
    echo "========================================================"
elif [ "$MODE" = "status" ]; then
    if [ -f /tmp/NVMTL_NO_HALF_WORDS ]; then
        echo "Current status: Mode B (NVMTL_NO_HALF_WORDS=1)"
    else
        echo "Current status: Mode A (NVMTL_NO_HALF_WORDS=unset)"
    fi
    echo "Last launches:"
    tail -n 15 /tmp/roblox_launcher.log 2>/dev/null || echo "No launcher log yet."
else
    echo "Usage: $0 [A | B | status]"
    exit 1
fi
