// SurfaceTouch: Intel Touch Host Controller (THC) driver for Microsoft Surface Laptop Studio & Tiger Lake devices on macOS.
// Based on Linux ithc driver by quo and macOS port by retropineaple (BSD-2-Clause / CC0).

#include "SurfaceTouch.hpp"
#include <IOKit/IOLib.h>
#include <IOKit/IOMessage.h>
#include <libkern/OSDebug.h>
#include <mach/kmod.h>
#include <pexpert/pexpert.h>

using namespace SurfaceTouchRegs;

OSDefineMetaClassAndStructors(SurfaceTouch, IOService)
OSDefineMetaClassAndStructors(SurfaceTouchHIDDevice, IOHIDDevice)

namespace {
    constexpr uint32_t ConfigDeviceIdTIC = 0x43495424; // "$TIC"
    constexpr uint32_t ConfigTouchCfgOffset = 0x0C;
    constexpr uint32_t TouchEnable = 1U << 0;
    constexpr uint32_t TouchHidReportEnable = 1U << 2;
    constexpr uint32_t TouchMask = 0x3F;
    inline constexpr uint32_t TouchPowerState(uint32_t x) { return (x & 7) << 3; }

    constexpr uint32_t RxInputReport = 3;
    constexpr uint32_t RxFeatureReport = 4;
    constexpr uint32_t RxReportDescriptor = 5;
    constexpr uint32_t RxReset = 7;
    constexpr uint32_t RxHeaderSize = 64;

    struct PRD {
        uint64_t addr; // 1 KiB units
        uint32_t size; // size | PrdFlagEnd
        uint32_t unused;
    };
    static_assert(sizeof(PRD) == 16, "PRD layout mismatch");

    // Synthetic HID Report Descriptor:
    // Report 0x02: Absolute Mouse / Pointer for direct macOS desktop cursor control
    // Report 0x40: Touch Screen Digitizer with Finger logical collection, Tip Switch, Contact ID, X, Y (0..32767), Contact Count
    // Feature Report 0x05: Set Mode (0 = Singletouch, 1 = Multitouch)
    // Report 0x01: Pen / Stylus with Tip Switch, Barrel Switch, Invert, Eraser, X, Y, Tip Pressure, X/Y Tilt
    static const uint8_t sAugmentedDescriptor[] = {
        // Report 0x02: Absolute Mouse / Pointer
        0x05, 0x01,                    // Usage Page (Generic Desktop)
        0x09, 0x02,                    // Usage (Mouse)
        0xA1, 0x01,                    // Collection (Application)
        0x85, 0x02,                    //   Report ID (2)
        0x09, 0x01,                    //   Usage (Pointer)
        0xA1, 0x00,                    //   Collection (Physical)
        0x05, 0x09,                    //     Usage Page (Button)
        0x19, 0x01,                    //     Usage Minimum (1)
        0x29, 0x03,                    //     Usage Maximum (3)
        0x15, 0x00,                    //     Logical Minimum (0)
        0x25, 0x01,                    //     Logical Maximum (1)
        0x75, 0x01,                    //     Report Size (1)
        0x95, 0x03,                    //     Report Count (3)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0x75, 0x05,                    //     Report Size (5)
        0x95, 0x01,                    //     Report Count (1)
        0x81, 0x03,                    //     Input (Cnst, Var, Abs)
        0x05, 0x01,                    //     Usage Page (Generic Desktop)
        0x09, 0x30,                    //     Usage (X)
        0x09, 0x31,                    //     Usage (Y)
        0x15, 0x00,                    //     Logical Minimum (0)
        0x26, 0xFF, 0x7F,              //     Logical Maximum (32767)
        0x75, 0x10,                    //     Report Size (16)
        0x95, 0x02,                    //     Report Count (2)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0xC0,                          //   End Collection (Physical)
        0xC0,                          // End Collection (Application)

        // Report 0x40: Touch Screen Digitizer
        0x05, 0x0D,                    // Usage Page (Digitizer)
        0x09, 0x04,                    // Usage (Touch Screen)
        0xA1, 0x01,                    // Collection (Application)
        0x85, 0x40,                    //   Report ID (64)
        0x09, 0x22,                    //   Usage (Finger)
        0xA1, 0x02,                    //   Collection (Logical)
        0x09, 0x42,                    //     Usage (Tip Switch)
        0x15, 0x00,                    //     Logical Minimum (0)
        0x25, 0x01,                    //     Logical Maximum (1)
        0x75, 0x01,                    //     Report Size (1)
        0x95, 0x01,                    //     Report Count (1)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0x09, 0x51,                    //     Usage (Contact Identifier)
        0x25, 0x0F,                    //     Logical Maximum (15)
        0x75, 0x07,                    //     Report Size (7)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0x05, 0x01,                    //     Usage Page (Generic Desktop)
        0x09, 0x30,                    //     Usage (X)
        0x75, 0x10,                    //     Report Size (16)
        0x95, 0x01,                    //     Report Count (1)
        0xA4,                          //     Push
        0x55, 0x0E,                    //     Unit Exponent (-2)
        0x65, 0x11,                    //     Unit (Centimeter)
        0x46, 0xD7, 0x0B,              //     Physical Maximum (3031)
        0x26, 0xFF, 0x7F,              //     Logical Maximum (32767)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0x09, 0x31,                    //     Usage (Y)
        0x46, 0xDA, 0x07,              //     Physical Maximum (2010)
        0x26, 0xFF, 0x7F,              //     Logical Maximum (32767)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0xB4,                          //     Pop
        0xC0,                          //   End Collection (Logical)
        0x05, 0x0D,                    //   Usage Page (Digitizer)
        0x09, 0x54,                    //   Usage (Contact Count)
        0x25, 0x01,                    //   Logical Maximum (1)
        0x75, 0x08,                    //   Report Size (8)
        0x95, 0x01,                    //   Report Count (1)
        0x81, 0x02,                    //   Input (Data, Var, Abs)
        0x85, 0x05,                    //   Report ID (5)
        0x06, 0x00, 0xFF,              //   Usage Page (Vendor 0xFF00)
        0x09, 0xC8,                    //   Usage (Set Mode 0xC8)
        0x15, 0x00,                    //   Logical Minimum (0)
        0x26, 0xFF, 0x00,              //   Logical Maximum (255)
        0x75, 0x08,                    //   Report Size (8)
        0x95, 0x01,                    //   Report Count (1)
        0xB1, 0x02,                    //   Feature (Data, Var, Abs)
        0xC0,                          // End Collection (Touch Screen)

        // Report 0x01: Pen / Stylus from hardware descriptor
        0x05, 0x0D, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x20, 0x35, 0x00, 0xA1, 0x00, 0x09, 0x32,
        0x09, 0x42, 0x09, 0x44, 0x09, 0x3C, 0x09, 0x45, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x05,
        0x81, 0x02, 0x95, 0x03, 0x81, 0x03, 0x05, 0x01, 0x09, 0x30, 0x75, 0x10, 0x95, 0x01, 0xA4, 0x55,
        0x0E, 0x65, 0x11, 0x46, 0xD7, 0x0B, 0x26, 0x80, 0x25, 0x81, 0x02, 0x09, 0x31, 0x46, 0xDA, 0x07,
        0x26, 0x20, 0x1C, 0x81, 0x02, 0xB4, 0x05, 0x0D, 0x09, 0x30, 0x26, 0x00, 0x10, 0x81, 0x02, 0xA4,
        0x55, 0x0E, 0x65, 0x14, 0x36, 0xD8, 0xDC, 0x46, 0x28, 0x23, 0x26, 0x50, 0x46, 0x09, 0x3D, 0x81,
        0x02, 0x09, 0x3E, 0x81, 0x02, 0x55, 0x0C, 0x66, 0x01, 0x10, 0x35, 0x00, 0x47, 0xFF, 0xFF, 0x00,
        0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x09, 0x56, 0x81, 0x02, 0xB4, 0x06, 0x00, 0xFF, 0x09, 0x01,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0x81, 0x03, 0xC0, 0xC0
    };
}

