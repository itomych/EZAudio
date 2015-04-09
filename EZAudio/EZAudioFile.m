//
//  EZAudioFile.m
//  EZAudio
//
//  Created by Syed Haris Ali on 12/1/13.
//  Copyright (c) 2013 Syed Haris Ali. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "EZAudioFile.h"

//------------------------------------------------------------------------------

#import "EZAudio.h"
#import "EZAudioFloatConverter.h"
#import "EZAudioFloatData.h"
#include <pthread.h>

//------------------------------------------------------------------------------

// errors
static OSStatus EZAudioFileReadPermissionFileDoesNotExistCode = -88776;

// constants
static UInt32 EZAudioFileWaveformDefaultResolution = 1024;

//------------------------------------------------------------------------------

typedef struct
{
    AudioFileID                 audioFileID;
    AudioStreamBasicDescription clientFormat;
    float                       duration;
    ExtAudioFileRef             extAudioFileRef;
    AudioStreamBasicDescription fileFormat;
    SInt64                      frames;
    EZAudioFilePermission       permission;
    CFURLRef                    sourceURL;
} EZAudioFileInfo;

//------------------------------------------------------------------------------
#pragma mark - EZAudioFile
//------------------------------------------------------------------------------

@interface EZAudioFile ()
@property (nonatomic, strong) EZAudioFloatConverter *floatConverter;
@property (nonatomic) float **floatData;
@property (nonatomic) EZAudioFileInfo info;
@property (nonatomic) pthread_mutex_t lock;
@property (nonatomic, strong) NSOperation *waveformOperation;
@end

//------------------------------------------------------------------------------

@implementation EZAudioFile

//------------------------------------------------------------------------------
#pragma mark - Initialization
//------------------------------------------------------------------------------

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        memset(&_info, 0, sizeof(_info));
        _floatData = NULL;
        _info.permission = EZAudioFilePermissionRead;
        pthread_mutex_init(&_lock, NULL);
    }
    return self;
}

//------------------------------------------------------------------------------

- (instancetype)initWithURL:(NSURL *)url
{
    AudioStreamBasicDescription asbd;
    return [self initWithURL:url
                  permission:EZAudioFilePermissionRead
                  fileFormat:asbd];
}

//------------------------------------------------------------------------------

- (instancetype)initWithURL:(NSURL*)url
                 permission:(EZAudioFilePermission)permission
                 fileFormat:(AudioStreamBasicDescription)fileFormat
{
    return [self initWithURL:url
                    delegate:nil
                  permission:permission
                  fileFormat:fileFormat];
}

//------------------------------------------------------------------------------

- (instancetype)initWithURL:(NSURL*)url
                   delegate:(id<EZAudioFileDelegate>)delegate
                 permission:(EZAudioFilePermission)permission
                 fileFormat:(AudioStreamBasicDescription)fileFormat
{
    return [self initWithURL:url
                    delegate:delegate
                  permission:permission
                  fileFormat:fileFormat
                clientFormat:[self.class defaultClientFormat]];
}

//------------------------------------------------------------------------------

- (instancetype)initWithURL:(NSURL*)url
                   delegate:(id<EZAudioFileDelegate>)delegate
                 permission:(EZAudioFilePermission)permission
                 fileFormat:(AudioStreamBasicDescription)fileFormat
               clientFormat:(AudioStreamBasicDescription)clientFormat
{
    self = [self init];
    if(self)
    {
        _info.clientFormat = clientFormat;
        _info.fileFormat = fileFormat;
        _info.permission = permission;
        _info.sourceURL = (__bridge CFURLRef)url;
        self.delegate = delegate;
        [self setup];
    }
    return self;
}

//------------------------------------------------------------------------------
#pragma mark - Class Initializers
//------------------------------------------------------------------------------

+ (instancetype)audioFileWithURL:(NSURL*)url
{
    return [[self alloc] initWithURL:url];
}

//------------------------------------------------------------------------------

+ (instancetype)audioFileWithURL:(NSURL*)url
                      permission:(EZAudioFilePermission)permission
                      fileFormat:(AudioStreamBasicDescription)fileFormat
{
    return [[self alloc] initWithURL:url
                          permission:permission
                          fileFormat:fileFormat];
}

//------------------------------------------------------------------------------

