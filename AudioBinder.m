//
//  Copyright (c) 2009-2016 Oleksandr Tymoshenko <gonzo@bluezbox.com>
//  All rights reserved.
// 
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  1. Redistributions of source code must retain the above copyright
//     notice unmodified, this list of conditions, and the following
//     disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 
//  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
//  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
//  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
//  SUCH DAMAGE.
//

#import <CoreServices/CoreServices.h>
#import <stdatomic.h>
#import <AudioToolbox/AudioConverter.h>

#import "AudioBinder.h"
#import "AudioBookVolume.h"
#import "ABBLog.h"

// 1M seems to be sane buffer size nowadays
#define AUDIO_BUFFER_SIZE 1*1024*1024

// Helper function
static NSString * 
stringForOSStatus(OSStatus err)
{
    // TODO: add proper description
    NSString * descString;
    BOOL isOSType = YES;
    char osTypeRepr[5];
    char *errStr = NULL;
    
    // Check if err is OSType and convert it to 4 chars representation
    osTypeRepr[4] = 0;
    for (int i = 0; i < 4; i++)
    {
        unsigned char c = (err >> 8*i) & 0xff;
        if (isprint(c))
            osTypeRepr[3-i] = c;
        else
        {
            isOSType = NO;
            break;
        }
    }
    
    switch (err) {
        case 0x7479703f:
            errStr = "Unsupported file type";
            break;
        case 0x666d743f:
            errStr = "Unsupported data format";
            break;
        case 0x7074793f:
            errStr = "Unsupported property";
            break;
        case 0x2173697a:
            errStr = "Bad property size";
            break;
        case 0x70726d3f:
            errStr = "Permission denied";
            break;
        case 0x6f70746d:
            errStr = "Not optimized";
            break;
        case 0x63686b3f:
            errStr = "Invalid chunk";
            break;
        case 0x6f66663f:
            errStr = "Does not allow 64bit data size";
            break;
        case 0x70636b3f:
            errStr = "Invalid packet offset";
            break;
        case 0x6474613f:
            errStr = "Invalid file";
            break;
        default:
            errStr = nil;
            break;
    }

    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
    const char *errDescr = isOSType ? (errStr ? errStr : osTypeRepr) : [error.description cStringUsingEncoding:NSUTF8StringEncoding];
    if ((errDescr != nil) && (strlen(errDescr) > 0))
        descString = [[NSString alloc] initWithFormat:@"err#%08lx (%s)", (long)err, errDescr];
    else
        descString = [[NSString alloc] initWithFormat:@"err#%08lx ", (long)err];
    
    return descString;
}

@interface AudioBinder() {
    ExtAudioFileRef _outAudioFile;
    SInt64 _outFileLength;
    SInt64 _outBookLength;
    __weak id<AudioBinderDelegate> _delegate;
    atomic_bool _canceled;
    BOOL _bitrateSet;
}
@end

@implementation AudioBinder

-(id)init
{
    if ((self = [super init])) {
        _volumes = [[NSMutableArray alloc] init];
        [self reset];
    }
 
    return self;
}

- (void) reset
{
    [_volumes removeAllObjects];
    _outAudioFile = nil;
    _outFileLength = 0;
    _outBookLength = 0;
    _delegate = nil;
    atomic_store(&_canceled, false);
    _sampleRate = DEFAULT_SAMPLE_RATE;
    _channels = 2;
    _bitrate = 0;
    _bitrateSet = NO;
}

-(void)setDelegate: (id<AudioBinderDelegate>)delegate
{
    _delegate = delegate;
}

-(void) addVolume:(NSString*)filename files:(NSArray*)files
{
    AudioBookVolume *volume = [[AudioBookVolume alloc] initWithName:filename files:files];
    [_volumes addObject:volume];
}

