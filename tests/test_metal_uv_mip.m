#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdlib.h>
#import <string.h>

static int checkPixel(const char *label, const unsigned char *p, int b, int g, int r, int a) {
    printf("%-8s BGRA = %3u %3u %3u %3u | expected %3d %3d %3d %3d\n", label, p[0], p[1], p[2], p[3], b, g, r, a);
    const int tolerance = 5;
    return abs((int)p[0] - b) <= tolerance &&
           abs((int)p[1] - g) <= tolerance &&
           abs((int)p[2] - r) <= tolerance &&
           abs((int)p[3] - a) <= tolerance;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s intel|nvidia nearest|linear|mip-one|mip-blend\n", argv[0]);
            return 2;
        }
        NSString *gpuArg = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        BOOL isIntel = [gpuArg isEqualToString:@"intel"];
        BOOL isNvidia = [gpuArg isEqualToString:@"nvidia"];
        BOOL nearest = [mode isEqualToString:@"nearest"];
        BOOL linear = [mode isEqualToString:@"linear"];
        BOOL mipOne = [mode isEqualToString:@"mip-one"];
        BOOL mipBlend = [mode isEqualToString:@"mip-blend"];
        BOOL sampleOnly = YES;
        BOOL depthOnly = NO;

        if ((!isIntel && !isNvidia) || (!nearest && !linear && !mipOne && !mipBlend)) {
            fprintf(stderr, "Usage: %s intel|nvidia nearest|linear|mip-one|mip-blend\n", argv[0]);
            return 2;
        }

        id<MTLDevice> device = nil;
        for (id<MTLDevice> d in MTLCopyAllDevices()) {
            NSString *name = d.name.lowercaseString;
            if ((isIntel && [name containsString:@"intel"]) ||
                (isNvidia && ([name containsString:@"nvidia"] || [name containsString:@"rtx"]))) {
                device = d;
                break;
            }
        }
        if (!device) {
            fprintf(stderr, "FAIL: requested GPU not found\n");
            return 1;
        }
        printf("GPU: %s\nMode: %s\n", device.name.UTF8String, mode.UTF8String);

        NSString *source = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct VOut { float4 position [[position]]; };\n"
            "vertex VOut vs(uint id [[vertex_id]],\n"
            "               constant float2 &p [[buffer(0)]]) {\n"
            "    const float2 xy[6] = {\n"
            "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
            "        float2(-1,1), float2(1,-1), float2(1,1)\n"
            "    };\n"
            "    VOut o;\n"
            "    o.position = float4(xy[id] * p.y, p.x, 1.0);\n"
            "    return o;\n"
            "}\n"
            "fragment float4 fs_solid(VOut in [[stage_in]],\n"
            "                         constant float4 &c [[buffer(0)]]) {\n"
            "    return c;\n"
            "}\n"
            "fragment float4 fs_texture(VOut in [[stage_in]],\n"
            "                           texture2d<float> tex [[texture(0)]],\n"
            "                           sampler s [[sampler(0)]],\n"
            "                           constant float &lod [[buffer(0)]]) {\n"
            "    float2 uv = float2(in.position.x / 256.0, 0.5);\n"
            "    return tex.sample(s, uv, level(lod));\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            fprintf(stderr, "FAIL: shader compile: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [library newFunctionWithName:@"vs"];
        pd.fragmentFunction = [library newFunctionWithName:depthOnly ? @"fs_solid" : @"fs_texture"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) {
            fprintf(stderr, "FAIL: pipeline: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = sampleOnly ? MTLCompareFunctionAlways : MTLCompareFunctionLess;
        dd.depthWriteEnabled = !sampleOnly;
        id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:dd];

        const NSUInteger width = 256, height = 256, rowBytes = 1024;
        MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        colorDesc.storageMode = MTLStorageModePrivate;
        colorDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> color = [device newTextureWithDescriptor:colorDesc];

        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:width height:height mipmapped:NO];
        depthDesc.storageMode = MTLStorageModePrivate;
        depthDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> depth = [device newTextureWithDescriptor:depthDesc];

        // mip 0: 4x4, left red, right green.
        // mip 1: 2x2, blue.
        // mip 2: 1x1, yellow.
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:YES];
        textureDesc.storageMode = MTLStorageModePrivate;
        textureDesc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];

        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = (nearest || mipOne) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sd.magFilter = sd.minFilter;
        sd.mipFilter = mipBlend ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];

        id<MTLBuffer> upload = [device newBufferWithLength:1792 options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback = [device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];

        if (!depthState || !color || !depth || !texture || !sampler || !upload || !readback || !queue || !cmd || !upload.contents || !readback.contents) {
            fprintf(stderr, "FAIL: resource allocation\n");
            return 1;
        }

        unsigned char *src = (unsigned char *)upload.contents;
        memset(src, 0, 1792);

        // Mip 0: 4x4, red cols 0-1, green cols 2-3
        for (NSUInteger y = 0; y < 4; y++) {
            for (NSUInteger x = 0; x < 4; x++) {
                unsigned char *p = src + y * 256 + x * 4;
                p[0] = x < 2 ? 255 : 0; // R
                p[1] = x < 2 ? 0 : 255; // G
                p[2] = 0;               // B
                p[3] = 255;
            }
        }
        // Mip 1: 2x2, blue
        for (NSUInteger y = 0; y < 2; y++) {
            for (NSUInteger x = 0; x < 2; x++) {
                unsigned char *p = src + 1024 + y * 256 + x * 4;
                p[0] = 0;
                p[1] = 0;
                p[2] = 255;
                p[3] = 255;
            }
        }
        // Mip 2: 1x1, yellow
        src[1536] = 255;
        src[1537] = 255;
        src[1538] = 0;
        src[1539] = 255;

        memset(readback.contents, 0, rowBytes * height);
        id<MTLBlitCommandEncoder> uploadBlit = [cmd blitCommandEncoder];
        if (!uploadBlit) {
            fprintf(stderr, "FAIL: upload blit encoder\n");
            return 1;
        }
        const NSUInteger offsets[3] = {0, 1024, 1536};
        const NSUInteger sizes[3] = {4, 2, 1};
        for (NSUInteger levelIndex = 0; levelIndex < 3; levelIndex++) {
            NSUInteger size = sizes[levelIndex];
            [uploadBlit copyFromBuffer:upload
                          sourceOffset:offsets[levelIndex]
                     sourceBytesPerRow:256
                   sourceBytesPerImage:256 * size
                            sourceSize:MTLSizeMake(size, size, 1)
                             toTexture:texture
                      destinationSlice:0
                      destinationLevel:levelIndex
                     destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        [uploadBlit endEncoding];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        pass.depthAttachment.clearDepth = 1.0;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        if (!enc) {
            fprintf(stderr, "FAIL: render encoder\n");
            return 1;
        }
        [enc setRenderPipelineState:pipeline];
        [enc setDepthStencilState:depthState];
        [enc setFragmentTexture:texture atIndex:0];
        [enc setFragmentSamplerState:sampler atIndex:0];

        // Rectangle covers x=32, 128, 223
        const float params[2] = {0.5f, 0.8f};
        float lod = mipOne ? 1.0f : (mipBlend ? 0.5f : 0.0f);
        [enc setVertexBytes:params length:sizeof(params) atIndex:0];
        [enc setFragmentBytes:&lod length:sizeof(lod) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [enc endEncoding];

        id<MTLBlitCommandEncoder> readBlit = [cmd blitCommandEncoder];
        if (!readBlit) {
            fprintf(stderr, "FAIL: readback blit encoder\n");
            return 1;
        }
        [readBlit copyFromTexture:color
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(width, height, 1)
                         toBuffer:readback
                destinationOffset:0
           destinationBytesPerRow:rowBytes
         destinationBytesPerImage:rowBytes * height];
        [readBlit endEncoding];

        [cmd commit];
        [cmd waitUntilCompleted];

        if (cmd.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "FAIL: command status=%lu error=%s\n", (unsigned long)cmd.status, cmd.error ? cmd.error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        const unsigned char *pixels = (const unsigned char *)readback.contents;
        const unsigned char *corner = pixels + 8 * rowBytes + 8 * 4;
        const unsigned char *left   = pixels + 128 * rowBytes + 32 * 4;
        const unsigned char *middle = pixels + 128 * rowBytes + 128 * 4;
        const unsigned char *right  = pixels + 128 * rowBytes + 223 * 4;

        int ok = 1;
        ok &= checkPixel("corner", corner, 0, 0, 0, 255);
        if (nearest) {
            ok &= checkPixel("left", left, 0, 0, 255, 255);
            ok &= checkPixel("middle", middle, 0, 255, 0, 255);
            ok &= checkPixel("right", right, 0, 255, 0, 255);
        } else if (linear) {
            ok &= checkPixel("left", left, 0, 0, 255, 255);
            ok &= checkPixel("middle", middle, 0, 129, 126, 255);
            ok &= checkPixel("right", right, 0, 255, 0, 255);
        } else if (mipOne) {
            ok &= checkPixel("left", left, 255, 0, 0, 255);
            ok &= checkPixel("middle", middle, 255, 0, 0, 255);
            ok &= checkPixel("right", right, 255, 0, 0, 255);
        } else {
            // mipBlend: 50% mip 0 + 50% blue mip 1
            ok &= checkPixel("left", left, 128, 0, 128, 255);
            ok &= checkPixel("middle", middle, 128, 65, 63, 255);
            ok &= checkPixel("right", right, 128, 128, 0, 255);
        }
        printf("RESULT=%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