bool SurfaceTouch::wait32(uint32_t o, uint32_t mask, uint32_t v) {
    for (unsigned i = 0; i < 5000; ++i) {
        if ((r32(o) & mask) == v) return true;
        IODelay(200);
    }
    return false;
}

bool SurfaceTouch::wait8(uint32_t o, uint8_t mask, uint8_t v) {
    for (unsigned i = 0; i < 5000; ++i) {
        if ((r8(o) & mask) == v) return true;
        IODelay(200);
    }
    return false;
}

bool SurfaceTouch::allocDMA(DMABuffer &b, uint32_t size) {
    b.size = uint32_t(round_page(size));
    b.md = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task,
        kIODirectionInOut | kIOMemoryPhysicallyContiguous,
        b.size,
        0xFFFFFFFFFFFFF000ULL
    );
    if (!b.md) return false;

    b.cmd = IODMACommand::withSpecification(
        kIODMACommandOutputHost64, 64, 0,
        IODMACommand::kMapped, 0, PAGE_SIZE
    );
    if (!b.cmd || b.cmd->setMemoryDescriptor(b.md, true) != kIOReturnSuccess)
        return false;

    IODMACommand::Segment64 segment {};
    UInt64 offset = 0;
    UInt32 count = 1;
    if (b.cmd->gen64IOVMSegments(&offset, &segment, &count) != kIOReturnSuccess ||
        count != 1 || segment.fLength < b.size)
        return false;

    b.dma = segment.fIOVMAddr;
    b.addr = static_cast<uint8_t *>(b.md->getBytesNoCopy());
    bzero(b.addr, b.size);
    return (b.dma & (PAGE_SIZE - 1)) == 0;
}

void SurfaceTouch::freeDMA(DMABuffer &b) {
    if (b.cmd) {
        b.cmd->clearMemoryDescriptor(true);
        b.cmd->release();
        b.cmd = nullptr;
    }
    OSSafeReleaseNULL(b.md);
    b.addr = nullptr;
    b.dma = 0;
}

void SurfaceTouch::setPowerD0() {
    uint8_t pm = 0;
    if (!pci->findPCICapability(kIOPCIPowerManagementCapability, &pm) || !pm)
        return;
    const uint16_t pmcsr = pci->configRead16(pm + 4);
    if (pmcsr & 3) {
        pci->configWrite16(pm + 4, pmcsr & ~3U);
        IOSleep(10);
    }
}

void SurfaceTouch::disableDevice() {
    bits32(ControlBits, ControlQuiesce, ControlQuiesce);
    wait32(ControlBits, ControlIsQuiesced, ControlIsQuiesced);
    bits32(ControlBits, ControlNReset, 0);
    bits8(SpiCmdControl, SpiCmdSend, 0);
    bits8(DmaTxControl, TxSend, 0);
    for (unsigned c = 0; c < 2; ++c)
        bits8(DmaRx(c) + RxControl, RxEnable, 0);
    w32(ErrorControl, 0);
    bits8(SpiCmdControl, SpiCmdIrq, 0);
    for (unsigned c = 0; c < 2; ++c)
        bits8(DmaRx(c) + RxControl, RxIrqUnknown1 | RxIrqError | RxIrqReady | RxIrqData, 0);
    bits8(DmaTxControl, TxIrq, 0);
    w32(ErrorFlags, 0xFFFFFFFF);
    w32(ErrorStatus, ErrorStatusDma | ErrorStatusSpi);
    w32(SpiCmdStatus, SpiStatusDone | SpiStatusError);
    for (unsigned c = 0; c < 2; ++c)
        w32(DmaRx(c) + RxStatus, RxStatusError | RxStatusReady | RxStatusHaveData);
    w32(DmaTxStatus, TxStatusDone | TxStatusError | TxStatusUnknown2);
}

