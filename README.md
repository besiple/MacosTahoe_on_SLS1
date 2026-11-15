# macOS Tahoe on Microsoft Surface Laptop Studio (1st Gen)

[![macOS](https://img.shields.io/badge/macOS-Tahoe%2026.7.3-black.svg?style=flat&logo=apple)](https://apple.com)
[![OpenCore](https://img.shields.io/badge/OpenCore-1.0.x-blue.svg?style=flat)](https://github.com/acidanthera/OpenCorePkg)
[![Intel](https://img.shields.io/badge/Intel-i7--11370H-0071C5.svg?style=flat&logo=intel)](https://intel.com)
[![NVIDIA](https://img.shields.io/badge/NVIDIA-RTX%203050%20Ti-76B900.svg?style=flat&logo=nvidia)](https://nvidia.com)

Complete turn-key OpenCore EFI configuration, custom ACPI SSDTs, patched kernel extensions, and driver fixes for running **macOS Tahoe 26.7.3** on the **Microsoft Surface Laptop Studio (1st Gen)**.

---

## 💻 Hardware Specifications & Status

| Component | Hardware | macOS Status | Implementation Details |
| :--- | :--- | :---: | :--- |
| **CPU** | Intel Core i7-11370H (4C/8T, up to 4.8 GHz) | ✅ Working | Custom `CPUFriendDataProvider` (EPP 0x80, LFM 800MHz), C7 Package Residency >60% |
| **iGPU** | Intel Iris Xe Graphics 96EU (`0x9A49`) | ✅ Working | Metal 3 Acceleration (`WhateverXe` Rev 4 with hardware `INSTDONE` erratum guard) |
| **Display** | 14.4" PixelSense Flow (2400 × 1600) | ✅ Working | **120 Hz ProMotion Refresh Rate**, native eDP brightness controls |
| **Sleep / Wake** | ACPI S3 & Instant Hibernation | ✅ Working | `SSDT-S3.aml` injection + OpenCore `HibernateMode=Auto` + NVRAM Preboot default |
| **dGPU** | NVIDIA GeForce RTX 3050 Ti Laptop (4 GB GDDR6) | 🔬 Experimental | Disabled via `SSDT-dGPU-Off.aml` for battery, or compute via `nullmoth-kit` |
| **Thunderbolt 4 / USB-C** | 2× Thunderbolt 4 (TCSS / XHCI) | ✅ Working | Full USB 2.0 & USB 3.0 port mapping via `USBMap.kext` |
| **Bluetooth** | Intel Wi-Fi 6 AX201 Bluetooth (8087:0029) | ✅ Working | Internal port `HS10` (`IntelBTPatcher` + `BlueToolFixup`) |
| **Wi-Fi** | Intel Wi-Fi 6 AX201 (8086:A0F0) | ✅ Working | Native speed via `AirportItlwm` |
| **Audio** | Realtek ALC274 on Tiger Lake HD Audio | ✅ Working | `AppleALC` (layout 28) + `SimpleHDA` for quad speakers |
| **Keyboard & Touchpad** | Surface SAM over UART/I2C | ✅ Working | Multi-touch gestures and haptics via `BigSurface` |
| **Battery / Power** | Surface Smart Battery | ✅ Working | Battery percentage, health, wattage & AC status via `BigSurface` |

---

## 🚀 Key Fixes & Breakthroughs

### 1. Intel Iris Xe Erratum & GPU Idle Hang Fix (`WhateverXe` Rev 4)
* **Problem:** On Tiger Lake Gen12, `AppleIntelTitanDriver` issues `MI_WAIT_FOR_EVENT` (`0x03800000`) for display scanline synchronization. If Render ForceWake is suspended while the Command Streamer (CS) is waiting on scanlines, the GPU enters an unrecoverable hardware hang (`INSTDONE: Not done= CS`). When WindowServer restarts, multi-engine resets caused kernel panics on empty CSB slots (`sample.raw == 0`).
* **Fix:** 
  1. Inspects hardware MMIO `0x206C` (`INSTDONE`) and Ring Head/Tail pointers (`0x2034`/`0x2030`) before releasing Render ForceWake. If CS is busy (`instdone != 0xFFFFFFFFU`), suspend is declined and deferred.
  2. Multi-engine streamer reset iterator across all 6 engines (`tglCSBEngines`).
  3. Graceful handling of empty CSB sample slots in intake loop.
* **Source:** See `tools/whateverxe-patches/`.

### 2. ACPI S3 Sleep & Instant Hibernation (`SSDT-S3.aml`)
* **Problem:** Microsoft Surface firmware omits the ACPI `_S3` sleep table (Modern Standby only). At boot, macOS `AppleACPIPlatformExpert::evaluateSleepStates()` found only S4/S5 and cleared its sleep capability bit, causing `queryPlatformCanSleep()` to fail with `kIOReturnNotResponding` (`0xe00002e2`) and throwing `IOPMrootDomain` into a broken 30-second darkwake loop (`kPMPCIUnsupported`).
* **Fix:** Injected custom `SSDT-S3.aml` declaring `Name (\_S3, Package (0x04) { 0x05, 0x05, Zero, Zero })`. macOS now successfully registers `ACPI: sleep states S3 S4 S5`.
* Paired with OpenCore `HibernateMode=Auto` and `HibernateSkipsPicker=True`, the machine sleeps and wakes via NVMe in ~1-2 seconds.

### 3. CPU Power Management & Quiet Cooling (`CPUFriend`)
* **Problem:** Under the `MacBookPro16,2` profile, the i7-11370H CPU ran at constant turbo boost (3.3–4.4 GHz) drawing 18W+ at idle with 0% C-States, keeping the fans spinning.
* **Fix:** Created a custom `CPUFriendDataProvider.kext` configured with Energy Performance Preference (EPP) `0x80` and Low Frequency Mode (LFM) at 800MHz. Frequencies drop to 1.6–1.8 GHz in light workloads, Package C7 residency exceeds 60%, and idle wattage drops significantly.

### 4. Automatic macOS Boot in OpenCore
* Configured `efi-boot-device` in NVRAM to permanently point to macOS APFS Preboot `boot.efi`.
* OpenCore is set with `Timeout = 3` and `AllowSetDefault = True`, automatically booting macOS without requiring keyboard input.

---

## 🛠️ Quick Installation

### Method A: Automated Sync (from existing macOS)
If you already have macOS booted and cloned this repo:
```bash
cd MacosTahoe_on_SLS1
./tools/sync-to-efi.sh
```
The script will locate your EFI partition, back up your previous config, sync `efi-oc` -> `EFI/OC`, verify `BOOTX64.EFI`, and configure the default boot disk in NVRAM.

### Method B: Manual Installation (USB or Internal NVMe)
1. Mount your EFI partition:
   ```bash
   sudo diskutil mount /dev/disk0s1
   ```
2. Copy the contents of `efi-oc/` into `/Volumes/EFI/EFI/OC/`:
   ```bash
   mkdir -p "/Volumes/EFI/EFI/OC"
   cp -R efi-oc/* "/Volumes/EFI/EFI/OC/"
   ```
3. Copy `efi-boot/BOOTX64.EFI` into `/Volumes/EFI/EFI/BOOT/`:
   ```bash
   mkdir -p "/Volumes/EFI/EFI/BOOT"
   cp efi-boot/BOOTX64.EFI "/Volumes/EFI/EFI/BOOT/"
   ```
4. Set macOS as default startup disk:
   ```bash
   sudo systemsetup -setstartupdisk /System/Library/CoreServices
   ```
5. Reboot!

---

## 📦 EFI Structure Summary

```
EFI/
├── BOOT/
│   └── BOOTX64.EFI
└── OC/
    ├── ACPI/
    │   ├── SSDT-EC-USBX.aml
    │   ├── SSDT-PLUG.aml
    │   ├── SSDT-PNLF.aml
    │   ├── SSDT-RTC0.aml
    │   ├── SSDT-S3.aml          <-- ACPI S3 sleep injection
    │   ├── SSDT-SGPC.aml
    │   ├── SSDT-USB-Ports.aml
    │   └── SSDT-dGPU-Off.aml
    ├── Drivers/
    │   ├── HfsPlus.efi
    │   ├── OpenCanopy.efi
    │   ├── OpenRuntime.efi
    │   ├── ResetNvramEntry.efi
    │   └── apfs_aligned.efi
    ├── Kexts/
    │   ├── AMFIPass.kext
    │   ├── AirportItlwm.kext
    │   ├── AppleALC.kext
    │   ├── BigSurface.kext
    │   ├── BlueToolFixup.kext
    │   ├── CPUFriend.kext
    │   ├── CPUFriendDataProvider.kext
    │   ├── IntelBTPatcher.kext
    │   ├── IntelBluetoothFirmware.kext
    │   ├── Lilu.kext
    │   ├── NVMeFix.kext
    │   ├── RestrictEvents.kext
    │   ├── SMCProcessor.kext
    │   ├── SMCSuperIO.kext
    │   ├── SimpleHDA.kext
    │   ├── USBMap.kext
    │   ├── VirtualSMC.kext
    │   ├── WhateverXe.kext      <-- Rev 4 with hardware INSTDONE erratum guard
    │   └── XHCI-unsupported.kext
    ├── Resources/               <-- OpenCanopy GUI themes and fonts
    ├── Tools/
    │   └── OpenShell.efi
    ├── OpenCore.efi
    └── config.plist
```
