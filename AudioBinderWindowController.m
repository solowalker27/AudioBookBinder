//
//  Copyright (c) 2013-2016 Oleksandr Tymoshenko <gonzo@bluezbox.com>
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

#import "AudioBinder.h"
#import "AudioBookVolume.h"
#import "AudioBinderWindowController.h"
#import "AudioBookBinderAppDelegate.h"
#import "AudioFile.h"
#import "Chapter.h"
#import "ChapterList.h"
#import "ConfigNames.h"
#import "ExpandedPathToIconTransformer.h"
#import "ExpandedPathToPathTransformer.h"
#import "MP4File.h"
#import "MetaEditor.h"
#import "NSOutlineView_Extension.h"
#import "StatsManager.h"
#import "QueueController.h"

#import <QuartzCore/QuartzCore.h>

// localized strings
#define TEXT_CONVERSION_FAILED  NSLocalizedString(@"Audiofile conversion failed", nil)
#define TEXT_BINDING_FAILED     NSLocalizedString(@"Audiobook binding failed", nil)
#define TEXT_ADDING_TAGS        NSLocalizedString(@"Adding artist/title tags", nil)
#define TEXT_ADDING_CHAPTERS    NSLocalizedString(@"Adding chapter markers", nil)
#define TEXT_CONVERTING         NSLocalizedString(@"Converting %@", nil)
#define TEXT_CANT_SPLIT         NSLocalizedString(@"Failed to split audiobook into volumes", nil)
#define TEXT_MAXDURATION_VIOLATED NSLocalizedString(@"%s: duration (%d sec) is larger than the maximum volume duration (%lld sec.)", nil)
#define TEXT_FAILED_TO_PLAY     NSLocalizedString(@"Failed to play", nil)
#define TEXT_CANT_PLAY          NSLocalizedString(@"Failed to play: %@", nil)
#define TEXT_AUDIOBOOK          NSLocalizedString(@"Audiobook", nil)
#define TEXT_AUDIOBOOKS         NSLocalizedString(@"Audiobooks", nil)
#define TEXT_FILE_EXISTS        NSLocalizedString(@"File exists", @"epub file exists")
#define TEXT_FILE_OVERWRITE     NSLocalizedString(@"File %@ already exists, replace?", @"epub file exists")
#define TEXT_OVERWRITE          NSLocalizedString(@"Replace", @"")
#define TEXT_CANCEL             NSLocalizedString(@"Cancel", @"")
#define TEXT_BOOK_IS_READY      NSLocalizedString(@"Audiobook is ready", @"")

#define ColumnsConfiguration                @"ColumnsConfiguration"

#define KVO_CONTEXT_CANPLAY_CHANGED         @"CanPlayChanged"
#define KVO_CONTEXT_HASFILES_CHANGED        @"HasFilesChanged"
#define KVO_CONTEXT_COMMONAUTHOR_CHANGED    @"CommonAuthorChanged"
#define KVO_CONTEXT_COMMONALBUM_CHANGED     @"CommonAlbumChanged"

#ifdef APP_STORE_BUILD
extern BOOL requiresUpdateHack;
#endif

typedef struct 
{
    __unsafe_unretained NSString *id;
    __unsafe_unretained NSString *title;
    BOOL enabled;
} column_t;

column_t columnDefs[] = {
    {COLUMNID_FILE, @"File", NO},
    {COLUMNID_AUTHOR, @"Author", NO},
    {COLUMNID_ALBUM, @"Album", NO},
    {COLUMNID_TIME, @"Time", NO},
    {nil, nil}
};

enum abb_form_fields {
    ABBAuthor = 0,
    ABBTitle,
};

@interface AudioBinderWindowController () <NSToolbarDelegate> {
    NSSegmentedControl *_sectionPicker;
    NSTextField *_emptyState;
    NSButton *_removeButton;
    NSURL *_destURL;
    NSMutableArray *knownGenres;
    BOOL autocompleting;
    NSString *outFile;
    AudioBinder *_binder;
    NSSound *_sound;
    NSString *_playingFile;
    NSImage *_playImg, *_stopImg;
    BOOL _conversionResult;
    AudioFileList *fileList;
    // QueueOverlayView *_queueOverlay;
    
    NSMutableArray *currentColumns;

    NSUInteger _currentFileProgress;
    NSUInteger _totalBookProgress;
    NSUInteger _totalBookDuration;
    BOOL _converting;
    BOOL _enqueued;
}

- (void)playFailed;
- (void)sound:(NSSound *)sound didFinishPlaying:(BOOL)finishedPlaying;

@end

@implementation AudioBinderWindowController

- (id)initWithWindow:(NSWindow *)window
{
    self = [super initWithWindow:window];

    if (self) {
        [self updateWindowTitle];
    }
    
    return self;
}

- (void)dealloc
{
    _sound.delegate = nil;
    [_sound stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [fileList removeObserver:self forKeyPath:@"hasFiles"];
    [fileList removeObserver:self forKeyPath:@"canPlay"];
    [fileList removeObserver:self forKeyPath:@"commonAuthor"];
    [fileList removeObserver:self forKeyPath:@"commonAlbum"];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    
    fileList = [[AudioFileList alloc] init];
    [fileListView setDataSource:fileList];
    [fileListView setDelegate:fileList];
    [fileListView setAllowsMultipleSelection:YES];
    [fileListView registerForDraggedTypes:@[NSPasteboardTypeString, NSPasteboardTypeFileURL]];
    [fileListView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
    [fileListView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [fileListView setAutoresizesOutlineColumn:NO];
    // expand initial chapter if chapter mode is enabled
    [fileListView expandItem:nil expandChildren:YES];
    
    _binder = [[AudioBinder alloc] init];
    _converting = NO;
    _enqueued = NO;
    _playImg = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:NSLocalizedString(@"Preview", nil)];
    _stopImg = [NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:NSLocalizedString(@"Stop", nil)];
    
    [playButton setImage:_playImg];
    playButton.accessibilityLabel = NSLocalizedString(@"Preview", nil);
    [self setPreviewEnabled:NO];
    _playingFile = nil;
    _destURL = nil;
    _totalBookProgress = 0;
    _totalBookDuration = 0;
    _currentFileProgress = 0;
    
    [fileList addObserver:self
        forKeyPath:@"canPlay"
           options:0
           context:KVO_CONTEXT_CANPLAY_CHANGED];
    [fileList addObserver:self
        forKeyPath:@"hasFiles"
           options:0
           context:KVO_CONTEXT_HASFILES_CHANGED];
    [fileList addObserver:self
               forKeyPath:@"commonAuthor"
                  options:0
                  context:KVO_CONTEXT_COMMONAUTHOR_CHANGED];
    [fileList addObserver:self
               forKeyPath:@"commonAlbum"
                  options:0
                  context:KVO_CONTEXT_COMMONALBUM_CHANGED];

    [self updateWindowTitle];
    [self setupColumns];
    [self setupGenres];
    [self setCreateEnabled:FALSE];
    
    AudioBookBinderAppDelegate *delegate = (AudioBookBinderAppDelegate*)[[NSApplication sharedApplication] delegate];
    [self.window setDelegate:delegate];
    
    [self modernizeWindow];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSelection:) name:NSOutlineViewSelectionDidChangeNotification object:fileListView];
}

