#import "ChapterList.h"
#import <mp4v2/mp4v2.h>
#import <math.h>

static id ImportError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"AudioBookBinder.ChapterImport" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

static BOOL UnsignedInteger(NSString *text, uint64_t *result) {
    if (!text.length) return NO;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9' || value > (UINT64_MAX - (c - '0')) / 10) return NO;
        value = value * 10 + c - '0';
    }
    *result = value;
    return YES;
}

static BOOL Milliseconds(long double value, uint64_t *result) {
    if (!isfinite(value) || value < 0 || value >= (long double)UINT64_MAX) return NO;
    *result = (uint64_t)floorl(value + 0.5L);
    return YES;
}

static BOOL LabelTime(NSString *text, uint64_t *result) {
    // Audacity exports six decimal places, with a dot regardless of locale.
    NSArray *parts = [text componentsSeparatedByString:@"."];
    uint64_t seconds;
    if (parts.count > 2 || !UnsignedInteger(parts[0], &seconds)) return NO;
    long double value = (long double)seconds * 1000;
    if (parts.count == 2) {
        NSString *fraction = parts[1];
        if (!fraction.length) return NO;
        long double scale = 100;
        for (NSUInteger i = 0; i < fraction.length; i++) {
            unichar c = [fraction characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
            value += (c - '0') * scale;
            scale /= 10;
        }
    }
    return Milliseconds(value, result);
}

// Decode ffmetadata quoting, including inline comments and escaped newlines.
static NSString *Unescape(NSString *text) {
    NSMutableString *result = [NSMutableString string];
    BOOL escaped = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (!escaped && (c == ';' || c == '#')) break;
        if (!escaped && c == '\\') { escaped = YES; continue; }
        [result appendFormat:@"%C", c];
        escaped = NO;
    }
    return escaped ? nil : result;
}

@implementation ChapterList

+ (NSArray<MP4Chapter *> *)chaptersFromURL:(NSURL *)url duration:(uint64_t)duration error:(NSError **)error {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return text ? [self chaptersFromText:text duration:duration error:error] : nil;
}

