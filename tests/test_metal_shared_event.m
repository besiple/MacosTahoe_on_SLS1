#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <string.h>

enum { W = 128, H = 96, ROW = W * 4 };

static id<MTLDevice> findDevice(NSString *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        NSString *name = d.name.lowercaseString;
        if ([which isEqualToString:@"intel"] && [name containsString:@"intel"]) return d;
        if ([which isEqualToString:@"nvidia"] && ([name containsString:@"nvidia"] || [name containsString:@"rtx"])) return d;
    }
    return nil;
}

static BOOL waitOK(id<MTLCommandBuffer> cmd, const char *stage) {
    [cmd commit];
    [cmd waitUntilCompleted];
    if (cmd.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FAIL %s: status=%lu error=%s\n", stage, (unsigned long)cmd.status, cmd.error ? cmd.error.localizedDescription.UTF8String : "(none)");
        return NO;
    }
    return YES;
}

static void awaitDone(dispatch_semaphore_t done, id<MTLCommandBuffer> cmd, const char *stage) {
    long timedOut = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (timedOut != 0) {
        fprintf(stderr, "TIMEOUT %s: status=%lu\n", stage, (unsigned long)cmd.status);
        fprintf(stderr, "GPU work may still be pending; do not continue tests.\n");
        fflush(NULL);
        _Exit(124);
    }
    if (cmd.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FAIL %s: status=%lu error=%s\n", stage, (unsigned long)cmd.status, cmd.error ? cmd.error.localizedDescription.UTF8String : "(none)");
        fprintf(stderr, "Other GPU work may still be pending.\n");
        fflush(NULL);
        _Exit(1);
    }
}

static void copyTextureToBuffer(id<MTLBlitCommandEncoder> blit, id<MTLTexture> texture, id<MTLBuffer> buffer) {
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(W, H, 1)
                 toBuffer:buffer
        destinationOffset:0
   destinationBytesPerRow:ROW
 destinationBytesPerImage:ROW * H];
}

static int checkExpected(const char *label, const unsigned char *p, unsigned frame) {
    unsigned long mismatches = 0;
    int maxDiff = 0;
    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            const unsigned char *pixel = p + y * ROW + x * 4;
            const int expected[4] = {
                (int)((x * 7 + y + 43 * frame) & 255), // B
                (int)((x * 2 + y * 5 + 29 * frame) & 255), // G
                (int)((x + y * 3 + 17 * frame) & 255), // R
                255
            };
            BOOL badPixel = NO;
            for (int c = 0; c < 4; c++) {
                int diff = abs((int)pixel[c] - expected[c]);
                if (diff > maxDiff) maxDiff = diff;
                if (diff > 1) badPixel = YES;
            }
            if (badPixel) {
                if (mismatches < 3) {
                    printf("%s mismatch (%u,%u): "
                           "got BGRA=%u,%u,%u,%u "
                           "expected=%d,%d,%d,%d\n",
                           label, x, y, pixel[0], pixel[1], pixel[2], pixel[3],
                           expected[0], expected[1], expected[2], expected[3]);
                }
                mismatches++;
            }
        }
    }
    printf("%s: mismatched_pixels=%lu max_channel_diff=%d\n", label, mismatches, maxDiff);
    return mismatches == 0;
}