void SurfaceTouch::setSpiConfig(uint8_t clkdiv, bool clkdiv8, uint8_t readMode, uint8_t writeMode) {
    if (!clkdiv || clkdiv > 7 || readMode > 2 || writeMode > 2) return;
    const uint32_t mask = (3U << 2) | (7U << 4) | (3U << 18) | (7U << 20) | (1U << 23);
    bits32(SpiConfig, mask,
           (uint32_t(readMode) << 2) |
           (uint32_t(clkdiv) << 4) |
           (uint32_t(writeMode) << 18) |
           (uint32_t(clkdiv) << 20) |
           (clkdiv8 ? (1U << 23) : 0));
}

bool SurfaceTouch::spiCommand(uint8_t code, uint32_t offset, uint32_t size, void *data) {
    if (size > 64) return false;
    if (!wait32(SpiCmdStatus, SpiStatusBusy, 0)) return false;
    w32(SpiCmdStatus, SpiStatusDone | SpiStatusError);
    w8(SpiCmdCode, code);
    w16(SpiCmdSize, uint16_t(size));
    w32(SpiCmdOffset, offset);
    auto p = static_cast<uint32_t *>(data);
    const uint32_t n = (size + 3) / 4;
    for (uint32_t i = 0; i < n; ++i) w32(SpiCmdData + 4 * i, p[i]);
    bits8(SpiCmdControl, SpiCmdSend, SpiCmdSend);
    if (!wait32(SpiCmdStatus, SpiStatusBusy, 0)) return false;
    if ((r32(SpiCmdStatus) & (SpiStatusDone | SpiStatusError)) != SpiStatusDone) return false;
    if (r16(SpiCmdSize) != size) return false;
    for (uint32_t i = 0; i < n; ++i) p[i] = r32(SpiCmdData + 4 * i);
    w32(SpiCmdStatus, SpiStatusDone | SpiStatusError);
    return true;
}

void SurfaceTouch::setLtrConfig(uint64_t activeNs, uint64_t idleNs) {
    auto calc = [](uint64_t ns, uint32_t &val, uint32_t &scale) {
        uint32_t s = 0;
        while (ns > 0x3FF) { ++s; ns >>= 5; }
        if (s > 5) { s = 5; ns = 0x3FF; }
        val = uint32_t(ns); scale = s;
    };
    uint32_t av, as, iv, is;
    calc(activeNs, av, as);
    calc(idleNs, iv, is);
    w32(LtrConfig, LtrEnableActive | LtrEnableIdle | LtrApply |
        ((as & 7) << 17) | ((av & 0x3FF) << 20) |
        ((is & 7) << 4) | ((iv & 0x3FF) << 7));
}

void SurfaceTouch::setLtrIdle() {
    const uint32_t ltr = r32(LtrConfig);
    if ((ltr & (LtrStatusActive | LtrStatusIdle)) == LtrStatusActive)
        w32(LtrConfig, ltr | LtrToggle | LtrApply);
}

bool SurfaceTouch::setDeviceEnabled(bool enable) {
    uint32_t x = touchCfg = (touchCfg & ~TouchMask) | TouchHidReportEnable |
        (enable ? (TouchEnable | TouchPowerState(3)) : 0);
    return spiCommand(SpiCodeWrite, ConfigTouchCfgOffset, sizeof(x), &x);
}

bool SurfaceTouch::legacyInit() {
    setSpiConfig(2, true, 0, 0);
    bits32(DmaRx(0) + RxInitUnknown, InitUnknown31, InitUnknown31);

    // Only set InitUnknown5 on Alder Lake (ADL) architectures
    const uint16_t devId = pci->configRead16(kIOPCIConfigDeviceID);
    if ((devId & 0xFF00) == 0x5100 || (devId & 0xFF00) == 0x7600) {
        bits32(DmaRx(0) + RxInitUnknown, InitUnknown5, InitUnknown5);
    }

    bits32(ControlBits, ControlQuiesce, 0);
    if (!wait32(ControlBits, ControlIsQuiesced, 0)) {
        failStep = 10;
        IOLog("SurfaceTouch: legacyInit failed waiting for ControlIsQuiesced\n");
        return false;
    }

    for (unsigned retries = 0;; ++retries) {
        bits32(ControlBits, ControlNReset, ControlNReset);
        if (wait32(IrqCause, 0xF, 2)) break;
        if (retries > 5) {
            failStep = 11;
            lastError = r32(IrqCause);
            IOLog("SurfaceTouch: failed to reset device, irq_cause=0x%08x\n", lastError);
            return false;
        }
        bits32(ControlBits, ControlNReset, 0);
        IOSleep(1000);
    }

    wait32(DmaRx(0) + RxStatus, RxStatusReady, RxStatusReady);

    for (unsigned retries = 0;; ++retries) {
        bzero(config, sizeof(config));
        if (!spiCommand(SpiCodeRead, 0, sizeof(config), config)) {
            failStep = 12;
            IOLog("SurfaceTouch: failed to read config over SPI\n");
            return false;
        }
        if (config[5] == ConfigDeviceIdTIC) break;
        if (retries > 10) {
            failStep = 13;
            lastError = config[5];
            IOLog("SurfaceTouch: unknown device signature 0x%08x (expected $TIC 0x43495424)\n", lastError);
            return false;
        }
        IOSleep(100);
    }

    const uint32_t sizes = config[2];
    const uint32_t spi = config[6];
    maxRx = ((sizes & 0x3FFF) + 1) << 6;
    maxTx = (((sizes >> 14) & 0x3FF) + 1) << 6;
    vendor = uint16_t(config[7]);
    product = uint16_t(config[7] >> 16);
    touchCfg = config[3];

    IOLog("SurfaceTouch: touch IC detected: vendor=0x%04x product=0x%04x maxRx=%u maxTx=%u\n",
          vendor, product, maxRx, maxTx);

    setSpiConfig((spi >> 1) & 7, (spi & (1U << 4)) != 0,
                 (spi & (1U << 7)) ? 2 : ((spi & (1U << 6)) ? 1 : 0), 0);

    if (!setDeviceEnabled(true)) {
        failStep = 14;
        IOLog("SurfaceTouch: setDeviceEnabled failed\n");
        return false;
    }
    return true;
}

