#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdint.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>

enum { W = 256, H = 256, ROW = W * 4, BASE = 16 };

static id<MTLDevice> findDevice(NSString *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        NSString *name = d.name.lowercaseString;
        if ([which isEqualToString:@"intel"] && [name containsString:@"intel"]) return d;
        if ([which isEqualToString:@"nvidia"] && ([name containsString:@"nvidia"] || [name containsString:@"rtx"])) return d;
    }
    return nil;
}

static int checkPixel(const char *name, const unsigned char *p, int b, int g, int r, int a) {
    printf("%s BGRA=%u,%u,%u,%u expected=%d,%d,%d,%d\n", name, p[0], p[1], p[2], p[3], b, g, r, a);
    return abs((int)p[0] - b) <= 3 && abs((int)p[1] - g) <= 3 && abs((int)p[2] - r) <= 3 && abs((int)p[3] - a) <= 3;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s intel|nvidia draw|index16|index32 output.bgra\n", argv[0]);
            return 2;
        }
        NSString *gpuName = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        BOOL draw = [mode isEqualToString:@"draw"];
        BOOL index16 = [mode isEqualToString:@"index16"];
        BOOL index32 = [mode isEqualToString:@"index32"];
        if ((!draw && !index16 && !index32) || (![gpuName isEqualToString:@"intel"] && ![gpuName isEqualToString:@"nvidia"])) {
            fprintf(stderr, "FAIL: invalid GPU or mode\n");
            return 2;
        }
        id<MTLDevice> device = findDevice(gpuName);
        if (!device) {
            fprintf(stderr, "FAIL: GPU not found\n");
            return 1;
        }
        printf("GPU=%s mode=%s\n", device.name.UTF8String, mode.UTF8String);

        NSString *source = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct In {\n"
            "    float2 pos [[attribute(0)]];\n"
            "    float4 color [[attribute(1)]];\n"
            "};\n"
            "struct Out {\n"
            "    float4 position [[position]];\n"
            "    float4 color;\n"
            "};\n"
            "vertex Out vs(In in [[stage_in]]) {\n"
            "    Out o;\n"
            "    o.position = float4(in.pos, 0.5, 1.0);\n"
            "    o.color = in.color;\n"
            "    return o;\n"
            "}\n"
            "fragment float4 fs(Out in [[stage_in]]) {\n"
            "    return in.color;\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
        if (!lib) {
            fprintf(stderr, "FAIL: shader: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat2;
        vd.attributes[0].offset = 4;
        vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride = 16;
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 4;
        vd.attributes[1].bufferIndex = 1;
        vd.layouts[1].stride = 24;
        vd.layouts[1].stepFunction = MTLVertexStepFunctionPerVertex;

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) {
            fprintf(stderr, "FAIL: pipeline: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        // Vertex table deliberately not in triangle order.
        const float positions[6][2] = {
            {-0.5f,  0.8f}, // 0: red top
            { 0.9f, -0.8f}, // 1: green bottom-right
            {-0.9f, -0.8f}, // 2: red bottom-left
            { 0.5f,  0.8f}, // 3: green top
            {-0.1f, -0.8f}, // 4: red bottom-right
            { 0.1f, -0.8f}  // 5: green bottom-left
        };
        const float red[4] = {1, 0, 0, 1};
        const float green[4] = {0, 1, 0, 1};
        const unsigned order[6] = {2, 4, 0, 5, 1, 3};

        unsigned char positionBytes[BASE + 6 * 16];
        unsigned char colorBytes[BASE + 6 * 24];
        memset(positionBytes, 0xCD, sizeof(positionBytes));
        memset(colorBytes, 0xCD, sizeof(colorBytes));

        for (unsigned i = 0; i < 6; i++) {
            // Non-indexed control stores vertices in draw order.
            // Indexed variants keep the shuffled table.
            unsigned src = draw ? order[i] : i;
            const float *color = (src == 0 || src == 2 || src == 4) ? red : green;
            memcpy(positionBytes + BASE + i * 16 + 4, positions[src], sizeof(positions[src]));
            memcpy(colorBytes + BASE + i * 24 + 4, color, sizeof(red));
        }

        id<MTLBuffer> posBuffer = [device newBufferWithBytes:positionBytes length:sizeof(positionBytes) options:MTLResourceStorageModeShared];
        id<MTLBuffer> colorBuffer = [device newBufferWithBytes:colorBytes length:sizeof(colorBytes) options:MTLResourceStorageModeShared];

        // Four-byte prefix tests indexBufferOffset.
        const uint16_t indices16[8] = { 0xffff, 0xffff, 2, 4, 0, 5, 1, 3 };
        const uint32_t indices32[7] = { 0xffffffff, 2, 4, 0, 5, 1, 3 };

        id<MTLBuffer> indexBuffer = nil;
        if (index16) {
            indexBuffer = [device newBufferWithBytes:indices16 length:sizeof(indices16) options:MTLResourceStorageModeShared];
        } else if (index32) {
            indexBuffer = [device newBufferWithBytes:indices32 length:sizeof(indices32) options:MTLResourceStorageModeShared];
        }

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];

        id<MTLBuffer> out = [device newBufferWithLength:ROW * H options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];

        if (!posBuffer || !colorBuffer || (!draw && !indexBuffer) || !target || !out || !out.contents || !queue || !cmd) {
            fprintf(stderr, "FAIL: resource allocation\n");
            return 1;
        }

        memset(out.contents, 0xCD, ROW * H);

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        if (!enc) {
            fprintf(stderr, "FAIL: render encoder\n");
            return 1;
        }

        [enc setRenderPipelineState:pipeline];
        [enc setVertexBuffer:posBuffer offset:BASE atIndex:0];
        [enc setVertexBuffer:colorBuffer offset:BASE atIndex:1];

        if (draw) {
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        } else {
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:6
                             indexType:index16 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32
                           indexBuffer:indexBuffer
                     indexBufferOffset:4];
        }
        [enc endEncoding];

        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (!blit) {
            fprintf(stderr, "FAIL: blit encoder\n");
            return 1;
        }
        [blit copyFromTexture:target
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(W, H, 1)
                     toBuffer:out
            destinationOffset:0
       destinationBytesPerRow:ROW
     destinationBytesPerImage:ROW * H];
        [blit endEncoding];

        [cmd commit];
        [cmd waitUntilCompleted];

        if (cmd.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "FAIL: command status=%lu error=%s\n", (unsigned long)cmd.status, cmd.error ? cmd.error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        const unsigned char *p = out.contents;
        int ok = 1;
        ok &= checkPixel("corner", p + 8 * ROW + 8 * 4, 0, 0, 0, 255);
        ok &= checkPixel("left", p + 128 * ROW + 64 * 4, 0, 0, 255, 255);
        ok &= checkPixel("gap", p + 128 * ROW + 128 * 4, 0, 0, 0, 255);
        ok &= checkPixel("right", p + 128 * ROW + 192 * 4, 0, 255, 0, 255);

        FILE *f = fopen(argv[3], "wb");
        if (!f) {
            perror("FAIL: fopen");
            return 1;
        }
        size_t written = fwrite(p, 1, ROW * H, f);
        int closeStatus = fclose(f);
        if (written != ROW * H || closeStatus != 0) {
            fprintf(stderr, "FAIL: output write\n");
            return 1;
        }
        printf("saved=%s bytes=%zu\n", argv[3], written);
        printf("RESULT=%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
