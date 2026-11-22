#import "Runtime.hpp"
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <cmath>
#include <mutex>

namespace {

using Encoder = id (*)(id, SEL, MTLRenderPassDescriptor *);
bool attachmentObserver;
typedef id (*SpatialScalerCreator)(id, SEL, id<MTLDevice>) __attribute__((ns_returns_retained));
SpatialScalerCreator originalSpatialScaler;

API_AVAILABLE(macCatalyst(16.0))
id __attribute__((ns_returns_retained))
ObserveSpatialScaler(MTLFXSpatialScalerDescriptor *descriptor, SEL selector, id<MTLDevice> device) {
    id<MTLFXSpatialScaler> scaler = originalSpatialScaler(descriptor, selector, device);
    if (scaler) {
        NSLog(@"[StarRailDesktopMode] MetalFX spatial input=%lux%lu output=%lux%lu",
              descriptor.inputWidth, descriptor.inputHeight, descriptor.outputWidth, descriptor.outputHeight);
    }
    return scaler;
}
std::mutex sampleLock;

struct Extents {
    NSUInteger width = 0;
    NSUInteger height = 0;
};
struct Attachment {
    NSString *label = nil;
    Extents color;
    Extents depth;
    NSUInteger hits = 0;
};
constexpr size_t MaxTargets = 16;
Attachment targets[MaxTargets];
bool collect;
double nextSample;
struct GraphicsSettings {
    double scale = 0;
    NSInteger resolutionQuality = -1;

    bool operator==(const GraphicsSettings &) const = default;
};
GraphicsSettings lastSettings{-1, -1};
CGSize lastDrawable;

Extents Dimensions(id<MTLTexture> image) {
    return {image.width, image.height};
}

void CaptureAttachments(MTLRenderPassDescriptor *descriptor) {
    {
        std::lock_guard lock(sampleLock);
        if (collect) {
            id<MTLTexture> color = descriptor.colorAttachments[0].texture;
            id<MTLTexture> depth = descriptor.depthAttachment.texture;
            if (color.width >= 320 && color.height >= 180) {
                for (Attachment &target : targets) {
                    if (!target.hits) {
                        target = {color.label, Dimensions(color), Dimensions(depth), 1};
                        break;
                    }
                    if (target.color.width == color.width && target.color.height == color.height &&
                        target.depth.width == depth.width && target.depth.height == depth.height &&
                        (target.label == color.label || [target.label isEqualToString:color.label])) {
                        ++target.hits;
                        break;
                    }
                }
            }
        }
    }
}

bool ObserveEncoder(Class type, SEL selector) {
    Method method = class_getInstanceMethod(type, selector);
    if (!method) return false;
    const auto original = reinterpret_cast<Encoder>(method_getImplementation(method));
    IMP observed = imp_implementationWithBlock(^id(id buffer, MTLRenderPassDescriptor *descriptor) {
        CaptureAttachments(descriptor);
        return original(buffer, selector, descriptor);
    });
    class_replaceMethod(type, selector, observed, method_getTypeEncoding(method));
    return true;
}

bool ObserveCommandBuffer(id<MTLCommandBuffer> sample) {
    Class type = object_getClass(sample);
    if (!type) return false;
    bool render = ObserveEncoder(type, @selector(renderCommandEncoderWithDescriptor:));
    bool parallel = ObserveEncoder(type, @selector(parallelRenderCommandEncoderWithDescriptor:));
    return render || parallel;
}

GraphicsSettings ReadGraphicsSettings() {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"GraphicsSettings_Model"];
    if ([stored isKindOfClass:NSString.class]) {
        NSData *data = [stored dataUsingEncoding:NSUTF8StringEncoding];
        stored = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    if (![stored isKindOfClass:NSDictionary.class]) return {};
    NSNumber *scale = stored[@"RenderScale"];
    NSNumber *quality = stored[@"ResolutionQuality"];
    const double value = [scale isKindOfClass:NSNumber.class] ? scale.doubleValue : 0;
    return {std::isfinite(value) && value > 0 ? value : 0,
            [quality isKindOfClass:NSNumber.class] ? quality.integerValue : -1};
}

} // namespace

void SRDMStartDiagnostics(void) {
    const id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> ordinary = [queue commandBuffer];
    id<MTLCommandBuffer> unretained = [queue commandBufferWithUnretainedReferences];
    id<MTLCommandBuffer> configured = [queue commandBufferWithDescriptor:[MTLCommandBufferDescriptor new]];
    attachmentObserver = ObserveCommandBuffer(ordinary);
    if (object_getClass(unretained) != object_getClass(ordinary)) {
        attachmentObserver |= ObserveCommandBuffer(unretained);
    }
    if (object_getClass(configured) != object_getClass(ordinary) &&
        object_getClass(configured) != object_getClass(unretained)) {
        attachmentObserver |= ObserveCommandBuffer(configured);
    }

    if (@available(macCatalyst 16.0, *)) {
        Method spatial = class_getInstanceMethod(NSClassFromString(@"MTLFXSpatialScalerDescriptor"), @selector(newSpatialScalerWithDevice:));
        if (spatial) {
            originalSpatialScaler = reinterpret_cast<SpatialScalerCreator>(method_getImplementation(spatial));
            method_setImplementation(spatial, (IMP)ObserveSpatialScaler);
        }
    }
    NSLog(@"[StarRailDesktopMode] Metal attachment_observer=%d spatial_observer=%d",
          attachmentObserver, originalSpatialScaler != nullptr);
}

void SRDMSampleGraphics(CAMetalLayer *layer) {
    const double now = CACurrentMediaTime();
    if (now < nextSample) return;
    const CGSize drawable = layer.drawableSize;
    const GraphicsSettings settings = ReadGraphicsSettings();
    if (lastSettings != settings || !CGSizeEqualToSize(lastDrawable, drawable)) {
        lastSettings = settings;
        lastDrawable = drawable;
        NSLog(@"[StarRailDesktopMode] graphics saved_scale=%.2f resolution_quality=%ld drawable=%.0fx%.0f",
              settings.scale, settings.resolutionQuality, drawable.width, drawable.height);
    }

    Attachment snapshot[MaxTargets];
    bool wasCollecting;
    {
        std::lock_guard lock(sampleLock);
        wasCollecting = collect;
        collect = attachmentObserver && !collect && drawable.width > 0;
        if (wasCollecting) {
            for (size_t i = 0; i < MaxTargets; ++i) {
                snapshot[i] = std::move(targets[i]);
                targets[i] = {};
            }
        }
    }
    nextSample = now + (collect ? 0.25 : 1.75);
    if (wasCollecting && snapshot[0].hits) {
        NSMutableString *summary = [NSMutableString stringWithFormat:
            @"[StarRailDesktopMode] Metal saved_scale=%.2f resolution_quality=%ld",
            settings.scale, settings.resolutionQuality];
        for (const Attachment &target : snapshot) {
            if (!target.hits) break;
            NSString *label = target.label ?: @"(unlabelled)";
            if (label.length > 80) label = [label substringToIndex:80];
            [summary appendFormat:@" | %@ %lux%lu depth %lux%lu ×%lu",
             label, target.color.width, target.color.height, target.depth.width,
             target.depth.height, target.hits];
        }
        NSLog(@"%@", summary);
    }
}