bool SurfaceTouch::initDevice() {
    const bool wasEnabled = (r32(ControlBits) & ControlNReset) != 0;
    disableDevice();
    if (!wait32(ControlBits, ControlReady, ControlReady)) {
        failStep = 2;
        IOLog("SurfaceTouch: initDevice timeout waiting for ControlReady\n");
        return false;
    }
    if (wasEnabled) IOSleep(100);
    setLtrConfig(50 * 1000, 100 * 1000 * 1000ULL);
    return legacyInit();
}

void SurfaceTouch::rxPut(unsigned idx) {
    auto prd = reinterpret_cast<PRD *>(rxPrds.addr) + idx * rxPages;
    const uint64_t dmaBase = rxBufs[idx].dma;
    for (uint32_t p = 0; p < rxPages; ++p) {
        prd[p].addr = (dmaBase + p * PAGE_SIZE) >> 10;
        prd[p].size = PAGE_SIZE | (p == rxPages - 1 ? PrdFlagEnd : 0);
        prd[p].unused = 0;
    }
    __sync_synchronize();
}

uint32_t SurfaceTouch::rxGet(unsigned idx) {
    __sync_synchronize();
    auto prd = reinterpret_cast<const PRD *>(rxPrds.addr) + idx * rxPages;
    uint32_t total = 0;
    for (uint32_t i = 0; i < rxPages; ++i) {
        const uint32_t s = prd[i].size;
        total += s & PrdSizeMask;
        if (s & PrdFlagEnd) break;
    }
    return total < rxPages * PAGE_SIZE ? total : rxPages * PAGE_SIZE;
}

bool SurfaceTouch::rxInit() {
    rxPages = (maxRx + PAGE_SIZE - 1) / PAGE_SIZE;
    if (!rxPages || rxPages > 16 || !allocDMA(rxPrds, NumRx * rxPages * sizeof(PRD))) {
        IOLog("SurfaceTouch: rxInit failed allocating PRDs (rxPages=%u)\n", rxPages);
        return false;
    }
    for (auto &b : rxBufs) {
        if (!allocDMA(b, rxPages * PAGE_SIZE)) {
            IOLog("SurfaceTouch: rxInit failed allocating RX buffer\n");
            return false;
        }
    }
    const uint32_t base = DmaRx(RxChannel);
    w8(base + RxControl2, RxControl2Reset);
    w64(base + RxAddr, rxPrds.dma);
    w8(base + RxNumBufs, NumRx - 1);
    w8(base + RxNumPrds, uint8_t(rxPages - 1));
    const uint8_t head = r8(base + RxHead);
    if (head) {
        failStep = 20;
        lastError = head;
        IOLog("SurfaceTouch: rxInit failed: head is non-zero (0x%02x)\n", head);
        return false;
    }
    for (unsigned i = 0; i < NumRx; ++i) rxPut(i);
    w8(base + RxTail, head ^ RxWrapFlag);
    numReceived = 0;
    return true;
}

void SurfaceTouch::rxEnable() {
    const uint32_t base = DmaRx(RxChannel);
    bits8(base + RxControl, RxEnable | RxIrqError | RxIrqData, RxEnable | RxIrqError | RxIrqData);
    wait32(base + RxStatus, RxStatusEnabled, RxStatusEnabled);
}

bool SurfaceTouch::txInit() {
    uint32_t txSize = maxTx ? maxTx : PAGE_SIZE;
    if (txSize > 64 * 1024) {
        IOLog("SurfaceTouch: txInit failed, maxTx too large (%u)\n", txSize);
        return false;
    }
    if (!allocDMA(txPrds, sizeof(PRD)) || !allocDMA(txBuf, txSize)) {
        IOLog("SurfaceTouch: txInit failed allocating DMA (txSize=%u)\n", txSize);
        return false;
    }
    w64(DmaTxAddr, txPrds.dma);
    w8(DmaTxNumPrds, 0);
    auto prd = reinterpret_cast<PRD *>(txPrds.addr);
    prd->addr = txBuf.dma >> 10;
    prd->size = PrdFlagEnd;
    prd->unused = 0;
    return true;
}

IOReturn SurfaceTouch::txLocked(uint32_t code, const void *data, uint32_t size) {
    const uint32_t padded = (size + 3) & ~3U;
    if (8 + padded > maxTx) return kIOReturnOverrun;
    auto hdr = reinterpret_cast<uint32_t *>(txBuf.addr);
    hdr[0] = code;
    hdr[1] = size;
    bzero(txBuf.addr + 8, padded);
    if (size) memcpy(txBuf.addr + 8, data, size);
    auto prd = reinterpret_cast<PRD *>(txPrds.addr);
    prd->addr = txBuf.dma >> 10;
    prd->size = (8 + padded) | PrdFlagEnd;
    __sync_synchronize();
    bits8(DmaTxControl, TxSend, TxSend);
    if (!wait8(DmaTxControl, TxSend, 0)) return kIOReturnTimeout;
    w32(DmaTxStatus, TxStatusDone);
    return kIOReturnSuccess;
}

