# Surface Laptop Studio: NVIDIA RTX 3050 Ti Laptop GPU on macOS Tahoe (26.7.3)

## Status: FULLY OPERATIONAL (Metal 4, 4 GB VRAM)

- **GPU:** NVIDIA GeForce RTX 3050 Ti Laptop GPU (Ampere GA107M, PCI ID `10DE:25A0`, Rev `0x00A1`)
- **Host:** Microsoft Surface Laptop Studio (1st Gen), Intel Core i7-11370H (Tiger Lake-H35)
- **OS:** macOS Tahoe 26.7.3 (`25G342`), Kernel `Darwin 25.6.0 x86_64`
- **Driver Suite:** NullMoth v2.9 (NVRM, NVAccel, NVRMFB, NVRMAGDC) + GSP Firmware 620.70.06
- **Metal Translation:** NVMTL / Mesa NVK (`GA107-A`) -> Metal 4 API
- **VRAM Aperture:** Resizable BAR (ReBAR) expanded from 64 MB to full 4096 MB (4 GB) at 64-bit BAR1 `0x7E00000000`

### Key Verified Metrics:
1. **System Profiler:** Reports `NVIDIA GeForce RTX 3050 Ti Laptop GPU`, `VRAM (Total): 4 GB`, `Metal Support: Metal 4`.
2. **Metal Runtime:** `MTLCopyAllDevices()` enumerates Device [1] `NVIDIA GeForce RTX 3050 Ti Laptop GPU (NVMTL over NVIDIA GeForce RTX 3050 Ti Laptop GPU (NVK GA107-A))`.
3. **Compute & Buffer Allocation:** Successfully allocated 16 MB Metal shared buffer, validated 3072 MB max buffer length, and verified bidirectional PCIe memory read/write consistency (`0xCAFEBABE`).
4. **Firmware:** GSP RISC-V CPU active (`0x000000a0`), 3D class `0xc797`, Copy `0xc7b5`, NVENC `0xc7b7`, NVDEC `0xc7b0`.
5. **Thermals:** Idle power management active under IOKit power tree (`PXSX`), fans whisper-quiet, zero thermal alerts (`pmset -g therm`).
6. **Boot Safety:** Controlled via OpenCore boot argument `-nvrmnogo` and userland daemon `/Library/LaunchDaemons/com.nullmoth.autogo.plist` executing `nvrmctl 2` after desktop launch.
