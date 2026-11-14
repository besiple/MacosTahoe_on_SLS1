# Technical Briefing: Surface Laptop Studio (macOS 26.7.3 Tahoe) Driver Collaboration

> **To: Claude Opus 5.5**  
> **From: Antigravity (Local Assistant on Bare-Metal macOS)**  
> **Target Machine: Microsoft Surface Laptop Studio (1st Gen)**  

---

## 1. System & Architecture Overview

- **Operating System:** macOS Tahoe 26.7.3 (Build `25G342`, Kernel `Darwin 25.6.0 x86_64`).
- **Dual-Boot Environment:** Dual-booting alongside Arch Linux (`7.2.15-arch1-1-surface`). Internal 512GB NVMe partitioned into APFS (`disk1`) and Btrfs (`disk0s3`/`disk0s6`). Shared EFI partition at `/boot/efi` (`disk0s1`).
- **CPU:** Intel Core i7-11370H (Tiger Lake-H35, 4C/8T, Family 6 Model 140 Stepping 1).
  - Spoofed via OpenCore to Ice Lake `0x706E5` (`Cpuid1Data = E5060700...`).
  - Core power & frequency management: XCPM + `RestrictEvents.kext` (`revcpu=1`, `revcpuname`).
- **Primary iGPU (Active Display):** Intel Iris Xe 96EU (`8086:9A49`, rev 01).
  - Acceleration: `WhateverXe.kext` (v0.8.2) + `WhateverXe-Graphics-0.4.4.pkg` userland AUX bundle.
  - Active Display: Internal 14.4" eDP panel (`LQ144P1JX01`), 2400x1600 physical (3:2 aspect ratio), running at **1200x800 HiDPI 120Hz** via BetterDisplay.
- **Secondary dGPU (Target for Driver Work):** NVIDIA GeForce RTX 3050 Ti Laptop GPU (Ampere GA107M, PCI ID `10DE:25A0`).
  - Architecture: **Muxless Optimus**. Internal display is wired exclusively to the Intel Iris Xe.
  - Current state: Temporarily disabled in ACPI via `SSDT-dGPU-Off.aml` (`_OFF` under `_OSI("Darwin")`) to prevent 25W idle TDP overheating. Dual-boot Linux retains full 50W TDP access.
- **Audio:** Realtek ALC274 (`0x10EC0274`) on Tiger Lake HD Audio (`8086:A0C8`). Fully working via `AppleALC.kext` (layout `alcid=28`) + `SimpleHDA.kext` + `SimpleHDA-HAL`.
- **Keyboard / Trackpad / Battery:** Microsoft Surface System Aggregator Module (SAM) over Tiger Lake UART/I2C. Internal keyboard, trackpad, and smart battery (100% capacity/AC status) are working via `BigSurface.kext` + `BigSurfaceHIDDriver.kext`.

---

## 2. The Driver Objective: NVIDIA RTX 3050 Ti on macOS Tahoe

### What we have on disk:
In `/Volumes/NMINSTALL/PostInstall/nullmoth-nvidia-2.9.tar.gz` (unpacked in `nullmoth-kit/` here):
- **NullMoth NVIDIA Driver Suite (v2.9, built for macOS 15 & 26 x86_64)**:
  - `NVRM.kext`: Ports NVIDIA's open-gpu-kernel-modules (620.70.06) through GSP firmware (`gsp_ga10x.bin`).
  - `NVAccel.kext`: Metal/IOAccelerator client shim for macOS 15/26.
  - `NVRMFB.kext` / `NVRMAGDC.kext`: Framebuffer and display management.
  - `NVMTLDriver.bundle`: Metal driver wrapping Mesa NVK / Nouveau / Vulkan -> Metal.
  - Device ID `25A0` (RTX 3050 Ti Mobile) is officially listed in `SUPPORTED_IDS`.
  - Installer includes scripts: `install.sh`, `nullmoth-runtime-check.sh`, `fw_fetch.sh`, `dlss_fetch.sh`.

### Key Challenges to Solve:
1. **Muxless Optimus / Hybrid Laptop Routing:**
   - Because the internal panel is connected to Intel Iris Xe, we cannot simply use standard NVRMFB direct display scanout.
   - NullMoth mentions support for an integrated-GPU proxy head (`nvfbigpu`) and hybrid sleep/wake replay (`nm_hybrid_resume*`).
   - Need to configure or adapt NullMoth so WindowServer either uses offscreen Metal rendering offloaded to RTX 3050 Ti, or Metal compute device enumeration (e.g. for PyTorch, Blender, compute workloads, or external Type-C DP output).
2. **Thermal & Power Budget Control:**
   - Without power management, the GA107M idles at ~25W, causing extreme fan noise and heat.
   - NullMoth references `nvrmtgp` with GPS (`nvrmgps`) and NVPCF (`nvrmnvpcf`) ACPI DSM methods.
3. **OpenCore Compatibility:**
   - When enabling NullMoth, `SSDT-dGPU-Off.aml` must be toggled off, and `SSDT-SGPC.aml` or custom NVPCF SSDT evaluated.

---

## 3. How We Collaborate

- **Opus 5.5:** Driver architecture, code inspection, modifying scripts/patches, writing custom SSDT DSL or driver wrappers.
- **Antigravity (Live Local Agent):** Bare-metal execution environment. Can compile, sign kexts, run `install.sh`, rebuild Kernel Collections (`kmutil`), test reboots, capture kernel panics, inspect `ioreg`, and profile thermals/fans.
- **Git / Workflow:**
  - You can write code or patches and push them to a shared GitHub repository or output them as diffs/scripts.
  - Antigravity pulls and tests directly on the Surface Laptop Studio hardware.
