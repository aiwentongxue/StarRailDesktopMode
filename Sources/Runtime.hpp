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
const section_64 *SRDMFindSection(const mach_header_64 &, const char *segmentName, const char *sectionName);
bool SRDMInstallMouse(const mach_header_64 &verifiedImage, intptr_t slide);
void SRDMSetCameraMouseCapture(bool enabled, double gain);
bool SRDMInstallKeyboard(const mach_header_64 &verifiedImage, intptr_t slide);
bool SRDMGameAcceptsKeyboard(void);
void SRDMReleaseKeyboard(void);