// Keep the existing models, bindings and actions while using native, adaptive AppKit controls.
- (void)modernizeWindow
{
    NSWindow *window = self.window;
    window.styleMask &= ~NSWindowStyleMaskTexturedBackground;
    window.titlebarAppearsTransparent = YES;
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.contentMinSize = NSMakeSize(780, 440);
    [window setContentSize:NSMakeSize(960, 640)];

    // Retain the nib's controls before detaching their original parent views.
    NSArray *fields = @[authorField, titleField, actorField, genresField];
    NSScrollView *scroll = fileListView.enclosingScrollView;
    [scroll removeFromSuperview];
    [coverImageView removeFromSuperview];
    [tabs removeFromSuperview];
    [playButton removeFromSuperview];
    [bindButton removeFromSuperview];
    [genresButton removeFromSuperview];
    for (NSView *field in fields) [field removeFromSuperview];

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 960, 640)];
    window.contentView = root;
    NSVisualEffectView *sidebar = [NSVisualEffectView new];
    sidebar.material = NSVisualEffectMaterialSidebar;
    sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:sidebar];

    NSTextField *heading = [NSTextField labelWithString:NSLocalizedString(@"Book details", nil)];
    heading.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    NSTextField *intro = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Turn your audio files into a book worth listening to.", nil)];
    intro.textColor = NSColor.secondaryLabelColor;
    NSStackView *details = [NSStackView stackViewWithViews:@[heading, intro]];
    details.orientation = NSUserInterfaceLayoutOrientationVertical;
    details.alignment = NSLayoutAttributeLeading;
    details.spacing = 12;
    details.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:details];
    NSArray *labels = @[NSLocalizedString(@"Author", nil), NSLocalizedString(@"Title", nil), NSLocalizedString(@"Narrator", nil), NSLocalizedString(@"Genre", nil)];
    for (NSUInteger i = 0; i < fields.count; i++) {
        NSTextField *field = fields[i];
        field.font = [NSFont systemFontOfSize:13];
        field.placeholderString = labels[i];
        field.accessibilityLabel = labels[i];
        NSTextField *label = [NSTextField labelWithString:labels[i]];
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        label.textColor = NSColor.secondaryLabelColor;
        [details addArrangedSubview:label];
        [details setCustomSpacing:5 afterView:label];
        if (field == genresField) {
            NSStackView *genreRow = [NSStackView stackViewWithViews:@[field, genresButton]];
            genreRow.spacing = 4;
            [genresButton.widthAnchor constraintEqualToConstant:26].active = YES;
            [details addArrangedSubview:genreRow];
            [genreRow.widthAnchor constraintEqualToAnchor:details.widthAnchor].active = YES;
        } else {
            [details addArrangedSubview:field];
            [field.widthAnchor constraintEqualToAnchor:details.widthAnchor].active = YES;
        }
        [field.heightAnchor constraintEqualToConstant:26].active = YES;
    }
    NSTextField *hint = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Export as an M4B audiobook with chapters and cover art. Audio quality and volume length can be changed in Settings.", nil)];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:hint];

    tabs.tabViewType = NSNoTabsNoBorder;
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:tabs];
    NSView *filesView = [tabs tabViewItemAtIndex:0].view;
    NSView *artView = [tabs tabViewItemAtIndex:1].view;
    for (NSView *view in filesView.subviews.copy) [view removeFromSuperview];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.borderType = NSNoBorder;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    fileListView.style = NSTableViewStyleFullWidth;
    fileListView.rowHeight = 28;
    fileListView.usesAlternatingRowBackgroundColors = YES;
    [filesView addSubview:scroll];
    _emptyState = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Your audiobook starts here\nAdd audio files or drag them into this list.", nil)];
    _emptyState.alignment = NSTextAlignmentCenter;
    _emptyState.textColor = NSColor.secondaryLabelColor;
    _emptyState.font = [NSFont systemFontOfSize:15];
    _emptyState.translatesAutoresizingMaskIntoConstraints = NO;
    [filesView addSubview:_emptyState];
    coverImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [artView addSubview:coverImageView];

    _sectionPicker = [NSSegmentedControl segmentedControlWithLabels:@[NSLocalizedString(@"Audio files", nil), NSLocalizedString(@"Cover art", nil)] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectSection:)];
    _sectionPicker.selectedSegment = 0;
    _sectionPicker.accessibilityLabel = NSLocalizedString(@"Audiobook section", nil);
    _sectionPicker.translatesAutoresizingMaskIntoConstraints = NO;
    _sectionPicker.segmentStyle = NSSegmentStyleAutomatic;
    [root addSubview:_sectionPicker];
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:270],
        [details.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:24],
        [details.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-24],
        [details.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:28],
        [hint.leadingAnchor constraintEqualToAnchor:details.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:details.trailingAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-24],
        [hint.topAnchor constraintGreaterThanOrEqualToAnchor:details.bottomAnchor constant:24],
        [_sectionPicker.topAnchor constraintEqualToAnchor:root.topAnchor constant:24],
        [_sectionPicker.centerXAnchor constraintEqualToAnchor:tabs.centerXAnchor],
        [_sectionPicker.widthAnchor constraintEqualToConstant:234],
        [tabs.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:20],
        [tabs.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [tabs.topAnchor constraintEqualToAnchor:_sectionPicker.bottomAnchor constant:24],
        [tabs.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-20],
        [scroll.leadingAnchor constraintEqualToAnchor:filesView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:filesView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:filesView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:filesView.bottomAnchor],
        [_emptyState.centerXAnchor constraintEqualToAnchor:filesView.centerXAnchor],
        [_emptyState.centerYAnchor constraintEqualToAnchor:filesView.centerYAnchor],
        [_emptyState.widthAnchor constraintLessThanOrEqualToAnchor:filesView.widthAnchor constant:-40],
        [coverImageView.centerXAnchor constraintEqualToAnchor:artView.centerXAnchor],
        [coverImageView.centerYAnchor constraintEqualToAnchor:artView.centerYAnchor],
        [coverImageView.widthAnchor constraintEqualToAnchor:artView.widthAnchor constant:-60],
        [coverImageView.heightAnchor constraintEqualToAnchor:artView.heightAnchor constant:-60]
    ]];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"AudiobookToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    window.toolbar = toolbar;
    [self updateEmptyState];
    // The old nib stores a screen position that can be outside today's display bounds.
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (screen) {
        NSRect frame = window.frame;
        frame.size.width = MIN(frame.size.width, screen.visibleFrame.size.width);
        frame.size.height = MIN(frame.size.height, screen.visibleFrame.size.height);
        [window setFrame:[window constrainFrameRect:frame toScreen:screen] display:NO];
    }
    [window center];
}

