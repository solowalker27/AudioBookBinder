//
//  Copyright (c) 2010-2016 Oleksandr Tymoshenko <gonzo@bluezbox.com>
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

#include "MetaEditor.h"

#include <mp4v2/mp4v2.h>
#import "Chapter.h"
#import "MP4File.h"

using namespace std;

int addChapters(const char *mp4, NSArray *chapters)
{
    // Flatten file-relative imports into the existing chapter timeline. A marker
    // at a group boundary replaces its generated name, avoiding a zero interval.
    NSMutableArray<MP4Chapter *> *markers = [NSMutableArray array];
    uint64_t offset = 0;
    for (Chapter *chapter in chapters) {
        if (!chapter.files.count) continue;
        [markers addObject:[[MP4Chapter alloc] initWithTitle:chapter.name ?: @"" startMilliseconds:offset]];
        for (AudioFile *file in chapter.files) {
            for (MP4Chapter *marker in file.chapterMarkers) {
                if (marker.startMilliseconds >= file.duration.unsignedLongLongValue) return -1;
                uint64_t start = offset + marker.startMilliseconds;
                if (markers.lastObject.startMilliseconds == start) [markers removeLastObject];
                [markers addObject:[[MP4Chapter alloc] initWithTitle:marker.title startMilliseconds:start]];
            }
            offset += file.duration.unsignedLongLongValue;
        }
    }
    NSUInteger numChapters = markers.count;
    if (!numChapters) return 0;
    if (numChapters > UINT32_MAX) return -1;
    for (NSUInteger i = 0; i < numChapters; i++) {
        MP4Chapter *marker = markers[i];
        NSData *title = [marker.title dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t end = i + 1 < numChapters ? markers[i + 1].startMilliseconds : offset;
        if (end <= marker.startMilliseconds || !title || title.length > MP4V2_CHAPTER_TITLE_MAX ||
            (title.length && memchr(title.bytes, 0, title.length))) return -1;
    }

    MP4FileHandle h = MP4Modify( mp4 );
    
    if( h == MP4_INVALID_FILE_HANDLE )
        return -1;

    
    MP4Chapter_t *mp4chapters;
    
    mp4chapters = (MP4Chapter_t*)malloc(numChapters * sizeof(MP4Chapter_t));
    if (!mp4chapters) {
        MP4Close(h);
        return -1;
    }
    for (NSUInteger i = 0; i < numChapters; i++) {
        MP4Chapter *marker = markers[i];
        MP4Chapter_t *chap = &mp4chapters[i];
        memset(chap, 0, sizeof(*chap));
        uint64_t end = i + 1 < numChapters ? markers[i + 1].startMilliseconds : offset;
        chap->duration = end - marker.startMilliseconds;
        memcpy(chap->title, marker.title.UTF8String, [marker.title lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }

    MP4ChapterType result = MP4SetChapters(h, mp4chapters, (uint32_t)numChapters, MP4ChapterTypeQt);
    free(mp4chapters);
    MP4Close(h);
    
    return result == MP4ChapterTypeNone ? -1 : 0;
}