IOReturn SurfaceTouch::sendData(Tx type, const void *data, uint32_t size) {
    if (stopping || !regs) return kIOReturnNotReady;
    static const uint64_t descriptorRequest = 0;
    if (type == Tx::GetReportDescriptor) {
        data = &descriptorRequest;
        size = sizeof(descriptorRequest);
    }
    IOLockLock(txLock);
    const auto r = txLocked(uint32_t(type), data, size);
    IOLockUnlock(txLock);
    return r;
}

IOReturn SurfaceTouch::getFeature(uint8_t reportID, void *buffer, uint32_t &size) {
    if (workLoop && workLoop->onThread()) return kIOReturnNotPermitted;
    IOLockLock(waitLock);
    featureBuf = static_cast<uint8_t *>(buffer);
    featureSize = size;
    featurePending = true;
    IOLockUnlock(waitLock);

    IOReturn r = sendData(Tx::GetFeature, &reportID, 1);
    IOLockLock(waitLock);
    if (r == kIOReturnSuccess) {
        AbsoluteTime deadline;
        clock_interval_to_deadline(1000, kMillisecondScale, &deadline);
        while (featurePending) {
            if (IOLockSleepDeadline(waitLock, &featurePending, deadline, THREAD_UNINT) == THREAD_TIMED_OUT)
                break;
        }
        r = featurePending ? kIOReturnTimeout : kIOReturnSuccess;
    }
    size = featureSize;
    featurePending = false;
    featureBuf = nullptr;
    IOLockUnlock(waitLock);
    return r;
}

void SurfaceTouch::handleRx(const uint8_t *data, uint32_t len) {
    if (len < RxHeaderSize) { ++counts[7]; return; }
    const uint32_t code = reinterpret_cast<const uint32_t *>(data)[0];
    const uint32_t size = reinterpret_cast<const uint32_t *>(data)[1];
    if (len != RxHeaderSize + size) { ++counts[7]; return; }
    const uint8_t *payload = data + RxHeaderSize;

    switch (code) {
    case RxInputReport:
        ++counts[2];
        if (size >= 6 && payload[0] == 0x40) {
            const uint8_t tip = payload[1] & 1;
            const uint16_t x = uint16_t(payload[2] | (uint16_t(payload[3]) << 8));
            const uint16_t y = uint16_t(payload[4] | (uint16_t(payload[5]) << 8));

            static uint32_t touchLogCount = 0;
            if (touchLogCount < 20 || (touchLogCount % 50 == 0)) {
                IOLog("SurfaceTouch: touch #%u: tip=%d x=%u y=%u\n", ++touchLogCount, tip, x, y);
            }

            if (hid && reportBuffer) {
                // 1. Send Absolute Mouse Report (Report ID 0x02) for direct macOS WindowServer cursor movement
                uint8_t mouse[6];
                mouse[0] = 0x02; // Report ID 2
                mouse[1] = tip ? 0x01 : 0x00; // Button 1 (Left click)
                mouse[2] = payload[2]; // X lo
                mouse[3] = payload[3]; // X hi
                mouse[4] = payload[4]; // Y lo
                mouse[5] = payload[5]; // Y hi
                memcpy(reportBuffer->getBytesNoCopy(), mouse, sizeof(mouse));
                reportBuffer->setLength(sizeof(mouse));
                hid->handleReport(reportBuffer, kIOHIDReportTypeInput);

                // 2. Also send Touch Screen Digitizer Report (Report ID 0x40)
                uint8_t synth[7];
                synth[0] = 0x40;
                synth[1] = tip; // bit 0 = tip switch, bits 1..7 = contact id 0
                synth[2] = payload[2];
                synth[3] = payload[3];
                synth[4] = payload[4];
                synth[5] = payload[5];
                synth[6] = tip ? 1 : 0; // contact count (1 when pressed, 0 when lifted)
                memcpy(reportBuffer->getBytesNoCopy(), synth, sizeof(synth));
                reportBuffer->setLength(sizeof(synth));
                hid->handleReport(reportBuffer, kIOHIDReportTypeInput);
            }
        } else if (hid && reportBuffer && size <= reportBuffer->getCapacity()) {
            memcpy(reportBuffer->getBytesNoCopy(), payload, size);
            reportBuffer->setLength(size);
            hid->handleReport(reportBuffer, kIOHIDReportTypeInput);
        }
        break;
    case RxReportDescriptor:
        ++counts[4];
        if (size < 8) break;
        IOLockLock(waitLock);
        if (!rdesc) {
            rdesc = static_cast<uint8_t *>(IOMalloc(size - 8));
            if (rdesc) {
                memcpy(rdesc, payload + 8, size - 8);
                rdescSize = size - 8;
                prepareDescriptor();
            }
        }
        rdescDone = true;
        IOLockWakeup(waitLock, &rdescDone, false);
        IOLockUnlock(waitLock);
        break;
    case RxFeatureReport:
        ++counts[3];
        IOLockLock(waitLock);
        if (featurePending && featureBuf) {
            if (size < featureSize) featureSize = size;
            memcpy(featureBuf, payload, featureSize);
            featurePending = false;
            IOLockWakeup(waitLock, &featurePending, false);
        }
        IOLockUnlock(waitLock);
        break;
    case RxReset:
        ++counts[5];
        IOLog("SurfaceTouch: received THC reset request\n");
        if (counts[5] <= 8 && initDevice()) rxEnable();
        break;
    default:
        ++counts[7];
        break;
    }
}