- (void)selectSection:(NSSegmentedControl *)sender
{
    [tabs selectTabViewItemAtIndex:sender.selectedSegment];
}

- (void)setToolbarItem:(NSString *)identifier enabled:(BOOL)enabled
{
    for (NSToolbarItem *item in self.window.toolbar.items)
        if ([item.itemIdentifier isEqualToString:identifier]) item.enabled = enabled;
}

- (void)setCreateEnabled:(BOOL)enabled
{
    bindButton.enabled = enabled;
    [self setToolbarItem:@"Create" enabled:enabled];
}

- (void)setPreviewEnabled:(BOOL)enabled
{
    playButton.enabled = enabled;
    [self setToolbarItem:@"Preview" enabled:enabled];
}

- (void)setRemoveEnabled:(BOOL)enabled
{
    _removeButton.enabled = enabled;
    [self setToolbarItem:@"Remove" enabled:enabled];
}

- (void)updateEmptyState
{
    _emptyState.hidden = fileList.hasFiles;
    fileListView.usesAlternatingRowBackgroundColors = fileList.hasFiles;
    [self setRemoveEnabled:fileListView.numberOfSelectedRows > 0];
}

- (void)updateSelection:(NSNotification *)notification
{
    [self setRemoveEnabled:fileListView.numberOfSelectedRows > 0];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    return @[@"Add", @"Remove", @"Preview", @"Artwork", NSToolbarFlexibleSpaceItemIdentifier, @"Create"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    NSDictionary *labels = @{@"Add": NSLocalizedString(@"Add Files", nil), @"Remove": NSLocalizedString(@"Remove", nil), @"Preview": NSLocalizedString(@"Preview", nil), @"Artwork": NSLocalizedString(@"Choose Cover", nil), @"Create": NSLocalizedString(@"Create Audiobook", nil)};
    item.label = labels[identifier];
    NSButton *button;
    if ([identifier isEqualToString:@"Create"]) {
        button = bindButton;
        button.title = item.label;
        button.image = [NSImage imageWithSystemSymbolName:@"book.closed" accessibilityDescription:nil];
        button.imagePosition = NSImageLeading;
        button.keyEquivalent = @"\r";
    } else if ([identifier isEqualToString:@"Preview"]) {
        button = playButton;
    } else {
        NSDictionary *symbols = @{@"Add": @"plus", @"Remove": @"minus", @"Artwork": @"photo"};
        SEL action = [identifier isEqualToString:@"Add"] ? @selector(addFiles:) : ([identifier isEqualToString:@"Remove"] ? @selector(delFiles:) : @selector(setCover:));
        button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbols[identifier] accessibilityDescription:item.label] target:self action:action];
        if ([identifier isEqualToString:@"Remove"]) _removeButton = button;
    }
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    button.accessibilityLabel = item.label;
    button.toolTip = item.label;
    [button sizeToFit];
    item.view = button;
    item.autovalidates = NO;
    item.enabled = button.enabled;
    return item;
}

- (void)setupColumns {
    int idx;
    // build table header context menu
    NSArray *cols = [[NSUserDefaults standardUserDefaults] arrayForKey:ColumnsConfiguration];
    // default case, add Name and Time columns
    if (cols == nil) {
        NSArray *tableColumns = [NSArray arrayWithArray:[fileListView tableColumns]];
        NSTableColumn *column = [tableColumns objectAtIndex:0];
        [column setIdentifier:COLUMNID_NAME];
        column = [[NSTableColumn alloc] initWithIdentifier:COLUMNID_TIME];
        
        [fileListView addTableColumn:column];
        [column setWidth:150];
    }
    else
    {
        // load from saved state
        NSDictionary *colinfo;
        NSTableColumn *column;
        NSArray *tableColumns = [NSArray arrayWithArray:[fileListView tableColumns]];
        
        idx = 0;
        for (colinfo in cols) {
            NSString *identifier = [colinfo objectForKey:@"identifier"];
            CGFloat width = [[colinfo objectForKey:@"width"] floatValue];
            if (idx == 0) {
                column = [tableColumns objectAtIndex:0];
                [column setIdentifier:identifier];
                [column setWidth:width];
            }
            else {
                column = [[NSTableColumn alloc] initWithIdentifier:identifier];
                [column setWidth:width];
                [fileListView addTableColumn:column];
            }
            
            idx++;
        }
        
    }

    // build table header context menu
    NSMenu *tableHeaderContextMenu = [[NSMenu alloc] initWithTitle:@""];
    [[fileListView headerView] setMenu:tableHeaderContextMenu];
    
    NSArray *columns = [fileListView tableColumns];
    
    for (NSTableColumn *c in columns) {
        BOOL found = NO;
        for (idx = 0; columnDefs[idx].id; idx++)
        {
            if ([columnDefs[idx].id isEqualToString:c.identifier]) {
                columnDefs[idx].enabled = YES;
                [[c headerCell] setStringValue:NSLocalizedString(columnDefs[idx].title, nil)];
                found = YES;
                break;
            }
        }
        // Name column is special. It can't be removed from view
        if (!found && ([c.identifier isEqualToString:COLUMNID_NAME])) {
            [[c headerCell] setStringValue:NSLocalizedString(@"Name", nil)];
            // make sure outline column is NameColumn
            [fileListView setOutlineTableColumn:c];
        }
    }

    
    for (idx = 0; columnDefs[idx].id; idx++)
    {
        NSString *title = NSLocalizedString(columnDefs[idx].title, nil);
        NSMenuItem *item = [tableHeaderContextMenu addItemWithTitle:title action:@selector(contextMenuSelected:) keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:columnDefs[idx].id];
        [item setState:columnDefs[idx].enabled?NSControlStateValueOn:NSControlStateValueOff];
    }
    
    
    // listen for changes so know when to save
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveTableColumns) name:NSOutlineViewColumnDidMoveNotification object:fileListView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveTableColumns) name:NSOutlineViewColumnDidResizeNotification object:fileListView];
    
    // [self.window setFrameAutosaveName:@"AudioBookbinderWindow"];  // Specify the autosave name for the window.
}

