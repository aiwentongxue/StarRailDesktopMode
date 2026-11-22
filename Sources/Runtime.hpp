#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

NSURL *SRDMApplicationSupport(void);
void SRDMStartDiagnostics(void);
void SRDMSampleGraphics(CAMetalLayer *layer);
bool SRDMInstallMouseSampling(void);
void SRDMFlushMouse(bool cameraOwnsInput, double gain, CAMetalLayer *layer);
bool SRDMHasGameMouseHandler(void);
