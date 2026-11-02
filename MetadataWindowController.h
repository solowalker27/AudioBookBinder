#import <Cocoa/Cocoa.h>

@interface MetadataWindowController : NSWindowController <NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (copy) void (^onClose)(MetadataWindowController *controller);
@property (readonly) BOOL saving;
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
@end