+ (instancetype)audioFileWithURL:(NSURL*)url
                        delegate:(id<EZAudioFileDelegate>)delegate
                      permission:(EZAudioFilePermission)permission
                      fileFormat:(AudioStreamBasicDescription)fileFormat
{
    return [[self alloc] initWithURL:url
                            delegate:delegate
                          permission:permission
                          fileFormat:fileFormat];
}

//------------------------------------------------------------------------------

+ (instancetype)audioFileWithURL:(NSURL*)url
                        delegate:(id<EZAudioFileDelegate>)delegate
                      permission:(EZAudioFilePermission)permission
                      fileFormat:(AudioStreamBasicDescription)fileFormat
                    clientFormat:(AudioStreamBasicDescription)clientFormat
{
    return [[self alloc] initWithURL:url
                            delegate:delegate
                          permission:permission
                          fileFormat:fileFormat
                        clientFormat:clientFormat];
}

//------------------------------------------------------------------------------
#pragma mark - Class Methods
//------------------------------------------------------------------------------

+ (AudioStreamBasicDescription)defaultClientFormat
{
    return [EZAudio stereoFloatNonInterleavedFormatWithSampleRate:44100];
}

//------------------------------------------------------------------------------

+ (NSArray *)supportedAudioFileTypes
{
    return @[
        @"aac",
        @"caf",
        @"aif",
        @"aiff",
        @"aifc",
        @"mp3",
        @"mp4",
        @"m4a",
        @"snd",
        @"au",
        @"sd2",
        @"wav"
    ];
}

//------------------------------------------------------------------------------
#pragma mark - Setup
//------------------------------------------------------------------------------

- (void)setup
{
    // we open the file differently depending on the permissions specified
    [EZAudio checkResult:[self openAudioFile]
               operation:"Failed to create/open audio file"];
    
    // set the client format
    self.clientFormat = self.info.clientFormat;
}

//------------------------------------------------------------------------------
#pragma mark - Creating/Opening Audio File
//------------------------------------------------------------------------------

- (OSStatus)openAudioFile
{
    // need a source url
    NSAssert(_info.sourceURL, @"EZAudioFile cannot be created without a source url!");
    
    // determine if the file actually exists
    CFURLRef url        = self.info.sourceURL;
    NSURL    *fileURL   = (__bridge NSURL *)(url);
    BOOL     fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path];
    
    // create the file wrapper slightly differently depending what we are
    // trying to do with it
    OSStatus              result     = noErr;
    EZAudioFilePermission permission = self.info.permission;
    UInt32                propSize;
    if (fileExists)
    {
        result = AudioFileOpenURL(url,
                                  permission,
                                  0,
                                  &_info.audioFileID);
        [EZAudio checkResult:result
                   operation:"failed to open audio file"];
    }
    else
    {
        // read permission is not applicable because the file does not exist
        if (permission == EZAudioFilePermissionRead)
        {
            result = EZAudioFileReadPermissionFileDoesNotExistCode;
        }
        else
        {
            result = AudioFileCreateWithURL(url,
                                            0,
                                            &_info.fileFormat,
                                            kAudioFileFlags_EraseFile,
                                            &_info.audioFileID);
        }
    }
    
    // get the ExtAudioFile wrapper
    if (result == noErr)
    {
        [EZAudio checkResult:ExtAudioFileWrapAudioFileID(self.info.audioFileID,
                                                         false,
                                                         &_info.extAudioFileRef)
                   operation:"Failed to wrap audio file ID in ext audio file ref"];
    }
    
    // store the file format if we opened an existing file
    if (fileExists)
    {
        propSize = sizeof(self.info.fileFormat);
        [EZAudio checkResult:ExtAudioFileGetProperty(self.info.extAudioFileRef,
                                                     kExtAudioFileProperty_FileDataFormat,
                                                     &propSize,
                                                     &_info.fileFormat)
                   operation:"Failed to get file audio format on existing audio file"];
    }
    
    // done
    return result;
}

//------------------------------------------------------------------------------
#pragma mark - Events
//------------------------------------------------------------------------------

