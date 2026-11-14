#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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
        if (!nvDevice) return 1;

        NSString *shaderSource = @""
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct VertexIn {\n"
            "    float3 position [[attribute(0)]];\n"
            "    float2 uv [[attribute(1)]];\n"
            "};\n"
            "struct VertexOut {\n"
            "    float4 position [[position]];\n"
            "    float2 uv;\n"
            "};\n"
            "vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {\n"
            "    VertexOut out;\n"
            "    out.position = float4(in.position, 1.0);\n"
            "    out.uv = in.uv;\n"
            "    return out;\n"
            "}\n"
            "fragment float4 fragment_main(VertexOut in [[stage_in]],\n"
            "                              texture2d<float> tex [[texture(0)]],\n"
            "                              sampler smp [[sampler(0)]]) {\n"
            "    return tex.sample(smp, in.uv);\n"
            "}\n";

        NSError *error = nil;
        id<MTLLibrary> library = [nvDevice newLibraryWithSource:shaderSource options:nil error:&error];
        if (!library) {
            printf("[-] Library error: %s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }

        MTLVertexDescriptor *vDesc = [MTLVertexDescriptor vertexDescriptor];
        vDesc.attributes[0].format = MTLVertexFormatFloat3;
        vDesc.attributes[0].offset = 0;
        vDesc.attributes[0].bufferIndex = 0;
        vDesc.attributes[1].format = MTLVertexFormatFloat2;
        vDesc.attributes[1].offset = sizeof(float)*3;
        vDesc.attributes[1].bufferIndex = 0;
        vDesc.layouts[0].stride = sizeof(float)*5;

        MTLRenderPipelineDescriptor *psoDesc = [[MTLRenderPipelineDescriptor alloc] init];
        psoDesc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
        psoDesc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
        psoDesc.vertexDescriptor = vDesc;
        psoDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        psoDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        id<MTLRenderPipelineState> pso = [nvDevice newRenderPipelineStateWithDescriptor:psoDesc error:&error];
        if (!pso) {
            printf("[-] PSO error with Depth + Sampler: %s\n", [[error localizedDescription] UTF8String]);
            return 1;
        }
        printf("[+] Pipeline state with Depth + Sampler created successfully!\n");

        // Test Depth Stencil State
        MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
        dsDesc.depthCompareFunction = MTLCompareFunctionLess;
        dsDesc.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dsState = [nvDevice newDepthStencilStateWithDescriptor:dsDesc];
        printf("[+] DepthStencilState created: %p\n", dsState);

        // Test Texture creation with mipmaps
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:512
                                                                                          height:512
                                                                                       mipmapped:YES];
        id<MTLTexture> sampleTex = [nvDevice newTextureWithDescriptor:texDesc];
        printf("[+] Mipmapped Texture created: %p (mip levels: %lu)\n", sampleTex, (unsigned long)[sampleTex mipmapLevelCount]);

        // Test Sampler creation
        MTLSamplerDescriptor *smpDesc = [[MTLSamplerDescriptor alloc] init];
        smpDesc.minFilter = MTLSamplerMinMagFilterLinear;
        smpDesc.magFilter = MTLSamplerMinMagFilterLinear;
        smpDesc.mipFilter = MTLSamplerMipFilterLinear;
        id<MTLSamplerState> sampler = [nvDevice newSamplerStateWithDescriptor:smpDesc];
        printf("[+] Trilinear Sampler created: %p\n", sampler);
    }
    return 0;
}

// Add execution and draw call
int run_draw() {
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        id<MTLDevice> nvDevice = nil;
        for (id<MTLDevice> d in devices) {
            if ([[d name] containsString:@"NVIDIA"] || [[d name] containsString:@"RTX"]) {
                nvDevice = d;
                break;
            }
        }
        id<MTLCommandQueue> queue = [nvDevice newCommandQueue];
        id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];

        // Create color + depth textures
        MTLTextureDescriptor *colDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:512 height:512 mipmapped:NO];
        colDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> colTex = [nvDevice newTextureWithDescriptor:colDesc];

        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:512 height:512 mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> depthTex = [nvDevice newTextureWithDescriptor:depthDesc];

        MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = colTex;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.3, 0.4, 1.0);

        passDesc.depthAttachment.texture = depthTex;
        passDesc.depthAttachment.loadAction = MTLLoadActionClear;
        passDesc.depthAttachment.storeAction = MTLStoreActionDontCare;
        passDesc.depthAttachment.clearDepth = 1.0;

        id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
        [encoder endEncoding];

        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        printf("[+] Depth Render Pass completed with status: %lu\n", (unsigned long)[cmdBuf status]);
        if ([cmdBuf error]) {
            printf("[-] Error: %s\n", [[[cmdBuf error] localizedDescription] UTF8String]);
        }
    }
    return 0;
}
