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

#import "CoverImageView.h"

@interface CoverImageView() {
    NSMutableDictionary *attributes;
    NSString *string;
    NSColor *highlightedColor, *normalColor;
    BOOL highlighted;
    NSImage  *scaledImage;
}

- (void) drawStringCenteredIn: (NSRect) bounds;
- (void) prepareAttributes;
@end

@implementation CoverImageView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = NSLocalizedString(@"Cover artwork. Choose a cover or drop an image here.", nil);
        self.coverImage = nil;
        highlighted = NO;
        highlightedColor = [NSColor controlAccentColor];
        normalColor = [NSColor secondaryLabelColor];
        [self prepareAttributes];
        string = NSLocalizedString(@"⌘ + I\nor\nDrag Image Here", nil);
        [self registerForDraggedTypes:@[NSPasteboardTypeTIFF, NSPasteboardTypePNG, NSPasteboardTypeFileURL]];
        self.coverImageFilename = nil;

    }
    return self;
}


- (void) prepareAttributes {
    attributes = [[NSMutableDictionary alloc] init];
    [attributes setObject:[NSFont systemFontOfSize:18]
                   forKey:NSFontAttributeName];


    NSMutableParagraphStyle *centeredStyle = 
        [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [centeredStyle setAlignment:NSTextAlignmentCenter];

    [attributes setObject:[centeredStyle copy]
                   forKey:NSParagraphStyleAttributeName];

    
}

- (void) resetImage
{
    self.coverImageFilename = nil;
    self.coverImage = nil;
}

- (BOOL) haveCover
{
    
    return (self.coverImage != nil);
}

- (BOOL) shouldConvert
{
    NSString *ext = self.coverImageFilename.pathExtension.lowercaseString;
    return ![@[@"jpg", @"jpeg", @"png"] containsObject:ext ?: @""];
}


- (void) setCoverImageFilename:(NSString *)imagePath
{
    if (_coverImageFilename) {
        _coverImageFilename = nil;
    }
    
    if (imagePath) {
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:imagePath]; 
        self.coverImage = img;
        // invalid image, do not set image path
        if (img == nil)
            return;
    
        _coverImageFilename = imagePath;
    }
}