- (void)readFrames:(UInt32)frames
    audioBufferList:(AudioBufferList *)audioBufferList
         bufferSize:(UInt32 *)bufferSize
               eof:(BOOL *)eof
{
    if (pthread_mutex_trylock(&_lock) == 0)
    {
        // perform read
        [EZAudio checkResult:ExtAudioFileRead(self.info.extAudioFileRef,
                                              &frames,
                                              audioBufferList)
                   operation:"Failed to read audio data from file"];
        *bufferSize = frames;
        *eof = frames == 0;
        
        // notify delegate
        if ([self.delegate respondsToSelector:@selector(audioFile:updatedPosition:)])
        {
            [self.delegate audioFile:self
                     updatedPosition:self.frameIndex];
        }
        
        // convert into float data
        [self.floatConverter convertDataFromAudioBufferList:audioBufferList
                                         withNumberOfFrames:*bufferSize
                                             toFloatBuffers:self.floatData];
        
        if ([self.delegate respondsToSelector:@selector(audioFile:readAudio:withBufferSize:withNumberOfChannels:)])
        {
            UInt32 channels = self.clientFormat.mChannelsPerFrame;
            [self.delegate audioFile:self
                           readAudio:self.floatData
                      withBufferSize:*bufferSize
                withNumberOfChannels:channels];
        }
        
        pthread_mutex_unlock(&_lock);
        
    }
}

//------------------------------------------------------------------------------

- (void)seekToFrame:(SInt64)frame
{
    if (pthread_mutex_trylock(&_lock) == 0)
    {
        [EZAudio checkResult:ExtAudioFileSeek(self.info.extAudioFileRef,
                                              frame)
                   operation:"Failed to seek frame position within audio file"];

        pthread_mutex_unlock(&_lock);
        
        // notify delegate
        if ([self.delegate respondsToSelector:@selector(audioFile:updatedPosition:)])
        {
            [self.delegate audioFile:self
                     updatedPosition:self.frameIndex];
        }
    }
}

//------------------------------------------------------------------------------
#pragma mark - Getters
//------------------------------------------------------------------------------

- (AudioStreamBasicDescription)floatFormat
{
    return [EZAudio stereoFloatNonInterleavedFormatWithSampleRate:44100];
}

//------------------------------------------------------------------------------

- (EZAudioFloatData *)getWaveformData
{
    return [self getWaveformDataWithNumberOfPoints:EZAudioFileWaveformDefaultResolution];
}

- (EZAudioFloatData *)getWaveformDataWithNumberOfPoints:(UInt32)numberOfPoints
{
    return [self getWaveformDataWithNumberOfPoints:numberOfPoints operation:nil];
}

//------------------------------------------------------------------------------

- (EZAudioFloatData *)getWaveformDataWithNumberOfPoints:(UInt32)numberOfPoints operation:(NSOperation *)operation
{
    EZAudioFloatData *waveformData;
    if (pthread_mutex_trylock(&_lock) == 0)
    {
        // store current frame
        SInt64 currentFrame     = self.frameIndex;
        UInt32 channels         = self.clientFormat.mChannelsPerFrame;
        BOOL   interleaved      = [EZAudio isInterleaved:self.clientFormat];
        SInt64 totalFrames      = self.totalClientFrames;
        SInt64 framesPerBuffer  = ((SInt64) totalFrames / numberOfPoints);
        SInt64 framesPerChannel = framesPerBuffer / channels;
        float  **data           = (float **)malloc( sizeof(float *) * channels );
        for (int i = 0; i < channels; i++)
        {
            data[i] = (float *)malloc( sizeof(float) * numberOfPoints );
        }
        
        // seek to 0
        [EZAudio checkResult:ExtAudioFileSeek(self.info.extAudioFileRef,
                                              0)
                   operation:"Failed to seek frame position within audio file"];
        
        // read through file and calculate rms at each point
        UInt32 bufferSize = (UInt32)framesPerBuffer;
        for (SInt64 i = 0; i < numberOfPoints; i++)
        {
            if (operation.isCancelled)
            {
                break;
            }
            
            // allocate an audio buffer list
            AudioBufferList *audioBufferList = [EZAudio audioBufferListWithNumberOfFrames:bufferSize
                                                                         numberOfChannels:self.info.clientFormat.mChannelsPerFrame
                                                                              interleaved:interleaved];
            
            [EZAudio checkResult:ExtAudioFileRead(self.info.extAudioFileRef,
                                                  &bufferSize,
                                                  audioBufferList)
                       operation:"Failed to read audio data from file waveform"];
            
            if (interleaved)
            {
                float *samples = (float *)audioBufferList->mBuffers[0].mData;
                for (int channel = 0; channel < channels; channel++)
                {
                    float channelData[framesPerChannel];
                    for (int frame = 0; frame < framesPerChannel; frame++)
                    {
                        channelData[frame] = samples[frame * channels + channel];
                    }
                    float rms = [EZAudio RMS:channelData length:(UInt32)framesPerChannel];
                    data[channel][i] = rms;
                }
            }
            else
            {
                for (int channel = 0; channel < channels; channel++)
                {
                    float *samples = (float *)audioBufferList->mBuffers[channel].mData;
                    float rms = [EZAudio RMS:samples length:bufferSize];
                    data[channel][i] = rms;
                }
            }
            
            // clean up
            [EZAudio freeBufferList:audioBufferList];
        }
        
        // seek back to previous position
        [EZAudio checkResult:ExtAudioFileSeek(self.info.extAudioFileRef,
                                              currentFrame)
                   operation:"Failed to seek frame position within audio file"];
        
        pthread_mutex_unlock(&_lock);
        
        if (!operation.isCancelled)
        {
            waveformData = [EZAudioFloatData dataWithNumberOfChannels:channels
                                                              buffers:(float **)data
                                                           bufferSize:numberOfPoints];
        }
        
        // cleanup
        for (int i = 0; i < channels; i++)
        {
            free(data[i]);
        }
        free(data);
    }
    return waveformData;
}

