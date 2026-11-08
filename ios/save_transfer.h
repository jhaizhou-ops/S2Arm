#pragma once
int s2a_ios_save_management_requested(void);
#ifdef __OBJC__
#import <UIKit/UIKit.h>
UIViewController *s2a_ios_save_manager(void (^start_game)(void));
void s2a_ios_save_present(UIViewController *presenter);
#endif
