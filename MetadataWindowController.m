#import "MetadataWindowController.h"
#import "MP4File.h"
#import "ChapterList.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MetadataWindowController ()
@property NSURL *fileURL;
@property BOOL scopedAccess;
@property MP4File *metadata;
@property NSArray<NSTextField *> *fields;
@property NSArray<NSString *> *keys;
@property NSImageView *coverView;
@property NSTextField *coverPlaceholder;
@property NSButton *removeCoverButton;
@property NSButton *chooseCoverButton;
@property NSButton *saveButton;
@property NSButton *cancelButton;
@property NSProgressIndicator *progress;
@property BOOL saving;
@property NSTableView *chapterTable;
@property NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *chapterRows;
@property NSButton *addChapterButton;
@property NSButton *importChapterButton;
@property NSButton *removeChapterButton;
@end

@implementation MetadataWindowController

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error
{
    if ((self = [super initWithWindow:nil])) {
        _fileURL = url;
        _scopedAccess = [url startAccessingSecurityScopedResource];
        _metadata = [[MP4File alloc] initWithFileName:url.path];
        if (![_metadata readMetadataWithError:error]) return nil;
        [self buildWindow];
    }
    return self;
}

- (void)dealloc
{
    if (_scopedAccess) [_fileURL stopAccessingSecurityScopedResource];
}

