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

#import <Cocoa/Cocoa.h>

@class MP4Atom;

@interface MP4Chapter : NSObject <NSCopying>
@property (copy) NSString *title;
@property uint64_t startMilliseconds;
- (instancetype)initWithTitle:(NSString *)title startMilliseconds:(uint64_t)start;
+ (NSString *)timestampForMilliseconds:(uint64_t)milliseconds;
+ (BOOL)parseTimestamp:(NSString *)text milliseconds:(uint64_t *)milliseconds;
@end

@interface MP4File : NSObject

@property (copy) NSString *artist;
@property (copy) NSString *narrator;
@property (copy) NSString *album;
@property (copy) NSString *title;
@property (copy) NSString *coverFile;
@property (copy) NSString *genre;
@property (assign) unsigned short track, tracksTotal;
@property (assign) BOOL gaplessPlay;
// Loaded embedded artwork; assign PNG/JPEG data to replace it. Use removeCover to clear it.
@property (copy) NSData *coverData;
@property (assign) BOOL removeCover;
@property (copy) NSArray<MP4Chapter *> *chapters;
// Audio track duration, independent of the existing chapter track's duration.
@property (readonly) uint64_t durationMilliseconds;

-(id) initWithFileName: (NSString*)fileName;
-(BOOL) updateFile;
// Load existing tags, then save edits through a replacement copy without encoding audio.
// Unchanged tags are preserved; empty strings remove edited text tags.
-(BOOL) readMetadataWithError:(NSError **)error;
-(BOOL) validateChaptersWithError:(NSError **)error;
-(BOOL) saveMetadataWithError:(NSError **)error;

@end
