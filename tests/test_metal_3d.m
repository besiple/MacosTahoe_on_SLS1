#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

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

        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if ([cmdBuf status] == MTLCommandBufferStatusCompleted) {
            printf("[+] Command buffer completed successfully! 3D triangle rendered on RTX 3050 Ti.\n");
        } else {
            printf("[-] Command buffer failed with status: %lu\n", (unsigned long)[cmdBuf status]);
            if ([cmdBuf error]) {
                printf("    Error: %s\n", [[[cmdBuf error] localizedDescription] UTF8String]);
            }
        }
    }
    return 0;
}