- (void) setupGenres {
    [genresField setStringValue:TEXT_AUDIOBOOKS];
    knownGenres = [[NSMutableArray alloc] initWithObjects:@"Art",
                   @"Biography",
                   @"Business",
                   @"Chick Lit",
                   @"Children's",
                   @"Christian",
                   @"Classics",
                   @"Comics",
                   @"Contemporary",
                   @"Cookbooks",
                   @"Crime",
                   @"Ebooks",
                   @"Fantasy",
                   @"Fiction",
                   @"Gay And Lesbian",
                   @"Historical Fiction",
                   @"History",
                   @"Horror",
                   @"Humor And Comedy",
                   @"Memoir",
                   @"Music",
                   @"Mystery",
                   @"Non Fiction",
                   @"Paranormal",
                   @"Philosophy",
                   @"Poetry",
                   @"Psychology",
                   @"Religion",
                   @"Romance",
                   @"Science",
                   @"Science Fiction",
                   @"Self Help",
                   @"Suspense",
                   @"Spirituality",
                   @"Sports",
                   @"Thriller",
                   @"Travel",
                   @"Young Adult",
                   nil];
    [genresButton removeAllItems];
    [genresButton addItemsWithTitles:knownGenres];
#ifdef notyet
    [[genresButton menu] addItem:[NSMenuItem separatorItem]];
    [genresButton addItemWithTitle:@"Edit genres"];
    [[genresButton lastItem] setTag:-1];
#endif
    [genresButton setTarget:self];
    [genresButton setAction:@selector(genresButtonChanged:)];
    
    autocompleting = NO;
    [genresField setDelegate:self];
}

- (void)saveTableColumns {
    NSMutableArray *cols = [NSMutableArray array];
    NSEnumerator *enumerator = [[fileListView tableColumns] objectEnumerator];
    NSTableColumn *column;
    while((column = [enumerator nextObject])) {
        [cols addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                         [column identifier], @"identifier",
                         [NSNumber numberWithFloat:[column width]], @"width",
                         nil]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:cols forKey:ColumnsConfiguration];
}

- (IBAction) addFiles: (id)sender
{
    if (_converting) return;
    NSOpenPanel *openDlg = [NSOpenPanel openPanel];
    
    [openDlg setCanChooseFiles:YES];
    [openDlg setCanChooseDirectories:YES];
    [openDlg setAllowsMultipleSelection:YES];

    if ( [openDlg runModal] == NSModalResponseOK )
    {
        BOOL sortFiles = [[NSUserDefaults standardUserDefaults] boolForKey:kConfigSortAudioFiles];
        NSArray *urls;
        
        if (sortFiles)
            urls = [[openDlg URLs] sortedArrayUsingComparator:^(id a, id b) {return [[a path] localizedStandardCompare:[b path]];}];
        else
            urls = [openDlg URLs];
        
        for(NSURL *url in urls)
        {
            NSString* fileName = [url path];
            BOOL isDir;
            if ([[NSFileManager defaultManager] fileExistsAtPath:fileName isDirectory:&isDir])
            {
                if (isDir)
                    // add file recursively
                    [fileList addFilesInDirectory:fileName];
                else
                    [fileList addFile:fileName];

            }
        }
        [fileList tryGuessingAuthorAndAlbum];
        [fileListView reloadData];
    }
}

- (IBAction) delFiles: (id)sender
{
    
    if (_converting) return;
    [fileList deleteSelected:fileListView];
}

- (IBAction) bind: (id)sender
{    
    if (_converting || !fileList.hasFiles) return;
    [self.window makeFirstResponder:nil];
    [self updateWindowTitle];
    [self playStopIfNeeded];

    NSString *author = [authorField stringValue];
    NSString *title = [titleField stringValue];
    NSMutableString *filename = [NSMutableString string];
    
    if (![author isEqualToString:@""])
        [filename appendString:
            [[author stringByReplacingOccurrencesOfString:@"/" withString:@" "]  stringByReplacingOccurrencesOfString:@":" withString:@" -"]];
    
    if (![title isEqualToString:@""]) {
        if (![filename isEqualToString:@""])
            [filename appendString:@" - "];
        
        [filename appendString:
            [[title stringByReplacingOccurrencesOfString:@"/" withString:@" "] stringByReplacingOccurrencesOfString:@":" withString:@" -"]];
    }
    
    if ([filename isEqualToString:@""])
        [filename setString:@"audiobook"];
    [filename appendString:@".m4b"];
    
#ifdef APP_STORE_BUILD
    saveAsFilename.stringValue = filename;
    [self.window beginSheet:saveAsPanel completionHandler:nil];
#else
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAccessoryView: nil];
    // [savePanel setAllowedFileTypes:[NSArray arrayWithObjects:@"m4a", @"m4b", nil]];
    NSString *dir = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigDestinationFolder];
    
    [savePanel setDirectoryURL:[NSURL fileURLWithPath:dir]];
    [savePanel setNameFieldStringValue:filename];
    NSInteger choice = [savePanel runModal];
    
    
    /* if successful, save file under designated name */
    if (choice == NSModalResponseOK)
    {
        outFile = [[savePanel URL] path];
        // A Save panel grants access to one file. Multiple volumes need a folder grant.
        NSInteger hours = [[NSUserDefaults standardUserDefaults] integerForKey:kConfigMaxVolumeSize];
        UInt64 total = 0;
        for (AudioFile *file in fileList.files) total += file.duration.unsignedLongLongValue;
        if (hours > 0 && hours < 25 && total > (UInt64)hours * 3600000) {
            NSOpenPanel *folderPanel = [NSOpenPanel openPanel];
            folderPanel.canChooseDirectories = YES;
            folderPanel.canChooseFiles = NO;
            folderPanel.canCreateDirectories = YES;
            folderPanel.directoryURL = savePanel.directoryURL;
            folderPanel.message = NSLocalizedString(@"This audiobook needs multiple volumes. Choose the folder where all volumes will be saved.", nil);
            folderPanel.prompt = NSLocalizedString(@"Choose Export Folder", nil);
            if ([folderPanel runModal] != NSModalResponseOK) return;
            _destURL = folderPanel.URL;
            [_destURL startAccessingSecurityScopedResource];
            outFile = [_destURL.path stringByAppendingPathComponent:outFile.lastPathComponent];
            NSMutableArray *existing = [NSMutableArray array];
            NSUInteger volume = 0;
            UInt64 duration = 0;
            for (AudioFile *file in fileList.files) {
                if (duration > 0 && duration + file.duration.unsignedLongLongValue > (UInt64)hours * 3600000) {
                    volume++;
                    duration = 0;
                }
                duration += file.duration.unsignedLongLongValue;
            }
            for (NSUInteger index = 0; index <= volume; index++) {
                NSString *name = index == 0 ? outFile : [NSString stringWithFormat:@"%@-%lu.%@", outFile.stringByDeletingPathExtension, (unsigned long)index, outFile.pathExtension];
                if ([NSFileManager.defaultManager fileExistsAtPath:name]) [existing addObject:name.lastPathComponent];
            }
            if (existing.count) {
                NSAlert *alert = [NSAlert new];
                alert.messageText = NSLocalizedString(@"Replace existing audiobook volumes?", nil);
                alert.informativeText = [existing componentsJoinedByString:@"\n"];
                [alert addButtonWithTitle:TEXT_CANCEL];
                [alert addButtonWithTitle:TEXT_OVERWRITE];
                if ([alert runModal] != NSAlertSecondButtonReturn) {
                    [_destURL stopAccessingSecurityScopedResource];
                    _destURL = nil;
                    return;
                }
            }
        }
        [self startBinding];
    }
    