-(BOOL)convert
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *outputs = [NSMutableArray array];
    NSMutableSet *destinations = [NSMutableSet set];
    BOOL success = NO;
    NSUInteger filesConverted = 0;
    _outBookLength = 0;

    if (!isfinite(_sampleRate) || _sampleRate <= 0 || (_channels != 1 && _channels != 2)) {
        [_delegate volumeFailed:@"" reason:@"Invalid sample rate or channel count"];
        return NO;
    }

    // Validate the entire job before touching any existing file, including input aliases.
    for (AudioBookVolume *volume in _volumes) {
        NSString *destination = volume.filename.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (volume.inputFiles.count == 0 || [destinations containsObject:destination]) {
            [_delegate volumeFailed:volume.filename reason:@"Empty volume or duplicate output path"];
            return NO;
        }
        for (AudioBookVolume *sourceVolume in _volumes) {
            for (AudioFile *input in sourceVolume.inputFiles) {
                NSString *source = input.filePath.stringByStandardizingPath.stringByResolvingSymlinksInPath;
                NSDictionary *sourceAttrs = [fm attributesOfItemAtPath:source error:nil];
                NSDictionary *destAttrs = [fm attributesOfItemAtPath:destination error:nil];
                BOOL sameFile = sourceAttrs && destAttrs &&
                    [sourceAttrs[NSFileSystemNumber] isEqual:destAttrs[NSFileSystemNumber]] &&
                    [sourceAttrs[NSFileSystemFileNumber] isEqual:destAttrs[NSFileSystemFileNumber]];
                if ([destination isEqualToString:source] || sameFile) {
                    [_delegate volumeFailed:volume.filename reason:@"The output must not replace an input file"];
                    return NO;
                }
            }
        }
        BOOL directory = NO;
        if ([fm fileExistsAtPath:destination isDirectory:&directory] && directory) {
            [_delegate volumeFailed:volume.filename reason:@"The output path is a directory"];
            return NO;
        }
        [destinations addObject:destination];
    }

    @try {
        for (AudioBookVolume *volume in _volumes) {
            if (atomic_load(&_canceled)) return NO;
            NSError *error = nil;
            NSURL *replacementDirectory = [fm URLForDirectory:NSItemReplacementDirectory
                                                     inDomain:NSUserDomainMask
                                            appropriateForURL:[NSURL fileURLWithPath:volume.filename]
                                                       create:YES error:&error];
            if (!replacementDirectory) {
                [_delegate volumeFailed:volume.filename reason:error.localizedDescription];
                return NO;
            }
            NSString *directory = replacementDirectory.path;
            NSString *staged = [directory stringByAppendingPathComponent:@"audio.m4b"];
            NSMutableDictionary *output = [@{@"directory": directory, @"staged": staged, @"destination": volume.filename} mutableCopy];
            [outputs addObject:output];
            if (![self openOutFile:staged]) {
                [_delegate volumeFailed:volume.filename reason:@"Can't create output file"];
                return NO;
            }
            NSUInteger volumeFiles = 0;
            for (AudioFile *input in volume.inputFiles) {
                NSString *reason = nil;
                if ([self convertOneFile:input reason:&reason]) {
                    filesConverted++;
                    volumeFiles++;
                } else if (![_delegate continueFailedConversion:input reason:reason]) {
                    return NO;
                }
                if (atomic_load(&_canceled)) return NO;
            }
            // Disposing flushes the encoder and writes its MP4 headers; failure is fatal.
            OSStatus status = ExtAudioFileDispose(_outAudioFile);
            _outAudioFile = NULL;
            if (status != noErr || volumeFiles == 0) {
                [_delegate volumeFailed:volume.filename reason:@"Could not finalize the audio file"];
                return NO;
            }
            _outBookLength += _outFileLength;
            output[@"duration"] = @((UInt32)(_outFileLength / _sampleRate));
        }
        if (filesConverted == 0 || atomic_load(&_canceled)) return NO;

        // Stage every volume first. Backups allow rollback if installing any volume fails.
        for (NSMutableDictionary *output in outputs) {
            NSString *destination = output[@"destination"];
            NSError *error = nil;
            if ([fm fileExistsAtPath:destination]) {
                NSString *backup = [output[@"directory"] stringByAppendingPathComponent:@"previous"];
                if (![fm moveItemAtPath:destination toPath:backup error:&error]) {
                    [_delegate volumeFailed:destination reason:error.localizedDescription];
                    return NO;
                }
                output[@"backup"] = backup;
            }
            if (![fm moveItemAtPath:output[@"staged"] toPath:destination error:&error]) {
                [_delegate volumeFailed:destination reason:error.localizedDescription];
                return NO;
            }
            output[@"installed"] = @YES;
        }
        success = YES;
        for (NSDictionary *output in outputs) [_delegate volumeReady:output[@"destination"] duration:[output[@"duration"] unsignedIntValue]];
        [_delegate audiobookReady:(UInt32)(_outBookLength / _sampleRate)];
        return YES;
    } @finally {
        [self closeOutFile];
        for (NSDictionary *output in outputs.reverseObjectEnumerator) {
            BOOL restored = YES;
            if (!success) {
                if ([output[@"installed"] boolValue]) [fm removeItemAtPath:output[@"destination"] error:nil];
                if (output[@"backup"]) {
                    NSError *error = nil;
                    restored = [fm moveItemAtPath:output[@"backup"] toPath:output[@"destination"] error:&error];
                    if (!restored) [_delegate volumeFailed:output[@"destination"] reason:[NSString stringWithFormat:@"Previous file preserved at %@: %@", output[@"backup"], error.localizedDescription]];
                }
            }
            if (restored) [fm removeItemAtPath:output[@"directory"] error:nil];
        }
        atomic_store(&_canceled, false);
    }
}

