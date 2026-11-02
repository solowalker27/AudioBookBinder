#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mp4v2/mp4v2.h>
#import "AudioBinder.h"
#import "AudioBookVolume.h"
#import "Chapter.h"
#import "MetaEditor.h"
#import "MP4File.h"
#import "MP4Atom.h"
#import "CoverImageView.h"

static NSUInteger assertions;
static void Check(BOOL condition, NSString *message) {
    assertions++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

@interface TestDelegate : NSObject <AudioBinderDelegate>
@property BOOL cancelOnProgress;
@property BOOL skipErrors;
@property AudioBinder *binder;
@property UInt32 seconds;
@end
@implementation TestDelegate
- (void)updateStatus:(AudioFile *)file handled:(UInt64)handled total:(UInt64)total { if (self.cancelOnProgress) [self.binder cancel]; }
- (void)conversionStart:(AudioFile *)file format:(AudioStreamBasicDescription *)format formatDescription:(NSString *)description length:(UInt64)length {}
- (BOOL)continueFailedConversion:(AudioFile *)file reason:(NSString *)reason { return self.skipErrors; }
- (void)conversionFinished:(AudioFile *)file duration:(UInt32)milliseconds { file.duration = @(milliseconds); }
- (void)audiobookReady:(UInt32)seconds { self.seconds = seconds; }
- (void)volumeFailed:(NSString *)file reason:(NSString *)reason { NSLog(@"Expected/diagnostic failure: %@", reason); }
- (void)volumeReady:(NSString *)file duration:(UInt32)seconds {}
@end

static void VerifyAudio(NSString *path, double expectedSeconds, UInt32 channels, double rate) {
    ExtAudioFileRef file = NULL;
    Check(ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file) == noErr, @"Output opens in Core Audio");
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    Check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr, @"Read AAC format");
    Check(format.mFormatID == kAudioFormatMPEG4AAC && format.mChannelsPerFrame == channels && format.mSampleRate == rate, @"Requested output format");
    SInt64 frames = 0; size = sizeof(frames);
    Check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr, @"Read output duration");
    Check(fabs(frames / rate - expectedSeconds) < 0.12, @"Output duration matches inputs");
    AudioStreamBasicDescription pcm = {0};
    pcm.mSampleRate = rate; pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    pcm.mChannelsPerFrame = channels; pcm.mBitsPerChannel = 32;
    pcm.mFramesPerPacket = 1; pcm.mBytesPerFrame = channels * 4; pcm.mBytesPerPacket = pcm.mBytesPerFrame;
    Check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(pcm), &pcm) == noErr, @"Decode AAC output");
    float samples[8192]; UInt32 count = 4096;
    AudioBufferList buffer = { .mNumberBuffers = 1, .mBuffers = {{channels, sizeof(samples), samples}} };
    Check(ExtAudioFileRead(file, &count, &buffer) == noErr && count > 1000, @"Read playable sample frames");
    double energy = 0; for (NSUInteger i = 0; i < count * channels; i++) energy += samples[i] * samples[i];
    Check(energy / (count * channels) > 0.001, @"Encoded audio contains signal");
    ExtAudioFileDispose(file);
}

// Compare compressed sample payloads directly: metadata editing must never encode audio.
static NSArray<NSData *> *AudioSamples(NSString *path) {
    MP4FileHandle file = MP4Read(path.fileSystemRepresentation);
    Check(file != MP4_INVALID_FILE_HANDLE, @"Open file for compressed sample comparison");
    NSMutableArray *samples = [NSMutableArray array];
    uint32_t tracks = MP4GetNumberOfTracks(file, MP4_AUDIO_TRACK_TYPE, 0);
    for (uint32_t i = 0; i < tracks; i++) {
        MP4TrackId track = MP4FindTrackId(file, i, MP4_AUDIO_TRACK_TYPE, 0);
        MP4SampleId count = MP4GetTrackNumberOfSamples(file, track);
        for (MP4SampleId sample = 1; sample <= count; sample++) {
            uint8_t *bytes = NULL; uint32_t size = 0;
            BOOL read = MP4ReadSample(file, track, sample, &bytes, &size, NULL, NULL, NULL, NULL);
            Check(read, @"Read compressed audio sample");
            [samples addObject:[NSData dataWithBytes:bytes length:size]];
            MP4Free(bytes);
        }
    }
    MP4Close(file, 0);
    return samples;
}

