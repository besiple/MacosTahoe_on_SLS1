#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

enum { W = 256, H = 256, ROW = W * 4, BYTES = ROW * H };

static id<MTLDevice> findDevice(NSString *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        NSString *name = d.name.lowercaseString;
        if ([which isEqualToString:@"intel"] && [name containsString:@"intel"]) return d;
        if ([which isEqualToString:@"nvidia"] && ([name containsString:@"nvidia"] || [name containsString:@"rtx"])) return d;
    }
    return nil;
}

static void drawRect(id<MTLRenderCommandEncoder> enc, float depth, float scale, const float *color) {
    const float params[2] = {depth, scale};
    [enc setVertexBytes:params length:sizeof(params) atIndex:0];
    if (color) [enc setFragmentBytes:color length:4 * sizeof(float) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

static int checkImage(const unsigned char *p, BOOL clearControl) {
    unsigned long bad = 0;
    int maxDiff = 0;
    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            BOOL insideFar = x >= 26 && x <= 229 && y >= 26 && y <= 229;
            BOOL insideNear = x >= 64 && x <= 191 && y >= 64 && y <= 191;
            // BGRA. Clear control loses near depth, so far green
            // overwrites near red inside the larger rectangle.
            int expected[4] = {0, 0, 0, 255};
            if (insideFar) expected[1] = 255;
            if (insideNear && !clearControl) {
                expected[1] = 0;
                expected[2] = 255;
            }
            const unsigned char *pixel = p + y * ROW + x * 4;
            BOOL pixelBad = NO;
            for (int c = 0; c < 4; c++) {
                int diff = abs((int)pixel[c] - expected[c]);
                if (diff > maxDiff) maxDiff = diff;
                if (diff > 1) pixelBad = YES;
            }
            if (pixelBad) {
                if (bad < 5) {
                    printf("mismatch (%u,%u): got BGRA=%u,%u,%u,%u expected=%d,%d,%d,%d\n",
                           x, y, pixel[0], pixel[1], pixel[2], pixel[3],
                           expected[0], expected[1], expected[2], expected[3]);
                }
                bad++;
            }
        }
    }
    const unsigned char *center = p + 128 * ROW + 128 * 4;
    const unsigned char *side = p + 128 * ROW + 40 * 4;
    const unsigned char *corner = p + 8 * ROW + 8 * 4;
    printf("center BGRA=%u,%u,%u,%u\n", center[0], center[1], center[2], center[3]);
    printf("side BGRA=%u,%u,%u,%u\n", side[0], side[1], side[2], side[3]);
    printf("corner BGRA=%u,%u,%u,%u\n", corner[0], corner[1], corner[2], corner[3]);
    printf("mismatched_pixels=%lu max_channel_diff=%d\n", bad, maxDiff);
    return bad == 0;
}

