#import <UIKit/UIKit.h>
#import "vpad_layout.h"

@interface S2AVPadSettings : UITableViewController
@property(nonatomic) BOOL embeddedInSettings;
@property(nonatomic, copy) S2AVPadLayout *(^currentLayout)(void);
- (instancetype)initWithStore:(S2AVPadLayoutStore *)store current:(S2AVPadLayout *)layout
                      changed:(void (^)(void))changed closed:(void (^)(void))closed;
@end
