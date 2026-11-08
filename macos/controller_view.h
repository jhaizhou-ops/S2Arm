#import <AppKit/AppKit.h>

// Selection changes only which frozen binding is displayed, never the mapping.
NSArray<NSString *> *s2a_mac_controller_targets(void);
@interface S2AReadOnlyControllerView : NSView
@property(nonatomic, copy) void (^onSelect)(NSString *);
@property(nonatomic, readonly) NSString *selectedTarget;
- (instancetype)initWithMapping:(NSDictionary *)mapping;
- (void)selectTarget:(NSString *)target;
@end
