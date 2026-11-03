#import <Cocoa/Cocoa.h>
#import "MP4File.h"

// Chapter lists describe markers, not audio edits: intervals end at the next
// marker, and the last interval runs to the end of the audio.
@interface ChapterList : NSObject
+ (NSArray<MP4Chapter *> *)chaptersFromText:(NSString *)text duration:(uint64_t)duration error:(NSError **)error;
+ (NSArray<MP4Chapter *> *)chaptersFromURL:(NSURL *)url duration:(uint64_t)duration error:(NSError **)error;
+ (void)chooseForWindow:(NSWindow *)window duration:(uint64_t)duration completion:(void (^)(NSArray<MP4Chapter *> *))completion;
+ (void)preview:(NSArray<MP4Chapter *> *)chapters window:(NSWindow *)window importing:(BOOL)importing completion:(void (^)(BOOL))completion;
@end
