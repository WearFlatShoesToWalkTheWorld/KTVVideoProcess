//
//  KTVVPFrameView.m
//  KTVVideoProcessDemo
//
//  Created by Single on 2018/3/15.
//  Copyright © 2018年 Single. All rights reserved.
//

#import "KTVVPFrameView.h"
#import "KTVVPMessageLoop.h"
#import "KTVVPGLRGBProgram.h"
#import "KTVVPGLPlaneModel.h"

typedef NS_ENUM(NSUInteger, KTVVPMessageTypeView)
{
    KTVVPMessageTypeViewIdle = 1900,
    KTVVPMessageTypeViewSnapshot,
};

@interface KTVVPFrameView () <KTVVPMessageLoopDelegate>

{
    GLuint _glFramebuffer;
    GLuint _glRenderbuffer;
}

@property (nonatomic, assign) KTVVPSize displaySize;

@property (nonatomic, assign) CGFloat glScale;
@property (nonatomic, strong) CAEAGLLayer * glLayer;
@property (nonatomic, strong) EAGLContext * glContext;
@property (nonatomic, strong) KTVVPGLRGBProgram * glProgram;
@property (nonatomic, strong) KTVVPGLPlaneModel * glModel;
@property (nonatomic, strong) KTVVPFrameUploader * frameUploader;
@property (nonatomic, strong) KTVVPMessageLoop * messageLoop;
@property (nonatomic, assign) CMTime previousFrameTime;
@property (nonatomic, strong) KTVVPFrame * currentFrame;
@property (nonatomic, copy) void (^snapshotCallback)(UIImage *);

@end

@implementation KTVVPFrameView

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (instancetype)initWithContext:(KTVVPContext *)context
{
    if (self = [super initWithFrame:CGRectZero])
    {
        _context = context;
        _scalingMode = KTVVPScalingModeResizeAspectFill;
        
        if ([self respondsToSelector:@selector(setContentScaleFactor:)])
        {
            self.contentScaleFactor = [[UIScreen mainScreen] scale];
            _glScale = self.contentScaleFactor;
        }
        
        _glLayer = (CAEAGLLayer *)self.layer;
        _glLayer.opaque = YES;
        _glLayer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking : @(NO),
                                            kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8};
        
        _messageLoop = [[KTVVPMessageLoop alloc] initWithIdentify:@"FrameView" delegate:self];
        [_messageLoop run];
        [_messageLoop putMessage:[KTVVPMessage messageWithType:KTVVPMessageTypeOpenGLSetupContext object:nil]];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"%s", __func__);
    
    [self destroyOnMessageLoopThread];
    [_messageLoop stop];
    _messageLoop = nil;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    int width = CGRectGetWidth(self.bounds);
    int height = CGRectGetHeight(self.bounds);
    if (width != _displaySize.width || height != _displaySize.width)
    {
        _displaySize = KTVVPSizeMake(width, height);
        [_messageLoop putMessage:[KTVVPMessage messageWithType:KTVVPMessageTypeOpenGLSetupFramebuffer object:nil]];
    }
}


#pragma mark - Control

- (void)snapshot:(void (^)(UIImage *))callback
{
    _snapshotCallback = callback;
    [_messageLoop putMessage:[KTVVPMessage messageWithType:KTVVPMessageTypeViewSnapshot object:nil]];
}

- (void)snapshotAndCallback
{
    if (_snapshotCallback)
    {
        UIImage * image = nil;
        CVPixelBufferRef pixelBuffer = _currentFrame.corePixelBuffer;
        if (pixelBuffer)
        {
            if (@available(iOS 9.0, *))
            {
                CIImage * ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                image = [UIImage imageWithCIImage:ciImage];
            }
            else
            {
                CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                void * baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
                size_t width = CVPixelBufferGetWidth(pixelBuffer);
                size_t height = CVPixelBufferGetHeight(pixelBuffer);
                size_t bufferSize = CVPixelBufferGetDataSize(pixelBuffer);
                size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            
                CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
                CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, baseAddress, bufferSize, NULL);
                
                CGImageRef cgImage = CGImageCreate(width,
                                                   height,
                                                   8,
                                                   32,
                                                   bytesPerRow,
                                                   rgbColorSpace,
                                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                                   provider,
                                                   NULL,
                                                   true,
                                                   kCGRenderingIntentDefault);
                
                image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                CGDataProviderRelease(provider);
                CGColorSpaceRelease(rgbColorSpace);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            }
        }
        void (^snapshotCallback)(UIImage *) = _snapshotCallback;
        dispatch_async(dispatch_get_main_queue(), ^{
            snapshotCallback(image);
        });
        _snapshotCallback = nil;
    }
}

- (void)updateCurrentFrame:(KTVVPFrame *)frame
{
    [frame lock];
    [_currentFrame unlock];
    _currentFrame = frame;
}


#pragma mark - Input

- (void)inputFrame:(KTVVPFrame *)frame fromSource:(id)source
{
    [frame lock];
    [self.messageLoop putMessage:[KTVVPMessage messageWithType:KTVVPMessageTypeOpenGLDrawing object:frame dropCallback:^(KTVVPMessage * message) {
        KTVVPFrame * object = (KTVVPFrame *)message.object;
        [object unlock];
    }]];
}


#pragma mark - OpenGL