- (void)buildWindow
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 740, 510)
                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered defer:NO];
    self.window = window;
    window.delegate = self;
    window.title = NSLocalizedString(@"Edit Audiobook Metadata", nil);
    window.representedURL = self.fileURL;
    window.releasedWhenClosed = NO;
    [window center];
    NSView *content = window.contentView;
    NSTabView *tabs = [NSTabView new];
    NSTabViewItem *detailsTab = [[NSTabViewItem alloc] initWithIdentifier:@"details"];
    detailsTab.label = NSLocalizedString(@"Book Details", nil);
    NSView *details = [NSView new];
    detailsTab.view = details;
    [tabs addTabViewItem:detailsTab];
    NSTabViewItem *chaptersTab = [[NSTabViewItem alloc] initWithIdentifier:@"chapters"];
    chaptersTab.label = NSLocalizedString(@"Chapters", nil);
    chaptersTab.view = [self buildChapterView];
    [tabs addTabViewItem:chaptersTab];
    NSTextField *filename = [NSTextField labelWithString:self.fileURL.lastPathComponent];
    filename.font = [NSFont boldSystemFontOfSize:15];
    filename.lineBreakMode = NSLineBreakByTruncatingMiddle;
    filename.toolTip = self.fileURL.path;

    self.keys = @[@"title", @"artist", @"narrator", @"album", @"genre"];
    NSArray *labels = @[NSLocalizedString(@"Title", nil), NSLocalizedString(@"Author", nil),
                        NSLocalizedString(@"Narrator", nil), NSLocalizedString(@"Album", nil),
                        NSLocalizedString(@"Genre", nil)];
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.keys.count; i++) {
        NSTextField *label = [NSTextField labelWithString:labels[i]];
        label.alignment = NSTextAlignmentRight;
        NSTextField *field = [NSTextField textFieldWithString:[self.metadata valueForKey:self.keys[i]] ?: @""];
        field.delegate = self;
        field.accessibilityLabel = labels[i];
        [fields addObject:field];
        [rows addObject:@[label, field]];
    }
    self.fields = fields;
    for (NSUInteger i = 0; i + 1 < fields.count; i++) [fields[i] setNextKeyView:fields[i + 1]];
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 14;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementFill;
    grid.yPlacement = NSGridCellPlacementCenter;
    [[grid columnAtIndex:1] setWidth:340];

    self.coverView = [NSImageView new];
    self.coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverView.accessibilityLabel = NSLocalizedString(@"Cover artwork", nil);
    self.coverPlaceholder = [NSTextField labelWithString:NSLocalizedString(@"No cover art", nil)];
    self.coverPlaceholder.textColor = NSColor.secondaryLabelColor;
    self.coverPlaceholder.alignment = NSTextAlignmentCenter;
    self.chooseCoverButton = [NSButton buttonWithTitle:NSLocalizedString(@"Choose Cover…", nil) target:self action:@selector(setCover:)];
    self.removeCoverButton = [NSButton buttonWithTitle:NSLocalizedString(@"Remove Cover", nil) target:self action:@selector(removeCover:)];
    NSStackView *artwork = [NSStackView stackViewWithViews:@[self.coverView, self.coverPlaceholder, self.chooseCoverButton, self.removeCoverButton]];
    artwork.orientation = NSUserInterfaceLayoutOrientationVertical;
    artwork.spacing = 8;
    [self.coverView.widthAnchor constraintEqualToConstant:144].active = YES;
    [self.coverView.heightAnchor constraintEqualToConstant:144].active = YES;
    [self refreshCover];

    NSTextField *note = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Save updates this file’s details, cover art, and chapters. Audio is preserved.", nil)];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    self.saveButton = [NSButton buttonWithTitle:NSLocalizedString(@"Save", nil) target:self action:@selector(save:)];
    self.saveButton.keyEquivalent = @"\r";
    self.cancelButton = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", nil) target:window action:@selector(performClose:)];
    self.cancelButton.keyEquivalent = @"\e";
    self.progress = [NSProgressIndicator new];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.displayedWhenStopped = NO;
    for (NSView *view in @[grid, artwork]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [details addSubview:view];
    }
    for (NSView *view in @[filename, tabs, note, self.saveButton, self.cancelButton, self.progress]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [filename.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [filename.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [filename.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [tabs.topAnchor constraintEqualToAnchor:filename.bottomAnchor constant:16],
        [tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [tabs.bottomAnchor constraintEqualToAnchor:note.topAnchor constant:-16],
        [grid.topAnchor constraintEqualToAnchor:details.topAnchor constant:24],
        [grid.leadingAnchor constraintEqualToAnchor:details.leadingAnchor constant:16],
        [grid.trailingAnchor constraintEqualToAnchor:artwork.leadingAnchor constant:-24],
        [artwork.topAnchor constraintEqualToAnchor:grid.topAnchor],
        [artwork.trailingAnchor constraintEqualToAnchor:details.trailingAnchor constant:-16],
        [note.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [note.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [note.bottomAnchor constraintEqualToAnchor:self.saveButton.topAnchor constant:-18],
        [self.saveButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [self.saveButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
        [self.saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:80],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.saveButton.leadingAnchor constant:-8],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:self.saveButton.centerYAnchor],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.cancelButton.leadingAnchor constant:-12],
        [self.progress.centerYAnchor constraintEqualToAnchor:self.saveButton.centerYAnchor]
    ]];
    window.initialFirstResponder = fields.firstObject;
}

- (NSView *)buildChapterView
{
    NSView *view = [NSView new];
    self.chapterRows = [NSMutableArray array];
    for (MP4Chapter *chapter in self.metadata.chapters)
        [self.chapterRows addObject:[@{@"title": chapter.title,
                                      @"start": [MP4Chapter timestampForMilliseconds:chapter.startMilliseconds]} mutableCopy]];
    self.chapterTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 640, 200)];
    self.chapterTable.dataSource = self;
    self.chapterTable.delegate = self;
    self.chapterTable.target = self;
    self.chapterTable.doubleAction = @selector(editChapterCell:);
    self.chapterTable.allowsMultipleSelection = YES;
    self.chapterTable.usesAlternatingRowBackgroundColors = YES;
    self.chapterTable.rowHeight = 30;
    self.chapterTable.accessibilityLabel = NSLocalizedString(@"Chapters", nil);
    NSArray *identifiers = @[@"number", @"start", @"title"];
    NSArray *titles = @[@"#", NSLocalizedString(@"Start Time", nil), NSLocalizedString(@"Chapter Title", nil)];
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifiers[i]];
        column.title = titles[i];
        column.width = i == 0 ? 40 : (i == 1 ? 150 : 430);
        column.minWidth = i == 0 ? 40 : (i == 1 ? 140 : 180);
        [self.chapterTable addTableColumn:column];
    }
    self.chapterTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.chapterTable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextField *hint = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Double-click to edit titles and start times (HH:MM:SS.mmm). The first chapter starts at zero; each chapter ends at the next start. Add Chapter splits the selected chapter in half.", nil)];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    NSTextField *duration = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Audio duration: %@", nil), [MP4Chapter timestampForMilliseconds:self.metadata.durationMilliseconds]]];
    duration.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    self.addChapterButton = [NSButton buttonWithTitle:NSLocalizedString(@"Add Chapter", nil) target:self action:@selector(addChapter:)];
    self.removeChapterButton = [NSButton buttonWithTitle:NSLocalizedString(@"Remove Chapter", nil) target:self action:@selector(removeChapter:)];
    self.removeChapterButton.enabled = NO;
    self.importChapterButton = [NSButton buttonWithTitle:NSLocalizedString(@"Import Chapters…", nil) target:self action:@selector(importChapters:)];
    for (NSView *child in @[scroll, hint, duration, self.addChapterButton, self.removeChapterButton, self.importChapterButton]) {
        child.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:child];
    }
    [NSLayoutConstraint activateConstraints:@[
        [duration.topAnchor constraintEqualToAnchor:view.topAnchor constant:16],
        [duration.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16],
        [scroll.topAnchor constraintEqualToAnchor:duration.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16],
        [scroll.bottomAnchor constraintEqualToAnchor:hint.topAnchor constant:-12],
        [hint.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:self.addChapterButton.topAnchor constant:-12],
        [self.addChapterButton.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [self.addChapterButton.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-12],
        [self.removeChapterButton.leadingAnchor constraintEqualToAnchor:self.addChapterButton.trailingAnchor constant:8],
        [self.removeChapterButton.centerYAnchor constraintEqualToAnchor:self.addChapterButton.centerYAnchor],
        [self.importChapterButton.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [self.importChapterButton.centerYAnchor constraintEqualToAnchor:self.addChapterButton.centerYAnchor]
    ]];
    return view;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.chapterRows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    BOOL number = [column.identifier isEqual:@"number"];
    NSString *value = number ? [NSString stringWithFormat:@"%ld", (long)(row + 1)] : self.chapterRows[row][column.identifier];
    NSTextField *field = number ? [NSTextField labelWithString:value] : [NSTextField textFieldWithString:value];
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.identifier = column.identifier;
    field.tag = row;
    field.enabled = !self.saving;
    if (!number) {
        field.delegate = self;
        field.accessibilityLabel = [NSString stringWithFormat:NSLocalizedString(@"Chapter %ld %@", nil), (long)(row + 1), column.title];
        field.editable = !([column.identifier isEqual:@"start"] && row == 0);
        field.selectable = YES;
        if ([column.identifier isEqual:@"start"])
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    }
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, tableView.rowHeight)];
    cell.identifier = column.identifier;
    cell.textField = field;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
        [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    return cell;
}

