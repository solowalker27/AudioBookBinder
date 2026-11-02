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

#import "MP4File.h"
#import <mp4v2/mp4v2.h>

@interface MP4File ()
@property (copy) NSString *fileName;
@property (copy) NSDictionary *originalValues;
@property (copy) NSDictionary *originalAttributes;
@property (copy) NSArray<MP4Chapter *> *originalChapters;
@property uint64_t durationMilliseconds;
@property uint64_t originalChapterEndMilliseconds;
@property MP4ChapterType chapterTypes;
@end

@implementation MP4Chapter

- (instancetype)initWithTitle:(NSString *)title startMilliseconds:(uint64_t)start
{
    if ((self = [super init])) { _title = [title copy]; _startMilliseconds = start; }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[MP4Chapter allocWithZone:zone] initWithTitle:self.title startMilliseconds:self.startMilliseconds];
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:MP4Chapter.class] && self.startMilliseconds == [object startMilliseconds] &&
           [self.title isEqual:[object title]];
}

- (NSUInteger)hash { return self.title.hash ^ (NSUInteger)self.startMilliseconds; }

+ (NSString *)timestampForMilliseconds:(uint64_t)milliseconds
{
    return [NSString stringWithFormat:@"%02llu:%02llu:%02llu.%03llu",
            (unsigned long long)(milliseconds / 3600000),
            (unsigned long long)(milliseconds / 60000 % 60),
            (unsigned long long)(milliseconds / 1000 % 60),
            (unsigned long long)(milliseconds % 1000)];
}

+ (BOOL)parseTimestamp:(NSString *)text milliseconds:(uint64_t *)milliseconds
{
    NSArray<NSString *> *parts = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@":"];
    if (parts.count < 1 || parts.count > 3) return NO;
    uint64_t seconds = 0, fraction = 0;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSArray<NSString *> *decimal = [parts[i] componentsSeparatedByString:@"."];
        if (decimal.count > 2 || (decimal.count == 2 && i != parts.count - 1)) return NO;
        NSString *digits = decimal[0];
        if (!digits.length) return NO;
        uint64_t value = 0;
        for (NSUInteger j = 0; j < digits.length; j++) {
            unichar c = [digits characterAtIndex:j];
            if (c < '0' || c > '9' || value > (UINT64_MAX - (c - '0')) / 10) return NO;
            value = value * 10 + c - '0';
        }
        if (i > 0 && value >= 60) return NO;
        if (seconds > (UINT64_MAX - value) / 60) return NO;
        seconds = seconds * 60 + value;
        if (decimal.count == 2) {
            NSString *digits = decimal[1];
            if (!digits.length || digits.length > 3) return NO;
            for (NSUInteger j = 0; j < digits.length; j++) {
                unichar c = [digits characterAtIndex:j];
                if (c < '0' || c > '9') return NO;
                fraction = fraction * 10 + c - '0';
            }
            for (NSUInteger j = digits.length; j < 3; j++) fraction *= 10;
        }
    }
    if (seconds > (UINT64_MAX - fraction) / 1000) return NO;
    if (milliseconds) *milliseconds = seconds * 1000 + fraction;
    return YES;
}

@end

static NSString *TagString(const char *value)
{
    return value ? ([NSString stringWithUTF8String:value] ?: @"") : @"";
}

