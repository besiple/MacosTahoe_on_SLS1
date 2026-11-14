# Investigation: 3D Rendering Artifacts on NVIDIA RTX 3050 Ti (GA107) under macOS Tahoe

> **Target Audience:** Driver Developers & Claude Opus  
> **Status:** Active Investigation  

---

## 1. Problem Statement
When offloading complex Metal 3D games (such as Roblox) to the discrete **NVIDIA GeForce RTX 3050 Ti Laptop GPU** via `libnvshim.dylib` (`MTLCreateSystemDefaultDevice` interposition):
- The GPU is recognized as `NVIDIA GeForce RTX 3050 Ti Laptop GPU (NVK GA107-A)`.
- Core clock, memory clock, and GPU utilization ramp up properly (utilization reached ~98%, VRAM allocated ~2.9 GB, package temp ~84°C).
- **The Issue:** Heavy visual artifacting appears in the 3D viewport (black/corrupted geometry fragments, jagged texture block flickering). Meanwhile, 2D UI elements overlaid on the screen render normally.

---

## 2. Experimental Verification on Bare Metal

We wrote and executed two isolated Metal test suites on this hardware:

1. **`tests/test_metal_3d.m` (Pure Rasterization Test):**
   - Simple 3D colored triangle with custom vertex & fragment shaders.
   - **Result:** Render pipeline compiled and executed via NVK command pool cleanly with status `MTLCommandBufferStatusCompleted`.

2. **`tests/test_metal_textured_cube.m` (Depth, Mipmaps & Sampler Test):**
   - Uses `MTLPixelFormatDepth32Float`, 10 mipmap levels (`MTLPixelFormatRGBA8Unorm`), and trilinear anisotropic filtering.
   - **Result:** DepthStencil state and mipmapped textures initialized cleanly.

---

## 3. Leading Hypotheses for the Artifacts

### Hypothesis A: Muxless Optimus `IOSurface` Tiling Mismatch
- The Microsoft Surface Laptop Studio uses a muxless architecture: the 14.4" 120Hz PixelSense display is wired **directly and exclusively to the Intel Iris Xe iGPU**.
- When an application renders on the NVIDIA RTX 3050 Ti, the final frame is presented via `CAMetalLayer`, which wraps an `IOSurface`.
- **The Tiling Trap:** NVIDIA Ampere (GA107) stores render targets in proprietary **Block-Linear (GOB) format**. Intel Iris Xe expects either **Tile-Y**, **Tile-X**, or **Linear (pitch)** memory layout.
- If `NVMTLDriver` or `libvulkan_nouveau` presents the `IOSurface` without a proper de-tiling resolve blit, or if the stride / row pitch is mismatched, the Intel compositor scans out scrambled tiled blocks.

### Hypothesis B: Incomplete Synchronization / Implicit Fencing
- If the NVIDIA GPU writes to the shared `IOSurface` buffer while the Intel Iris Xe / WindowServer compositor is reading it without proper GPU cross-device synchronization fences (`IOSurfaceSharedEvent`), half-rendered frames or dirty cache lines result in tearing and black triangular artifacts.

### Hypothesis C: NVK Vulkan-to-AIR Shader Lowering on GA107
`libnvmtl_translate.dylib` contains several tuning flags for NVK/SPIR-V translation:
- `NVMTL_NO_BINDLESS_ALL`: Disables bindless texture arrays.
- `NVMTL_NO_B78_DW3D`: Controls 3D suballocation.
- `NVMTL_NO_HALF_WORDS`: Controls 16-bit half precision float instructions.
- `NVMTL_VRAM_HEADROOM_MB`: Currently set to 256 MB in `nvrm610.conf`.

---

## 4. Next Steps for Opus & Antigravity
1. Test dumping failed shaders via `NVMTL_DUMP_FAILED_DIR=/tmp/nv_dumps`.
2. Test running with `NVMTL_NO_BINDLESS_ALL=1` and `NVMTL_NO_HALF_WORDS=1`.
3. Trace `IOSurface` cross-GPU presentation in `libnvshim.dylib` to verify format and blit synchronization.