static int compareBuffers(const unsigned char *a, const unsigned char *b) {
    unsigned long mismatches = 0;
    int maxDiff = 0;
    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            const unsigned char *pa = a + y * ROW + x * 4;
            const unsigned char *pb = b + y * ROW + x * 4;
            BOOL badPixel = NO;
            for (int c = 0; c < 4; c++) {
                int diff = abs((int)pa[c] - (int)pb[c]);
                if (diff > maxDiff) maxDiff = diff;
                if (diff > 1) badPixel = YES;
            }
            if (badPixel) mismatches++;
        }
    }
    printf("producer_vs_consumer: mismatched_pixels=%lu "
           "max_channel_diff=%d\n", mismatches, maxDiff);
    return mismatches == 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (argc != 4) {
            fprintf(stderr, "Usage: %s intel|nvidia intel|nvidia ready|pending\n", argv[0]);
            return 2;
        }
        NSString *producerName = [NSString stringWithUTF8String:argv[1]];
        NSString *consumerName = [NSString stringWithUTF8String:argv[2]];
        NSString *mode = [NSString stringWithUTF8String:argv[3]];
        BOOL pending = [mode isEqualToString:@"pending"];
        if (!pending && ![mode isEqualToString:@"ready"]) {
            fprintf(stderr, "FAIL: unknown mode\n");
            return 2;
        }

        id<MTLDevice> producer = findDevice(producerName);
        id<MTLDevice> consumer = findDevice(consumerName);
        if (!producer || !consumer) {
            fprintf(stderr, "FAIL: requested GPU not found\n");
            return 1;
        }
        printf("Producer: %s\nConsumer: %s\n", producer.name.UTF8String, consumer.name.UTF8String);

        id<MTLSharedEvent> producerEvent = [producer newSharedEvent];
        MTLSharedEventHandle *handle = [producerEvent newSharedEventHandle];
        id<MTLSharedEvent> consumerEvent = handle ? [consumer newSharedEventWithHandle:handle] : nil;
        if (!producerEvent || !handle || !consumerEvent) {
            fprintf(stderr, "FAIL: shared event creation/import "
                    "(producer=%s handle=%s consumer=%s)\n",
                    producerEvent ? "yes" : "no",
                    handle ? "yes" : "no",
                    consumerEvent ? "yes" : "no");
            return 1;
        }
        printf("mode=%s initial_event_values=%llu/%llu\n",
               mode.UTF8String,
               (unsigned long long)producerEvent.signaledValue,
               (unsigned long long)consumerEvent.signaledValue);

        if (producerEvent.signaledValue != 0 || consumerEvent.signaledValue != 0) {
            fprintf(stderr, "FAIL: unexpected initial event value\n");
            return 1;
        }

        size_t surfaceRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, ROW);
        NSDictionary *props = @{
            (__bridge NSString *)kIOSurfaceWidth: @(W),
            (__bridge NSString *)kIOSurfaceHeight: @(H),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *)kIOSurfaceBytesPerRow: @(surfaceRow),
            (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241U)
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surface) {
            fprintf(stderr, "FAIL: IOSurfaceCreate\n");
            return 1;
        }
        printf("IOSurface: id=%u size=%zux%zu rowBytes=%zu\n",
               IOSurfaceGetID(surface),
               IOSurfaceGetWidth(surface),
               IOSurfaceGetHeight(surface),
               IOSurfaceGetBytesPerRow(surface));

        MTLTextureDescriptor *writeDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        writeDesc.storageMode = MTLStorageModeManaged;
        writeDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

        MTLTextureDescriptor *readDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        readDesc.storageMode = MTLStorageModeManaged;
        readDesc.usage = MTLTextureUsageShaderRead;

        id<MTLTexture> writeTex = [producer newTextureWithDescriptor:writeDesc iosurface:surface plane:0];
        id<MTLTexture> readTex = [consumer newTextureWithDescriptor:readDesc iosurface:surface plane:0];
        if (!writeTex || !readTex) {
            fprintf(stderr, "FAIL: IOSurface texture import "
                    "(producer=%s consumer=%s)\n",
                    writeTex ? "yes" : "no",
                    readTex ? "yes" : "no");
            CFRelease(surface);
            return 1;
        }
        printf("Texture storage modes: producer=%lu consumer=%lu\n",
               (unsigned long)writeTex.storageMode, (unsigned long)readTex.storageMode);

        NSString *source = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct V { float4 position [[position]]; };\n"
            "vertex V vs(uint id [[vertex_id]]) {\n"
            "    const float2 p[6] = {\n"
            "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
            "        float2(-1,1), float2(1,-1), float2(1,1)\n"
            "    };\n"
            "    V out; out.position = float4(p[id], 0.5, 1.0);\n"
            "    return out;\n"
            "}\n"
            "fragment float4 fs(V in [[stage_in]],\n"
            "                   constant uint &frame [[buffer(0)]]) {\n"
            "    uint x = uint(in.position.x);\n"
            "    uint y = uint(in.position.y);\n"
            "    uint r = (x + y * 3 + 17 * frame) & 255;\n"
            "    uint g = (x * 2 + y * 5 + 29 * frame) & 255;\n"
            "    uint b = (x * 7 + y + 43 * frame) & 255;\n"
            "    return float4(float(r), float(g), float(b), 255.0) / 255.0;\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> library = [producer newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            fprintf(stderr, "FAIL: shader compile: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            CFRelease(surface);
            return 1;
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [library newFunctionWithName:@"vs"];
        pd.fragmentFunction = [library newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        id<MTLRenderPipelineState> pipeline = [producer newRenderPipelineStateWithDescriptor:pd error:&error];
        id<MTLCommandQueue> producerQueue = [producer newCommandQueue];
        id<MTLCommandQueue> consumerQueue = [consumer newCommandQueue];
        id<MTLBuffer> producerOut = [producer newBufferWithLength:ROW * H options:MTLResourceStorageModeShared];
        id<MTLBuffer> consumerOut = [consumer newBufferWithLength:ROW * H options:MTLResourceStorageModeShared];

        if (!pipeline || !producerQueue || !consumerQueue || !producerOut || !consumerOut || !producerOut.contents || !consumerOut.contents) {
            fprintf(stderr, "FAIL: pipeline or resource creation: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            CFRelease(surface);
            return 1;
        }

        int allOK = 1;
        for (unsigned frame = 0; frame < 3; frame++) {
            printf("\n--- frame %u ---\n", frame);
            memset(producerOut.contents, 0xCD, ROW * H);
            memset(consumerOut.contents, 0xCD, ROW * H);

            id<MTLCommandBuffer> pcmd = [producerQueue commandBuffer];
            if (!pcmd) {
                fprintf(stderr, "FAIL: producer command buffer\n");
                allOK = 0;
                break;
            }
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture = writeTex;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

            id<MTLRenderCommandEncoder> enc = [pcmd renderCommandEncoderWithDescriptor:pass];
            if (!enc) {
                fprintf(stderr, "FAIL: render encoder\n");
                allOK = 0;
                break;
            }
            [enc setRenderPipelineState:pipeline];
            [enc setFragmentBytes:&frame length:sizeof(frame) atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [enc endEncoding];

            id<MTLBlitCommandEncoder> pblit = [pcmd blitCommandEncoder];
            if (!pblit) {
                fprintf(stderr, "FAIL: producer blit encoder\n");
                allOK = 0;
                break;
            }
            copyTextureToBuffer(pblit, writeTex, producerOut);
            // Для managed-ресурса запрашиваем GPU→CPU синхронизацию.
            if (writeTex.storageMode == MTLStorageModeManaged) [pblit synchronizeResource:writeTex];
            [pblit endEncoding];

            uint64_t value = (uint64_t)frame + 1;
            if (producerEvent.signaledValue >= value || consumerEvent.signaledValue >= value) {
                fprintf(stderr, "FAIL: event already reached frame value\n");
                allOK = 0;
                break;
            }
            // Сигнал ПОСЛЕ render, producer readback и synchronizeResource.
            [pcmd encodeSignalEvent:producerEvent value:value];

            id<MTLCommandBuffer> ccmd = [consumerQueue commandBuffer];
            if (!ccmd) {
                fprintf(stderr, "FAIL: consumer command buffer\n");
                allOK = 0;
                break;
            }
            // Wait расположен ПЕРЕД consumer blit.
            [ccmd encodeWaitForEvent:consumerEvent value:value];

            id<MTLBlitCommandEncoder> cblit = [ccmd blitCommandEncoder];
            if (!cblit) {
                fprintf(stderr, "FAIL: consumer blit encoder\n");
                allOK = 0;
                break;
            }
            copyTextureToBuffer(cblit, readTex, consumerOut);
            [cblit endEncoding];

            dispatch_semaphore_t producerDone = dispatch_semaphore_create(0);
            dispatch_semaphore_t consumerDone = dispatch_semaphore_create(0);
            [pcmd addCompletedHandler:^(id<MTLCommandBuffer> ignored) {
                dispatch_semaphore_signal(producerDone);
            }];
            [ccmd addCompletedHandler:^(id<MTLCommandBuffer> ignored) {
                dispatch_semaphore_signal(consumerDone);
            }];

            if (pending) {
                // Сначала ставим consumer в очередь с ещё не достигнутым value.
                [ccmd commit];
                // Проверяем, что он не завершился до отправки producer.
                long early = dispatch_semaphore_wait(
                    consumerDone,
                    dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
                if (early == 0) {
                    fprintf(stderr, "FAIL: consumer completed before signal; "
                            "status=%lu\n", (unsigned long)ccmd.status);
                    fflush(NULL);
                    _Exit(1);
                }
                printf("consumer did not complete before producer commit\n");
                [pcmd commit];
                // Оба command buffer уже отправлены. CPU ожидает здесь
                // только ради проверки результатов, не для упорядочивания.
                awaitDone(producerDone, pcmd, "producer");
                awaitDone(consumerDone, ccmd, "consumer");
            } else {
                // Контроль: сигнал уже достигнут до отправки consumer.
                [pcmd commit];
                awaitDone(producerDone, pcmd, "producer");
                [ccmd commit];
                awaitDone(consumerDone, ccmd, "consumer");
            }

            printf("event values after completion: producer=%llu consumer=%llu "
                   "required=%llu\n",
                   (unsigned long long)producerEvent.signaledValue,
                   (unsigned long long)consumerEvent.signaledValue,
                   (unsigned long long)value);

            if (producerEvent.signaledValue < value || consumerEvent.signaledValue < value) {
                fprintf(stderr, "FAIL: event value not observed\n");
                allOK = 0;
                break;
            }

            const unsigned char *p = producerOut.contents;
            const unsigned char *c = consumerOut.contents;
            int producerOK = checkExpected("producer", p, frame);
            int consumerOK = checkExpected("consumer", c, frame);
            int matchOK = compareBuffers(p, c);
            if (!producerOK || !consumerOK || !matchOK) {
                allOK = 0;
                break;
            }
        }

        printf("\nRESULT=%s\n", allOK ? "PASS" : "FAIL");
        CFRelease(surface);
        return allOK ? 0 : 1;
    }
}