static NSArray *ChapterSnapshot(NSString *path) {
    MP4FileHandle file = MP4Read(path.fileSystemRepresentation);
    MP4Chapter_t *chapters = NULL; uint32_t count = 0;
    MP4GetChapters(file, &chapters, &count, MP4ChapterTypeQt);
    NSMutableArray *values = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++)
        [values addObject:@[@(chapters[i].title), @(chapters[i].duration)]];
    MP4Free(chapters); MP4Close(file, 0);
    return values;
}

static void VerifyMetadataEditing(NSString *dir) {
    NSString *book = [dir stringByAppendingPathComponent:@"book.m4b"];
    NSString *cover = [dir stringByAppendingPathComponent:@"cover.png"];
    NSArray *samples = AudioSamples(book);
    NSArray *chapters = ChapterSnapshot(book);
    MP4FileHandle handle = MP4Modify(book.fileSystemRepresentation, 0);
    const MP4Tags *tags = MP4TagsAlloc();
    Check(MP4TagsFetch(tags, handle), @"Load preservation fixture tags");
    MP4TagsSetComments(tags, "Keep this comment");
    MP4TagsSetReleaseDate(tags, "2021-06-15");
    MP4TagsSetAlbumArtist(tags, "Album Author");
    MP4TagsSetComposer(tags, "Separate Composer");
    MP4TagsSetSortName(tags, "Sort Title");
    uint8_t mediaType = 1, gapless = 1;
    MP4TagsSetMediaType(tags, &mediaType); MP4TagsSetGapless(tags, &gapless);
    MP4TagTrack track = {3, 9}; MP4TagsSetTrack(tags, &track);
    Check(MP4TagsStore(tags, handle), @"Seed unrelated tags");
    MP4TagsFree(tags);
    MP4ItmfItem *custom = MP4ItmfItemAlloc("----", 1);
    custom->mean = strdup("org.audiobookbinder.test"); custom->name = strdup("preserve");
    custom->dataList.elements[0].typeCode = MP4_ITMF_BT_UTF8;
    custom->dataList.elements[0].value = (uint8_t *)strdup("Custom value");
    custom->dataList.elements[0].valueSize = 12;
    Check(MP4ItmfAddItem(handle, custom), @"Seed custom metadata");
    MP4ItmfItemFree(custom); MP4Close(handle, 0);

    NSError *error = nil;
    MP4File *editor = [[MP4File alloc] initWithFileName:book];
    Check([editor readMetadataWithError:&error], @"Load an existing audiobook for editing");
    Check([editor.title isEqual:@"A Book — 日本語"] && [editor.artist isEqual:@"Test Author"] &&
          [editor.album isEqual:@"Test Album"] && [editor.genre isEqual:@"Fiction"], @"Editable text fields load current values");
    Check([editor.narrator isEqual:@"Test Narrator"], @"Narrator atom takes precedence over composer fallback");
    Check([editor.coverData isEqual:[NSData dataWithContentsOfFile:cover]], @"Load embedded cover bytes");
    editor.title = @"Edited — 日本語 🎧";
    editor.artist = @"New Author";
    Check([editor saveMetadataWithError:&error], @"Save existing metadata through a replacement copy");
    Check([AudioSamples(book) isEqual:samples], @"Editing preserves every compressed audio sample byte for byte");
    Check([ChapterSnapshot(book) isEqual:chapters], @"Editing preserves chapter names and timing");
    handle = MP4Read(book.fileSystemRepresentation); tags = MP4TagsAlloc(); MP4TagsFetch(tags, handle);
    Check(strcmp(tags->comments, "Keep this comment") == 0 && strcmp(tags->releaseDate, "2021-06-15") == 0 &&
          strcmp(tags->albumArtist, "Album Author") == 0 && strcmp(tags->sortName, "Sort Title") == 0, @"Unexposed standard tags survive editing");
    Check(*tags->mediaType == 1 && *tags->gapless == 1 && tags->track->index == 3 && tags->track->total == 9, @"Media flags and volume numbering are preserved");
    Check(strcmp(tags->composer, "Separate Composer") == 0, @"Unchanged narrator preserves a separate composer");
    Check(tags->artworkCount == 1, @"Unchanged cover is retained");
    MP4ItmfItemList *items = MP4ItmfGetItemsByMeaning(handle, "org.audiobookbinder.test", "preserve");
    Check(items && items->size == 1 && items->elements[0].dataList.elements[0].valueSize == 12 &&
          memcmp(items->elements[0].dataList.elements[0].value, "Custom value", 12) == 0, @"Custom metadata survives editing");
    MP4ItmfItemListFree(items);
    items = MP4ItmfGetItemsByCode(handle, "\251nrt");
    Check(items && items->size == 1, @"Repeated writes leave exactly one narrator atom");
    MP4ItmfItemListFree(items); MP4TagsFree(tags); MP4Close(handle, 0);

    editor = [[MP4File alloc] initWithFileName:book];
    Check([editor readMetadataWithError:&error] && [editor.title isEqual:@"Edited — 日本語 🎧"], @"Reopen edited metadata");
    editor.title = @""; editor.artist = @""; editor.narrator = @""; editor.album = @""; editor.genre = @"";
    editor.removeCover = YES;
    Check([editor saveMetadataWithError:&error], @"Clear text tags and remove cover art");
    handle = MP4Read(book.fileSystemRepresentation); tags = MP4TagsAlloc(); MP4TagsFetch(tags, handle);
    Check(!tags->name && !tags->artist && !tags->album && !tags->genre && !tags->composer && tags->artworkCount == 0, @"Cleared values are removed from the file");
    items = MP4ItmfGetItemsByCode(handle, "\251nrt");
    Check(items && items->size == 0, @"Clearing narrator removes custom narrator atoms");
    MP4ItmfItemListFree(items); MP4TagsFree(tags); MP4Close(handle, 0);
    editor = [[MP4File alloc] initWithFileName:book];
    Check([editor readMetadataWithError:&error], @"Load cleared metadata");
    editor.coverData = [NSData dataWithContentsOfFile:cover]; editor.narrator = @"New Narrator";
    Check([editor saveMetadataWithError:&error], @"Add artwork and narrator to an existing book");
    editor = [[MP4File alloc] initWithFileName:book];
    Check([editor readMetadataWithError:&error] && [editor.narrator isEqual:@"New Narrator"] && editor.coverData.length, @"Added cover and narrator round trip");
    editor.narrator = @"Replacement Narrator";
    editor.coverData = [[NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:cover]] representationUsingType:NSBitmapImageFileTypeJPEG properties:@{}];
    Check([editor saveMetadataWithError:&error], @"Replace embedded artwork and narrator");
    handle = MP4Read(book.fileSystemRepresentation); tags = MP4TagsAlloc(); MP4TagsFetch(tags, handle);
    items = MP4ItmfGetItemsByCode(handle, "\251nrt");
    Check(items && items->size == 1 && tags->artworkCount == 1 && tags->artwork[0].type == MP4_ART_JPEG, @"Replacement does not accumulate narrator or artwork atoms");
    MP4ItmfItemListFree(items); MP4TagsFree(tags); MP4Close(handle, 0);
    Check([AudioSamples(book) isEqual:samples] && [ChapterSnapshot(book) isEqual:chapters], @"Clearing and replacing tags preserve audio and chapters");
    VerifyAudio(book, 4.5, 2, 44100);

    editor = [[MP4File alloc] initWithFileName:book];
    Check([editor readMetadataWithError:&error], @"Load file for failure checks");
    NSData *original = [NSData dataWithContentsOfFile:book];
    editor.title = @"Must not be written";
    editor.coverFile = [dir stringByAppendingPathComponent:@"mono.wav"];
    Check(![editor saveMetadataWithError:&error] && error != nil, @"Invalid artwork reports save failure");
    Check([[NSData dataWithContentsOfFile:book] isEqual:original], @"Failed metadata save preserves original bytes");
    editor.coverFile = nil;
    MP4File *other = [[MP4File alloc] initWithFileName:book]; other.title = @"Changed elsewhere";
    Check([other updateFile], @"Simulate an external metadata change");
    original = [NSData dataWithContentsOfFile:book]; error = nil;
    Check(![editor saveMetadataWithError:&error] && error != nil, @"Stale editor cannot overwrite external changes");
    Check([[NSData dataWithContentsOfFile:book] isEqual:original], @"External changes remain intact");
    Check(![[[MP4File alloc] initWithFileName:[dir stringByAppendingPathComponent:@"mono.wav"]] readMetadataWithError:&error], @"Reject non-MP4 input");
    Check(![[[MP4File alloc] initWithFileName:[dir stringByAppendingPathComponent:@"missing.m4b"]] readMetadataWithError:&error], @"Reject missing audiobook");
}

