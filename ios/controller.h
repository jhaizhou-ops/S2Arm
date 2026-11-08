#import <UIKit/UIKit.h>
// 以下接口只在主线程调用；触控回调也在主线程。
void s2a_controller_attach(UIView *root, void (^touchEnabled)(BOOL enabled));
void s2a_controller_set_foreground(int foreground);