- (void) setCoverImage:(NSImage *)image
{
    
    if (image == nil)
    {
        _coverImage = nil;
        scaledImage = nil;
        [self setNeedsDisplay:YES];
        return;
    }
    
    _coverImage = [image copy];
   
    NSImageRep *rep = [[self.coverImage representations] objectAtIndex:0]; 
    [_coverImage setSize:NSMakeSize([rep pixelsWide], [rep pixelsHigh])];
    
    NSSize origSize = NSMakeSize([rep pixelsWide], [rep pixelsHigh]);
    
    if ((origSize.width > ITUNES_COVER_SIZE) || (origSize.height > ITUNES_COVER_SIZE)) {
        NSSize scaledSize;
        if (origSize.width > origSize.height) {
            scaledSize.width = ITUNES_COVER_SIZE;
            scaledSize.height = origSize.height * ITUNES_COVER_SIZE/origSize.width;
        }
        else {
            scaledSize.height = ITUNES_COVER_SIZE;
            scaledSize.width = origSize.width * ITUNES_COVER_SIZE/origSize.height;                
        }

        scaledImage = [[NSImage alloc] initWithSize:scaledSize];
        
        // Composite image appropriately
        [scaledImage lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [_coverImage drawInRect:NSMakeRect(0, 0, scaledSize.width, scaledSize.height)
                    fromRect:NSMakeRect(0, 0, origSize.width, origSize.height)
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];
        [scaledImage unlockFocus];
    }
    else {
        scaledImage = [self.coverImage copy];
    }

    [self setNeedsDisplay:YES];
}

- (void)drawStringCenteredIn: (NSRect)r 
{
    NSSize strSize = [string sizeWithAttributes:attributes];
    NSRect strRect;
    strRect.origin.x = r.origin.x + (r.size.width - strSize.width)/2;
    strRect.origin.y = r.origin.y + (r.size.height - strSize.height)/2;
    strRect.size = strSize;
    [string drawInRect:strRect withAttributes:attributes];
}

- (void)drawRect: (NSRect)dirtyRect 
{
    if (scaledImage == nil) {
        NSColor *bgColor;
        if(highlighted) {
            bgColor = highlightedColor;
            [attributes setObject:highlightedColor 
                           forKey:NSForegroundColorAttributeName];
        
        }
        else {
            bgColor = normalColor;
            [attributes setObject:normalColor
                           forKey:NSForegroundColorAttributeName];    
        }
        float     borderWidth = 4.0;
        NSRect boxRect = [self bounds];
        NSRect bgRect = boxRect;
        bgRect = NSInsetRect(boxRect, borderWidth / 2.0, borderWidth / 2.0);
        bgRect = NSIntegralRect(bgRect);
        bgRect.origin.x += 0.5;
        bgRect.origin.y += 0.5;
        
        int minX = NSMinX(bgRect);
        int midX = NSMidX(bgRect);
        int maxX = NSMaxX(bgRect);
        int minY = NSMinY(bgRect);
        int midY = NSMidY(bgRect);
        int maxY = NSMaxY(bgRect);
        float radius = 25.0; 
        NSBezierPath *bgPath = [NSBezierPath bezierPath];
        
        // Bottom edge and bottom-right curve
        [bgPath moveToPoint:NSMakePoint(midX, minY)];
        [bgPath appendBezierPathWithArcFromPoint:NSMakePoint(maxX, minY)
                                         toPoint:NSMakePoint(maxX, midY)
                                          radius:radius];
        
        // Right edge and top-right curve
        [bgPath appendBezierPathWithArcFromPoint:NSMakePoint(maxX, maxY)
                                         toPoint:NSMakePoint(midX, maxY)
                                          radius:radius];
        
        // Top edge and top-left curve
        [bgPath appendBezierPathWithArcFromPoint:NSMakePoint(minX, maxY)
                                         toPoint:NSMakePoint(minX, midY)
                                          radius:radius];
        
        // Left edge and bottom-left curve
        [bgPath appendBezierPathWithArcFromPoint:bgRect.origin
                                         toPoint:NSMakePoint(midX, minY)
                                          radius:radius];
        [bgPath closePath];
        
        // [bgPath fill];
        [bgColor set];

        
        [bgPath setLineWidth:borderWidth];
        
        CGFloat arr[2];
        arr[0] = 5.0;
        arr[1] = 2.0;
        
        [bgPath setLineDash:arr count:2 phase:0.0];
        [bgPath setLineCapStyle:NSLineCapStyleRound];
        [bgPath stroke];
        [self drawStringCenteredIn:[self bounds]];
    }
    else {
        NSRect viewSize = [self bounds];
        NSSize imageSize = [scaledImage size];
        NSRect imageRect = NSMakeRect(0, 0, imageSize.width, imageSize.height);
        NSPoint orig;
        orig.x = (viewSize.size.width - imageSize.width) / 2;
        orig.y = (viewSize.size.height - imageSize.height) / 2;
        
        [scaledImage drawAtPoint:orig fromRect:imageRect operation:NSCompositingOperationSourceOver fraction:1.0];
    }
    
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    if (sender.draggingSource == self) return NSDragOperationNone;
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *files = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL canRead = files.count == 1 || (files.count == 0 && [pasteboard canReadObjectForClasses:@[NSImage.class] options:@{}]);
    highlighted = canRead;
    [self setNeedsDisplay:YES];
    return canRead ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    highlighted = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *files = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (files.count == 1) {
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:files.firstObject];
        if (!image) return NO;
        self.coverImageFilename = files.firstObject.path;
    } else {
        NSArray<NSImage *> *images = [pasteboard readObjectsForClasses:@[NSImage.class] options:@{}];
        if (images.count == 0) return NO;
        [self resetImage];
        self.coverImage = images.firstObject;
    }
    return YES;
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
    highlighted = NO;
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent*)event_ {
    BOOL isDeleteKey = FALSE;
    
    NSString *eventCharacters = [event_ characters];        
    if ([eventCharacters length]) {
        switch ([eventCharacters characterAtIndex:0]) {
            case NSDeleteFunctionKey:
            case NSDeleteCharFunctionKey:
            case NSDeleteCharacter:                                
                isDeleteKey = YES;
                break;
            default:
                break;
        }
    }
    
    if (isDeleteKey) {
        [self resetImage];
        [self setNeedsDisplay:YES];
    } else {
        [super keyDown:event_];
    }
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

@end
