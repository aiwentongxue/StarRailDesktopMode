#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach-o/loader.h>

NSURL *SRDMApplicationSupport(void);
bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide);
void SRDMStartDiagnostics(void);
void SRDMSampleGraphics(CAMetalLayer *layer);
bool SRDMInstallMouseSampling(void);
void SRDMFlushMouse(bool cameraOwnsInput, double gain, CAMetalLayer *layer);
bool SRDMHasGameMouseHandler(void);
