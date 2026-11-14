# macOS Tahoe on Microsoft Surface Laptop Studio (1st Gen)

[![macOS](https://img.shields.io/badge/macOS-Tahoe%2026.7.3-black.svg?style=flat&logo=apple)](https://apple.com)
[![OpenCore](https://img.shields.io/badge/OpenCore-1.0.x-blue.svg?style=flat)](https://github.com/acidanthera/OpenCorePkg)
[![Intel](https://img.shields.io/badge/Intel-i7--11370H-0071C5.svg?style=flat&logo=intel)](https://intel.com)
[![NVIDIA](https://img.shields.io/badge/NVIDIA-RTX%203050%20Ti-76B900.svg?style=flat&logo=nvidia)](https://nvidia.com)

Complete OpenCore configuration, custom SSDTs, Kexts, and driver patches for running **macOS Tahoe 26.7.3** on the **Microsoft Surface Laptop Studio (1st Gen)**.

---

## 💻 Hardware Specifications

| Component | Hardware | macOS Status | Notes |
| :--- | :--- | :---: | :--- |
| **CPU** | Intel Core i7-11370H (4C/8T, up to 4.8 GHz) | ✅ Working | Full XCPM Speed Shift & C-States (C7) |
| **iGPU** | Intel Iris Xe Graphics 96EU | ✅ Working | Metal 2/3 Hardware Acceleration (`WhateverXe`) |
| **Display** | 14.4" PixelSense Flow (2400 × 1600) | ✅ Working | **120 Hz ProMotion Refresh Rate** |
| **dGPU** | NVIDIA GeForce RTX 3050 Ti Laptop (4 GB GDDR6) | 🔬 Experimental | Headless Metal Acceleration via `NVAccel` / `NVMTLDriver` |
| **Thunderbolt 4 / USB-C** | 2× Thunderbolt 4 (TCSS / XHCI) | ✅ Working | Full USB 2.0 & USB 3.0 port mapping |
| **Bluetooth** | Intel Wi-Fi 6 AX201 Bluetooth (8087:0029) | ✅ Working | Working via internal port `HS10` (`IntelBTPatcher` + `BlueToolFixup`) |
| **Wi-Fi** | Intel Wi-Fi 6 AX201 (8086:A0F0) | ✅ Working | Native speed via `AirportItlwm` |
| **Audio** | Realtek ALC274 on Tiger Lake HD Audio | ✅ Working | `AppleALC` (layout 28) + `SimpleHDA` |
| **Keyboard & Touchpad** | Surface SAM over UART/I2C | ✅ Working | Multi-touch gestures via `BigSurface` |
| **Battery / Power** | Surface Smart Battery | ✅ Working | Battery percentage, health & AC status |

---

## 🛠️ Repository Contents

- `efi-oc/`: OpenCore EFI folder containing:
  - `config.plist`: Production OpenCore config with `MacBookPro16,2` SMBIOS.
  - `ACPI/`: Patched ACPI tables (`SSDT-EC-USBX`, `SSDT-PLUG`, `SSDT-PNLF`, `SSDT-RTC0`, `SSDT-SGPC`, `SSDT-USB-Ports`).
  - `Kexts/USBMap.kext`: Corrected USB map with dual `MacBookPro16,1` & `MacBookPro16,2` personalities for Type-C ports and Bluetooth.
- `nullmoth-kit/`: NullMoth NVIDIA driver suite for macOS Tahoe (Metal 4 / Vulkan Nouveau bridge).
- `sysinfo/`: Hardware diagnostics and telemetry logs.
- `README-OPUS.md`: Technical briefing and reverse-engineering roadmap for the NVIDIA RTX 3050 Ti driver.
- `SUCCESS-REPORT-RTX3050TI.md`: Proof of successful Metal compute and 3D rasterization on GA107 Ampere.

---

## 🚀 Key Fixes Included

1. **Dual USB-C & Bluetooth Fix (`USBMap.kext`):**
   - Fixed SMBIOS matching bug where `model` was mismatched (`MacBookPro16,1` vs `MacBookPro16,2`).
   - Restored USB 2.0 (`HS05`/`HS06`) and USB 3.0 (`SS01`/`SS02`) lines on the physical left ports.
   - Restored internal USB port `HS10` (Intel Bluetooth controller `8087:0029`), enabling Bluetooth connectivity.
2. **NVIDIA RTX 3050 Ti Metal Acceleration:**
   - Boot safely with `NVAccel.kext` headless mode.
   - Dynamic VRAM allocation and async copy engine initialization.