#endif
}


- (IBAction) saveAsOk:(id)sender
{
    [NSApp endSheet:saveAsPanel];
    [saveAsPanel orderOut:nil];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *destPath;
    _destURL = [NSURL URLByResolvingBookmarkData:[defaults objectForKey:kConfigDestinationFolderBookmark] options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:nil error:nil];
    if (_destURL == nil) {
#ifdef APP_STORE_BUILD
        if (requiresUpdateHack) {
            NSString *currentDest = [defaults stringForKey:kConfigDestinationFolder];
            NSOpenPanel * panel = [NSOpenPanel openPanel];
            
            [panel setPrompt: NSLocalizedString(@"Select", nil)];
            [panel setAllowsMultipleSelection: NO];
            [panel setCanChooseFiles: NO];
            [panel setCanChooseDirectories: YES];
            [panel setCanCreateDirectories: YES];
            [panel setDirectoryURL:[NSURL fileURLWithPath:currentDest]];
            NSInteger result = [panel runModal];
            if (result == NSModalResponseOK)
            {
                _destURL = [panel URL];
                destPath = [_destURL path];
                
            }
            else
                return;
        }
        else
            destPath = [defaults stringForKey:kConfigDestinationFolder];
#else
        // standard Music directory
        destPath = [defaults stringForKey:kConfigDestinationFolder];
#endif
    }
    else {
        destPath = [_destURL path];
        [_destURL startAccessingSecurityScopedResource];
    }
    
    outFile = [destPath stringByAppendingPathComponent:[saveAsFilename stringValue]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outFile]) {
        NSAlert *a = [[NSAlert alloc] init];
        [a addButtonWithTitle:TEXT_OVERWRITE];
        [a addButtonWithTitle:TEXT_CANCEL];
        
        [a setMessageText:TEXT_FILE_EXISTS];
        [a setAlertStyle:NSAlertStyleWarning];
        [a setInformativeText: [NSString stringWithFormat:TEXT_FILE_OVERWRITE, outFile]];
        NSInteger result = [a runModal];
        if (result == NSAlertSecondButtonReturn) {
            return;
        }
    }
    
    [self startBinding];
}

- (IBAction) saveAsCancel:(id)sender
{
    
    [NSApp endSheet:saveAsPanel];
    [saveAsPanel orderOut:nil];
}

- (IBAction) setCover: (id)sender
{
    if (_converting) return;
    NSOpenPanel *openDlg = [NSOpenPanel openPanel];
    
    [openDlg setCanChooseFiles:YES];
    [openDlg setCanChooseDirectories:NO];
    [openDlg setAllowsMultipleSelection:NO];
    
    if ( [openDlg runModal] == NSModalResponseOK )
    {
        NSURL *url = [openDlg URL];
        
        NSString* fileName = [url path];
        BOOL isDir;
        if ([[NSFileManager defaultManager] fileExistsAtPath:fileName isDirectory:&isDir])
        {
            if (!isDir) // just sanity check
            {
                coverImageView.coverImageFilename = fileName;
                [tabs selectTabViewItemAtIndex:1];
                _sectionPicker.selectedSegment = 1;
            }
        }
        
        [fileListView reloadData];
    }
}

// Import is deliberately scoped to one source so timestamps are unambiguous.
- (IBAction)importChapters:(id)sender
{
    if (_converting || fileList.files.count != 1) return;
    AudioFile *file = fileList.files.firstObject;
    [ChapterList chooseForWindow:self.window duration:(uint64_t)llround(file.sourceDuration.doubleValue) completion:^(NSArray *chapters) {
        if (self->_converting || self->fileList.files.count != 1 || self->fileList.files.firstObject != file) return;
        file.chapterMarkers = chapters;
        if (!self->fileList.chapterMode) [self->fileList switchChapterMode];
        [self->fileListView reloadData];
        [self->fileListView expandItem:nil expandChildren:YES];
    }];
}

- (IBAction)removeImportedChapters:(id)sender
{
    if (_converting) return;
    for (AudioFile *file in fileList.files) file.chapterMarkers = nil;
    [fileListView reloadData];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if (item.action == @selector(importChapters:)) return !_converting && fileList.files.count == 1;
    if (item.action == @selector(removeImportedChapters:)) {
        if (_converting) return NO;
        for (AudioFile *file in fileList.files) if (file.chapterMarkers.count) return YES;
        return NO;
    }
    return !_converting;
}

- (IBAction) toggleChapters: (id)sender
{
    [fileList switchChapterMode];
    [fileListView reloadData];
    [fileListView expandItem:nil expandChildren:YES];
}

- (IBAction) renumberChapters: (id)sender
{
    [fileList renumberChapters];
    [fileListView reloadData];
}

- (IBAction) joinFiles: (id)sender
{
    [fileList joinSelectedFiles:fileListView];
}

- (IBAction) splitFiles: (id)sender
{
    [fileList splitSelectedFiles:fileListView];
}

