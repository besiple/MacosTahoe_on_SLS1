#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

enum { W = 128, H = 96, ROW = W * 4, BYTES = ROW * H };

static id<MTLDevice> findDevice(NSString *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        NSString *name = d.name.lowercaseString;
        if ([which isEqualToString:@"intel"] && [name containsString:@"intel"]) return d;
        if ([which isEqualToString:@"nvidia"] && ([name containsString:@"nvidia"] || [name containsString:@"rtx"])) return d;
    }
    return nil;
}

static int checkImage(const char *label, const unsigned char *p, BOOL patternA) {
    unsigned long bad = 0;
    int maxDiff = 0;
    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            const unsigned char *pixel = p + y * ROW + x * 4;
            int r, g, b;
            if (patternA) {
                r = (x * 3 + y * 5 + 17) & 255;
                g = (x * 7 + y + 31) & 255;
                b = (x + y * 11 + 59) & 255;
            } else {
                r = (x * 13 + y * 2 + 71) & 255;
                g = (x + y * 9 + 113) & 255;
                b = (x * 5 + y * 3 + 149) & 255;
            }
            // Output texture is BGRA8, alpha is always 255.
            int expected[4] = {b, g, r, 255};
            BOOL pixelBad = NO;
            for (int c = 0; c < 4; c++) {
                int diff = abs((int)pixel[c] - expected[c]);
                if (diff > maxDiff) maxDiff = diff;
                if (diff > 1) pixelBad = YES;
            }
            if (pixelBad) {
                if (bad < 3) {
                    printf("%s mismatch (%u,%u): "
                           "got=%u,%u,%u,%u expected=%d,%d,%d,%d\n",
                           label, x, y, pixel[0], pixel[1], pixel[2], pixel[3],
                           expected[0], expected[1], expected[2], expected[3]);
                }
                bad++;
            }
        }
    }
    printf("%s: mismatched_pixels=%lu max_channel_diff=%d\n", label, bad, maxDiff);
    return bad == 0;
}

static int saveImage(NSString *path, const void *bytes) {
    FILE *f = fopen(path.fileSystemRepresentation, "wb");
    if (!f) {
        perror("FAIL fopen");
        return 0;
    }
    size_t written = fwrite(bytes, 1, BYTES, f);
    int closeResult = fclose(f);
    if (written != BYTES || closeResult != 0) {
        fprintf(stderr, "FAIL: writing %s\n", path.UTF8String);
        return 0;
    }
    printf("saved=%s bytes=%zu\n", path.UTF8String, written);
    return 1;
}

static void encodeReadback(id<MTLBlitCommandEncoder> blit, id<MTLTexture> tex, id<MTLBuffer> out) {
    [blit copyFromTexture:tex
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(W, H, 1)
                 toBuffer:out
        destinationOffset:0
   destinationBytesPerRow:ROW
 destinationBytesPerImage:BYTES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (argc != 4) {
            fprintf(stderr, "Usage: %s intel|nvidia a|b|mrt output-prefix\n", argv[0]);
            return 2;
        }
        NSString *gpu = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        NSString *prefix = [NSString stringWithUTF8String:argv[3]];
        BOOL singleA = [mode isEqualToString:@"a"];
        BOOL singleB = [mode isEqualToString:@"b"];
        BOOL mrt = [mode isEqualToString:@"mrt"];
        if ((![gpu isEqualToString:@"intel"] && ![gpu isEqualToString:@"nvidia"]) || (!singleA && !singleB && !mrt)) {
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
            "vertex V vs(uint id [[vertex_id]]) {\n"
            "    const float2 p[6] = {\n"
            "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
            "        float2(-1,1), float2(1,-1), float2(1,1)\n"
            "    };\n"
            "    V o; o.position = float4(p[id], 0.5, 1.0); return o;\n"
            "}\n"
            "float4 patternA(uint x, uint y) {\n"
            "    uint r = (x*3 + y*5 + 17) & 255;\n"
            "    uint g = (x*7 + y + 31) & 255;\n"
            "    uint b = (x + y*11 + 59) & 255;\n"
            "    return float4(float(r), float(g), float(b), 255.0) / 255.0;\n"
            "}\n"
            "float4 patternB(uint x, uint y) {\n"
            "    uint r = (x*13 + y*2 + 71) & 255;\n"
            "    uint g = (x + y*9 + 113) & 255;\n"
            "    uint b = (x*5 + y*3 + 149) & 255;\n"
            "    return float4(float(r), float(g), float(b), 255.0) / 255.0;\n"
            "}\n"
            "fragment float4 fsA(V in [[stage_in]]) {\n"
            "    return patternA(uint(in.position.x), uint(in.position.y));\n"
            "}\n"
            "fragment float4 fsB(V in [[stage_in]]) {\n"
            "    return patternB(uint(in.position.x), uint(in.position.y));\n"
            "}\n"
            "struct MRTOut {\n"
            "    float4 a [[color(0)]];\n"
            "    float4 b [[color(1)]];\n"
            "};\n"
            "fragment MRTOut fsMRT(V in [[stage_in]]) {\n"
            "    uint x = uint(in.position.x), y = uint(in.position.y);\n"
            "    MRTOut o; o.a = patternA(x,y); o.b = patternB(x,y);\n"
            "    return o;\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
        if (!lib) {
            fprintf(stderr, "FAIL: shader: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:mrt ? @"fsMRT" : (singleA ? @"fsA" : @"fsB")];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (mrt) pd.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;

        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) {
            fprintf(stderr, "FAIL: pipeline: %s\n", error ? error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;

        id<MTLTexture> tex0 = [device newTextureWithDescriptor:td];
        id<MTLTexture> tex1 = mrt ? [device newTextureWithDescriptor:td] : nil;
        id<MTLBuffer> out0 = [device newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
        id<MTLBuffer> out1 = mrt ? [device newBufferWithLength:BYTES options:MTLResourceStorageModeShared] : nil;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];

        if (!tex0 || !out0 || !out0.contents || !queue || !cmd || (mrt && (!tex1 || !out1 || !out1.contents))) {
            fprintf(stderr, "FAIL: resource allocation\n");
            return 1;
        }

        memset(out0.contents, 0xCD, BYTES);
        if (mrt) memset(out1.contents, 0xCD, BYTES);

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = tex0;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        if (mrt) {
            pass.colorAttachments[1].texture = tex1;
            pass.colorAttachments[1].loadAction = MTLLoadActionClear;
            pass.colorAttachments[1].storeAction = MTLStoreActionStore;
            pass.colorAttachments[1].clearColor = MTLClearColorMake(1, 0, 1, 1);
        }

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        if (!enc) {
            fprintf(stderr, "FAIL: render encoder\n");
            return 1;
        }
        [enc setRenderPipelineState:pipeline];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [enc endEncoding];

        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (!blit) {
            fprintf(stderr, "FAIL: blit encoder\n");
            return 1;
        }
        encodeReadback(blit, tex0, out0);
        if (mrt) encodeReadback(blit, tex1, out1);
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

        int ok = 1;
        if (singleA || mrt) {
            ok &= checkImage("A", out0.contents, YES);
            ok &= saveImage([prefix stringByAppendingString:@".a.bgra"], out0.contents);
        }
        if (singleB) {
            ok &= checkImage("B", out0.contents, NO);
            ok &= saveImage([prefix stringByAppendingString:@".b.bgra"], out0.contents);
        }
        if (mrt) {
            ok &= checkImage("B", out1.contents, NO);
            ok &= saveImage([prefix stringByAppendingString:@".b.bgra"], out1.contents);
        }

        printf("RESULT=%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
