#include "VideoRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

// =======================================================================
// Private Class for Objective-C
// =======================================================================
@interface DXAVRecorder : NSObject
// Shared Properties
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL isGif;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, strong) dispatch_queue_t writeQueue;

// MP4 (AVFoundation)
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;

// GIF (ImageIO)
@property (nonatomic, assign) CGImageDestinationRef gifDestination;
@property (nonatomic, assign) CGImageRef lastGifFrame;
@property (nonatomic, assign) CMTime lastGifFrameTime;

- (BOOL)startToURL:(NSURL*)url width:(int)w height:(int)h;
- (void)appendCGImage:(CGImageRef)image;
- (void)stop:(void(^)(void))completion;
@end

@implementation DXAVRecorder

- (instancetype)init {
    if (self = [super init]) {
        _writeQueue = dispatch_queue_create("com.dx3270.videorecorder", DISPATCH_QUEUE_SERIAL);
        _isRecording = NO;
    }
    return self;
}

- (BOOL)startToURL:(NSURL*)url width:(int)w height:(int)h {
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    
    self.isGif = [[url pathExtension].lowercaseString isEqualToString:@"gif"];
    self.startTime = CMClockGetTime(CMClockGetHostTimeClock());
    
    if (self.isGif) {
        // ---- INITIALIZE GIF ----
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.gifDestination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, kUTTypeGIF, 0, NULL);
#pragma clang diagnostic pop
        
        if (!self.gifDestination) return NO;
        
        NSDictionary *fileProps = @{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFLoopCount: @0 // loop infinito
            }
        };
        CGImageDestinationSetProperties(self.gifDestination, (__bridge CFDictionaryRef)fileProps);
        
        self.lastGifFrameTime = self.startTime;
        self.lastGifFrame = NULL;
    } else {
        // ---- INITIALIZE MP4 ----
        self.assetWriter = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
        if (error) return NO;
        
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(w),
            AVVideoHeightKey: @(h)
        };
        
        self.writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        self.writerInput.expectsMediaDataInRealTime = YES;
        
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h)
        };
        
        self.adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:self.writerInput sourcePixelBufferAttributes:attributes];
        if ([self.assetWriter canAddInput:self.writerInput]) {
            [self.assetWriter addInput:self.writerInput];
        }
        
        [self.assetWriter startWriting];
        [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    }
    
    self.isRecording = YES;
    return YES;
}

- (void)appendCGImage:(CGImageRef)cgImage {
    if (!self.isRecording) return;
    
    CMTime currentTime = CMClockGetTime(CMClockGetHostTimeClock());
    CGImageRetain(cgImage); 
    
    dispatch_async(self.writeQueue, ^{
        if (self.isGif) {
            // ---- WRITE GIF ----
            if (self.lastGifFrame) {
                CMTime duration = CMTimeSubtract(currentTime, self.lastGifFrameTime);
                float delay = CMTimeGetSeconds(duration);
                if (delay < 0.05) delay = 0.05; 
                
                NSDictionary *frameProps = @{
                    (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                        (__bridge NSString *)kCGImagePropertyGIFDelayTime: @(delay)
                    }
                };
                CGImageDestinationAddImage(self.gifDestination, self.lastGifFrame, (__bridge CFDictionaryRef)frameProps);
                CGImageRelease(self.lastGifFrame);
            }
            self.lastGifFrame = cgImage;
            self.lastGifFrameTime = currentTime;
            
        } else {
            // ---- WRITE MP4 ----
            if (self.assetWriter.status == AVAssetWriterStatusWriting && self.writerInput.readyForMoreMediaData) {
                CMTime presentationTime = CMTimeSubtract(currentTime, self.startTime);
                CVPixelBufferRef pixelBuffer = [self pixelBufferFromCGImage:cgImage];
                if (pixelBuffer) {
                    [self.adaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
                    CVPixelBufferRelease(pixelBuffer);
                }
            }
            CGImageRelease(cgImage);
        }
    });
}

- (void)stop:(void(^)(void))completion {
    if (!self.isRecording) return;
    self.isRecording = NO;
    
    dispatch_async(self.writeQueue, ^{
        if (self.isGif) {
            if (self.lastGifFrame) {
                NSDictionary *frameProps = @{
                    (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                        (__bridge NSString *)kCGImagePropertyGIFDelayTime: @(1.0)
                    }
                };
                CGImageDestinationAddImage(self.gifDestination, self.lastGifFrame, (__bridge CFDictionaryRef)frameProps);
                CGImageRelease(self.lastGifFrame);
                self.lastGifFrame = NULL;
            }
            if (self.gifDestination) {
                CGImageDestinationFinalize(self.gifDestination);
                CFRelease(self.gifDestination);
                self.gifDestination = NULL;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion();
            });
            
        } else {
            [self.writerInput markAsFinished];
            [self.assetWriter finishWritingWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion();
                });
            }];
        }
    });
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)cgImage {
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef)options, &pxbuffer);
    if (status == kCVReturnSuccess && pxbuffer != NULL) {
        CVPixelBufferLockBaseAddress(pxbuffer, 0);
        void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
        CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pxdata, width, height,
                                                     8, CVPixelBufferGetBytesPerRow(pxbuffer),
                                                     rgbColorSpace, kCGImageAlphaNoneSkipFirst);
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
            CGContextRelease(context);
        }
        CGColorSpaceRelease(rgbColorSpace);
        CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    }
    return pxbuffer;
}

@end

// =======================================================================
// Implementation of the C++ Wrapper 
// =======================================================================
namespace x3270 {

VideoRecorder::VideoRecorder() {
    impl_ = (void*)CFBridgingRetain([[DXAVRecorder alloc] init]);
}

VideoRecorder::~VideoRecorder() {
    if (impl_) {
        DXAVRecorder *rec = (__bridge_transfer DXAVRecorder*)impl_;
        if (rec.isRecording) {
            [rec stop:nil];
        }
        impl_ = nullptr;
    }
}

bool VideoRecorder::startRecording(const std::string& filePath, int width, int height) {
    DXAVRecorder *rec = (__bridge DXAVRecorder*)impl_;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filePath.c_str()]];
    return [rec startToURL:url width:width height:height];
}

void VideoRecorder::appendFrame(void* cgImageRef) {
    DXAVRecorder *rec = (__bridge DXAVRecorder*)impl_;
    [rec appendCGImage:(CGImageRef)cgImageRef];
}

void VideoRecorder::stopRecording(std::function<void()> completion) {
    DXAVRecorder *rec = (__bridge DXAVRecorder*)impl_;
    [rec stop:^{
        if (completion) completion();
    }];
}

bool VideoRecorder::isRecording() const {
    DXAVRecorder *rec = (__bridge DXAVRecorder*)impl_;
    return rec.isRecording;
}

} // namespace x3270