- (IBAction) resetToDefaults: (id)sender
{
    [authorField setStringValue:@""];
    [titleField setStringValue:@""];
    [actorField setStringValue:@""];
    [genresField setStringValue:@"Audiobooks"];
    [fileList removeAllFiles:fileListView];
    [coverImageView resetImage];
}

- (void) bindingThreadIsDone:(id)sender
{
    _converting = NO;
    if (_destURL) {
        [_destURL stopAccessingSecurityScopedResource];
        _destURL = nil;
    }
    
    if (_conversionResult) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = TEXT_BOOK_IS_READY;
        alert.informativeText = outFile.lastPathComponent;
        [alert addButtonWithTitle:NSLocalizedString(@"Show in Finder", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Done", nil)];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn)
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self->outFile]]];
        }];
    }
    
    [self setCreateEnabled:fileList.hasFiles];
}

- (void) showProgressPanel: (id) sender
{
    [self.window beginSheet:progressPanel completionHandler:nil];
}

- (void) hideProgressPanel: (id) sender
{
    [NSApp endSheet:progressPanel];
    [progressPanel orderOut:nil];
}

- (void)startBinding
{
    _converting = YES;
    _conversionResult = NO;
    [self setCreateEnabled:NO];
    [_binder reset];
    [_binder setDelegate:self];
    [self showProgressPanel:nil];
    [NSThread detachNewThreadSelector:@selector(bindToFileThread:) toTarget:self withObject:nil];
}

- (void)bindToFileThread:(id)object
{
    @autoreleasepool {
        [self bindToFile];
    }
}

- (void)bindToFile
{
    NSString *coverImageFilename = nil;
    __block NSData *convertedCover = nil;
    __block NSString *sourceCover = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if ([self->coverImageView haveCover]) {
            if ([self->coverImageView shouldConvert]) {
                NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:self->coverImageView.coverImage.TIFFRepresentation];
                convertedCover = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            } else sourceCover = self->coverImageView.coverImageFilename;
        }
    });
    UInt64 maxVolumeDuration = 0;
    NSInteger hours = [[NSUserDefaults standardUserDefaults] integerForKey:kConfigMaxVolumeSize];
    if ((hours > 0) && (hours < 25))
        maxVolumeDuration = hours * 3600;
    
    NSLog(@"maxVolumeDuration == %lld", maxVolumeDuration);
    // split output filename to base and extension in order to get
    // filenames for consecutive volume files
    NSString *outFileBase = [outFile stringByDeletingPathExtension];
    NSString *outFileExt = [outFile pathExtension];
    
    NSArray *files = [fileList files];
    NSMutableArray *inputFiles = [[NSMutableArray alloc] init];
    UInt64 estVolumeDuration = 0;
    NSString *currentVolumeName = [outFile copy];
    NSMutableArray *volumeChapters = [[NSMutableArray alloc] init];
    NSArray *chapters = nil;
    NSMutableArray *curChapters = [[NSMutableArray alloc] init];
    Chapter *curChapter = nil;
    int chapterIdx = 0;
    BOOL hasChapters = [fileList chapterMode];
    
    if (hasChapters) {
        chapters = [fileList chapters];
        curChapter = [[chapters objectAtIndex:chapterIdx] copy];
        chapterIdx++;
        [curChapters addObject:curChapter];
    }
    
    int totalVolumes = 0;
    _currentFileProgress = 0;
    _totalBookDuration = 0;
    _totalBookProgress = 0;
    self.currentProgress = 0;

    [[StatsManager sharedInstance] updateConverter:self];
    
    BOOL onChapterBoundary = YES;
    for (AudioFile *file in files) {
        if (maxVolumeDuration && file.duration.unsignedLongLongValue > maxVolumeDuration * 1000) {
            [self volumeFailed:outFile reason:NSLocalizedString(@"An input file is longer than the maximum volume length. Increase the limit in Settings.", nil)];
            [[StatsManager sharedInstance] removeConverter:self];
            [self performSelectorOnMainThread:@selector(hideProgressPanel:) withObject:nil waitUntilDone:NO];
            [self performSelectorOnMainThread:@selector(bindingThreadIsDone:) withObject:nil waitUntilDone:NO];
            return;
        }
        if (hasChapters) {
            if (![curChapter containsFile:file]) {
                NSLog(@"%@ -> next chapter", file.filePath);
                curChapter = [[chapters objectAtIndex:chapterIdx] copy];
                chapterIdx++;
                onChapterBoundary = YES;
                [curChapters addObject:curChapter];
            }
        }
        
        if (maxVolumeDuration) {
            if ((estVolumeDuration + [file.duration intValue]) > maxVolumeDuration*1000) {
                if ([inputFiles count] > 0) {
                    [_binder addVolume:currentVolumeName files:inputFiles];
                    [inputFiles removeAllObjects];
                    estVolumeDuration = 0;
                    totalVolumes++;
                    if (hasChapters && onChapterBoundary) [curChapters removeLastObject];
                    currentVolumeName = [[NSString alloc] initWithFormat:@"%@-%d.%@",
                                         outFileBase, totalVolumes, outFileExt];
                    if (hasChapters) {
                        [volumeChapters addObject:curChapters];
                        if (!onChapterBoundary) {
                            curChapter = [curChapter splitAtFile:file];
                            NSLog(@"Splitting chapter %@ on file %@", curChapter.name, file.filePath);
                        }
                        curChapters = [[NSMutableArray alloc] init];
                        [curChapters addObject:curChapter];
                    }
                }
            }
        }
        onChapterBoundary = NO;
        [inputFiles addObject:file];
        estVolumeDuration += [file.duration intValue];
        _totalBookDuration += [file.duration intValue];
    }
    
    [_binder addVolume:currentVolumeName files:inputFiles];
    [volumeChapters addObject:curChapters];
    
    // make sure that at this point we have valid bitrate in settings
    // setup channels/samplerate
    
    _binder.channels = (UInt32)[[NSUserDefaults standardUserDefaults] integerForKey:kConfigChannels];
    _binder.sampleRate = [[NSUserDefaults standardUserDefaults] floatForKey:kConfigSampleRate];
    _binder.bitrate = (UInt32)[[NSUserDefaults standardUserDefaults] integerForKey:kConfigBitrate];
    

    [self updateProgress:0 total:100];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->fileProgress displayIfNeeded];
    });
    if (!(_conversionResult = [_binder convert]))
    {
        NSLog(@"Conversion failed");
    }
    
    else
    {
        @try {
            [self updateProgressString:TEXT_ADDING_TAGS];
            BOOL temporaryFile = convertedCover != nil;
            coverImageFilename = sourceCover;
            if (convertedCover) {
                coverImageFilename = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
                if (![convertedCover writeToFile:coverImageFilename atomically:YES])
                    [NSException raise:@"MetadataError" format:@"Could not save cover artwork"];
            }

            int track = 1;
            NSArray *volumes = [_binder volumes];
            for (AudioBookVolume *v in volumes) {
                NSString *volumeName = v.filename;
                MP4File *mp4 = [[MP4File alloc] initWithFileName:volumeName];
                mp4.artist = self.author;
                if ([volumes count] > 1) {
                    mp4.title = [NSString stringWithFormat:@"%@ #%02d", self.title, track];
                    mp4.gaplessPlay = YES;
                }
                else
                    mp4.title = self.title;
                mp4.narrator = self.actor;
                mp4.album = self.title;
                mp4.genre = self.genre;
                if (coverImageFilename)
                    [mp4 setCoverFile:coverImageFilename];
                mp4.track = track;
                mp4.tracksTotal = [volumes count];
                if (![mp4 updateFile]) [NSException raise:@"MetadataError" format:@"Could not write metadata to %@", volumeName];
                track ++;
            }

            if ((coverImageFilename != nil) && temporaryFile) {
                NSLog(@"Unlink %@", coverImageFilename);
                [[NSFileManager defaultManager] removeItemAtPath:coverImageFilename
                                                           error:nil];
            }

            if ([fileList chapterMode]) {
                [self updateProgressString:TEXT_ADDING_CHAPTERS];
                int idx = 0;
                for (AudioBookVolume *v in volumes) {
                    if (addChapters([v.filename fileSystemRepresentation], [volumeChapters objectAtIndex:idx]) != 0)
                        [NSException raise:@"MetadataError" format:@"Could not write chapters to %@", v.filename];
                    idx++;
                }
                
            }

            [self updateProgressString:@"Done"];

        }
        @catch (NSException *e) {
            _conversionResult = NO;
            [self volumeFailed:outFile reason:e.reason];
            if (convertedCover && coverImageFilename) [[NSFileManager defaultManager] removeItemAtPath:coverImageFilename error:nil];
        }
    }

    [[StatsManager sharedInstance] removeConverter:self];
    [self performSelectorOnMainThread:@selector(hideProgressPanel:) withObject:nil waitUntilDone:NO];
    [self performSelectorOnMainThread:@selector(bindingThreadIsDone:) withObject:nil waitUntilDone:NO];
}

