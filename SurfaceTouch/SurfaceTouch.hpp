// SurfaceTouch: Intel Touch Host Controller (THC) driver for Microsoft Surface Laptop Studio & Tiger Lake devices on macOS.
// Based on Linux ithc driver by quo and macOS port by retropineaple (BSD-2-Clause / CC0).
#ifndef SURFACETOUCH_HPP
#define SURFACETOUCH_HPP

#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOInterruptEventSource.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODMACommand.h>
#include <IOKit/IOLocks.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/hid/IOHIDDevice.h>

namespace SurfaceTouchRegs {
    constexpr uint32_t LtrConfig = 0x0014;
    constexpr uint32_t ControlBits = 0x1008;
    constexpr uint32_t SpiConfig = 0x1010;
    constexpr uint32_t ErrorControl = 0x1020;
    constexpr uint32_t ErrorStatus = 0x1024;
    constexpr uint32_t ErrorFlags = 0x1028;
    constexpr uint32_t SpiCmdControl = 0x1040;
    constexpr uint32_t SpiCmdCode = 0x1041;
    constexpr uint32_t SpiCmdSize = 0x1042;
    constexpr uint32_t SpiCmdStatus = 0x1044;
    constexpr uint32_t SpiCmdOffset = 0x1048;
    constexpr uint32_t SpiCmdData = 0x104C;
    constexpr uint32_t DmaTxAddr = 0x1090;
    constexpr uint32_t DmaTxControl = 0x1098;
    constexpr uint32_t DmaTxNumPrds = 0x109B;
    constexpr uint32_t DmaTxStatus = 0x109C;
    constexpr uint32_t IrqCause = 0x10BC;
    constexpr uint32_t DmaRx(unsigned c) { return 0x1100 + 0x100 * c; }
    constexpr uint32_t RxAddr = 0x00;
    constexpr uint32_t RxNumBufs = 0x08;
    constexpr uint32_t RxNumPrds = 0x09;
    constexpr uint32_t RxControl = 0x0C;
    constexpr uint32_t RxHead = 0x0D;
    constexpr uint32_t RxTail = 0x0E;
    constexpr uint32_t RxControl2 = 0x0F;
    constexpr uint32_t RxStatus = 0x10;
    constexpr uint32_t RxInitUnknown = 0x28;

    constexpr uint32_t LtrEnableActive = 1U << 0;
    constexpr uint32_t LtrToggle = 1U << 1;
    constexpr uint32_t LtrEnableIdle = 1U << 2;
    constexpr uint32_t LtrApply = 1U << 3;
    constexpr uint32_t LtrStatusActive = 1U << 30;
    constexpr uint32_t LtrStatusIdle = 1U << 31;

    constexpr uint32_t ControlQuiesce = 1U << 1;
    constexpr uint32_t ControlIsQuiesced = 1U << 2;
    constexpr uint32_t ControlNReset = 1U << 3;
    constexpr uint32_t ControlReady = 1U << 29;

    constexpr uint32_t ErrorStatusDma = 1U << 28;
    constexpr uint32_t ErrorStatusSpi = 1U << 30;
    constexpr uint32_t ErrorFlagDmaRxTimeout = 1U << 12;

    constexpr uint8_t SpiCmdSend = 1U << 0;
    constexpr uint8_t SpiCmdIrq = 1U << 1;
    constexpr uint8_t SpiCodeRead = 4;
    constexpr uint8_t SpiCodeWrite = 6;
    constexpr uint32_t SpiStatusDone = 1U << 0;
    constexpr uint32_t SpiStatusError = 1U << 1;
    constexpr uint32_t SpiStatusBusy = 1U << 3;

    constexpr uint8_t TxSend = 1U << 0;
    constexpr uint8_t TxIrq = 1U << 3;
    constexpr uint32_t TxStatusDone = 1U << 0;
    constexpr uint32_t TxStatusError = 1U << 1;
    constexpr uint32_t TxStatusUnknown2 = 1U << 2;

    constexpr uint8_t RxEnable = 1U << 0;
    constexpr uint8_t RxIrqUnknown1 = 1U << 1;
    constexpr uint8_t RxIrqError = 1U << 3;
    constexpr uint8_t RxIrqReady = 1U << 4;
    constexpr uint8_t RxIrqData = 1U << 5;
    constexpr uint8_t RxControl2Reset = 1U << 7;
    constexpr uint8_t RxWrapFlag = 1U << 7;
    constexpr uint32_t RxStatusError = 1U << 3;
    constexpr uint32_t RxStatusReady = 1U << 4;
    constexpr uint32_t RxStatusHaveData = 1U << 5;
    constexpr uint32_t RxStatusEnabled = 1U << 8;

    constexpr uint32_t InitUnknown5 = 1U << 5;
    constexpr uint32_t InitUnknown31 = 1U << 31;
    constexpr uint32_t PrdSizeMask = 0xFFFFFF;
    constexpr uint32_t PrdFlagEnd = 0x1000000;
}

class SurfaceTouchHIDDevice;