static int saveImage(const char *path, const void *data) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror("FAIL fopen");
        return 0;
    }
    size_t written = fwrite(data, 1, BYTES, f);
    int closeResult = fclose(f);
    if (written != BYTES || closeResult != 0) {
        fprintf(stderr, "FAIL: image write\n");
        return 0;
    }
    printf("saved=%s bytes=%zu\n", path, written);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (argc != 4) {
            fprintf(stderr, "Usage: %s intel|nvidia single|prepass|clear-control output.bgra\n", argv[0]);
            return 2;
        }
        NSString *gpu = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        BOOL single = [mode isEqualToString:@"single"];
        BOOL prepass = [mode isEqualToString:@"prepass"];
        BOOL clearControl = [mode isEqualToString:@"clear-control"];
        BOOL twoPass = prepass || clearControl;
        if ((![gpu isEqualToString:@"intel"] && ![gpu isEqualToString:@"nvidia"]) || (!single && !twoPass)) {
            fprintf(stderr, "FAIL: invalid GPU or mode\n");
            return 2;
        }
        id<MTLDevice> device = findDevice(gpu);
        if (!device) {
            fprintf(stderr, "FAIL: requested GPU not found\n");
            return 1;
        }
        printf("GPU=%s mode=%s\n", device.name.UTF8String, mode.UTF8String);

        NSString *source = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct V { float4 position [[position]]; };\n"
            "vertex V vs(uint id [[vertex_id]],\n"
            "            constant float2 &p [[buffer(0)]]) {\n"
            "    const float2 xy[6] = {\n"
            "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
            "        float2(-1,1), float2(1,-1), float2(1,1)\n"
            "    };\n"
            "    V o; o.position = float4(xy[id] * p.y, p.x, 1.0);\n"
            "    return o;\n"
            "}\n"
            "fragment float4 fs(V in [[stage_in]],\n"
            "                   constant float4 &c [[buffer(0)]]) {\n"
            "    return c;\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
        if (!lib) {
            fprintf(stderr, "FAIL: shader: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        MTLRenderPipelineDescriptor *colorPD = [MTLRenderPipelineDescriptor new];
        colorPD.vertexFunction = [lib newFunctionWithName:@"vs"];
        colorPD.fragmentFunction = [lib newFunctionWithName:@"fs"];
        colorPD.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        colorPD.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        id<MTLRenderPipelineState> colorPipeline = [device newRenderPipelineStateWithDescriptor:colorPD error:&error];
        if (!colorPipeline) {
            fprintf(stderr, "FAIL: color pipeline: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        id<MTLRenderPipelineState> depthPipeline = nil;
        if (twoPass) {
            // Depth-only pipeline: no color attachment or fragment shader.
            MTLRenderPipelineDescriptor *depthPD = [MTLRenderPipelineDescriptor new];
            depthPD.vertexFunction = [lib newFunctionWithName:@"vs"];
            depthPD.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            depthPipeline = [device newRenderPipelineStateWithDescriptor:depthPD error:&error];
            if (!depthPipeline) {
                fprintf(stderr, "FAIL: depth-only pipeline: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
                return 1;
            }
        }

        MTLDepthStencilDescriptor *writeDD = [MTLDepthStencilDescriptor new];
        writeDD.depthCompareFunction = MTLCompareFunctionLess;
        writeDD.depthWriteEnabled = YES;
        id<MTLDepthStencilState> writeDepth = [device newDepthStencilStateWithDescriptor:writeDD];

        MTLDepthStencilDescriptor *readDD = [MTLDepthStencilDescriptor new];
        readDD.depthCompareFunction = MTLCompareFunctionLessEqual;
        readDD.depthWriteEnabled = NO;
        id<MTLDepthStencilState> readDepth = [device newDepthStencilStateWithDescriptor:readDD];

        MTLTextureDescriptor *colorTD = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        colorTD.storageMode = MTLStorageModePrivate;
        colorTD.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> color = [device newTextureWithDescriptor:colorTD];

        MTLTextureDescriptor *depthTD = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
        depthTD.storageMode = MTLStorageModePrivate;
        depthTD.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> depth = [device newTextureWithDescriptor:depthTD];

        id<MTLBuffer> out = [device newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];

        if (!writeDepth || !readDepth || !color || !depth || !out || !out.contents || !queue || !cmd) {
            fprintf(stderr, "FAIL: resource allocation\n");
            return 1;
        }

        memset(out.contents, 0xCD, BYTES);
        const float red[4] = {1, 0, 0, 1};
        const float green[4] = {0, 1, 0, 1};

        if (twoPass) {
            MTLRenderPassDescriptor *first = [MTLRenderPassDescriptor new];
            first.depthAttachment.texture = depth;
            first.depthAttachment.loadAction = MTLLoadActionClear;
            first.depthAttachment.clearDepth = 1.0;
            first.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:first];
            if (!enc) {
                fprintf(stderr, "FAIL: prepass encoder\n");
                return 1;
            }
            [enc setRenderPipelineState:depthPipeline];
            [enc setDepthStencilState:writeDepth];
            // Record near depth only. No color output.
            drawRect(enc, 0.25f, 0.5f, NULL);
            [enc endEncoding];
        }

        MTLRenderPassDescriptor *second = [MTLRenderPassDescriptor new];
        second.colorAttachments[0].texture = color;
        second.colorAttachments[0].loadAction = MTLLoadActionClear;
        second.colorAttachments[0].storeAction = MTLStoreActionStore;
        second.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        second.depthAttachment.texture = depth;
        second.depthAttachment.loadAction = prepass ? MTLLoadActionLoad : MTLLoadActionClear;
        second.depthAttachment.clearDepth = 1.0;
        second.depthAttachment.storeAction = MTLStoreActionDontCare;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:second];
        if (!enc) {
            fprintf(stderr, "FAIL: color pass encoder\n");
            return 1;
        }
        [enc setRenderPipelineState:colorPipeline];
        [enc setDepthStencilState:single ? writeDepth : readDepth];
        // Near red first, then larger far green.
        // In prepass, depth writes are disabled in this pass.
        drawRect(enc, 0.25f, 0.5f, red);
        drawRect(enc, 0.75f, 0.8f, green);
        [enc endEncoding];

        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (!blit) {
            fprintf(stderr, "FAIL: readback encoder\n");
            return 1;
        }
        [blit copyFromTexture:color
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(W, H, 1)
                     toBuffer:out
            destinationOffset:0
       destinationBytesPerRow:ROW
     destinationBytesPerImage:BYTES];
        [blit endEncoding];

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> ignored) {
            dispatch_semaphore_signal(done);
        }];
        [cmd commit];

        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
            fprintf(stderr, "TIMEOUT: GPU work may still be pending; stop tests\n");
            fflush(NULL);
            _Exit(124);
        }

        if (cmd.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "FAIL: status=%lu error=%s\n", (unsigned long)cmd.status, cmd.error ? cmd.error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        int ok = checkImage(out.contents, clearControl);
        ok &= saveImage(argv[3], out.contents);
        printf("RESULT=%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