static BOOL MetadataError(NSError **error, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:@"AudioBookBinder.Metadata" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@implementation MP4File

- (id)initWithFileName:(NSString *)fileName
{
    if ((self = [super init])) {
        _fileName = [fileName copy];
        _genre = @"Audiobooks";
    }
    return self;
}

- (NSDictionary *)editableValues
{
    return @{@"title": self.title ?: @"", @"artist": self.artist ?: @"",
             @"album": self.album ?: @"", @"genre": self.genre ?: @"",
             @"narrator": self.narrator ?: @""};
}

- (BOOL)readMetadataWithError:(NSError **)error
{
    self.originalValues = nil;
    self.originalAttributes = nil;
    self.fileName = self.fileName.stringByResolvingSymlinksInPath;
    MP4FileHandle handle = MP4Read(self.fileName.fileSystemRepresentation);
    if (handle == MP4_INVALID_FILE_HANDLE)
        return MetadataError(error, NSLocalizedString(@"This file could not be opened as an MPEG-4 audiobook.", nil));
    const MP4Tags *tags = MP4TagsAlloc();
    @try {
        if (!tags || !MP4TagsFetch(tags, handle))
            return MetadataError(error, NSLocalizedString(@"The audiobook’s metadata could not be read.", nil));
        if (MP4GetNumberOfTracks(handle, MP4_AUDIO_TRACK_TYPE, 0) == 0)
            return MetadataError(error, NSLocalizedString(@"This file does not contain an audio track.", nil));
        self.title = TagString(tags->name);
        self.artist = TagString(tags->artist);
        self.album = TagString(tags->album);
        self.genre = TagString(tags->genre);
        self.narrator = TagString(tags->composer);
        MP4ItmfItemList *items = MP4ItmfGetItemsByCode(handle, "\251nrt");
        if (items) {
            if (items->size && items->elements[0].dataList.size) {
                MP4ItmfData value = items->elements[0].dataList.elements[0];
                NSString *narrator = [[NSString alloc] initWithBytes:value.value length:value.valueSize encoding:NSUTF8StringEncoding];
                if (narrator) self.narrator = narrator;
            }
            MP4ItmfItemListFree(items);
        }
        self.track = tags->track ? tags->track->index : 0;
        self.tracksTotal = tags->track ? tags->track->total : 0;
        self.gaplessPlay = tags->gapless && *tags->gapless;
        self.coverData = tags->artworkCount ? [NSData dataWithBytes:tags->artwork[0].data length:tags->artwork[0].size] : nil;
        self.coverFile = nil;
        self.removeCover = NO;
        uint64_t duration = 0;
        uint32_t audioTracks = MP4GetNumberOfTracks(handle, MP4_AUDIO_TRACK_TYPE, 0);
        for (uint32_t i = 0; i < audioTracks; i++) {
            MP4TrackId track = MP4FindTrackId(handle, i, MP4_AUDIO_TRACK_TYPE, 0);
            if (!MP4GetTrackTimeScale(handle, track))
                return MetadataError(error, NSLocalizedString(@"The audio track has an invalid time scale.", nil));
            uint64_t presentation = 0;
            uint64_t trackDuration = MP4ConvertFromTrackDuration(handle, track, MP4GetTrackDuration(handle, track), MP4_MILLISECONDS_TIME_SCALE);
            // tkhd uses the movie timeline, including edits that trim AAC priming/padding.
            if (MP4GetTimeScale(handle) && MP4GetTrackIntegerProperty(handle, track, "tkhd.duration", &presentation) &&
                presentation && presentation != MP4_INVALID_DURATION)
                trackDuration = MP4ConvertFromMovieDuration(handle, presentation, MP4_MILLISECONDS_TIME_SCALE);
            duration = MAX(duration, trackDuration);
        }
        self.durationMilliseconds = duration;
        NSMutableArray *loadedChapters = [NSMutableArray array];
        self.chapterTypes = MP4ChapterTypeNone;
        self.originalChapterEndMilliseconds = 0;
        for (NSNumber *kind in @[@(MP4ChapterTypeQt), @(MP4ChapterTypeNero)]) {
            MP4Chapter_t *list = NULL;
            uint32_t count = 0;
            MP4ChapterType found = MP4GetChapters(handle, &list, &count, kind.intValue);
            if (found != MP4ChapterTypeNone && count) {
                self.chapterTypes = self.chapterTypes == MP4ChapterTypeNone ? found : MP4ChapterTypeAny;
                if (!loadedChapters.count) {
                    uint64_t start = 0;
                    for (uint32_t i = 0; i < count; i++) {
                        [loadedChapters addObject:[[MP4Chapter alloc] initWithTitle:TagString(list[i].title) startMilliseconds:start]];
                        start += list[i].duration;
                    }
                    self.originalChapterEndMilliseconds = start;
                }
            }
            if (list) MP4Free(list);
        }
        self.chapters = loadedChapters;
        self.originalChapters = [[NSArray alloc] initWithArray:loadedChapters copyItems:YES];
        NSMutableDictionary *values = [self.editableValues mutableCopy];
        if (self.coverData) values[@"coverData"] = self.coverData;
        self.originalValues = values;
        self.originalAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.fileName error:error];
        return self.originalAttributes != nil;
    } @finally {
        if (tags) MP4TagsFree(tags);
        MP4Close(handle, 0);
    }
}