//------------------------------------------------------------------------------

- (void)getWaveformDataWithCompletionBlock:(WaveformDataCompletionBlock)waveformDataCompletionBlock
{
    [self getWaveformDataWithNumberOfPoints:EZAudioFileWaveformDefaultResolution
                                 completion:waveformDataCompletionBlock];
}

//------------------------------------------------------------------------------

- (void)getWaveformDataWithNumberOfPoints:(UInt32)numberOfPoints
                               completion:(WaveformDataCompletionBlock)completion
{
    if (!completion)
    {
        return;
    }

    NSCache *cache = [[self class] sharedWaveformCache];
    NSString *waveformCacheKey = [self url].absoluteString;
    
    EZAudioFloatData *waveformData = [cache objectForKey:waveformCacheKey];
    if (waveformData)
    {
        completion(waveformData);
    }
    else
    {
        NSBlockOperation *operation = [[NSBlockOperation alloc] init];
        
        _waveformOperation = operation;
        __weak typeof(self) weakSelf = self;
        __weak NSOperation *weakOperation = operation;
        
        [operation addExecutionBlock:^{
            EZAudioFloatData *waveformData = [weakSelf getWaveformDataWithNumberOfPoints:numberOfPoints operation:weakOperation];
            if (waveformData)
            {
                [cache setObject:waveformData forKey:waveformCacheKey];
            }
            if (!weakOperation.isCancelled)
            {
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    completion(waveformData);
                }];
            }
        }];
        
        [[[self class] sharedWaveformOperationQueue] addOperation:operation];
    }
}

//------------------------------------------------------------------------------

- (AudioStreamBasicDescription)clientFormat
{
    return self.info.clientFormat;
}

//------------------------------------------------------------------------------

- (AudioStreamBasicDescription)fileFormat
{
    return self.info.fileFormat;
}

//------------------------------------------------------------------------------

- (SInt64)frameIndex
{
    SInt64 frameIndex;
    [EZAudio checkResult:ExtAudioFileTell(self.info.extAudioFileRef, &frameIndex)
               operation:"Failed to get frame index"];
    return frameIndex;
}

//------------------------------------------------------------------------------

- (NSDictionary *)metadata
{
    // get size of metadata property (dictionary)
    UInt32          propSize = sizeof(_info.audioFileID);
    CFDictionaryRef metadata;
    UInt32          writable;
    [EZAudio checkResult:AudioFileGetPropertyInfo(self.info.audioFileID,
                                                  kAudioFilePropertyInfoDictionary,
                                                  &propSize,
                                                  &writable)
               operation:"Failed to get the size of the metadata dictionary"];
    
    // pull metadata
    [EZAudio checkResult:AudioFileGetProperty(self.info.audioFileID,
                                              kAudioFilePropertyInfoDictionary,
                                              &propSize,
                                              &metadata)
               operation:"Failed to get metadata dictionary"];
    
    // cast to NSDictionary
    return (__bridge NSDictionary*)metadata;
}

