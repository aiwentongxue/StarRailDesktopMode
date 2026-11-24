#import "Runtime.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <atomic>
#include <mutex>

__attribute__((availability(maccatalyst,introduced=16.0)))
@interface SRDMTemporalResources : NSObject
@property(nonatomic, strong) id<MTLFXTemporalScaler> scaler;
@property(nonatomic, strong) id<MTLTexture> color;
@property(nonatomic, strong) id<MTLTexture> depth;
@property(nonatomic, strong) id<MTLTexture> motion;
@property(nonatomic, strong) id<MTLTexture> output;
@property(nonatomic, strong) id<MTLRenderPipelineState> prepareInputs;
@property(nonatomic, strong) id<MTLRenderPipelineState> presentOutput;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, weak) id<MTLTexture> previousDepth;
@property(nonatomic) CFTimeInterval lastFrame;
@property(nonatomic) unsigned history;
@end

@implementation SRDMTemporalResources
@end

@interface SRDMTemporalInputs : NSObject
@property(nonatomic, strong) id<MTLTexture> depth;
@property(nonatomic, strong) id<MTLTexture> motion;
@end

@implementation SRDMTemporalInputs
@end

namespace {

std::atomic<bool> temporalEnabled;
std::atomic<bool> commandFailed;
std::atomic<unsigned> historyGeneration;
char inputsKey;
char resourcesKey;
std::mutex hookLock;

NSString *const ShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

vertex float4 fullScreen(uint id [[vertex_id]]) {
    return float4(id == 1 ? 3.0f : -1.0f, id == 2 ? -3.0f : 1.0f, 0.0f, 1.0f);
}

struct Inputs {
    half4 color [[color(0)]];
    float depth [[color(1)]];
    half2 motion [[color(2)]];
};

fragment Inputs prepareInputs(float4 pixel [[position]],
                              texture2d<float, access::read> colorTexture [[texture(0)]],
                              depth2d<float> depthTexture [[texture(1)]],
                              texture2d<float> motionTexture [[texture(2)]]) {
    constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
    uint2 p = uint2(pixel.xy);
    float2 uv = pixel.xy / float2(colorTexture.get_width(), colorTexture.get_height());
    float4 color = colorTexture.read(p);
    float3 linear = select(color.rgb / 12.92f, powr((color.rgb + 0.055f) / 1.055f, 2.4f),
                           color.rgb > 0.04045f);

    // The game's RG8 target stores sign-preserving square-root UV displacement.
    float2 encoded = (motionTexture.sample(nearest, uv).rg * 255.0f - 127.0f) / 127.0f;
    float2 previousLocation = -encoded * abs(encoded);
    return {half4(half3(linear), half(color.a)), depthTexture.sample(nearest, uv),
            half2(previousLocation)};
}

fragment float4 presentOutput(float4 pixel [[position]],
                              texture2d<float, access::read> source [[texture(0)]]) {
    float4 color = source.read(uint2(pixel.xy));
    float3 linear = saturate(color.rgb);
    color.rgb = select(linear * 12.92f, 1.055f * powr(linear, 1.0f / 2.4f) - 0.055f,
                       linear > 0.0031308f);
    return color;
}
)";

bool IsReadable(id<MTLTexture> texture, MTLPixelFormat format) {
    return texture && texture.pixelFormat == format && texture.storageMode != MTLStorageModeMemoryless &&
           texture.textureType == MTLTextureType2D && (texture.usage & MTLTextureUsageShaderRead);
}

