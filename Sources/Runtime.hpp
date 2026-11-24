#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach-o/loader.h>
#include "ClientProfile.hpp"

NSURL *SRDMApplicationSupport(void);
bool SRDMEnableDesktopLayout(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client);
bool SRDMEnableDesktopCursor(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client);
struct SRDMUnityCursorState {
    bool known;
    bool visible;
    bool locked;
};
SRDMUnityCursorState SRDMRequestedCursor();
void SRDMStartDiagnostics(void);
void SRDMSampleGraphics(CAMetalLayer *layer);
bool SRDMInstallLoginVersionLabel(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client);
bool SRDMInstallGraphicsSettings(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client);
void SRDMUpdateGraphicsSettings(void);
CGSize SRDMGameDrawableSize(void);
bool SRDMInstallTemporalMetalFX(void);
void SRDMSetTemporalMetalFX(bool enabled);
const section_64 *SRDMFindSection(const mach_header_64 &, const char *segmentName, const char *sectionName);
bool SRDMInstallMouse(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client,
                     bool &radialPositionInstalled);
void SRDMSetCameraMouseCapture(bool enabled, double gain, CGPoint warp = CGPointZero);
bool SRDMInstallKeyboard(const mach_header_64 &verifiedImage, intptr_t slide, const starrail::ClientProfile &client);
bool SRDMGameAcceptsKeyboard(void);
void SRDMReleaseKeyboard(void);
bool SRDMSendMouseButton(unsigned button, bool down);

void SRDMSetRadialPosition(bool enabled, CGPoint pixels);