//------------------------------------------------------------------------------

- (NSTimeInterval)totalDuration
{
    SInt64 totalFrames = [self totalFrames];
    return (NSTimeInterval) totalFrames / self.info.fileFormat.mSampleRate;
}

//------------------------------------------------------------------------------

- (SInt64)totalClientFrames
{
    SInt64 totalFrames = [self totalFrames];
    
    // check sample rate of client vs file format
    AudioStreamBasicDescription clientFormat = self.info.clientFormat;
    AudioStreamBasicDescription fileFormat   = self.info.fileFormat;
    BOOL sameSampleRate = clientFormat.mSampleRate == fileFormat.mSampleRate;
    if (!sameSampleRate)
    {
        NSTimeInterval duration = [self totalDuration];
        totalFrames = duration * clientFormat.mSampleRate;
    }
    
    return totalFrames;
}

//------------------------------------------------------------------------------

- (SInt64)totalFrames
{
    SInt64 totalFrames;
    UInt32 size = sizeof(SInt64);
    [EZAudio checkResult:ExtAudioFileGetProperty(self.info.extAudioFileRef,
                                                 kExtAudioFileProperty_FileLengthFrames,
                                                 &size,
                                                 &totalFrames)
               operation:"Failed to get total frames"];
    return totalFrames;
}

//------------------------------------------------------------------------------

- (NSURL*)url
{
  return (__bridge NSURL*)self.info.sourceURL;
}

//------------------------------------------------------------------------------
#pragma mark - Setters
//------------------------------------------------------------------------------

- (void)setClientFormat:(AudioStreamBasicDescription)clientFormat
{
    NSAssert([EZAudio isLinearPCM:clientFormat], @"Client format must be linear PCM");
    
    // store the client format
    _info.clientFormat = clientFormat;
    
    // set the client format on the extended audio file ref
    [EZAudio checkResult:ExtAudioFileSetProperty(self.info.extAudioFileRef,
                                                 kExtAudioFileProperty_ClientDataFormat,
                                                 sizeof(clientFormat),
                                                 &clientFormat)
               operation:"Couldn't set client data format on file"];
    
    // create a new float converter using the client format as the input format
    self.floatConverter = [EZAudioFloatConverter converterWithInputFormat:clientFormat];
    
    UInt32 maxPacketSize;
    UInt32 propSize = sizeof(maxPacketSize);
    [EZAudio checkResult:ExtAudioFileGetProperty(self.info.extAudioFileRef,
                                                 kExtAudioFileProperty_ClientMaxPacketSize,
                                                 &propSize,
                                                 &maxPacketSize)
               operation:"Failed to get max packet size"];
    
    
    
    // figure out what the max packet size is
    
    if (self.floatData)
    {
        [EZAudio freeFloatBuffers:self.floatData
                 numberOfChannels:self.clientFormat.mChannelsPerFrame];
        
        self.floatData = NULL;
    }
    
    self.floatData = [EZAudio floatBuffersWithNumberOfFrames:1024
                                            numberOfChannels:self.clientFormat.mChannelsPerFrame];
}

//------------------------------------------------------------------------------

-(void)dealloc
{
    pthread_mutex_destroy(&_lock);
    [EZAudio freeFloatBuffers:self.floatData numberOfChannels:self.clientFormat.mChannelsPerFrame];
    [EZAudio checkResult:AudioFileClose(self.info.audioFileID) operation:"Failed to close audio file"];
    [EZAudio checkResult:ExtAudioFileDispose(self.info.extAudioFileRef) operation:"Failed to dispose of ext audio file"];
}

//------------------------------------------------------------------------------
#pragma mark - Waveform Operation Queue
//------------------------------------------------------------------------------

+ (NSOperationQueue *)sharedWaveformOperationQueue
{
    static NSOperationQueue *operationQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.maxConcurrentOperationCount = 3;
    });
    return operationQueue;
}

//------------------------------------------------------------------------------

- (void)cancelWaveformDataOperation
{
    [self.waveformOperation cancel];
    self.waveformOperation = nil;
}

//------------------------------------------------------------------------------
#pragma mark - Waveform Cache
//------------------------------------------------------------------------------

+ (NSCache *)sharedWaveformCache
{
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *__unused notification) {
            [cache removeAllObjects];
        }];
    });
    return cache;
}

@end