//
// AudioBinderDelegate methods
//
-(void) conversionStart: (AudioFile*)file
                 format: (AudioStreamBasicDescription*)asbd
      formatDescription: (NSString*)description
                 length: (UInt64)frames

{
    [self updateProgressString:[NSString stringWithFormat:TEXT_CONVERTING,
                                 [file filePath]]];
    [self updateProgress:0 total:frames];
}

- (void)recalculateProgress
{
    NSUInteger newProgress = 0;
    if (_totalBookDuration > 0)
        newProgress = floor((_currentFileProgress + _totalBookProgress)*100./_totalBookDuration);
    if (newProgress != self.currentProgress) {
        self.currentProgress = newProgress;
        [[StatsManager sharedInstance] updateConverter:self];
    }
}

- (void) updateProgressString: (NSString*)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->currentFile setStringValue:message];
    });
}

- (void) updateProgress: (double)handledFrames total:(double)totalFrames
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->fileProgress setMaxValue:(double)totalFrames];
        [self->fileProgress setDoubleValue:(double)handledFrames];
    });
}

-(void) updateStatus: (AudioFile *)file handled:(UInt64)handledFrames total:(UInt64)totalFrames
{

    [self updateProgress:handledFrames total:totalFrames];

    if (totalFrames > 0) {
        _currentFileProgress = [file.duration intValue]*handledFrames/totalFrames;
        [self recalculateProgress];
    }
}

-(BOOL) continueFailedConversion:(AudioFile*)file reason:(NSString*)reason
{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:@"OK"];
        [alert setMessageText:TEXT_CONVERSION_FAILED];
        [alert setInformativeText:reason];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert runModal];
    });
    return NO;
}

-(void) volumeFailed:(NSString*)filename reason:(NSString*)reason
{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:@"OK"];
        [alert setMessageText:TEXT_BINDING_FAILED];
        [alert setInformativeText:reason];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert runModal];
    });
}


-(void) conversionFinished:(AudioFile*)file duration:(UInt32)milliseconds
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->fileProgress setDoubleValue:[self->fileProgress doubleValue]];
    });
    file.valid = YES;
    file.duration = [[NSNumber alloc] initWithInt:milliseconds];
    if (_totalBookDuration > 0) {
        _totalBookProgress += [file.duration intValue];
        _currentFileProgress = 0;
        [self recalculateProgress];
    }
}

-(void) volumeReady:(NSString*)filename duration: (UInt32)seconds
{
}

-(void) audiobookReady:(UInt32)seconds
{
}

- (IBAction) cancel: (id)sender
{
    [_binder cancel];
}

- (void)playStopIfNeeded
{
    if (_sound.isPlaying) [self playStop:nil];
}

- (IBAction) playStop: (id)sender
{
    if ((_sound != nil) && [_sound isPlaying]) {
        [_sound stop];
        _sound.delegate = nil;
        _sound = nil;
        [playButton setImage:_playImg];
        playButton.accessibilityLabel = NSLocalizedString(@"Preview", nil);
        [self setPreviewEnabled:fileList.canPlay];
        return;
    }
    
    if ([[fileListView selectedItems] count] != 1)
        return;
    
    id item = [[fileListView selectedItems] objectAtIndex:0];
    if ([item isKindOfClass:[AudioFile class]]) {
        AudioFile *file = (AudioFile *)item;
        [playButton setImage:_stopImg];
        playButton.accessibilityLabel = NSLocalizedString(@"Stop preview", nil);
        
        _playingFile = [file.filePath copy];
        _sound = [[NSSound alloc] initWithContentsOfFile:file.filePath byReference:NO];
        [_sound setDelegate:self];
        if (![_sound play]) {
            [playButton setImage:_playImg];
            playButton.accessibilityLabel = NSLocalizedString(@"Preview", nil);
            _sound = nil;
            [self setPreviewEnabled:fileList.canPlay];
            [self playFailed];
        }
    }
}

