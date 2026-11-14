#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdlib.h>
#import <string.h>

static int checkPixel(const char *label, const unsigned char *p, int b, int g, int r, int a) {
    printf("%-8s BGRA = %3u %3u %3u %3u | expected %3d %3d %3d %3d\n", label, p[0], p[1], p[2], p[3], b, g, r, a);
    const int tolerance = 3;
    return abs((int)p[0] - b) <= tolerance &&
           abs((int)p[1] - g) <= tolerance &&
           abs((int)p[2] - r) <= tolerance &&
           abs((int)p[3] - a) <= tolerance;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s intel|nvidia sample|depth|combined\n", argv[0]);
            return 2;
        }
        NSString *gpuArg = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        BOOL isIntel = [gpuArg isEqualToString:@"intel"];
        BOOL isNvidia = [gpuArg isEqualToString:@"nvidia"];
        BOOL sampleOnly = [mode isEqualToString:@"sample"];
        BOOL depthOnly = [mode isEqualToString:@"depth"];
        BOOL combined = [mode isEqualToString:@"combined"];
        if ((!isIntel && !isNvidia) || (!sampleOnly && !depthOnly && !combined)) {
            fprintf(stderr, "Invalid GPU or mode\n");
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
            "                           constant float2 &uv [[buffer(0)]]) {\n"
            "    return tex.sample(s, uv);\n"
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

        // 2x1 RGBA8 texture: red texel, green texel.
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:1 mipmapped:NO];
        textureDesc.storageMode = MTLStorageModePrivate;
        textureDesc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];

        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];

        // A 256-byte row avoids ambiguity around row alignment.
        id<MTLBuffer> upload = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback = [device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];

        if (!depthState || !color || !depth || !texture || !sampler || !upload || !readback || !queue || !cmd || !upload.contents || !readback.contents) {
            fprintf(stderr, "FAIL: resource allocation\n");
            return 1;
        }

        memset(upload.contents, 0, 256);
        const unsigned char texels[8] = {
            255, 0, 0, 255,   // red
            0, 255, 0, 255    // green
        };
        memcpy(upload.contents, texels, sizeof(texels));
        memset(readback.contents, 0, rowBytes * height);

        id<MTLBlitCommandEncoder> uploadBlit = [cmd blitCommandEncoder];
        if (!uploadBlit) {
            fprintf(stderr, "FAIL: upload blit encoder\n");
            return 1;
        }
        [uploadBlit copyFromBuffer:upload
                      sourceOffset:0
                 sourceBytesPerRow:256
               sourceBytesPerImage:256
                        sourceSize:MTLSizeMake(2, 1, 1)
                         toTexture:texture
                  destinationSlice:0
                  destinationLevel:0
                 destinationOrigin:MTLOriginMake(0, 0, 0)];
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

        const float nearParams[2] = {0.25f, 0.5f};
        const float farParams[2]  = {0.75f, 0.8f};
        const float red[4]   = {1, 0, 0, 1};
        const float green[4] = {0, 1, 0, 1};
        const float redUV[2]   = {0.25f, 0.5f};
        const float greenUV[2] = {0.75f, 0.5f};

        // Near red: smaller rectangle, submitted first.
        [enc setVertexBytes:nearParams length:sizeof(nearParams) atIndex:0];
        if (depthOnly) [enc setFragmentBytes:red length:sizeof(red) atIndex:0];
        else [enc setFragmentBytes:redUV length:sizeof(redUV) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

        // Far green: larger rectangle, submitted second.
        [enc setVertexBytes:farParams length:sizeof(farParams) atIndex:0];
        if (depthOnly) [enc setFragmentBytes:green length:sizeof(green) atIndex:0];
        else [enc setFragmentBytes:greenUV length:sizeof(greenUV) atIndex:0];
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

        const unsigned char *pixels = readback.contents;
        const unsigned char *corner = pixels + 8 * rowBytes + 8 * 4;
        const unsigned char *side   = pixels + 128 * rowBytes + 40 * 4;
        const unsigned char *center = pixels + 128 * rowBytes + 128 * 4;

        int ok = 1;
        ok &= checkPixel("corner", corner, 0, 0, 0, 255);
        ok &= checkPixel("side", side, 0, 255, 0, 255);
        if (sampleOnly)
            ok &= checkPixel("center", center, 0, 255, 0, 255);
        else
            ok &= checkPixel("center", center, 0, 0, 255, 255);

        printf("RESULT=%s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