void SurfaceTouch::processRx() {
    const uint32_t base = DmaRx(RxChannel);
    uint32_t n = numReceived;
    const uint8_t headWrap = r8(base + RxHead);
    for (unsigned guard = 0; guard < 4 * NumRx; ++guard) {
        const uint8_t tail = uint8_t(n % NumRx);
        const uint8_t tailWrap = tail | (((n / NumRx) & 1) ? 0 : RxWrapFlag);
        w8(base + RxTail, tailWrap);
        if (tailWrap == (headWrap ^ RxWrapFlag)) return;
        const uint32_t len = rxGet(tail);
        numReceived = ++n;
        ++counts[1];
        handleRx(rxBufs[tail].addr, len);
        rxPut(tail);
    }
}

void SurfaceTouch::process() {
    if (stopping) return;
    if (idleTimer) idleTimer->setTimeoutMS(1000);
    const uint32_t base = DmaRx(RxChannel);
    const bool rx = (r32(base + RxStatus) & (RxStatusError | RxStatusHaveData)) != 0;
    const uint32_t err = r32(ErrorFlags);
    if (err) {
        w32(ErrorFlags, err);
        lastError = err;
        ++counts[6];
    }
    w32(base + RxStatus, RxStatusError | RxStatusReady | RxStatusHaveData);
    if (rx) processRx();
}

void SurfaceTouch::interruptOccurred(IOInterruptEventSource *, int) {
    ++counts[0];
    process();
}

void SurfaceTouch::idleTimeout(IOTimerEventSource *) {
    if (!stopping) {
        setLtrIdle();
        publishState();
    }
}

void SurfaceTouch::pollTimeout(IOTimerEventSource *timer) {
    if (stopping) return;
    if (polling) {
        const uint32_t before = numReceived;
        process();
        timer->setTimeoutMS(numReceived != before ? 10 : 50);
    } else {
        // MSI interrupt is active: slow 2-second watchdog only, no high-frequency CPU wakeups!
        process();
        timer->setTimeoutMS(2000);
    }
}

void SurfaceTouch::prepareDescriptor() {
    uint32_t page = 0, usage = 0, usageOffset = 0, depth = 0, reportSize = 0, reportCount = 0;
    int32_t logicalMax = 0;
    uint8_t reportID = 0;
    for (uint32_t i = 0; i < rdescSize;) {
        const uint8_t b = rdesc[i];
        if (b == 0xFE) {
            if (i + 1 >= rdescSize) break;
            i += 3 + rdesc[i + 1];
            continue;
        }
        const uint32_t n = (b & 3) == 3 ? 4 : (b & 3);
        if (i + 1 + n > rdescSize) break;
        uint32_t v = 0;
        for (uint32_t k = 0; k < n; ++k) v |= uint32_t(rdesc[i + 1 + k]) << (8 * k);
        switch (b & 0xFC) {
        case 0x04: page = v; break;
        case 0x08: usage = v; usageOffset = i; break;
        case 0x84: reportID = uint8_t(v); break;
        case 0x74: reportSize = v; break;
        case 0x94: reportCount = v; break;
        case 0x24: logicalMax = (n == 1) ? int8_t(v) : (n == 2) ? int16_t(v) : int32_t(v); break;
        case 0xA0: // Collection
            if (!depth && page == 0x01 && (usage == 0x06 || usage == 0x07) &&
                (rdesc[usageOffset] & 0xFC) == 0x08 && (rdesc[usageOffset] & 3) == 1) {
                // Prevent Keyboard Setup Assistant popup
                rdesc[usageOffset + 1] = 0;
            }
            ++depth;
            break;
        case 0xC0:
            if (depth) --depth;
            break;
        case 0xB0: // Feature
            if (page == 0x0D && usage == 0x55 && reportID && reportSize == 8 &&
                reportCount == 1 && logicalMax > 0 && logicalMax < 256) {
                contactMaxReport = reportID;
                contactMaxValue = uint8_t(logicalMax);
            }
            break;
        }
        if ((b & 0x0C) == 0x00) usage = ((b & 0xFC) == 0xA0 || (b & 0xFC) == 0xC0) ? usage : 0;
        i += 1 + n;
    }
}

bool SurfaceTouch::readDescriptor() {
    for (unsigned retries = 0; retries < 10; ++retries) {
        IOLockLock(waitLock);
        rdescDone = false;
        IOLockUnlock(waitLock);
        if (sendData(Tx::GetReportDescriptor, nullptr, 0) != kIOReturnSuccess) {
            IOSleep(50);
            continue;
        }
        for (unsigned poll = 0; poll < 30; ++poll) {
            IOSleep(20);
            process();
            IOLockLock(waitLock);
            const bool done = rdescDone && rdesc;
            IOLockUnlock(waitLock);
            if (done) return true;
        }
    }
    return false;
}

void SurfaceTouch::publishState() {
    uint64_t r[16 + 8 + 8 + 1] {};
    for (unsigned i = 0; i < 16; ++i) r[i] = config[i];
    for (unsigned i = 0; i < 8; ++i) r[16 + i] = counts[i];
    r[24] = lastError;
    r[25] = failStep;
    r[26] = maxRx;
    r[27] = maxTx;
    r[28] = (uint32_t(vendor) << 16) | product;
    r[29] = numReceived;
    r[30] = polling;
    r[31] = rdescSize;
    r[32] = (uint32_t(contactMaxReport) << 8) | contactMaxValue;
    setProperty("SurfaceTouchState", r, sizeof(r));
}

