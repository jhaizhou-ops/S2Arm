#import "vpad_data.h"

@implementation S2AVPadData
+ (NSURL *)rootURL {
    static NSURL *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"vpad-data" ofType:nil];
        BOOL isDir = NO;
        if (path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] && isDir)
            root = [NSURL fileURLWithPath:path isDirectory:YES];
    });
    return root;
}
+ (NSURL *)urlForRelativePath:(NSString *)relativePath {
    NSURL *root = [self rootURL];
    if (!root || !relativePath.length || [relativePath containsString:@".."]) return nil;
    NSURL *url = [root URLByAppendingPathComponent:relativePath];
    return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
}
+ (NSData *)dataForRelativePath:(NSString *)relativePath {
    NSURL *url = [self urlForRelativePath:relativePath];
    return url ? [NSData dataWithContentsOfURL:url] : nil;
}
+ (NSDictionary *)jsonForRelativePath:(NSString *)relativePath {
    NSData *data = [self dataForRelativePath:relativePath];
    id doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [doc isKindOfClass:NSDictionary.class] ? doc : nil;
}
@end