- (void)editChapterCell:(id)sender
{
    NSInteger row = self.chapterTable.clickedRow, column = self.chapterTable.clickedColumn;
    if (self.saving || row < 0 || column < 1 || (row == 0 && column == 1)) return;
    NSTableCellView *cell = [self.chapterTable viewAtColumn:column row:row makeIfNecessary:YES];
    [self.window makeFirstResponder:cell.textField];
    [cell.textField selectText:nil];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    self.removeChapterButton.enabled = !self.saving && self.chapterTable.selectedRowIndexes.count > 0;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    NSTextField *field = notification.object;
    if (([field.identifier isEqual:@"start"] || [field.identifier isEqual:@"title"]) &&
        field.tag >= 0 && field.tag < (NSInteger)self.chapterRows.count)
        self.chapterRows[field.tag][field.identifier] = field.stringValue;
}

- (BOOL)commitChaptersWithError:(NSError **)error
{
    NSMutableArray *chapters = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.chapterRows.count; i++) {
        uint64_t milliseconds = 0;
        if (![MP4Chapter parseTimestamp:self.chapterRows[i][@"start"] milliseconds:&milliseconds]) {
            if (error) *error = [NSError errorWithDomain:@"AudioBookBinder.Chapters" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu has an invalid start time. Use HH:MM:SS.mmm, MM:SS.mmm, or seconds.", nil), (unsigned long)(i + 1)]}];
            return NO;
        }
        [chapters addObject:[[MP4Chapter alloc] initWithTitle:self.chapterRows[i][@"title"] startMilliseconds:milliseconds]];
    }
    self.metadata.chapters = chapters;
    return [self.metadata validateChaptersWithError:error];
}