bool SurfaceTouch::start(IOService *provider) {
    if (!super::start(provider)) return false;
    pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) return false;
    pci->retain();

    IOLog("SurfaceTouch: attaching to THC device 0x%04x:0x%04x\n",
          pci->configRead16(kIOPCIConfigVendorID),
          pci->configRead16(kIOPCIConfigDeviceID));

    if (!pci->open(this)) {
        failStep = 1;
        publishState();
        IOLog("SurfaceTouch: failed to open PCI provider\n");
        return false;
    }

    setPowerD0();
    pci->setMemoryEnable(true);
    pci->setBusMasterEnable(true);
    map = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    if (!map || map->getLength() < 0x1300) {
        failStep = 3;
        IOLog("SurfaceTouch: failed to map MMIO BAR0\n");
        goto fail;
    }
    regs = reinterpret_cast<volatile uint8_t *>(map->getVirtualAddress());

    txLock = IOLockAlloc();
    waitLock = IOLockAlloc();
    workLoop = IOWorkLoop::workLoop();
    if (!txLock || !waitLock || !workLoop) {
        failStep = 4;
        IOLog("SurfaceTouch: failed to allocate locks or workLoop\n");
        goto fail;
    }

    {
        int msi = -1;
        for (int i = 0;; ++i) {
            int type = 0;
            if (pci->getInterruptType(i, &type) != kIOReturnSuccess) break;
            if (type & kIOInterruptTypePCIMessaged) { msi = i; break; }
        }
        int flag = 0;
        polling = msi < 0 ||
                  PE_parse_boot_argn("-ithcpoll", &flag, sizeof(flag)) ||
                  PE_parse_boot_argn("-surfacetouchpoll", &flag, sizeof(flag));

        idleTimer = IOTimerEventSource::timerEventSource(
            this,
            OSMemberFunctionCast(IOTimerEventSource::Action, this, &SurfaceTouch::idleTimeout)
        );
        if (!idleTimer || workLoop->addEventSource(idleTimer) != kIOReturnSuccess) {
            failStep = 5;
            IOLog("SurfaceTouch: failed to add idle timer event source\n");
            goto fail;
        }

        if (!initDevice()) goto fail;
        if (!rxInit()) { if (!failStep) failStep = 21; goto fail; }
        if (!txInit()) { failStep = 22; goto fail; }

        reportBuffer = IOBufferMemoryDescriptor::withCapacity(maxRx, kIODirectionOut);
        if (!reportBuffer) { failStep = 23; goto fail; }

        if (msi >= 0 && !polling) {
            IOLog("SurfaceTouch: registering MSI interrupt index %d\n", msi);
            interrupt = IOInterruptEventSource::interruptEventSource(
                this,
                OSMemberFunctionCast(IOInterruptEventSource::Action, this, &SurfaceTouch::interruptOccurred),
                pci, msi
            );
            if (interrupt && workLoop->addEventSource(interrupt) == kIOReturnSuccess) {
                interrupt->enable();
            } else {
                polling = true;
            }
        } else {
            polling = true;
        }

        // Activate pollTimer as fallback or slow watchdog
        pollTimer = IOTimerEventSource::timerEventSource(
            this,
            OSMemberFunctionCast(IOTimerEventSource::Action, this, &SurfaceTouch::pollTimeout)
        );
        if (!pollTimer || workLoop->addEventSource(pollTimer) != kIOReturnSuccess) {
            failStep = 24;
            goto fail;
        }
        pollTimer->setTimeoutMS(polling ? 15 : 2000);

        rxEnable();

        IOLog("SurfaceTouch: retrieving HID report descriptor...\n");
        if (!readDescriptor()) {
            failStep = 30;
            IOLog("SurfaceTouch: failed to read HID report descriptor\n");
            goto fail;
        }
        IOLog("SurfaceTouch: HID report descriptor ready (%u bytes)\n", rdescSize);

        // Put touch digitizer into active SingleTouch streaming mode (Report 5, Mode 0)
        uint8_t modeCmd[2] = { 0x05, 0x00 };
        IOReturn mr = sendData(Tx::SetFeature, modeCmd, sizeof(modeCmd));
        IOLog("SurfaceTouch: set Singletouch mode (Report 5) result=0x%08x\n", mr);

        hid = OSTypeAlloc(SurfaceTouchHIDDevice);
        if (!hid || !hid->init(this) || !hid->attach(this)) {
            failStep = 31;
            OSSafeReleaseNULL(hid);
            IOLog("SurfaceTouch: failed to allocate/attach SurfaceTouchHIDDevice\n");
            goto fail;
        }
        if (!hid->start(this)) {
            failStep = 32;
            hid->detach(this);
            OSSafeReleaseNULL(hid);
            IOLog("SurfaceTouch: failed to start SurfaceTouchHIDDevice\n");
            goto fail;
        }
        setLtrIdle();
    }

    publishState();
    registerService();
    IOLog("SurfaceTouch: driver fully started and published!\n");
    return true;

fail:
    publishState();
    stopping = true;
    if (pollTimer) pollTimer->cancelTimeout();
    if (interrupt) interrupt->disable();
    if (regs) disableDevice();
    if (pci) pci->close(this);
    IOLog("SurfaceTouch: start aborted at failStep=%u, lastError=0x%08x\n", failStep, lastError);
    return false;
}

void SurfaceTouch::stop(IOService *provider) {
    stopping = true;
    if (pollTimer) pollTimer->cancelTimeout();
    if (idleTimer) idleTimer->cancelTimeout();
    if (interrupt) interrupt->disable();
    if (regs) {
        setDeviceEnabled(false);
        disableDevice();
        for (unsigned c = 0; c < 2; ++c) {
            wait32(DmaRx(c) + RxStatus, RxStatusEnabled, 0);
            w64(DmaRx(c) + RxAddr, 0);
            w8(DmaRx(c) + RxNumBufs, 0);
            w8(DmaRx(c) + RxNumPrds, 0);
        }
        w64(DmaTxAddr, 0);
        w8(DmaTxNumPrds, 0);
    }
    if (hid) {
        hid->terminate();
    }
    if (pci) pci->close(this);
    super::stop(provider);
}