-(BOOL)openOutFile:(NSString*)outFile
{
    OSStatus status;
    AudioStreamBasicDescription outputFormat;
    
    // delete file if exists
    if([[NSFileManager defaultManager] fileExistsAtPath:outFile]) 
    {
        if (![[NSFileManager defaultManager] removeItemAtPath:outFile 
                                                      error:nil])
        {
            ABBLog(@"Can't remove file %@", outFile);
            return NO;
        }
    }    
   
    id url = [NSURL fileURLWithPath:outFile];
    
    memset(&outputFormat, 0, sizeof(AudioStreamBasicDescription));
    outputFormat.mSampleRate = _sampleRate;
    outputFormat.mFormatID = kAudioFormatMPEG4AAC;
    outputFormat.mChannelsPerFrame = _channels;
   
    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url,
                                   kAudioFileMPEG4Type, &outputFormat, 
                                   NULL, kAudioFileFlags_EraseFile, &_outAudioFile);
    
    if (status != noErr)
    {
        ABBLog(@"Can't create output file %@: %@", 
              outFile, stringForOSStatus(status));
        return NO;
    }
    
    // reset output file length
    _outFileLength = 0;
    _bitrateSet = NO;

    return YES;
}

-(void)closeOutFile
{
    if (_outAudioFile != nil)
        ExtAudioFileDispose(_outAudioFile);
    _outAudioFile = nil;
}