static MP4Chapter *TestChapterMarker(NSString *title, uint64_t start) {
    return [[MP4Chapter alloc] initWithTitle:title startMilliseconds:start];
}

static void VerifyChapterEditing(NSString *dir) {
    uint64_t milliseconds = 0;
    Check([MP4Chapter parseTimestamp:@"01:02:03.045" milliseconds:&milliseconds] && milliseconds == 3723045, @"Parse hours and millisecond precision");
    Check([MP4Chapter parseTimestamp:@"90:05.2" milliseconds:&milliseconds] && milliseconds == 5405200, @"Parse minutes with fractional seconds");
    Check([MP4Chapter parseTimestamp:@" 12.34 " milliseconds:&milliseconds] && milliseconds == 12340, @"Parse seconds with outer whitespace");
    for (NSString *invalid in @[@"", @"-1", @"nan", @"1e3", @"1:60", @"1:99:00", @"1:2:3:4", @"1.1234", @"1.", @".5", @"1: 02", @"18446744073709551616", @"18446744073709552"])
        Check(![MP4Chapter parseTimestamp:invalid milliseconds:&milliseconds], @"Reject malformed or overflowing chapter time");
    NSString *maximum = [MP4Chapter timestampForMilliseconds:UINT64_MAX];
    Check([MP4Chapter parseTimestamp:maximum milliseconds:&milliseconds] && milliseconds == UINT64_MAX, @"Timestamp formatting round trips without overflow");
    NSString *book = [dir stringByAppendingPathComponent:@"chapter-edit.m4b"];
    Check([NSFileManager.defaultManager copyItemAtPath:[dir stringByAppendingPathComponent:@"book.m4b"] toPath:book error:nil], @"Create disposable chapter fixture");
    MP4FileHandle fixture = MP4Modify(book.fileSystemRepresentation, 0);
    const MP4Tags *fixtureTags = MP4TagsAlloc();
    MP4TagsFetch(fixtureTags, fixture); MP4TagsSetComments(fixtureTags, "");
    Check(MP4TagsStore(fixtureTags, fixture), @"Seed an explicitly empty unrelated tag");
    MP4TagsFree(fixtureTags); MP4Close(fixture, 0);
    NSArray *samples = AudioSamples(book);
    MP4File *editor = [[MP4File alloc] initWithFileName:book];
    NSError *error = nil;
    Check([editor readMetadataWithError:&error], @"Load existing chapters");
    NSArray *originalChapters = ChapterSnapshot(book);
    Check(editor.chapters.count == 2 && editor.chapters[0].startMilliseconds == 0 && editor.chapters[1].startMilliseconds == [originalChapters[0][1] unsignedLongLongValue], @"Read chapter starts from embedded durations");
    Check(editor.durationMilliseconds >= 4400 && editor.durationMilliseconds < 4700, @"Chapter editor uses audio duration");
    fixture = MP4Read(book.fileSystemRepresentation);
    MP4TrackId audioTrack = MP4FindTrackId(fixture, 0, MP4_AUDIO_TRACK_TYPE, 0);
    uint64_t presentation = 0;
    Check(MP4GetTrackIntegerProperty(fixture, audioTrack, "tkhd.duration", &presentation) &&
          editor.durationMilliseconds == MP4ConvertFromMovieDuration(fixture, presentation, MP4_MILLISECONDS_TIME_SCALE), @"Chapter end respects the audio presentation timeline and excludes AAC padding");
    MP4Close(fixture, 0);
    NSString *savedTitle = editor.title, *savedNarrator = editor.narrator;
    NSData *savedCover = editor.coverData;
    editor.chapters[0].title = @"Renamed — 日本語 🎧";
    Check([editor saveMetadataWithError:&error], @"Rename an existing chapter");
    NSArray *renamed = ChapterSnapshot(book);
    Check([renamed[0][0] isEqual:@"Renamed — 日本語 🎧"] && [renamed[0][1] isEqual:originalChapters[0][1]] && [renamed[1][1] isEqual:originalChapters[1][1]], @"Rename preserves every chapter duration including the final end");
    editor.chapters = @[TestChapterMarker(@"Introduction", 0), TestChapterMarker(@"Inserted — 二", 500), TestChapterMarker(@"Ending", 2000)];
    Check([editor saveMetadataWithError:&error], @"Insert chapter and edit start times");
    Check(editor.chapters.count == 3 && editor.chapters[1].startMilliseconds == 500 && editor.chapters[2].startMilliseconds == 2000, @"New chapter boundaries round trip");
    Check([editor.title isEqual:savedTitle] && [editor.narrator isEqual:savedNarrator] && [editor.coverData isEqual:savedCover], @"Chapter editing preserves book metadata and artwork");
    fixture = MP4Read(book.fileSystemRepresentation);
    MP4ItmfItemList *emptyComments = MP4ItmfGetItemsByCode(fixture, "\251cmt");
    Check(emptyComments && emptyComments->size == 1 && emptyComments->elements[0].dataList.size == 1 &&
          emptyComments->elements[0].dataList.elements[0].valueSize == 0, @"Chapter-only saves preserve explicitly empty metadata atoms");
    MP4ItmfItemListFree(emptyComments); MP4Close(fixture, 0);
    Check([AudioSamples(book) isEqual:samples], @"Chapter edits preserve all compressed audio payloads");
    VerifyAudio(book, 4.5, 2, 44100);
    NSArray *valid = editor.chapters;
    NSData *original = [NSData dataWithContentsOfFile:book];
    NSString *longTitle = [@"é" stringByPaddingToLength:512 withString:@"é" startingAtIndex:0];
    NSString *nullTitle = [NSString stringWithCharacters:(unichar[]){'a', 0, 'b'} length:3];
    for (NSArray *invalid in @[
        @[TestChapterMarker(@"Late first chapter", 1)],
        @[TestChapterMarker(@"One", 0), TestChapterMarker(@"Duplicate", 0)],
        @[TestChapterMarker(@"One", 0), TestChapterMarker(@"Past end", editor.durationMilliseconds)],
        @[TestChapterMarker(@"One", 0), TestChapterMarker(@"Later", 2000), TestChapterMarker(@"Earlier", 1000)],
        @[TestChapterMarker(longTitle, 0)], @[TestChapterMarker(nullTitle, 0)]]) {
        editor.chapters = invalid; error = nil;
        editor.title = @"Invalid changes must not leak";
        Check(![editor saveMetadataWithError:&error] && error, @"Invalid chapter edits fail with a useful error");
        Check([[NSData dataWithContentsOfFile:book] isEqual:original], @"Invalid chapter edit leaves the entire original file intact");
    }
    editor.title = savedTitle;
    editor.chapters = @[valid[0], valid[2]];
    Check([editor saveMetadataWithError:&error] && editor.chapters.count == 2 && editor.chapters[1].startMilliseconds == 2000, @"Remove a middle marker without shifting later chapters");
    editor.chapters = @[];
    Check([editor saveMetadataWithError:&error] && editor.chapters.count == 0, @"Remove all chapter markers");
    Check(ChapterSnapshot(book).count == 0, @"No chapter track remains after removing all markers");
    editor.chapters = @[TestChapterMarker(@"New first chapter", 0), TestChapterMarker(@"New second chapter", 1000)];
    Check([editor saveMetadataWithError:&error] && editor.chapters.count == 2, @"Add chapters to a book with no markers");
    Check([AudioSamples(book) isEqual:samples], @"Removing and recreating chapters preserve audio");

    for (NSNumber *kind in @[@(MP4ChapterTypeNero), @(MP4ChapterTypeAny)]) {
        MP4FileHandle handle = MP4Modify(book.fileSystemRepresentation, 0);
        MP4DeleteChapters(handle, MP4ChapterTypeAny, MP4_INVALID_TRACK_ID);
        MP4Chapter_t seed[2] = {{0}};
        strcpy(seed[0].title, "First"); seed[0].duration = 1000;
        strcpy(seed[1].title, "Second"); seed[1].duration = editor.durationMilliseconds - 1000;
        Check(MP4SetChapters(handle, seed, 2, kind.intValue) == kind.intValue, @"Seed Nero-only or dual-format chapters");
        MP4Close(handle, 0);
        Check([editor readMetadataWithError:&error] && editor.chapters.count == 2, @"Read Nero-only and dual-format books");
        original = [NSData dataWithContentsOfFile:book];
        editor.chapters = @[TestChapterMarker([@"é" stringByPaddingToLength:128 withString:@"é" startingAtIndex:0], 0)];
        Check(![editor saveMetadataWithError:&error] && [[NSData dataWithContentsOfFile:book] isEqual:original], @"Nero title limit is validated in UTF-8 bytes before writing");
        editor.chapters = @[TestChapterMarker(@"Updated — 一", 0), TestChapterMarker(@"Updated — 二", 700)];
        Check([editor saveMetadataWithError:&error], @"Save Nero-only and dual-format chapter changes");
        handle = MP4Read(book.fileSystemRepresentation);
        MP4Chapter_t *list = NULL; uint32_t count = 0;
        Check(MP4GetChapters(handle, &list, &count, MP4ChapterTypeNero) == MP4ChapterTypeNero && count == 2 && list[0].duration == 700 && strcmp(list[1].title, "Updated — 二") == 0, @"Nero chapter names and start times are updated");
        MP4Free(list); list = NULL; count = 0;
        MP4ChapterType found = MP4GetChapters(handle, &list, &count, MP4ChapterTypeQt);
        Check(kind.intValue == MP4ChapterTypeNero ? found == MP4ChapterTypeNone : (found == MP4ChapterTypeQt && count == 2 && list[0].duration == 700), @"Existing chapter representations stay in sync without adding unwanted formats");
        if (list) MP4Free(list);
        MP4Close(handle, 0);
        editor.chapters = @[];
        Check([editor saveMetadataWithError:&error], @"Delete every existing chapter representation");
        handle = MP4Read(book.fileSystemRepresentation); list = NULL; count = 0;
        Check(MP4GetChapters(handle, &list, &count, MP4ChapterTypeAny) == MP4ChapterTypeNone && count == 0, @"Both chapter formats are removed");
        if (list) MP4Free(list);
        MP4Close(handle, 0);
    }
    Check([AudioSamples(book) isEqual:samples], @"Nero and dual-format saves preserve compressed audio");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"Fixture directory provided");
        NSString *dir = @(argv[1]);
        NSString *(^path)(NSString *) = ^NSString *(NSString *name) { return [dir stringByAppendingPathComponent:name]; };
        AudioFile *mono = [[AudioFile alloc] initWithPath:path(@"mono.wav")];
        AudioFile *stereo = [[AudioFile alloc] initWithPath:path(@"stereo.wav")];
        AudioFile *aac = [[AudioFile alloc] initWithPath:path(@"input.m4a")];
        Check(mono.valid && stereo.valid && aac.valid, @"WAV and AAC inputs recognized");
        Check(![[[AudioFile alloc] initWithPath:path(@"missing.wav")] valid], @"Missing input rejected");
        AudioBinder *binder = [AudioBinder new];
        TestDelegate *delegate = [TestDelegate new]; delegate.binder = binder;
        [binder setDelegate:delegate]; binder.channels = 2; binder.sampleRate = 44100; binder.bitrate = 128000;
        Check([[binder validBitrates] containsObject:@128000], @"AAC bitrate discovery");
        [binder addVolume:path(@"book.m4b") files:@[mono, stereo, aac]];
        [binder addVolume:path(@"second.m4b") files:@[mono]];
        Check([binder convert], @"Mixed rate/channel conversion and multiple volumes");
        VerifyAudio(path(@"book.m4b"), 4.5, 2, 44100);
        VerifyAudio(path(@"second.m4b"), 1.25, 2, 44100);
        Check(delegate.seconds == 5, @"Total duration across volumes");
        MP4File *metadata = [[MP4File alloc] initWithFileName:path(@"book.m4b")];
        metadata.title = @"A Book — 日本語"; metadata.artist = @"Test Author"; metadata.album = @"Test Album";
        metadata.narrator = @"Test Narrator"; metadata.genre = @"Fiction"; metadata.coverFile = path(@"cover.png");
        metadata.track = 1; metadata.tracksTotal = 2;
        Check([metadata updateFile], @"Write Unicode metadata and PNG artwork");
        Check([metadata updateFile], @"Repeated metadata updates replace artwork safely");
        MP4FileHandle handle = MP4Read(path(@"book.m4b").fileSystemRepresentation);
        const MP4Tags *tags = MP4TagsAlloc();
        Check(MP4TagsFetch(tags, handle), @"Read stored metadata");
        Check(strcmp(tags->name, metadata.title.UTF8String) == 0 && strcmp(tags->artist, "Test Author") == 0, @"Title and author round trip");
        Check(tags->artworkCount == 1 && tags->artwork[0].type == MP4_ART_PNG, @"Valid PNG artwork");
        Check(tags->mediaType && *tags->mediaType == 2 && tags->track->total == 2, @"Audiobook media type and volume tags");
        Check(strcmp(tags->composer, "Test Narrator") == 0, @"Narrator metadata");
        MP4TagsFree(tags); MP4Close(handle, 0);
        Chapter *first = [Chapter new]; first.name = @"Opening — 一"; [first addFile:mono];
        Chapter *second = [Chapter new]; second.name = @"Next"; [second addFiles:@[stereo, aac]];
        Check(addChapters(path(@"book.m4b").fileSystemRepresentation, @[first, second]) == 0, @"Write QuickTime chapters");
        handle = MP4Read(path(@"book.m4b").fileSystemRepresentation);
        MP4Chapter_t *chapters = NULL; uint32_t chapterCount = 0;
        MP4GetChapters(handle, &chapters, &chapterCount, MP4ChapterTypeQt);
        Check(chapterCount == 2 && strcmp(chapters[0].title, first.name.UTF8String) == 0, @"Chapter count and Unicode titles round trip");
        Check(llabs((long long)chapters[0].duration - 1250) < 50, @"Chapter timing");
        MP4Free(chapters); MP4Close(handle, 0);
        VerifyAudio(path(@"book.m4b"), 4.5, 2, 44100);
        VerifyMetadataEditing(dir);
        VerifyChapterEditing(dir);
        CoverImageView *cover = [[CoverImageView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [[NSData dataWithContentsOfFile:path(@"cover.png")] writeToFile:path(@"extensionless") atomically:YES];
        cover.coverImageFilename = path(@"extensionless");
        Check(cover.haveCover && cover.shouldConvert, @"Extensionless artwork handled without crash");
        [cover resetImage]; Check(!cover.haveCover, @"Reset cover");
        MP4Atom *atom = [[MP4Atom alloc] initWithName:@"moov" andLength:8];
        Check(memcmp((const char *)atom.encode.bytes + 4, "moov", 4) == 0, @"Atom encoding works with assertions disabled");
        Check([[MP4Atom alloc] initWithHeaderData:[NSData data] andOffset:0] == nil, @"Truncated atom header rejected");

        NSData *original = [NSData dataWithContentsOfFile:path(@"book.m4b")];
        [binder reset]; [binder setDelegate:delegate];
        AudioFile *broken = [[AudioFile alloc] initWithPath:path(@"missing.wav")];
        [binder addVolume:path(@"book.m4b") files:@[broken]];
        [binder addVolume:path(@"second.m4b") files:@[mono]];
        NSData *previousSecond = [NSData dataWithContentsOfFile:path(@"second.m4b")];
        Check(![binder convert], @"Failed conversion reported");
        Check([[NSData dataWithContentsOfFile:path(@"book.m4b")] isEqual:original], @"Existing destination survives failure");
        Check([[NSData dataWithContentsOfFile:path(@"second.m4b")] isEqual:previousSecond], @"Untouched later destination survives failure");
        [binder reset]; [binder setDelegate:delegate];
        [binder addVolume:path(@"book.m4b") files:@[mono]];
        [binder addVolume:path(@"second.m4b") files:@[broken]];
        Check(![binder convert], @"A later volume failure aborts the complete job");
        Check([[NSData dataWithContentsOfFile:path(@"book.m4b")] isEqual:original], @"Earlier staged volume does not replace the destination on failure");
        Check([[NSData dataWithContentsOfFile:path(@"second.m4b")] isEqual:previousSecond], @"Later failed volume preserves its destination");
        [binder reset]; [binder setDelegate:delegate]; delegate.cancelOnProgress = YES;
        [binder addVolume:path(@"book.m4b") files:@[stereo]];
        NSNumber *inputDuration = stereo.duration;
        Check(![binder convert], @"Cancellation reported");
        Check([inputDuration isEqual:stereo.duration], @"Cancellation preserves input duration for retry");
        Check([[NSData dataWithContentsOfFile:path(@"book.m4b")] isEqual:original], @"Cancellation preserves destination");
        delegate.cancelOnProgress = NO;
        [binder reset]; [binder setDelegate:delegate];
        [binder addVolume:mono.filePath files:@[mono]];
        Check(![binder convert] && mono.valid, @"Input overwrite rejected");
        NSString *alias = path(@"alias.wav");
        [NSFileManager.defaultManager linkItemAtPath:mono.filePath toPath:alias error:nil];
        [binder reset]; [binder setDelegate:delegate]; [binder addVolume:alias files:@[mono]];
        Check(![binder convert], @"Input hard-link overwrite rejected");
        [binder reset]; [binder setDelegate:delegate];
        binder.channels = 1; binder.sampleRate = 22050; binder.bitrate = 64000;
        [binder addVolume:path(@"mono-output.m4b") files:@[stereo]];
        Check([binder convert], @"Reuse binder after failure, stereo to mono resampling");
        Check(delegate.seconds >= 1 && delegate.seconds <= 2, @"Reset clears previous book duration");
        VerifyAudio(path(@"mono-output.m4b"), 2, 1, 22050);
        Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] != nil, @"Fixture directory readable");
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
            Check(![name hasPrefix:@".abbinder-"], @"Temporary conversion files cleaned up");
        NSLog(@"PASS: %lu core integration assertions", (unsigned long)assertions);
    }
    return 0;
}