- (void)sound:(NSSound *)sound didFinishPlaying:(BOOL)finishedPlaying
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sound:sound didFinishPlaying:finishedPlaying]; });
        return;
    }
    if (sound != _sound) return;
    [playButton setImage:_playImg];
    playButton.accessibilityLabel = NSLocalizedString(@"Preview", nil);
    _sound = nil;
    [self setPreviewEnabled:fileList.canPlay];
}

- (void) playFailed
{
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *msg = [NSString stringWithFormat:TEXT_CANT_PLAY, _playingFile];
    [alert addButtonWithTitle:@"OK"];
    [alert setMessageText:TEXT_FAILED_TO_PLAY];
    [alert setInformativeText:msg];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
}



- (void)contextMenuSelected:(id)sender
{
    NSMenuItem *item = sender;
    if (item.state == NSControlStateValueOff) {
        [item setState:NSControlStateValueOn];
        
        BOOL found = NO;
        int idx;
        for (idx = 0; columnDefs[idx].id; idx++)
        {
            if ([columnDefs[idx].id isEqualToString:[item representedObject]]) {
                found = YES;
                break;
            }
        }
        
        if (found) {
            NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:columnDefs[idx].id];
            [fileListView addTableColumn:c];
            [[c headerCell] setStringValue:NSLocalizedString(columnDefs[idx].title, nil)];
        }
    }
    else {
        NSTableColumn *c = [fileListView tableColumnWithIdentifier:[item representedObject]];
        if (c) {
            [fileListView removeTableColumn:c];
        }
        [item setState:NSControlStateValueOff];
    }
    
}

- (IBAction) genresButtonChanged: (id)sender
{
    
    [genresField setStringValue:[[genresButton selectedItem] title]];
}

- (void) controlTextDidChange: (NSNotification *)genre {
#ifdef notyet
    if (!autocompleting) {
        NSTextView * fieldEditor = [[genre userInfo] objectForKey:@"NSFieldEditor"];
        autocompleting = YES;
        [fieldEditor complete:nil];
        autocompleting = NO;
        NSLog(@"Did change %@", fieldEditor);
    }
#endif
}

- (NSArray *)control:(NSControl *)control textView:(NSTextView *)textView completions:(NSArray *)words forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)index
{
    NSMutableArray *genres = [NSMutableArray arrayWithCapacity:[knownGenres count]];
    
    for (NSString *g in knownGenres) {
        if([g compare:[textView string] options:NSCaseInsensitiveSearch range:charRange] == NSOrderedSame) {
            [genres addObject:g];
        }
    }
    *index = 0;
    
    return genres;
}


//whenever an observed key path changes, this method will be called
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context;
{
    //use the context to make sure this is a change in the address,
    //because we may also be observing other things
    if(context == KVO_CONTEXT_CANPLAY_CHANGED){
        if (_sound == nil) {
            [self setPreviewEnabled:fileList.canPlay];
        }
    }
    else if(context == KVO_CONTEXT_HASFILES_CHANGED){
        [self setCreateEnabled:fileList.hasFiles && !_converting];
        [self updateEmptyState];
    }
    else if (context == KVO_CONTEXT_COMMONAUTHOR_CHANGED) {
        NSString *author = [authorField stringValue];
        if ([author isEqualTo:@""] || (author == nil))
        {
            NSString *guessedAuthor = [fileList commonAuthor];
            if ((guessedAuthor != nil) && !([guessedAuthor isEqualToString:@""]))
                [authorField setStringValue:guessedAuthor];
        }
        [self updateWindowTitle];
    }
    else if (context == KVO_CONTEXT_COMMONALBUM_CHANGED) {
        NSString *title = [titleField stringValue];

        if ([title isEqualTo:@""] || (title == nil))
        {
            NSString *guessedTitle = [fileList commonAlbum];

            if ((guessedTitle != nil) && !([guessedTitle isEqualToString:@""]))
                [titleField setStringValue:guessedTitle];
        }
        [self updateWindowTitle];
    }
}

- (void)updateWindowTitle
{
    self.author = [[authorField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.title = [[titleField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.actor = [[actorField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.genre = [[genresField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    self.windowTitle = nil;
    NSString *title;
    
    if (([self.author length] == 0) && ([self.title length] == 0))
    {
        title = TEXT_AUDIOBOOK;
    }
    else {
        title = [NSString stringWithFormat:@"%@ - %@", self.title, self.author];
    }
    
    if (_enqueued)
        title = [NSString stringWithFormat:@"[QUEUED] %@", title];
    self.windowTitle = title;
    
    // do not update if it hasn't been changed
    if (![self.windowTitle isEqualToString:self.window.title])
        [self.window setTitle:self.windowTitle];

}

-(BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor {
    if ((control == authorField) || (control == titleField) || (control == actorField)) {
        [self updateWindowTitle];
    }

    return YES;
}

- (NSUInteger) totalBookProgress {
    return _currentFileProgress + _totalBookProgress;
}

- (IBAction)folderSheetShow: (id) sender
{
    NSOpenPanel * panel = [NSOpenPanel openPanel];
    
    [panel setPrompt: NSLocalizedString(@"Select", "Preferences -> Open panel prompt")];
    [panel setAllowsMultipleSelection: NO];
    [panel setCanChooseFiles: NO];
    [panel setCanChooseDirectories: YES];
    [panel setCanCreateDirectories: YES];
    [panel beginSheetModalForWindow:saveAsPanel completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            NSURL *folderURL = [panel URL];
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

#ifdef APP_STORE_BUILD

            NSData* data = [folderURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
            [defaults setObject:data forKey:kConfigDestinationFolderBookmark];
            // Menu item is bound to DestinationFolder key so let AppStore
            // build set it as well
#endif
            NSString * folder = [folderURL path];
            [defaults setObject:folder forKey:kConfigDestinationFolder];
        }
        [self->saveAsFolderPopUp selectItemAtIndex:0];

    }];
}

- (IBAction) toggleQueue: (id)sender
{
    AudioBookBinderAppDelegate *delegate = (AudioBookBinderAppDelegate *)[[NSApplication sharedApplication] delegate];

    _enqueued = !_enqueued;
    if (_enqueued) {
        [delegate.queueController addBookWindowController:self];
        // [_queueOverlay setFrame:self.window.contentView.frame];
        // [self.window.contentView addSubview:_queueOverlay positioned:NSWindowAbove relativeTo:nil];
        // [_queueOverlay becomeFirstResponder];
    }
    else {
        // [_queueOverlay removeFromSuperview];
        [delegate.queueController removeBookWindowController:self];
    }
    [self updateWindowTitle];
}

@end