void SurfaceTouch::free() {
    if (workLoop) {
        if (interrupt) workLoop->removeEventSource(interrupt);
        if (idleTimer) workLoop->removeEventSource(idleTimer);
        if (pollTimer) workLoop->removeEventSource(pollTimer);
    }
    OSSafeReleaseNULL(interrupt);
    OSSafeReleaseNULL(idleTimer);
    OSSafeReleaseNULL(pollTimer);
    OSSafeReleaseNULL(workLoop);
    OSSafeReleaseNULL(hid);
    freeDMA(rxPrds);
    for (auto &b : rxBufs) freeDMA(b);
    freeDMA(txPrds);
    freeDMA(txBuf);
    OSSafeReleaseNULL(reportBuffer);
    if (rdesc) {
        IOFree(rdesc, rdescSize);
        rdesc = nullptr;
    }
    OSSafeReleaseNULL(map);
    if (txLock) { IOLockFree(txLock); txLock = nullptr; }
    if (waitLock) { IOLockFree(waitLock); waitLock = nullptr; }
    OSSafeReleaseNULL(pci);
    super::free();
}

// SurfaceTouchHIDDevice implementation

bool SurfaceTouchHIDDevice::init(SurfaceTouch *owner) {
    if (!super::init(nullptr)) return false;
    thc = owner;
    return true;
}

bool SurfaceTouchHIDDevice::handleStart(IOService *provider) {
    if (!super::handleStart(provider)) return false;
    setProperty("Built-In", kOSBooleanTrue);
    setProperty("HIDDefaultBehavior", kOSBooleanTrue);
    return true;
}

void SurfaceTouchHIDDevice::handleStop(IOService *provider) {
    thc = nullptr;
    super::handleStop(provider);
}

IOReturn SurfaceTouchHIDDevice::newReportDescriptor(IOMemoryDescriptor **descriptor) const {
    auto md = IOBufferMemoryDescriptor::withBytes(sAugmentedDescriptor, sizeof(sAugmentedDescriptor), kIODirectionNone);
    if (!md) return kIOReturnNoMemory;
    *descriptor = md;
    return kIOReturnSuccess;
}

OSString *SurfaceTouchHIDDevice::newTransportString() const {
    return OSString::withCString("SPI");
}

OSString *SurfaceTouchHIDDevice::newManufacturerString() const {
    return OSString::withCString("Microsoft");
}

OSString *SurfaceTouchHIDDevice::newProductString() const {
    return OSString::withCString("Surface Touchscreen Digitizer");
}

OSNumber *SurfaceTouchHIDDevice::newVendorIDNumber() const {
    return OSNumber::withNumber(thc ? thc->vendorID() : 0x045E, 32);
}

OSNumber *SurfaceTouchHIDDevice::newProductIDNumber() const {
    return OSNumber::withNumber(thc ? thc->productID() : 0x0C1B, 32);
}

OSNumber *SurfaceTouchHIDDevice::newVersionNumber() const {
    return OSNumber::withNumber(0x0100, 32);
}

OSNumber *SurfaceTouchHIDDevice::newLocationIDNumber() const {
    return OSNumber::withNumber(0x00100006ULL, 32);
}

IOReturn SurfaceTouchHIDDevice::setReport(IOMemoryDescriptor *report, IOHIDReportType reportType, IOOptionBits options) {
    if (!report) return kIOReturnBadArgument;
    const uint8_t id = uint8_t(options & 0xFF);
    const auto len = uint32_t(min(report->getLength(), IOByteCount(4096)));
    auto buf = static_cast<uint8_t *>(IOMalloc(len + 1));
    if (!buf) return kIOReturnNoMemory;
    report->readBytes(0, buf + 1, len);
    uint8_t *data = buf + 1;
    uint32_t size = len;
    if (id && (!len || buf[1] != id)) {
        buf[0] = id;
        data = buf;
        size = len + 1;
    }
    IOReturn r = kIOReturnSuccess;
    if (thc) {
        if (reportType == kIOHIDReportTypeFeature)
            r = thc->sendData(SurfaceTouch::Tx::SetFeature, data, size);
        else if (reportType == kIOHIDReportTypeOutput)
            r = thc->sendData(SurfaceTouch::Tx::OutputReport, data, size);
    }
    IOFree(buf, len + 1);
    return r;
}

IOReturn SurfaceTouchHIDDevice::getReport(IOMemoryDescriptor *report, IOHIDReportType reportType, IOOptionBits options) {
    if (!report) return kIOReturnBadArgument;
    const uint8_t id = uint8_t(options & 0xFF);
    if (reportType == kIOHIDReportTypeFeature) {
        if (id == 0x05) {
            uint8_t buf[2] = { 0x05, 0x00 };
            report->writeBytes(0, buf, sizeof(buf));
            return kIOReturnSuccess;
        }
    }
    if (!thc) return kIOReturnNotReady;
    const auto len = uint32_t(min(report->getLength(), IOByteCount(4160)));
    if (!len) return kIOReturnBadArgument;
    auto buf = static_cast<uint8_t *>(IOMalloc(len));
    if (!buf) return kIOReturnNoMemory;
    uint32_t size = len;
    IOReturn r = thc->getFeature(id, buf, size);
    if (r == kIOReturnSuccess) {
        report->writeBytes(0, buf, size);
        if (auto b = OSDynamicCast(IOBufferMemoryDescriptor, report))
            b->setLength(size);
    }
    IOFree(buf, len);
    return r;
}

extern "C" kern_return_t SurfaceTouchStart(kmod_info_t *, void *) { return KERN_SUCCESS; }
extern "C" kern_return_t SurfaceTouchStop(kmod_info_t *, void *) { return KERN_SUCCESS; }

KMOD_EXPLICIT_DECL(org.besiple.SurfaceTouch, "1.0.0", SurfaceTouchStart, SurfaceTouchStop)
__attribute__((visibility("hidden"))) kmod_start_func_t *_realmain = SurfaceTouchStart;
__attribute__((visibility("hidden"))) kmod_stop_func_t *_antimain = SurfaceTouchStop;
