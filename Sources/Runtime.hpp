#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach-o/loader.h>

NSURL *SRDMApplicationSupport(void);
bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide);
bool SRDMEnableDesktopCursor(const mach_header_64 &verifiedImage, intptr_t slide);
struct SRDMUnityCursorState {
    bool known;
    bool visible;
    bool locked;
};
SRDMUnityCursorState SRDMRequestedCursor();
void SRDMStartDiagnostics(void);
void SRDMSampleGraphics(CAMetalLayer *layer);
bool SRDMInstallMouseSampling(void);
void SRDMFlushMouse(bool cameraOwnsInput, double gain, CAMetalLayer *layer);
bool SRDMHasGameMouseHandler(void);
