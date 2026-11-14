# SurfaceTouch.kext

**SurfaceTouch** is a native macOS IOKit kernel extension (driver) for the **Intel Touch Host Controller (THC)** on Microsoft Surface Laptop Studio (1st Gen) and Tiger Lake / Alder Lake devices.

Ported and enhanced from the Linux `ithc` driver by [quo](https://github.com/quo/ithc-linux) and the Alder Lake macOS port by [retropineaple](https://github.com/retropineaple/whateverxe-hp-envy-x360).

---

## 🚀 Features

- **Direct THC Hardware Binding:** Matches PCI ID `0x8086:0xa0d0` (Tiger Lake LP THC0 Port 1) with subsystem `0x1414:0x0049` (Microsoft SLS1).
- **SPI Touch IC Protocol:** Initializes touch IC out of reset via legacy TIC protocol (`$TIC` signature), reads device capabilities and speeds.
- **DMA Ring Buffer Management:** Configures hardware PRD tables for 64-bit continuous DMA packet reception and transmission.
- **Native macOS Tahoe Multi-Touch Integration:** Extracted HID Report Descriptor is sanitized (keyboard collections neutralized to avoid phantom Keyboard Setup Assistant dialogs) and published as an `IOHIDDevice` (`SurfaceTouchHIDDevice`). In macOS Tahoe (26.x), Apple's `AppleUserHIDEventDriver` / `IOHIDFamily` automatically binds to Digitizer usage page `0x0D`, routing touches directly into the OS event stream.
- **Telemetry & Diagnostics:** Exposes full state vector via `SurfaceTouchState` in IORegistry and logs lifecycle progress to `IOLog`.
- **Failsafe Polling Option:** Supports boot argument `-surfacetouchpoll` (or `-ithcpoll`) if MSI interrupt delivery is blocked by interrupt remapping.

---

## 🛠️ Building

To build `SurfaceTouch.kext`:

```bash
cd SurfaceTouch
python3 build.py
```

The compiled kext is output to `SurfaceTouch/build/SurfaceTouch.kext`.

---

## 📦 Installation (Auxiliary Kernel Collection)

No OpenCore EFI or NVRAM modifications required. SurfaceTouch installs into macOS's native `/Library/Extensions` and is linked directly into `/Library/KernelCollections/AuxiliaryKernelExtensions.kc`:

```bash
sudo tools/install_surfacetouch.sh install
```

To check driver status:
```bash
tools/install_surfacetouch.sh status
```

To uninstall:
```bash
sudo tools/install_surfacetouch.sh uninstall
```

---

## 🔍 Verification & Diagnostics

After rebooting:

1. **Verify driver attachment:**
   ```bash
   ioreg -r -c SurfaceTouch -l
   ```
2. **Inspect state vector:**
   ```bash
   ioreg -r -c SurfaceTouch -l | grep SurfaceTouchState
   ```
3. **View live kernel logs:**
   ```bash
   sudo dmesg | grep SurfaceTouch
   ```