void CaptureInputs(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *pass) {
    if (!temporalEnabled || commandFailed ||
        pass.colorAttachments[0].texture.pixelFormat != MTLPixelFormatRG8Unorm ||
        pass.colorAttachments[1].texture.pixelFormat != MTLPixelFormatR8Unorm) return;
    id<MTLTexture> motion = pass.colorAttachments[0].texture;
    id<MTLTexture> depth = pass.depthAttachment.texture;
    if (motion.width < 320 || !IsReadable(motion, MTLPixelFormatRG8Unorm) ||
        !IsReadable(depth, MTLPixelFormatDepth32Float_Stencil8) ||
        depth.width != motion.width || depth.height != motion.height) return;
    auto *record = [SRDMTemporalInputs new];
    record.motion = motion;
    record.depth = depth;
    objc_setAssociatedObject(cb, &inputsKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

id<MTLTexture> MakeTexture(id<MTLDevice> device, MTLPixelFormat format, MTLTextureUsage usage,
                           NSUInteger width, NSUInteger height, NSString *label) {
    auto *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width
                                                                          height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    texture.label = label;
    return texture;
}

__attribute__((availability(maccatalyst,introduced=16.0)))
SRDMTemporalResources *MakeResources(id<MTLFXSpatialScaler> spatial, id<MTLCommandQueue> queue) {
    id<MTLDevice> device = queue.device;
    auto *descriptor = [MTLFXTemporalScalerDescriptor new];
    descriptor.inputWidth = spatial.inputWidth;
    descriptor.inputHeight = spatial.inputHeight;
    descriptor.outputWidth = spatial.outputWidth;
    descriptor.outputHeight = spatial.outputHeight;
    descriptor.colorTextureFormat = MTLPixelFormatRGBA16Float;
    descriptor.depthTextureFormat = MTLPixelFormatR32Float;
    descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
    descriptor.outputTextureFormat = MTLPixelFormatRGBA16Float;
    if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) return nil;
    id<MTLFXTemporalScaler> scaler = [descriptor newTemporalScalerWithDevice:device];
    if (!scaler) return nil;

    auto *resources = [SRDMTemporalResources new];
    resources.queue = queue;
    resources.scaler = scaler;
    resources.color = MakeTexture(device, descriptor.colorTextureFormat, scaler.colorTextureUsage | MTLTextureUsageRenderTarget,
                                  descriptor.inputWidth, descriptor.inputHeight, @"SRDM Temporal color");
    resources.depth = MakeTexture(device, descriptor.depthTextureFormat, scaler.depthTextureUsage | MTLTextureUsageRenderTarget,
                                  descriptor.inputWidth, descriptor.inputHeight, @"SRDM Temporal depth");
    resources.motion = MakeTexture(device, descriptor.motionTextureFormat, scaler.motionTextureUsage | MTLTextureUsageRenderTarget,
                                   descriptor.inputWidth, descriptor.inputHeight, @"SRDM Temporal motion");
    resources.output = MakeTexture(device, descriptor.outputTextureFormat, scaler.outputTextureUsage | MTLTextureUsageShaderRead,
                                   descriptor.outputWidth, descriptor.outputHeight, @"SRDM Temporal output");

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:ShaderSource options:nil error:&error];
    if (!library) {
        NSLog(@"[StarRailDesktopMode] Temporal shader %@", error);
        return nil;
    }
    auto *pipeline = [MTLRenderPipelineDescriptor new];
    pipeline.vertexFunction = [library newFunctionWithName:@"fullScreen"];
    pipeline.fragmentFunction = [library newFunctionWithName:@"prepareInputs"];
    pipeline.colorAttachments[0].pixelFormat = resources.color.pixelFormat;
    pipeline.colorAttachments[1].pixelFormat = resources.depth.pixelFormat;
    pipeline.colorAttachments[2].pixelFormat = resources.motion.pixelFormat;
    resources.prepareInputs = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
    if (!resources.prepareInputs) {
        NSLog(@"[StarRailDesktopMode] Temporal input pipeline %@", error);
        return nil;
    }
    pipeline.fragmentFunction = [library newFunctionWithName:@"presentOutput"];
    pipeline.colorAttachments[0].pixelFormat = spatial.outputTextureFormat;
    pipeline.colorAttachments[1].pixelFormat = MTLPixelFormatInvalid;
    pipeline.colorAttachments[2].pixelFormat = MTLPixelFormatInvalid;
    resources.presentOutput = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
    if (!resources.presentOutput || !resources.color || !resources.depth || !resources.motion || !resources.output) {
        NSLog(@"[StarRailDesktopMode] Temporal output pipeline or textures %@", error);
        return nil;
    }
    scaler.colorTexture = resources.color;
    scaler.depthTexture = resources.depth;
    scaler.motionTexture = resources.motion;
    scaler.outputTexture = resources.output;
    scaler.preExposure = 1;
    scaler.depthReversed = YES;
    scaler.inputContentWidth = descriptor.inputWidth;
    scaler.inputContentHeight = descriptor.inputHeight;
    scaler.motionVectorScaleX = descriptor.inputWidth;
    scaler.motionVectorScaleY = descriptor.inputHeight;
    return resources;
}