-(BOOL) convertOneFile: (AudioFile *)inFile reason: (NSString**)reason
{
    // Get description
    NSString *fileFormat;
    UInt32 specSize;
    OSStatus status;

    ExtAudioFileRef inAudioFile = nil;
    AudioStreamBasicDescription format;    
    AudioStreamBasicDescription pcmFormat;      
    UInt32 size;
    AudioConverterRef conv = NULL;
    UInt64 framesTotal = 0, framesConverted = 0;
    UInt32 framesToRead = 0;
    AudioBufferList bufferList;
    void *audioBuffer = NULL;
        
    @try {

        id url = [NSURL fileURLWithPath:inFile.filePath];
        status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &inAudioFile);
        if (status != noErr)
            [NSException raise:@"ConvertException" 
                format:@"ExtAudioFileOpenURL failed: %@", 
                stringForOSStatus(status)];
        
        // Query file type
        size = sizeof(AudioStreamBasicDescription);
        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_FileDataFormat,
                                         &size, &format);
        if(status != noErr)
            [NSException raise:@"ConvertException" 
                format:@"AudioFileGetProperty failed: %@", 
             stringForOSStatus(status)];
        
        specSize = sizeof(fileFormat);
        size = sizeof(AudioStreamBasicDescription);
        status = AudioFormatGetProperty(kAudioFormatProperty_FormatName, 
                                        size, &format, &specSize, &fileFormat);
        
        if(status != noErr) 
            [NSException raise:@"ConvertException" 
                format:@"AudioFormatGetProperty failed: %@", 
                stringForOSStatus(status)];        

        size = sizeof(framesTotal);
        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_FileLengthFrames,
                                         &size, &framesTotal);
        
        if(status != noErr)
            [NSException raise:@"ConvertException" 
                        format:@"can't get input file length: %@", 
             stringForOSStatus(status)];
        
        [_delegate conversionStart: inFile 
                            format: &format
                 formatDescription: fileFormat
                            length: framesTotal];        
        // framesTotal was calculated with respect to original format
        // in order to get proper progress dialog we need convert to to client
        // format
        framesTotal = (framesTotal * _sampleRate) / format.mSampleRate;

        // Setup input format descriptor, preserve mSampleRate
        bzero(&pcmFormat, sizeof(pcmFormat));
        pcmFormat.mSampleRate = _sampleRate;
        pcmFormat.mFormatID = kAudioFormatLinearPCM;
        pcmFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger 
            | kAudioFormatFlagIsBigEndian 
            | kAudioFormatFlagIsPacked;

        pcmFormat.mBitsPerChannel = 16;
        pcmFormat.mChannelsPerFrame = _channels;
        pcmFormat.mFramesPerPacket = 1;
        pcmFormat.mBytesPerPacket = 
            (pcmFormat.mBitsPerChannel / 8) * pcmFormat.mChannelsPerFrame;
        pcmFormat.mBytesPerFrame = 
            pcmFormat.mBytesPerPacket * pcmFormat.mFramesPerPacket;

        status = ExtAudioFileSetProperty(inAudioFile, 
                                         kExtAudioFileProperty_ClientDataFormat, 
                                         sizeof(pcmFormat), &pcmFormat);
        if(status != noErr)
            [NSException raise:@"ConvertException" 
                format:@"ExtAudioFileSetProperty(ClientDataFormat) failed: %@", 
                stringForOSStatus(status)];

        // Get the underlying AudioConverterRef
        size = sizeof(AudioConverterRef);

        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_AudioConverter, 
                                         &size, &conv);
        if(status != noErr)
            [NSException raise:@"ConvertException" 
                        format:@"can't get AudioConverter: %@", 
                        stringForOSStatus(status)]; 
        
        // Convert mono files to stereo by duplicating channel
        if ((format.mChannelsPerFrame == 1) && (_channels == 2))
        {
            if (conv)
            {
                SInt32 channelMap[] = { 0, 0 };
                status = AudioConverterSetProperty(conv, 
                                                   kAudioConverterChannelMap, 
                                                   2*sizeof(SInt32), 
                                                   channelMap);
                if(status != noErr)
                    [NSException raise:@"ConvertException" 
                                format:@"Can't set ChannelMap: %@", 
                                stringForOSStatus(status)];             
            }
            else
            {
                [NSException raise:@"ConvertException" 
                            format:@"Can't get AudioConverter ref"];             
                
            }
        }

        status = ExtAudioFileSetProperty(_outAudioFile, 
                                         kExtAudioFileProperty_ClientDataFormat, 
                                         sizeof(pcmFormat), &pcmFormat);
        if(status != noErr)
            [NSException raise:@"ConvertException" 
                format:@"can't set ClientDataFormat: %@", 
                stringForOSStatus(status)];
        
        if (_bitrate > 0) {
            if (!_bitrateSet) {
                if (![self setConverterBitrate]) {
                    [NSException raise:@"ConvertException" 
                        format:@"can't set output bit rate"]; 
                }
                _bitrateSet = YES;
            }
        }
        
        audioBuffer = malloc(AUDIO_BUFFER_SIZE);
        if (!audioBuffer) [NSException raise:@"ConvertException" format:@"Unable to allocate audio buffer"];
        bufferList.mNumberBuffers = 1;
        bufferList.mBuffers[0].mNumberChannels = pcmFormat.mChannelsPerFrame;
        bufferList.mBuffers[0].mData = audioBuffer;
        bufferList.mBuffers[0].mDataByteSize = AUDIO_BUFFER_SIZE;
                
        do {
            bufferList.mBuffers[0].mDataByteSize = AUDIO_BUFFER_SIZE;
            
            framesToRead = 
                bufferList.mBuffers[0].mDataByteSize / pcmFormat.mBytesPerFrame;
            status = ExtAudioFileRead(inAudioFile, &framesToRead, &bufferList);
            if(status != noErr)
                [NSException raise:@"ConvertException" 
                            format:@"ExtAudioFileRead failed: %@", 
                            stringForOSStatus(status)];
            
            if (framesToRead > 0) 
            {
                status = ExtAudioFileWrite(_outAudioFile, 
                                           framesToRead, &bufferList);
                if(status != noErr)
                    [NSException raise:@"ConvertException" 
                        format:@"ExtAudioFileWrite failed: %@", 
                        stringForOSStatus(status)];
            }

            framesConverted += framesToRead;

            [_delegate updateStatus:inFile 
                            handled:framesConverted 
                              total:framesTotal];

            status = ExtAudioFileTell(_outAudioFile, &_outFileLength);
            if(status != noErr)
                [NSException raise:@"ConvertException" 
                            format:@"ExtAudioFileTell failed: %@", 
                 stringForOSStatus(status)];
            
            if (atomic_load(&_canceled))
                break;

        } while(framesToRead > 0);


        if (!atomic_load(&_canceled)) {
            // A float sample rate would force the entire expression to float,
            // losing milliseconds on long books. Round once at the output boundary.
            UInt32 duration = (UInt32)llround((double)framesConverted * 1000.0 / (double)_sampleRate);
            [_delegate conversionFinished:inFile duration:duration];
        }
    }  
    @catch (NSException *e) {
        if (reason) *reason = [e reason];
        if (inAudioFile != nil)
            ExtAudioFileDispose(inAudioFile);
        if (audioBuffer)
            free(audioBuffer);
        return NO;
    }
    
    // _needNextVolume = YES;
    
    if (inAudioFile != nil)
        ExtAudioFileDispose(inAudioFile);
    if (audioBuffer)
        free(audioBuffer);

    return YES;
}