- (BOOL)shouldWrite:(NSString *)key
{
    return !self.originalValues || ![self.originalValues[key] isEqual:self.editableValues[key]];
}

- (BOOL)metadataHasChanges
{
    for (NSString *key in self.editableValues)
        if ([self shouldWrite:key]) return YES;
    return self.coverFile || self.removeCover ||
           (self.coverData && ![self.coverData isEqual:self.originalValues[@"coverData"]]);
}

- (BOOL)writeMetadataToFile:(NSString *)fileName
{
    // The library maintains atom sizes and chunk offsets without re-encoding audio.
    MP4FileHandle handle = MP4Modify(fileName.fileSystemRepresentation, 0);
    if (handle == MP4_INVALID_FILE_HANDLE) return NO;
    const MP4Tags *tags = MP4TagsAlloc();
    if (!tags) { MP4Close(handle, 0); return NO; }
    BOOL result = NO;
    @try {
        if (!MP4TagsFetch(tags, handle)) return NO;
        if ([self shouldWrite:@"title"] && self.title) MP4TagsSetName(tags, self.title.length ? self.title.UTF8String : NULL);
        if ([self shouldWrite:@"artist"] && self.artist) MP4TagsSetArtist(tags, self.artist.length ? self.artist.UTF8String : NULL);
        if ([self shouldWrite:@"album"] && self.album) MP4TagsSetAlbum(tags, self.album.length ? self.album.UTF8String : NULL);
        if ([self shouldWrite:@"genre"] && self.genre) {
            MP4TagsSetGenre(tags, self.genre.length ? self.genre.UTF8String : NULL);
            MP4TagsSetGenreType(tags, NULL);
        }
        BOOL narratorChanged = [self shouldWrite:@"narrator"] && self.narrator != nil;
        if (narratorChanged) MP4TagsSetComposer(tags, self.narrator.length ? self.narrator.UTF8String : NULL);
        // Creation defaults must not overwrite flags or volume numbering in an existing book.
        if (!self.originalValues) {
            uint8_t mediaType = 2;
            MP4TagsSetMediaType(tags, &mediaType);
            if (self.track && self.tracksTotal > 1) {
                MP4TagTrack track = { self.track, self.tracksTotal };
                MP4TagsSetTrack(tags, &track);
            }
            uint8_t gapless = self.gaplessPlay;
            MP4TagsSetGapless(tags, &gapless);
        }
        BOOL artworkChanged = self.coverFile || (self.coverData && ![self.coverData isEqual:self.originalValues[@"coverData"]]);
        if (self.removeCover || artworkChanged) {
            NSData *data = self.coverFile ? [NSData dataWithContentsOfFile:self.coverFile] : self.coverData;
            MP4TagArtworkType type = MP4_ART_UNDEFINED;
            if (!self.removeCover) {
                if (data.length < 8 || data.length > UINT32_MAX) return NO;
                const unsigned char *bytes = data.bytes;
                if (bytes[0] == 0xff && bytes[1] == 0xd8) type = MP4_ART_JPEG;
                else if (memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0) type = MP4_ART_PNG;
                else return NO;
            }
            uint32_t count = tags->artworkCount;
            for (uint32_t i = 0; i < count; i++) if (!MP4TagsRemoveArtwork(tags, 0)) return NO;
            if (!self.removeCover) {
                MP4TagArtwork art = { (void *)data.bytes, (uint32_t)data.length, type };
                if (!MP4TagsAddArtwork(tags, &art)) return NO;
            }
        }
        result = MP4TagsStore(tags, handle);
        if (result && narratorChanged) {
            // Replace every old narrator atom, including duplicates from older releases.
            MP4ItmfItemList *items = MP4ItmfGetItemsByCode(handle, "\251nrt");
            if (!items) return NO;
            for (uint32_t i = 0; i < items->size; i++) {
                if (!MP4ItmfRemoveItem(handle, &items->elements[i])) result = NO;
            }
            MP4ItmfItemListFree(items);
            if (!result || !self.narrator.length) return result;
            MP4ItmfItem *item = MP4ItmfItemAlloc("\251nrt", 1);
            if (!item) return NO;
            NSData *name = [self.narrator dataUsingEncoding:NSUTF8StringEncoding];
            MP4ItmfData *value = &item->dataList.elements[0];
            value->typeCode = MP4_ITMF_BT_UTF8;
            value->valueSize = (uint32_t)name.length;
            value->value = malloc(name.length);
            if (value->value) {
                memcpy(value->value, name.bytes, name.length);
                result = MP4ItmfAddItem(handle, item);
            } else result = NO;
            MP4ItmfItemFree(item);
        }
    } @finally {
        MP4TagsFree(tags);
        MP4Close(handle, 0);
    }
    return result;
}

