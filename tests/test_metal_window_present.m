#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <stddef.h>
#import <stdlib.h>
#import <stdio.h>

struct Vertex {
    simd_float2 position;
    simd_float4 color;
};

static id<MTLDevice> findDevice(NSString *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        NSString *name = d.name.lowercaseString;
        if ([which isEqualToString:@"intel"] && [name containsString:@"intel"]) return d;
        if ([which isEqualToString:@"nvidia"] && ([name containsString:@"nvidia"] || [name containsString:@"rtx"])) return d;
    }
    return nil;
}

@interface RenderView : NSView
@end

@implementation RenderView
- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}
@end

@interface AppController : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) NSString *gpuName;
@property (nonatomic, strong) NSString *mode; // @"A" or @"B"
@property (nonatomic, assign) unsigned currentFrame;
@property (nonatomic, assign) unsigned totalFrames;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL isRendering;
@end

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSRect frame = NSMakeRect(200, 200, 512, 512);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = [NSString stringWithFormat:@"Metal Present Test: GPU=%@ Mode=%@", self.gpuName, self.mode];

    RenderView *view = [[RenderView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    self.metalLayer = (CAMetalLayer *)view.layer;
    self.metalLayer.device = self.device;
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalLayer.framebufferOnly = YES;
    self.metalLayer.drawableSize = CGSizeMake(512, 512);

    self.window.contentView = view;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self setupPipeline];
    self.currentFrame = 0;
    self.isRendering = NO;

    NSLog(@"Starting presentation loop: Mode=%@ (%@), TotalFrames=%u",
          self.mode,
          [self.mode isEqualToString:@"A"] ? @"Standard presentDrawable: before commit" : @"Diagnostic heldDrawable present on GPU completion",
          self.totalFrames);

    // Schedule 60 FPS rendering timer
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                  target:self
                                                selector:@selector(renderFrame)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)setupPipeline {
    self.queue = [self.device newCommandQueue];

    NSString *source = @""
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VertexIn {\n"
        "    float2 position [[attribute(0)]];\n"
        "    float4 color    [[attribute(1)]];\n"
        "};\n"
        "struct VertexOut {\n"
        "    float4 position [[position]];\n"
        "    float4 color;\n"
        "};\n"
        "vertex VertexOut vs(VertexIn in [[stage_in]],\n"
        "                    constant float &angle [[buffer(1)]]) {\n"
        "    VertexOut out;\n"
        "    float s = sin(angle);\n"
        "    float c = cos(angle);\n"
        "    float2 rot = float2(in.position.x * c - in.position.y * s,\n"
        "                        in.position.x * s + in.position.y * c);\n"
        "    out.position = float4(rot, 0.5, 1.0);\n"
        "    out.color = in.color;\n"
        "    return out;\n"
        "}\n"
        "fragment float4 fs(VertexOut in [[stage_in]]) {\n"
        "    return in.color;\n"
        "}\n";

    NSError *error = nil;
    id<MTLLibrary> lib = [self.device newLibraryWithSource:source options:nil error:&error];
    if (!lib) {
        NSLog(@"FAIL: Shader compilation error: %@", error);
        [NSApp terminate:nil];
        return;
    }

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = offsetof(struct Vertex, position);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat4;
    vd.attributes[1].offset = offsetof(struct Vertex, color);
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(struct Vertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    NSLog(@"Vertex layout: pos=%zu color=%zu stride=%zu",
          offsetof(struct Vertex, position),
          offsetof(struct Vertex, color),
          sizeof(struct Vertex));

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.vertexDescriptor = vd;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    self.pipeline = [self.device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!self.pipeline) {
        NSLog(@"FAIL: Pipeline creation error: %@", error);
        [NSApp terminate:nil];
    }
}

- (void)renderFrame {
    if (self.isRendering) return;

    if (self.currentFrame >= self.totalFrames) {
        [self.timer invalidate];
        NSLog(@"Finished %u frames. Exiting cleanly.", self.totalFrames);
        [NSApp terminate:nil];
        return;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        return;
    }

    unsigned frameNum = self.currentFrame++;
    self.isRendering = YES;

    struct Vertex vertices[3] = {
        { {  0.0f,  0.75f }, { 1.0f, 0.0f, 0.0f, 1.0f } }, // Red top
        { { -0.75f, -0.75f }, { 0.0f, 1.0f, 0.0f, 1.0f } }, // Green bottom-left
        { {  0.75f, -0.75f }, { 0.0f, 0.0f, 1.0f, 1.0f } }  // Blue bottom-right
    };

    float angle = (float)frameNum * 0.05f;

    id<MTLBuffer> vertexBuffer = [self.device newBufferWithBytes:vertices
                                                          length:sizeof(vertices)
                                                         options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cmd = [self.queue commandBuffer];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    float bg = (float)((frameNum * 3) % 256) / 1024.0f;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(bg, bg, bg, 1.0);

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:self.pipeline];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&angle length:sizeof(angle) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    BOOL modeB = [self.mode isEqualToString:@"B"];
    id<CAMetalDrawable> heldDrawable = modeB ? drawable : nil;
    __weak typeof(self) weakSelf = self;
    if (!modeB) {
        [cmd presentDrawable:drawable];
    }
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        MTLCommandBufferStatus status = finished.status;
        NSError *gpuError = finished.error;
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController *controller = weakSelf;
            if (!controller) return;
            if (status != MTLCommandBufferStatusCompleted) {
                NSLog(@"FAIL frame=%u status=%lu error=%@", frameNum, (unsigned long)status, gpuError);
                [controller.timer invalidate];
                exit(1);
            }
            if (modeB) {
                [heldDrawable present];
            }
            NSLog(@"COMPLETED frame=%u mode=%@", frameNum, controller.mode);
            controller.isRendering = NO;
        });
    }];
    [cmd commit];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s intel|nvidia A|B [num_frames]\n", argv[0]);
            return 2;
        }

        NSString *gpuArg = [NSString stringWithUTF8String:argv[1]];
        NSString *modeArg = [NSString stringWithUTF8String:argv[2]];
        unsigned totalFrames = (argc >= 4) ? (unsigned)atoi(argv[3]) : 60;

        id<MTLDevice> device = findDevice(gpuArg);
        if (!device) {
            fprintf(stderr, "FAIL: GPU not found for '%s'\n", argv[1]);
            return 1;
        }

        printf("GPU: %s\nMode: %s\nFrames: %u\n", device.name.UTF8String, modeArg.UTF8String, totalFrames);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppController *controller = [AppController new];
        controller.gpuName = gpuArg;
        controller.mode = modeArg;
        controller.device = device;
        controller.totalFrames = totalFrames;
        app.delegate = controller;

        [app run];
        return 0;
    }
}