- (void) cancel
{
    atomic_store(&_canceled, true);
}

-(NSArray*) validBitrates
{
    OSStatus status;
    ExtAudioFileRef tmpAudioFile;
    AudioConverterRef outConverter;
    NSMutableArray *validBitrates = [[NSMutableArray alloc] init];
    UInt32 size;
    
    AudioStreamBasicDescription outputFormat, pcmFormat;  
    
    // open out file
    NSString *dir = NSTemporaryDirectory();
    NSString *file = [dir stringByAppendingFormat:@"/%@",
                      [[NSProcessInfo processInfo] globallyUniqueString]];

    
    memset(&outputFormat, 0, sizeof(AudioStreamBasicDescription));
    outputFormat.mSampleRate = _sampleRate;
    outputFormat.mFormatID = kAudioFormatMPEG4AAC;
    outputFormat.mChannelsPerFrame = _channels;
    
    id url = [NSURL fileURLWithPath:file];
    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url,
                                   kAudioFileMPEG4Type, &outputFormat, 
                                   NULL, kAudioFileFlags_EraseFile, &tmpAudioFile);
    
    if (status != noErr)
        return validBitrates;
    
    // Setup input format descriptor, preserve mSampleRate
    bzero(&pcmFormat, sizeof(pcmFormat));
    pcmFormat.mSampleRate = _sampleRate;
    pcmFormat.mFormatID = kAudioFormatLinearPCM;
    pcmFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger 
                                | kAudioFormatFlagIsBigEndian 
                                | kAudioFormatFlagIsPacked;
    
    pcmFormat.mBitsPerChannel = 16;
    pcmFormat.mChannelsPerFrame = _channels;
    pcmFormat.mFramesPerPacket = 1;
    pcmFormat.mBytesPerPacket = 
    (pcmFormat.mBitsPerChannel / 8) * pcmFormat.mChannelsPerFrame;
    pcmFormat.mBytesPerFrame = 
    pcmFormat.mBytesPerPacket * pcmFormat.mFramesPerPacket;
    
    status = ExtAudioFileSetProperty(tmpAudioFile, 
                                     kExtAudioFileProperty_ClientDataFormat, 
                                     sizeof(pcmFormat), &pcmFormat);

    if(status != noErr) {
        ExtAudioFileDispose(tmpAudioFile);
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        return validBitrates;
    }
    
    // Get the underlying AudioConverterRef
    size = sizeof(AudioConverterRef);
    status = ExtAudioFileGetProperty(tmpAudioFile, 
                                     kExtAudioFileProperty_AudioConverter, 
                                     &size, &outConverter);
    
    if(status != noErr) {
        ExtAudioFileDispose(tmpAudioFile);
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        return validBitrates;
    }
    
    size = 0;
    // Get the available bitrates (CBR)
    status = AudioConverterGetPropertyInfo(outConverter, 
                                           kAudioConverterApplicableEncodeBitRates, 
                                           &size, NULL);
    if(noErr != status) {
        ExtAudioFileDispose(tmpAudioFile);
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        return validBitrates;
    }

    AudioValueRange *bitrates = malloc(size);
    NSCAssert(NULL != bitrates, 
              NSLocalizedStringFromTable(@"Unable to allocate memory.", @"Exceptions", @""));
    
    status = AudioConverterGetProperty(outConverter, 
                                       kAudioConverterApplicableEncodeBitRates, 
                                       &size, bitrates);

    if(noErr == status) {
        int bitrateCount = size / sizeof(AudioValueRange);

        for(int n = 0; n < bitrateCount; ++n) {
            unsigned long minRate = (unsigned long) bitrates[n].mMinimum;
            if(0 != minRate) {
                [validBitrates addObject:[NSNumber numberWithUnsignedLong: minRate]];
            }
        }
    }
    
    free(bitrates);
    
    ExtAudioFileDispose(tmpAudioFile);
    [[NSFileManager defaultManager] removeItemAtPath:file error:nil];

    return validBitrates;
    
}


-(BOOL) setConverterBitrate
{
    OSStatus status;
    AudioConverterRef outConverter;
    UInt32 size;
    
    // Get the underlying AudioConverterRef
    size = sizeof(AudioConverterRef);
    status = ExtAudioFileGetProperty(_outAudioFile, 
                                     kExtAudioFileProperty_AudioConverter, 
                                     &size, &outConverter);
    
    if(status != noErr)
        return NO;
    
    status = AudioConverterSetProperty(outConverter, kAudioConverterEncodeBitRate, 
                                       sizeof(_bitrate), &_bitrate);
    if(status != noErr)
        return NO;
    
    return YES;
    
}

@end
