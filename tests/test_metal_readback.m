#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <stdlib.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        id<MTLDevice> nvDevice = nil;
        for (id<MTLDevice> d in devices) {
            if ([[d name] containsString:@"NVIDIA"] || [[d name] containsString:@"RTX"]) {
                nvDevice = d;
                break;
            }
        }
        if (!nvDevice) {
            printf("[-] NVIDIA Metal device not found!\n");
            return 1;
        }
        printf("[+] Found target GPU: %s\n", [[nvDevice name] UTF8String]);

        // Shader source: 3D colored triangle
        NSString *shaderSource = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct VertexOut {\n"
            "    float4 position [[position]];\n"
            "    float4 color;\n"
            "};\n"
            "vertex VertexOut vertex_main(uint vid [[vertex_id]]) {\n"
            "    const float2 pos[3] = { float2(0.0, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5) };\n"
            "    const float4 col[3] = { float4(1,0,0,1), float4(0,1,0,1), float4(0,0,1,1) };\n"
            "    VertexOut out;\n"
            "    out.position = float4(pos[vid], 0.0, 1.0);\n"
            "    out.color = col[vid];\n"
            "    return out;\n"
            "}\n"
            "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
            "    return in.color;\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> library = [nvDevice newLibraryWithSource:shaderSource options:nil error:&error];
        if (!library) {
            printf("[-] Failed to compile Metal library: %s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }
        printf("[+] Metal library compiled successfully!\n");

        id<MTLFunction> vertFunc = [library newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fragFunc = [library newFunctionWithName:@"fragment_main"];

        MTLRenderPipelineDescriptor *psoDesc = [[MTLRenderPipelineDescriptor alloc] init];
        psoDesc.vertexFunction = vertFunc;
        psoDesc.fragmentFunction = fragFunc;
        psoDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        id<MTLRenderPipelineState> pso = [nvDevice newRenderPipelineStateWithDescriptor:psoDesc error:&error];
        if (!pso) {
            printf("[-] Failed to create Render PSO: %s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }
        printf("[+] Render Pipeline State created!\n");

        // Target texture
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:256
                                                                                          height:256
                                                                                       mipmapped:NO];
        texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> targetTex = [nvDevice newTextureWithDescriptor:texDesc];

        // Command Buffer & Encoder
        id<MTLCommandQueue> queue = [nvDevice newCommandQueue];
        id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];

        MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = targetTex;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);

        id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
        [encoder setRenderPipelineState:pso];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        // BGRA8, 256 x 256; 1024 bytes per row.
        const NSUInteger width = 256, height = 256;
        const NSUInteger rowBytes = width * 4;
        id<MTLBuffer> readback = [nvDevice newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        if (!targetTex || !queue || !cmdBuf || !encoder || !readback) {
            fprintf(stderr, "FAIL: Metal resource creation failed\n");
            return 1;
        }
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        if (!blit) {
            fprintf(stderr, "FAIL: blit encoder unavailable\n");
            return 1;
        }
        [blit copyFromTexture:targetTex
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                     toBuffer:readback
            destinationOffset:0
       destinationBytesPerRow:rowBytes
     destinationBytesPerImage:rowBytes * height];
        [blit endEncoding];

        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "FAIL: command status=%lu error=%s\n", (unsigned long)cmdBuf.status, cmdBuf.error ? cmdBuf.error.localizedDescription.UTF8String : "(none)");
            return 1;
        }

        const unsigned char *bytes = (const unsigned char *)readback.contents;
        if (!bytes) {
            fprintf(stderr, "FAIL: readback buffer has no CPU contents\n");
            return 1;
        }

        // Pixel order is BGRA, not RGBA.
        const unsigned char *corner = bytes + 8 * rowBytes + 8 * 4;
        const unsigned char *center = bytes + 128 * rowBytes + 128 * 4;
        printf("corner BGRA = %u %u %u %u\n", corner[0], corner[1], corner[2], corner[3]);
        printf("center BGRA = %u %u %u %u\n", center[0], center[1], center[2], center[3]);

        // Background clear: RGB ≈ 26. Triangle center: R ≈ 128, G/B ≈ 64. Tolerance accommodates rasterization/rounding.
        int cornerOK = abs((int)corner[0] - 26) <= 8 && abs((int)corner[1] - 26) <= 8 && abs((int)corner[2] - 26) <= 8 && corner[3] >= 245;
        int centerOK = abs((int)center[0] - 64) <= 24 && abs((int)center[1] - 64) <= 24 && abs((int)center[2] - 128) <= 24 && center[3] >= 245;

        printf("READBACK_%s\n", (cornerOK && centerOK) ? "PASS" : "FAIL");
        return (cornerOK && centerOK) ? 0 : 1;
    }
}