class SurfaceTouch : public IOService {
    OSDeclareDefaultStructors(SurfaceTouch)
    using super = IOService;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // For SurfaceTouchHIDDevice
    enum class Tx : uint32_t {
        SetFeature = 3,
        GetFeature = 4,
        OutputReport = 5,
        GetReportDescriptor = 7
    };
    IOReturn sendData(Tx type, const void *data, uint32_t size);
    IOReturn getFeature(uint8_t reportID, void *buffer, uint32_t &size);
    const uint8_t *reportDescriptor(uint32_t &size) const { size = rdescSize; return rdesc; }
    uint16_t vendorID() const { return vendor; }
    uint16_t productID() const { return product; }
    uint8_t contactMaxReport {}, contactMaxValue {};

private:
    struct DMABuffer {
        IOBufferMemoryDescriptor *md {};
        IODMACommand *cmd {};
        uint64_t dma {};
        uint8_t *addr {};
        uint32_t size {};
    };
    static constexpr unsigned NumRx = 16, RxChannel = 1;

    IOPCIDevice *pci {};
    IOMemoryMap *map {};
    volatile uint8_t *regs {};
    IOWorkLoop *workLoop {};
    IOInterruptEventSource *interrupt {};
    IOTimerEventSource *idleTimer {}, *pollTimer {};
    IOLock *txLock {}, *waitLock {};
    DMABuffer rxPrds, rxBufs[NumRx], txPrds, txBuf;
    IOBufferMemoryDescriptor *reportBuffer {};
    SurfaceTouchHIDDevice *hid {};

    uint32_t maxRx {}, maxTx {}, rxPages {}, numReceived {}, touchCfg {};
    uint16_t vendor {}, product {};
    uint32_t config[16] {};
    uint8_t *rdesc {};
    uint32_t rdescSize {};
    void prepareDescriptor();
    bool rdescDone {}, featurePending {}, stopping {}, polling {};
    uint8_t *featureBuf {};
    uint32_t featureSize {};
    uint64_t counts[8] {}; // interrupts, rx, input, feature, descriptor, reset, errors, bad
    uint32_t lastError {}, failStep {};

    inline uint32_t r32(uint32_t o) const { return *reinterpret_cast<volatile uint32_t *>(regs + o); }
    inline uint16_t r16(uint32_t o) const { return *reinterpret_cast<volatile uint16_t *>(regs + o); }
    inline uint8_t r8(uint32_t o) const { return regs[o]; }
    inline void w32(uint32_t o, uint32_t v) { *reinterpret_cast<volatile uint32_t *>(regs + o) = v; }
    inline void w16(uint32_t o, uint16_t v) { *reinterpret_cast<volatile uint16_t *>(regs + o) = v; }
    inline void w8(uint32_t o, uint8_t v) { regs[o] = v; }
    inline void w64(uint32_t o, uint64_t v) { w32(o, uint32_t(v)); w32(o + 4, uint32_t(v >> 32)); }
    inline void bits32(uint32_t o, uint32_t mask, uint32_t v) { w32(o, (r32(o) & ~mask) | (v & mask)); }
    inline void bits8(uint32_t o, uint8_t mask, uint8_t v) { w8(o, uint8_t((r8(o) & ~mask) | (v & mask))); }

    bool wait32(uint32_t o, uint32_t mask, uint32_t v);
    bool wait8(uint32_t o, uint8_t mask, uint8_t v);

    bool allocDMA(DMABuffer &b, uint32_t size);
    void freeDMA(DMABuffer &b);
    void setPowerD0();
    void disableDevice();
    bool initDevice();
    bool legacyInit();
    bool spiCommand(uint8_t code, uint32_t offset, uint32_t size, void *data);
    void setSpiConfig(uint8_t clkdiv, bool clkdiv8, uint8_t readMode, uint8_t writeMode);
    void setLtrConfig(uint64_t activeNs, uint64_t idleNs);
    void setLtrIdle();
    bool setDeviceEnabled(bool enable);
    bool rxInit();
    void rxPut(unsigned idx);
    uint32_t rxGet(unsigned idx);
    void rxEnable();
    bool txInit();
    IOReturn txLocked(uint32_t code, const void *data, uint32_t size);
    void process();
    void processRx();
    void handleRx(const uint8_t *data, uint32_t len);
    bool readDescriptor();
    void publishState();
    void interruptOccurred(IOInterruptEventSource *source, int count);
    void idleTimeout(IOTimerEventSource *timer);
    void pollTimeout(IOTimerEventSource *timer);
};

class SurfaceTouchHIDDevice : public IOHIDDevice {
    OSDeclareDefaultStructors(SurfaceTouchHIDDevice)
    using super = IOHIDDevice;
public:
    bool init(SurfaceTouch *owner);
    bool handleStart(IOService *provider) override;
    void handleStop(IOService *provider) override;
    IOReturn newReportDescriptor(IOMemoryDescriptor **descriptor) const override;
    OSString *newTransportString() const override;
    OSString *newManufacturerString() const override;
    OSString *newProductString() const override;
    OSNumber *newVendorIDNumber() const override;
    OSNumber *newProductIDNumber() const override;
    OSNumber *newVersionNumber() const override;
    OSNumber *newLocationIDNumber() const override;
    IOReturn setReport(IOMemoryDescriptor *report, IOHIDReportType reportType, IOOptionBits options) override;
    IOReturn getReport(IOMemoryDescriptor *report, IOHIDReportType reportType, IOOptionBits options) override;
private:
    SurfaceTouch *thc {};
};

#endif // SURFACETOUCH_HPP
