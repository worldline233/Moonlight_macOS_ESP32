#pragma once
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

// Decoder-native compressed surfaces must never be read as linear Y bytes.
// Private to the serial vision queue; one reusable destination, no render changes.
class ESP32PixelBufferReader {
    VTPixelTransferSessionRef session=nullptr;
    CVPixelBufferRef destination=nullptr;
public:
    static bool compressed420(OSType format) {
        // Apple's lossless (&) / lossy (-) 8-bit and packed 10-bit 4:2:0.
        unsigned family=(format>>24)&255,depth=(format>>16)&255,range=(format>>8)&255;
        return (family=='&'||family=='-') && (depth=='8'||depth=='x') &&
               (range=='v'||range=='f') && (format&255)=='0';
    }
    static OSType linearFormat(OSType format) {
        return ((format>>8)&255)=='f' ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    ~ESP32PixelBufferReader() {
        if(destination)CVPixelBufferRelease(destination);
        if(session){VTPixelTransferSessionInvalidate(session);CFRelease(session);}
    }
    CVPixelBufferRef convert(CVPixelBufferRef source,OSStatus& status) {
        status=noErr;
        const size_t width=CVPixelBufferGetWidth(source),height=CVPixelBufferGetHeight(source);
        OSType output=linearFormat(CVPixelBufferGetPixelFormatType(source));
        if(!session){status=VTPixelTransferSessionCreate(kCFAllocatorDefault,&session);if(status!=noErr)return nullptr;}
        if(destination && (CVPixelBufferGetWidth(destination)!=width || CVPixelBufferGetHeight(destination)!=height || CVPixelBufferGetPixelFormatType(destination)!=output)) {
            CVPixelBufferRelease(destination);destination=nullptr;
        }
        if(!destination){
            NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
            status=CVPixelBufferCreate(kCFAllocatorDefault,width,height,output,(__bridge CFDictionaryRef)attributes,&destination);
            if(status!=noErr)return nullptr;
        }
        CVBufferPropagateAttachments(source,destination);
        status=VTPixelTransferSessionTransferImage(session,source,destination);
        return status==noErr ? destination : nullptr;
    }
};