- (BOOL)updateFile
{
    return [self writeMetadataToFile:self.fileName];
}

- (BOOL)sourceIsUnchanged
{
    NSDictionary *current = [NSFileManager.defaultManager attributesOfItemAtPath:self.fileName error:nil];
    for (NSString *key in @[NSFileSystemNumber, NSFileSystemFileNumber, NSFileSize, NSFileModificationDate]) {
        if (![current[key] isEqual:self.originalAttributes[key]]) return NO;
    }
    return YES;
}

- (BOOL)validateChaptersWithError:(NSError **)error
{
    // Untouched chapter tracks may use unusual timing; preserve them as they are.
    if ([self.chapters isEqual:self.originalChapters]) return YES;
    BOOL nero = self.chapterTypes == MP4ChapterTypeNero || self.chapterTypes == MP4ChapterTypeAny;
    if (self.chapters.count > UINT32_MAX || (nero && self.chapters.count > 255))
        return MetadataError(error, NSLocalizedString(@"This chapter format supports at most 255 chapters.", nil));
    uint64_t previous = 0;
    for (NSUInteger i = 0; i < self.chapters.count; i++) {
        MP4Chapter *chapter = self.chapters[i];
        if ((i == 0 && chapter.startMilliseconds != 0) || (i > 0 && chapter.startMilliseconds <= previous) ||
            chapter.startMilliseconds >= self.durationMilliseconds)
            return MetadataError(error, NSLocalizedString(@"Chapters must start at zero, have increasing start times, and begin before the end of the audio.", nil));
        NSData *title = [chapter.title dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger limit = nero ? 255 : MP4V2_CHAPTER_TITLE_MAX;
        if (!title || title.length > limit || (title.length && memchr(title.bytes, 0, title.length)))
            return MetadataError(error, [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu has an invalid title. Titles must fit within %lu UTF-8 bytes and cannot contain a null character.", nil), (unsigned long)(i + 1), (unsigned long)limit]);
        previous = chapter.startMilliseconds;
    }
    return YES;
}

- (BOOL)writeChaptersToFile:(NSString *)fileName error:(NSError **)error
{
    if ([self.chapters isEqual:self.originalChapters]) return YES;
    MP4FileHandle handle = MP4Modify(fileName.fileSystemRepresentation, 0);
    if (handle == MP4_INVALID_FILE_HANDLE)
        return MetadataError(error, NSLocalizedString(@"The audiobook could not be opened to update chapters.", nil));
    MP4Chapter_t *list = NULL;
    BOOL success = NO;
    @try {
        if (!self.chapters.count) {
            MP4DeleteChapters(handle, MP4ChapterTypeAny, MP4_INVALID_TRACK_ID);
            MP4Chapter_t *remaining = NULL; uint32_t count = 0;
            MP4GetChapters(handle, &remaining, &count, MP4ChapterTypeAny);
            if (remaining) MP4Free(remaining);
            success = count == 0;
        } else {
            list = calloc(self.chapters.count, sizeof(MP4Chapter_t));
            if (!list) return MetadataError(error, NSLocalizedString(@"There is not enough memory to save the chapters.", nil));
            // Renaming alone preserves the original final chapter end as well as all starts.
            BOOL sameStarts = self.chapters.count == self.originalChapters.count;
            for (NSUInteger i = 0; sameStarts && i < self.chapters.count; i++)
                sameStarts = self.chapters[i].startMilliseconds == self.originalChapters[i].startMilliseconds;
            uint64_t end = sameStarts ? self.originalChapterEndMilliseconds : self.durationMilliseconds;
            for (NSUInteger i = 0; i < self.chapters.count; i++) {
                MP4Chapter *chapter = self.chapters[i];
                uint64_t next = i + 1 < self.chapters.count ? self.chapters[i + 1].startMilliseconds : end;
                list[i].duration = next - chapter.startMilliseconds;
                NSData *title = [chapter.title dataUsingEncoding:NSUTF8StringEncoding];
                memcpy(list[i].title, title.bytes, title.length);
            }
            MP4ChapterType type = self.chapterTypes == MP4ChapterTypeNone ? MP4ChapterTypeQt : self.chapterTypes;
            success = MP4SetChapters(handle, list, (uint32_t)self.chapters.count, type) == type;
            // Check each representation so a file with both chapter formats stays consistent.
            for (NSNumber *kind in @[@(MP4ChapterTypeQt), @(MP4ChapterTypeNero)]) {
                if (!success || (type != MP4ChapterTypeAny && type != kind.intValue)) continue;
                MP4Chapter_t *written = NULL; uint32_t count = 0;
                MP4GetChapters(handle, &written, &count, kind.intValue);
                success = count == self.chapters.count;
                for (uint32_t i = 0; success && i < count; i++)
                    success = strcmp(written[i].title, list[i].title) == 0 &&
                              (i + 1 == count || written[i].duration == list[i].duration);
                if (written) MP4Free(written);
            }
        }
    } @finally {
        free(list);
        MP4Close(handle, 0);
    }
    if (!success) return MetadataError(error, NSLocalizedString(@"The chapters could not be saved. The original audiobook has been preserved.", nil));
    return YES;
}

- (BOOL)saveMetadataWithError:(NSError **)error
{
    if (!self.originalValues || !self.originalAttributes)
        return MetadataError(error, NSLocalizedString(@"Load the audiobook’s metadata before saving edits.", nil));
    if (![self sourceIsUnchanged])
        return MetadataError(error, NSLocalizedString(@"The audiobook has changed since it was opened. Close this editor and reopen the file before saving.", nil));
    if (![self validateChaptersWithError:error]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *destination = [NSURL fileURLWithPath:self.fileName];
    NSURL *directory = [fm URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                       appropriateForURL:destination create:YES error:error];
    if (!directory) return NO;
    NSURL *staged = [directory URLByAppendingPathComponent:@"metadata.m4b"];
    @try {
        if (![fm copyItemAtURL:destination toURL:staged error:error]) return NO;
        if ([self metadataHasChanges] && ![self writeMetadataToFile:staged.path])
            return MetadataError(error, NSLocalizedString(@"The metadata could not be saved. The original audiobook has been preserved. Check that the file is writable and any new cover is a valid PNG or JPEG.", nil));
        if (![self writeChaptersToFile:staged.path error:error]) return NO;
        if (![self sourceIsUnchanged])
            return MetadataError(error, NSLocalizedString(@"The audiobook changed while saving. Reopen it before trying again.", nil));
        if (![fm replaceItemAtURL:destination withItemAtURL:staged backupItemName:nil
                         options:0 resultingItemURL:nil error:error]) return NO;
        [self readMetadataWithError:NULL];
        return YES;
    } @finally {
        [fm removeItemAtURL:directory error:nil];
    }
}

@end