void SetAttachment(MTLRenderPassDescriptor *pass, NSUInteger index, id<MTLTexture> texture) {
    auto *attachment = pass.colorAttachments[index];
    attachment.texture = texture;
    attachment.loadAction = MTLLoadActionDontCare;
    attachment.storeAction = MTLStoreActionStore;
}

__attribute__((availability(maccatalyst,introduced=16.0)))
bool EncodeTemporal(id<MTLFXSpatialScaler> spatial, id<MTLCommandBuffer> cb, SRDMTemporalInputs *inputs) {
    if (!temporalEnabled || commandFailed || !inputs) return false;
    id<MTLTexture> color = spatial.colorTexture;
    id<MTLTexture> output = spatial.outputTexture;
    // The game can round geometry and post-processing sizes one pixel apart.
    // Match only that difference and map the auxiliary inputs by normalized coordinates.
    const auto adjacent = [](NSUInteger a, NSUInteger b) { return a > b ? a - b <= 1 : b - a <= 1; };
    if (!adjacent(inputs.depth.width, color.width) || !adjacent(inputs.depth.height, color.height) ||
        !IsReadable(color, MTLPixelFormatRGBA8Unorm) ||
        output.pixelFormat != MTLPixelFormatRGBA8Unorm || !(output.usage & MTLTextureUsageRenderTarget) ||
        output.storageMode == MTLStorageModeMemoryless ||
        spatial.colorProcessingMode != MTLFXSpatialScalerColorProcessingModePerceptual ||
        spatial.inputContentWidth != color.width || spatial.inputContentHeight != color.height ||
        spatial.inputWidth != color.width || spatial.inputHeight != color.height ||
        spatial.outputWidth != output.width || spatial.outputHeight != output.height ||
        output.width < color.width || output.height < color.height) return false;

    auto *resources = (SRDMTemporalResources *)objc_getAssociatedObject(spatial, &resourcesKey);
    if (!resources || resources.queue != cb.commandQueue) {
        resources = MakeResources(spatial, cb.commandQueue);
        if (!resources) {
            commandFailed = true;
            return false;
        }
        objc_setAssociatedObject(spatial, &resourcesKey, resources, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    auto *prepare = [MTLRenderPassDescriptor renderPassDescriptor];
    SetAttachment(prepare, 0, resources.color);
    SetAttachment(prepare, 1, resources.depth);
    SetAttachment(prepare, 2, resources.motion);
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:prepare];
    if (!encoder) return false;
    encoder.label = @"SRDM Prepare MetalFX Temporal";
    [encoder setRenderPipelineState:resources.prepareInputs];
    [encoder setFragmentTexture:color atIndex:0];
    [encoder setFragmentTexture:inputs.depth atIndex:1];
    [encoder setFragmentTexture:inputs.motion atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    const CFTimeInterval now = CACurrentMediaTime();
    const unsigned history = historyGeneration.load();
    const bool reset = resources.history != history || resources.previousDepth != inputs.depth ||
                       now - resources.lastFrame > 0.25;
    resources.scaler.reset = reset;
    resources.history = history;
    resources.previousDepth = inputs.depth;
    resources.lastFrame = now;
    [resources.scaler encodeToCommandBuffer:cb];

    auto *present = [MTLRenderPassDescriptor renderPassDescriptor];
    SetAttachment(present, 0, output);
    encoder = [cb renderCommandEncoderWithDescriptor:present];
    if (!encoder) return false;
    encoder.label = @"SRDM Present MetalFX Temporal";
    [encoder setRenderPipelineState:resources.presentOutput];
    [encoder setFragmentTexture:resources.output atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    const NSUInteger inputWidth = color.width, inputHeight = color.height;
    const NSUInteger outputWidth = output.width, outputHeight = output.height;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // Unity can create command buffers without retaining their texture arguments.
        (void)resources.scaler;
        (void)inputs.depth;
        if (completed.status != MTLCommandBufferStatusCompleted) {
            if (!commandFailed.exchange(true)) NSLog(@"[StarRailDesktopMode] Temporal GPU %@", completed.error);
        } else if (reset) {
            NSLog(@"[StarRailDesktopMode] Temporal %lux%lu → %lux%lu completed after reset",
                  inputWidth, inputHeight, outputWidth, outputHeight);
        }
    }];
    return true;
}

__attribute__((availability(maccatalyst,introduced=16.0)))
void ObserveScaler(id<MTLFXSpatialScaler> scaler) {
    if (!scaler) return;
    static NSMutableSet<Class> *hooked = [NSMutableSet set];
    std::lock_guard guard(hookLock);
    Class cls = object_getClass(scaler);
    if ([hooked containsObject:cls]) return;

    SEL selector = @selector(encodeToCommandBuffer:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    auto original = reinterpret_cast<void(*)(id, SEL, id)>(method_getImplementation(method));
    IMP replacement = imp_implementationWithBlock(^(id<MTLFXSpatialScaler> spatial, id<MTLCommandBuffer> cb) {
        auto *inputs = (SRDMTemporalInputs *)objc_getAssociatedObject(cb, &inputsKey);
        if (inputs) objc_setAssociatedObject(cb, &inputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (EncodeTemporal(spatial, cb, inputs)) return;
        auto *resources = (SRDMTemporalResources *)objc_getAssociatedObject(spatial, &resourcesKey);
        resources.lastFrame = 0;
        original(spatial, selector, cb);
    });
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    [hooked addObject:cls];
}

bool ObserveCommandBuffer(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return false;
    IMP original = method_getImplementation(method);
    IMP replacement;
    if (selector == @selector(commit)) {
        replacement = imp_implementationWithBlock(^(id<MTLCommandBuffer> cb) {
            if (objc_getAssociatedObject(cb, &inputsKey)) {
                objc_setAssociatedObject(cb, &inputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            reinterpret_cast<void(*)(id, SEL)>(original)(cb, selector);
        });
    } else if (selector == sel_registerName("renderCommandEncoderWithDescriptor:options:")) {
        replacement = imp_implementationWithBlock(^id(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *pass, NSUInteger options) {
            CaptureInputs(cb, pass);
            return reinterpret_cast<id(*)(id, SEL, id, NSUInteger)>(original)(cb, selector, pass, options);
        });
    } else {
        replacement = imp_implementationWithBlock(^id(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *pass) {
            CaptureInputs(cb, pass);
            return reinterpret_cast<id(*)(id, SEL, id)>(original)(cb, selector, pass);
        });
    }
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return true;
}

} // namespace

bool SRDMInstallTemporalMetalFX() {
    if (@available(macCatalyst 16.0, *)) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device || ![MTLFXTemporalScalerDescriptor supportsDevice:device]) return false;

        auto *descriptor = [MTLFXSpatialScalerDescriptor new];
        descriptor.inputWidth = 640;
        descriptor.inputHeight = 360;
        descriptor.outputWidth = 960;
        descriptor.outputHeight = 540;
        descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLFXSpatialScaler> sample = [descriptor newSpatialScalerWithDevice:device];
        if (!sample) return false;

        id<MTLCommandQueue> sampleQueue = [device newCommandQueue];
        Class cbClass = object_getClass([sampleQueue commandBuffer]);
        if (!cbClass) return false;
        bool observed = ObserveCommandBuffer(cbClass, @selector(renderCommandEncoderWithDescriptor:));
        observed |= ObserveCommandBuffer(cbClass, @selector(parallelRenderCommandEncoderWithDescriptor:));
        observed |= ObserveCommandBuffer(cbClass, sel_registerName("renderCommandEncoderWithDescriptor:options:"));
        if (!observed || !ObserveCommandBuffer(cbClass, @selector(commit))) return false;
        ObserveScaler(sample);
        return true;
    }
    return false;
}

void SRDMSetTemporalMetalFX(bool enabled) {
    if (temporalEnabled.exchange(enabled) != enabled) ++historyGeneration;
}