- (void)importChapters:(id)sender
{
    if (self.saving || ![self.window makeFirstResponder:nil]) return;
    [ChapterList chooseForWindow:self.window duration:self.metadata.durationMilliseconds completion:^(NSArray *chapters) {
        NSArray *previous = self.metadata.chapters;
        self.metadata.chapters = chapters;
        NSError *error = nil;
        if (![self.metadata validateChaptersWithError:&error]) {
            self.metadata.chapters = previous;
            [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        [self.chapterRows removeAllObjects];
        for (MP4Chapter *chapter in chapters)
            [self.chapterRows addObject:[@{@"title": chapter.title, @"start": [MP4Chapter timestampForMilliseconds:chapter.startMilliseconds]} mutableCopy]];
        [self.chapterTable deselectAll:nil];
        [self.chapterTable reloadData];
        self.window.documentEdited = YES;
    }];
}

- (void)addChapter:(id)sender
{
    if (self.saving || ![self.window makeFirstResponder:nil]) return;
    NSError *error = nil;
    if (![self commitChaptersWithError:&error]) {
        [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSInteger selected = self.chapterTable.selectedRow;
    NSUInteger index = selected >= 0 ? (NSUInteger)selected : (self.chapterRows.count ? self.chapterRows.count - 1 : 0);
    uint64_t start = 0;
    if (self.chapterRows.count) {
        uint64_t previous = self.metadata.chapters[index].startMilliseconds;
        uint64_t end = index + 1 < self.metadata.chapters.count ? self.metadata.chapters[index + 1].startMilliseconds : self.metadata.durationMilliseconds;
        if (end <= previous || end - previous < 2) { NSBeep(); return; }
        start = previous + (end - previous) / 2;
        index++;
    }
    NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Chapter %lu", nil), (unsigned long)(self.chapterRows.count + 1)];
    [self.chapterRows insertObject:[@{@"title": title, @"start": [MP4Chapter timestampForMilliseconds:start]} mutableCopy] atIndex:index];
    [self.chapterTable reloadData];
    [self.chapterTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self.chapterTable scrollRowToVisible:index];
    self.window.documentEdited = YES;
}

- (void)removeChapter:(id)sender
{
    if (self.saving || ![self.window makeFirstResponder:nil]) return;
    NSIndexSet *selected = self.chapterTable.selectedRowIndexes;
    if (!selected.count) return;
    [self.chapterRows removeObjectsAtIndexes:selected];
    if (self.chapterRows.count) self.chapterRows[0][@"start"] = [MP4Chapter timestampForMilliseconds:0];
    [self.chapterTable deselectAll:nil];
    [self.chapterTable reloadData];
    self.window.documentEdited = YES;
}

- (void)refreshCover
{
    self.coverView.image = self.metadata.removeCover ? nil : [[NSImage alloc] initWithData:self.metadata.coverData];
    self.coverPlaceholder.hidden = self.coverView.image != nil;
    self.removeCoverButton.enabled = self.metadata.coverData.length && !self.metadata.removeCover;
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    self.window.documentEdited = YES;
}

- (void)setCover:(id)sender
{
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowedContentTypes = @[UTTypePNG, UTTypeJPEG];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL *url = panel.URL;
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (scoped) [url stopAccessingSecurityScopedResource];
        const unsigned char *bytes = data.bytes;
        BOOL supported = data.length >= 8 && ((bytes[0] == 0xff && bytes[1] == 0xd8) || memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0);
        if (!supported || ![[NSImage alloc] initWithData:data]) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = NSLocalizedString(@"Choose a valid PNG or JPEG image.", nil);
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        self.metadata.coverData = data;
        self.metadata.removeCover = NO;
        [self refreshCover];
        self.window.documentEdited = YES;
    }];
}

- (void)removeCover:(id)sender
{
    self.metadata.removeCover = YES;
    [self refreshCover];
    self.window.documentEdited = YES;
}

- (void)save:(id)sender
{
    if (self.saving || ![self.window makeFirstResponder:nil]) return;
    for (NSUInteger i = 0; i < self.keys.count; i++)
        [self.metadata setValue:self.fields[i].stringValue forKey:self.keys[i]];
    NSError *chapterError = nil;
    if (![self commitChaptersWithError:&chapterError]) {
        [[NSAlert alertWithError:chapterError] beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    self.saving = YES;
    [self setControlsEnabled:NO];
    [self.progress startAnimation:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL saved = [self.metadata saveMetadataWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.saving = NO;
            [self.progress stopAnimation:nil];
            if (saved) {
                self.window.documentEdited = NO;
                [self.window close];
            } else {
                [self setControlsEnabled:YES];
                [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
            }
        });
    });
}

- (void)saveDocument:(id)sender
{
    [self save:sender];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    for (NSTextField *field in self.fields) field.enabled = enabled;
    self.chooseCoverButton.enabled = enabled;
    self.removeCoverButton.enabled = enabled && self.metadata.coverData.length && !self.metadata.removeCover;
    self.chapterTable.enabled = enabled;
    for (NSInteger row = 0; row < self.chapterTable.numberOfRows; row++) {
        for (NSInteger column = 1; column < self.chapterTable.numberOfColumns; column++) {
            NSTableCellView *cell = [self.chapterTable viewAtColumn:column row:row makeIfNecessary:NO];
            cell.textField.enabled = enabled;
        }
    }
    self.addChapterButton.enabled = enabled;
    self.importChapterButton.enabled = enabled;
    self.removeChapterButton.enabled = enabled && self.chapterTable.selectedRowIndexes.count > 0;
    self.saveButton.enabled = enabled;
    self.cancelButton.enabled = enabled;
    [self.window standardWindowButton:NSWindowCloseButton].enabled = enabled;
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (self.saving) return NO;
    if (!sender.documentEdited) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = NSLocalizedString(@"Save changes to this audiobook?", nil);
    alert.informativeText = self.fileURL.lastPathComponent;
    [alert addButtonWithTitle:NSLocalizedString(@"Save", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Don’t Save", nil)];
    [alert beginSheetModalForWindow:sender completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self save:nil];
        else if (response == NSAlertThirdButtonReturn) [self.window close];
    }];
    return NO;
}

- (void)windowWillClose:(NSNotification *)notification
{
    if (self.onClose) self.onClose(self);
}

@end