+ (NSArray<MP4Chapter *> *)chaptersFromText:(NSString *)text duration:(uint64_t)duration error:(NSError **)error {
    if ([text hasPrefix:@"\uFEFF"]) text = [text substringFromIndex:1];
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<MP4Chapter *> *chapters = [NSMutableArray array];
    NSMutableArray<NSNumber *> *ends = [NSMutableArray array];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    BOOL ffmetadata = [lines.firstObject isEqual:@";FFMETADATA1"];
    if (ffmetadata) {
        NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
        NSMutableDictionary *section = nil;
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *line = lines[i];
            // Join lines only when the trailing backslash itself is unescaped.
            NSUInteger slashes = 0;
            for (NSUInteger j = line.length; j > 0 && [line characterAtIndex:j - 1] == '\\'; j--) slashes++;
            while (slashes % 2) {
                if (++i >= lines.count) return ImportError(error, NSLocalizedString(@"The FFmpeg metadata file ends with an incomplete escape.", nil));
                line = [line stringByAppendingFormat:@"\n%@", lines[i]];
                slashes = 0;
                for (NSUInteger j = lines[i].length; j > 0 && [lines[i] characterAtIndex:j - 1] == '\\'; j--) slashes++;
            }
            if (!line.length || [line hasPrefix:@";"] || [line hasPrefix:@"#"]) continue;
            if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
                section = [line isEqual:@"[CHAPTER]"] ? [NSMutableDictionary dictionary] : nil;
                if (section) [sections addObject:section];
                continue;
            }
            if (!section) continue; // global/stream tags are not chapter markers
            NSUInteger equals = NSNotFound;
            BOOL escaped = NO;
            for (NSUInteger j = 0; j < line.length; j++) {
                unichar c = [line characterAtIndex:j];
                if (!escaped && c == '=') { equals = j; break; }
                if (!escaped && c == '\\') escaped = YES; else escaped = NO;
            }
            if (equals == NSNotFound) return ImportError(error, NSLocalizedString(@"An FFmpeg chapter entry must use key=value.", nil));
            NSString *key = Unescape([line substringToIndex:equals]);
            NSString *value = Unescape([line substringFromIndex:equals + 1]);
            if (!key || !value || section[key]) return ImportError(error, NSLocalizedString(@"An FFmpeg chapter has an invalid escape or duplicate field.", nil));
            section[key] = value;
        }
        for (NSDictionary *section in sections) {
            uint64_t start, end, numerator = 1, denominator = 1000000000;
            NSArray *base = section[@"TIMEBASE"] ? [section[@"TIMEBASE"] componentsSeparatedByString:@"/"] : @[@"1", @"1000000000"];
            if (base.count != 2 || !UnsignedInteger(base[0], &numerator) || !UnsignedInteger(base[1], &denominator) || !numerator || !denominator ||
                !UnsignedInteger(section[@"START"], &start) || !UnsignedInteger(section[@"END"], &end) ||
                !Milliseconds((long double)start * numerator * 1000 / denominator, &start) ||
                !Milliseconds((long double)end * numerator * 1000 / denominator, &end) || end <= start)
                return ImportError(error, NSLocalizedString(@"Each FFmpeg chapter needs a valid TIMEBASE and START < END (integer ticks).", nil));
            NSString *title = section[@"title"] ?: [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu", nil), (unsigned long)(chapters.count + 1)];
            [chapters addObject:[[MP4Chapter alloc] initWithTitle:title startMilliseconds:start]];
            [ends addObject:@(end)];
        }
    } else {
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *line = lines[i];
            if (!line.length) continue;
            NSArray *columns = [line componentsSeparatedByString:@"\t"];
            uint64_t start, end;
            if (columns.count < 2 || !LabelTime(columns[0], &start) || !LabelTime(columns[1], &end) || end < start)
                return ImportError(error, [NSString stringWithFormat:NSLocalizedString(@"Line %lu is not an Audacity label. Use start seconds, a tab, end seconds, and an optional tab and title; or import a file beginning with ;FFMETADATA1.", nil), (unsigned long)(i + 1)]);
            NSString *title = columns.count > 2 ? [[columns subarrayWithRange:NSMakeRange(2, columns.count - 2)] componentsJoinedByString:@"\t"] :
                [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu", nil), (unsigned long)(chapters.count + 1)];
            [chapters addObject:[[MP4Chapter alloc] initWithTitle:title startMilliseconds:start]];
            [ends addObject:@(end)];
        }
    }
    if (!chapters.count) return ImportError(error, NSLocalizedString(@"The file contains no chapters. Choose FFmpeg metadata or an Audacity label file in UTF-8.", nil));
    for (NSUInteger i = 0; i < chapters.count; i++) {
        MP4Chapter *chapter = chapters[i];
        if (i == 0 && chapter.startMilliseconds != 0)
            return ImportError(error, [NSString stringWithFormat:NSLocalizedString(@"The first chapter starts at %@. The first chapter must start at 00:00:00.000.", nil), [MP4Chapter timestampForMilliseconds:chapter.startMilliseconds]]);
        if (i && chapter.startMilliseconds <= chapters[i - 1].startMilliseconds)
            return ImportError(error, [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu (“%@”) must start after chapter %lu. Times must remain distinct at millisecond precision.", nil), (unsigned long)(i + 1), chapter.title, (unsigned long)i]);
        if (chapter.startMilliseconds >= duration || ends[i].unsignedLongLongValue > duration)
            return ImportError(error, [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu (“%@”) spans %@–%@, beyond the audio duration of %@. Check that the chapter list matches this audio file.", nil), (unsigned long)(i + 1), chapter.title, [MP4Chapter timestampForMilliseconds:chapter.startMilliseconds], [MP4Chapter timestampForMilliseconds:ends[i].unsignedLongLongValue], [MP4Chapter timestampForMilliseconds:duration]]);
        NSData *title = [chapter.title dataUsingEncoding:NSUTF8StringEncoding];
        if (!title || title.length > MP4V2_CHAPTER_TITLE_MAX || (title.length && memchr(title.bytes, 0, title.length)))
            return ImportError(error, NSLocalizedString(@"A chapter title is too long or contains a null character.", nil));
    }
    return chapters;
}

+ (void)chooseForWindow:(NSWindow *)window duration:(uint64_t)duration completion:(void (^)(NSArray<MP4Chapter *> *))completion {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = NSLocalizedString(@"Import Chapters", nil);
    panel.message = NSLocalizedString(@"Choose FFmpeg metadata (.ffmetadata, .ffmeta, .txt) or Audacity labels (.txt).", nil);
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSError *error = nil;
        NSArray *chapters = [self chaptersFromURL:panel.URL duration:duration error:&error];
        if (!chapters) { [[NSAlert alertWithError:error] beginSheetModalForWindow:window completionHandler:nil]; return; }
        [self preview:chapters window:window importing:YES completion:^(BOOL accepted) { if (accepted) completion(chapters); }];
    }];
}

+ (void)preview:(NSArray<MP4Chapter *> *)chapters window:(NSWindow *)window importing:(BOOL)importing completion:(void (^)(BOOL))completion {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"%@ %lu chapters", nil), importing ? NSLocalizedString(@"Import", nil) : NSLocalizedString(@"Imported", nil), (unsigned long)chapters.count];
    alert.informativeText = NSLocalizedString(@"Each chapter ends at the next start; the last runs to the end of the audio. Import replaces the current chapter list for this audio.", nil);
    [alert addButtonWithTitle:importing ? NSLocalizedString(@"Import", nil) : NSLocalizedString(@"Done", nil)];
    if (importing) [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 500, 230)];
    scroll.hasVerticalScroller = YES;
    NSTextView *view = [[NSTextView alloc] initWithFrame:scroll.bounds];
    view.editable = NO;
    view.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSMutableString *list = [NSMutableString string];
    for (MP4Chapter *chapter in chapters) [list appendFormat:@"%@  %@\n", [MP4Chapter timestampForMilliseconds:chapter.startMilliseconds], chapter.title];
    view.string = list;
    scroll.documentView = view;
    alert.accessoryView = scroll;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) { if (completion) completion(response == NSAlertFirstButtonReturn); }];
}
@end