- (void)drawFrame:(KTVVPFrame *)frame
{
    [self drawPrepare];
    [self drawUpdateViewport:frame.size];
    [_glProgram use];
    [frame uploadIfNeeded:_frameUploader];
    [_glProgram bindTexture:frame.texture];
    _glModel.rotationMode = frame.rotationMode;
    _glModel.flipMode = frame.textureFlipMode;
    [_glModel reloadDataIfNeeded];
    [_glModel bindPosition_location:_glProgram.position_location
             textureCoordinate_location:_glProgram.textureCoordinate_location];
    [_glModel draw];
    [_glModel bindEmpty];
    [self drawFlush];
}

- (void)drawClear
{
    [self drawPrepare];
    [self drawFlush];
}

- (void)drawPrepare
{
    [_glContext setCurrentIfNeeded];
    glBindFramebuffer(GL_FRAMEBUFFER, _glFramebuffer);
    glViewport(0, 0, (GLint)_displaySize.width * self.glScale, (GLint)_displaySize.height * self.glScale);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

- (void)drawUpdateViewport:(KTVVPSize)size
{
    GLint width = (GLint)_displaySize.width * self.glScale;
    GLint height = (GLint)_displaySize.height * self.glScale;
    CGRect rect = CGRectMake(0, 0, width, height);
    switch (_scalingMode)
    {
        case KTVVPScalingModeResize:
            break;
        case KTVVPScalingModeResizeAspect:
            rect = AVMakeRectWithAspectRatioInsideRect(CGSizeMake(size.width, size.height), rect);
            break;
        case KTVVPScalingModeResizeAspectFill:
        {
            rect = AVMakeRectWithAspectRatioInsideRect(CGSizeMake(size.width, size.height), rect);
            CGFloat scale = 1 + MAX(rect.origin.x * 2 / rect.size.width, rect.origin.y * 2 / rect.size.height);
            CGSize size = CGSizeApplyAffineTransform(rect.size, CGAffineTransformMakeScale(scale, scale));
            rect = CGRectMake(-(size.width - width) / 2,
                              -(size.height - height) / 2,
                              size.width,
                              size.height);
        }
            break;
    }
    glViewport(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
}

- (void)drawFlush
{
    glBindRenderbuffer(GL_RENDERBUFFER, _glRenderbuffer);
    [_glContext presentRenderbuffer:GL_RENDERBUFFER];
}


#pragma mark - Setup

- (void)setupOpenGL
{
    _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:_context.mainGLContext.sharegroup];
    [_glContext setCurrentIfNeeded];
    _glModel = [[KTVVPGLPlaneModel alloc] initWithGLContext:_glContext];
    _glProgram = [[KTVVPGLRGBProgram alloc] initWithGLContext:_glContext];
    _frameUploader = [[KTVVPFrameUploader alloc] initWithGLContext:_glContext];
}

- (void)setupFramebuffer
{
    if (_displaySize.width == 0 || _displaySize.height == 0)
    {
        return;
    }
    [_glContext setCurrentIfNeeded];
    glGenFramebuffers(1, &_glFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _glFramebuffer);
    glGenRenderbuffers(1, &_glRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _glRenderbuffer);
    [_glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_glLayer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _glRenderbuffer);
}

- (void)destroyFramebuffer
{
    [_glContext setCurrentIfNeeded];
    if (_glFramebuffer)
    {
        glDeleteFramebuffers(1, &_glFramebuffer);
        _glFramebuffer = 0;
    }
    if (_glRenderbuffer)
    {
        glDeleteRenderbuffers(1, &_glRenderbuffer);
        _glRenderbuffer = 0;
    }
}

- (void)destroyOnMessageLoopThread
{
    EAGLContext * glContext = _glContext;
    GLuint glFramebuffer = _glFramebuffer;
    GLuint glRenderbuffer = _glRenderbuffer;
    KTVVPFrame * currentFrame = _currentFrame;
    [_messageLoop setFinishedCallback:^(KTVVPMessageLoop * messageLoop) {
        [glContext setCurrentIfNeeded];
        if (glFramebuffer)
        {
            glDeleteFramebuffers(1, &glFramebuffer);
        }
        if (glRenderbuffer)
        {
            glDeleteRenderbuffers(1, &glRenderbuffer);
        }
        if (currentFrame)
        {
            [currentFrame unlock];
        }
    }];
}


#pragma mark - KTVVPMessageLoopDelegate

- (void)messageLoop:(KTVVPMessageLoop *)messageLoop processingMessage:(KTVVPMessage *)message
{
    if (message.type == KTVVPMessageTypeOpenGLSetupContext)
    {
        [self setupOpenGL];
    }
    else if (message.type == KTVVPMessageTypeOpenGLSetupFramebuffer)
    {
        [self destroyFramebuffer];
        [self setupFramebuffer];
    }
    else if (message.type == KTVVPMessageTypeOpenGLDrawing)
    {
        KTVVPFrame * frame = (KTVVPFrame *)message.object;
        if (CMTIME_IS_VALID(frame.timeStamp)
            && CMTIME_IS_VALID(_previousFrameTime))
        {
            if (CMTimeCompare(frame.timeStamp, _previousFrameTime) < 0)
            {
                NSLog(@"KTVVPFrameView Frame time is less than previous time.");
                [frame unlock];
                return;
            }
        }
        _previousFrameTime = frame.timeStamp;
        [self drawFrame:frame];
        [self updateCurrentFrame:frame];
        [frame unlock];
    }
    else if (message.type == KTVVPMessageTypeOpenGLClear)
    {
        [self drawClear];
    }
    else if (message.type == KTVVPMessageTypeViewSnapshot)
    {
        [self snapshotAndCallback];
    }
}

@end