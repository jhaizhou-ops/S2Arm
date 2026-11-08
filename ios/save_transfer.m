// 弱链接[ios]：S2A_SaveTransfer（C# 存档迁移入口；未链服务层时向用户报错）
// 弱链接[ios]：S2A_SaveTransferFree（释放 C# 存档迁移返回的字符串）
#import "save_transfer.h"
#include "save_gate.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>

extern char *S2A_SaveTransfer(const char *request) __attribute__((weak_import));
extern void S2A_SaveTransferFree(char *response) __attribute__((weak_import));
void s2a_host_shutdown(const char *why);
static NSString *const ManageKey = @"S2ASaveManageOnOpen";

static NSString *data_root(void) {
    const char *configured = getenv("S2A_RYU_DATA");
    NSString *root = configured ? [NSString stringWithUTF8String:configured] :
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"S2A/ryujinx"];
    // Foundation may shorten /private/var back to /var. Resolve an existing
    // ancestor with POSIX realpath, including before the first save is created.
    NSString *ancestor = root;
    NSMutableArray<NSString *> *suffix = [NSMutableArray new];
    while (![NSFileManager.defaultManager fileExistsAtPath:ancestor] && ancestor.length > 1) {
        [suffix insertObject:ancestor.lastPathComponent atIndex:0];
        ancestor = ancestor.stringByDeletingLastPathComponent;
    }
    char *resolved = realpath(ancestor.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *canonical = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    free(resolved);
    for (NSString *part in suffix) canonical = [canonical stringByAppendingPathComponent:part];
    return canonical;
}
static NSString *work_root(void) {
    return [[data_root() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"save-transfer"];
}
// 列不出事务目录时记下原因（审计 P2-9：原先读不到也当「有未完成事务」，恢复再失败时提示说的是事务，玩家无从下手）。
//   仍进存档页、仍先试恢复（服务层能读到就照常恢复）；恢复失败时提示写明是「读不到操作记录目录」及系统原因
static NSString *g_journal_error;
static BOOL recovery_pending(void) {
    g_journal_error = nil;
    if (!data_root()) return YES;
    NSString *directory = [work_root() stringByAppendingPathComponent:@"save-transactions"];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return NO;
    NSError *error = nil;
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
    // Even an unreadable journal directory must enter management, never skip recovery.
    if (error) { g_journal_error = error.localizedDescription ?: @"未知原因"; return YES; }
    for (NSString *entry in entries) if ([entry.pathExtension isEqualToString:@"json"]) return YES;
    return NO;
}
int s2a_ios_save_management_requested(void) {
    @autoreleasepool {
        return [NSUserDefaults.standardUserDefaults boolForKey:ManageKey] || recovery_pending();
    }
}

@interface S2ASaveManager : UIViewController <UIDocumentPickerDelegate>
@property(copy) void (^startGame)(void);
@property(strong) NSDictionary *game;
@property(strong) UILabel *status;
@property(strong) UIButton *importButton, *exportButton, *backupButton, *startButton, *overrideButton;
@property(strong) UIActivityIndicatorView *spinner;
@property(strong) NSDictionary *preview;
@property(copy) NSString *importPath, *backupPath, *temporaryExportPath;
@property(weak) UIDocumentPickerViewController *exportPicker;
@property(copy) NSString *dataRoot, *workRoot;
@property(strong) dispatch_queue_t worker;
@property BOOL busy, hasSave, recoveryOverridden;
@property enum s2a_save_phase phase;
@end

@implementation S2ASaveManager
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style]; label.adjustsFontForContentSizeCategory = YES;
    return label;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES; button.titleLabel.numberOfLines = 0;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    button.configuration = configuration;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.worker = dispatch_queue_create("dev.s2arm.save-transfer", DISPATCH_QUEUE_SERIAL);
    self.phase = s2a_save_next(S2A_SAVE_CHECKING, recovery_pending() ? S2A_SAVE_EV_OPEN_TX : S2A_SAVE_EV_OPEN_NO_TX);
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]]];
    UILabel *title = [self label:@"存档备份与恢复" style:UIFontTextStyleTitle1];
    title.accessibilityTraits |= UIAccessibilityTraitHeader; [stack addArrangedSubview:title];
    [stack addArrangedSubview:[self label:@"游戏尚未启动。可导出存档到“文件”，或导入 Mac / 其他设备的 .s2asave 备份。恢复前会保留当前存档。" style:UIFontTextStyleBody]];
    self.status = [self label:@"正在检查存档…" style:UIFontTextStyleBody]; [stack addArrangedSubview:self.status];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES; [stack addArrangedSubview:self.spinner];
    self.exportButton = [self button:@"导出当前存档…" action:@selector(exportSave)];
    self.importButton = [self button:@"选择备份并检查…" action:@selector(importSave)];
    self.backupButton = [self button:@"导出恢复前备份…" action:@selector(exportBackup)];
    self.startButton = [self button:@"开始游戏" action:@selector(start)];
    // 恢复失败时才出现：单独确认后放开「开始游戏」（审计 P0-1：失败分支不放开，玩家这次安装就再也进不了游戏）
    self.overrideButton = [self button:@"仍要开始游戏…" action:@selector(confirmOverride)];
    for (UIButton *button in @[self.exportButton, self.importButton, self.backupButton, self.startButton, self.overrideButton]) [stack addArrangedSubview:button];
    self.dataRoot = data_root();
    if (!self.dataRoot) {
        self.phase = s2a_save_next(self.phase, S2A_SAVE_EV_NO_ROOT);
        self.status.text = @"无法访问存档位置，这次不能导入或导出存档。可以先关闭后重新打开；也可以「仍要开始游戏…」照常进游戏。";
        [self updateButtons]; return;
    }
    self.workRoot = [[self.dataRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"save-transfer"];
    NSError *error = nil;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"save-identity" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:&error] : nil;
    id game = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![game isKindOfClass:NSDictionary.class] || !S2A_SaveTransfer || !S2A_SaveTransferFree) {
        if (self.phase == S2A_SAVE_CHECKING) { [self blockRecovery:S2A_SAVE_EV_NO_SERVICE reason:@"此安装包缺少存档迁移所需的游戏身份或服务，无法恢复上次中断的存档操作。"]; return; }
        self.status.text = @"此安装包缺少存档迁移所需的游戏身份或服务。请从新版 Mac 启动器重新打包安装。当前存档仍可照常使用。";
        [self updateButtons]; return;
    }
    self.game = game;
    [self request:@{ @"operation": @"recover" } completion:^(NSDictionary *result) {
        self.phase = s2a_save_next(self.phase, S2A_SAVE_EV_RECOVER_OK); [self refresh];
    }];
}
- (void)updateButtons {
    struct s2a_save_buttons b = s2a_save_buttons(self.phase, self.recoveryOverridden, self.game != nil, self.hasSave, self.busy);
    self.importButton.enabled = b.import; self.exportButton.enabled = b.export_;
    self.backupButton.enabled = !self.busy && self.backupPath.length;
    self.startButton.enabled = b.start; self.overrideButton.hidden = !b.override;
    if (self.busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}
// 恢复失败：说清楚数据在哪、怎么拷走，并给「仍要开始游戏」（单独确认）。事务记录原样保留，下次打开照常先试恢复（新版本可能恢复得了）
- (void)blockRecovery:(enum s2a_save_event)event reason:(NSString *)reason {
    self.phase = s2a_save_next(self.phase, event); self.recoveryOverridden = NO; self.preview = nil;
    [self showError:[NSString stringWithFormat:@"%@\n\n先把数据拷走再决定：打开“文件”App →“我的 iPhone”（iPad 为“我的 iPad”）→“%@”，把整个“S2A”文件夹拷到别处；未完成的操作记录在 S2A/save-transfer/save-transactions 里。也可以用 Mac 访达选中这台设备 →“文件”，把这个 App 下的“S2A”拖出来。\n\n拷好后，可以重新打包安装再试，或点“仍要开始游戏…”。", reason, NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"S2Arm"]];
}
- (void)confirmOverride {
    // 读不到存档位置（审计 18:00 P2-14）与恢复失败共用这个确认，但不冒充「有没做完的事务」：各说各的
    BOOL noRoot = self.phase == S2A_SAVE_NO_ROOT;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"仍要开始游戏？" message:noRoot ? @"读不到存档位置：这次不能导入或导出存档，游戏照常启动。" : @"上次没做完的存档导入 / 恢复可能会丢掉，游戏将按存档目录现在的内容启动。建议先按页面上的步骤把“S2A”文件夹拷走。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:noRoot ? @"开始游戏" : @"我已知道可能丢失，开始游戏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; self.recoveryOverridden = YES;
        self.status.text = noRoot ? @"已解除阻止。这次不能导入或导出存档。" : @"已解除阻止。上次中断的操作记录仍保留，下次打开会再试恢复。"; [self updateButtons];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
// 读屏播报分成功 / 出错（审计 P2-12：原先成功也走 showError，读屏把「备份已导出」听成和失败一样的播报）：出错的播报前加「出错：」
- (void)showError:(NSString *)message {
    self.status.text = message; [self updateButtons];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [@"出错：" stringByAppendingString:message]);
}
- (void)showStatus:(NSString *)message {
    self.status.text = message; [self updateButtons];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}
// 成功 / 取消的结果：临时副本清理失败（warning）才算出错
- (void)showResult:(NSString *)message warning:(NSString *)warning {
    if (warning) [self showError:[NSString stringWithFormat:@"%@\n%@", message, warning]];
    else [self showStatus:message];
}
- (NSString *)removeTemporaryFile:(NSString *)path {
    if (!path.length) return nil;
    NSError *error = nil;
    if ([NSFileManager.defaultManager removeItemAtPath:path error:&error] ||
        ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError)) return nil;
    return [NSString stringWithFormat:@"临时副本清理失败，仍占用设备空间。请在“文件”中删除 App 内名为“%@”的临时副本。", path.lastPathComponent];
}
- (NSString *)clearImport {
    NSString *warning = [self removeTemporaryFile:self.importPath];
    if (!warning) self.importPath = nil;
    return warning;
}
- (NSString *)clearExport {
    NSString *warning = [self removeTemporaryFile:self.temporaryExportPath];
    if (!warning) self.temporaryExportPath = nil;
    return warning;
}
- (void)request:(NSDictionary *)operation completion:(void (^)(NSDictionary *))completion {
    // 上一项还没做完：说一声再返回（审计 P2-23：原先静默丢掉，玩家只看到原来那句「正在处理」）。按钮忙时本就禁用，走到这里的是界面外的入口
    if (self.busy) { [self showStatus:@"上一项存档操作还在进行，请等它完成后再试。"]; return; }
    self.busy = YES; self.status.text = @"正在处理存档，请稍候…"; [self updateButtons];
    NSMutableDictionary *request = [operation mutableCopy];
    request[@"game"] = self.game; request[@"dataRoot"] = self.dataRoot; request[@"workRoot"] = self.workRoot;
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
            NSDictionary *response = nil;
            if (json) {
                NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                char *raw = S2A_SaveTransfer(text.UTF8String);
                if (raw) {
                    NSData *bytes = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
                    S2A_SaveTransferFree(raw);
                    if (bytes) response = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                if (![response isKindOfClass:NSDictionary.class] || ![response[@"ok"] boolValue]) {
                    NSString *message = [response[@"error"] isKindOfClass:NSDictionary.class] ? response[@"error"][@"message"] : nil;
                    NSString *cleanup = nil;
                    if ([operation[@"operation"] isEqual:@"inspect"] || [operation[@"operation"] isEqual:@"restore"]) cleanup = [self clearImport];
                    message = message ?: @"存档服务未返回有效结果。请关闭后重新打开 App，保留现有数据。";
                    if (cleanup) message = [NSString stringWithFormat:@"%@\n%@", message, cleanup];
                    // 恢复失败、或还原失败后留下了没做完的事务：不能只把按钮按灰就返回。还原失败但没留事务（已回滚）照常可开始
                    if ([operation[@"operation"] isEqual:@"recover"])
                        [self blockRecovery:S2A_SAVE_EV_RECOVER_FAIL reason:g_journal_error ? [NSString stringWithFormat:@"读不到存档操作记录目录（%@），没法确认上次的导入 / 恢复有没有做完。\n%@", g_journal_error, message] : message];
                    else if ([operation[@"operation"] isEqual:@"restore"] && recovery_pending()) [self blockRecovery:S2A_SAVE_EV_RESTORE_FAIL_TX reason:message];
                    else [self showError:message];
                    return;
                }
                completion(response[@"result"]); [self updateButtons];
            });
        }
    });
}
- (void)refresh {
    [self request:@{ @"operation": @"status" } completion:^(NSDictionary *result) {
        self.hasSave = [result[@"hasSave"] boolValue];
        self.backupPath = [result[@"previousBackup"] isKindOfClass:NSString.class] ? result[@"previousBackup"] : nil;
        self.status.text = self.hasSave ? @"当前存档可以导出。导入会先检查游戏版本、账号归属和文件完整性，再由你确认恢复。" : @"尚无可导出的存档。可以导入备份，或开始游戏创建存档。";
    }];
}
- (void)start {
    if (!s2a_save_buttons(self.phase, self.recoveryOverridden, self.game != nil, self.hasSave, self.busy).start) return;
    // 玩家确认过「仍要开始」就不再先跑恢复（它刚失败过，失败分支不会走到 finishManagement）
    if (self.game && !self.recoveryOverridden) {
        [self request:@{ @"operation": @"recover" } completion:^(NSDictionary *result) {
            (void)result; [self finishManagement];
        }];
    } else [self finishManagement];
}
- (void)finishManagement {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:ManageKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    self.startGame();
}
- (void)presentExport:(NSString *)path {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[[NSURL fileURLWithPath:path]] asCopy:YES];
    picker.directoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    picker.delegate = self; self.exportPicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)exportSave {
    NSString *warning = [self clearExport];
    if (warning) { [self showError:warning]; return; }
    NSString *name = [NSString stringWithFormat:@"%@-%@.s2asave", self.game[@"id"], NSUUID.UUID.UUIDString];
    NSString *path = [[[self.dataRoot stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"save-exports"] stringByAppendingPathComponent:name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]) { [self showError:@"无法创建导出目录，请检查设备剩余空间。"]; return; }
    [self request:@{ @"operation": @"export", @"path": path } completion:^(NSDictionary *result) {
        self.temporaryExportPath = result[@"outputPath"];
        self.status.text = @"备份已生成，请选择保存位置。"; [self presentExport:result[@"outputPath"]];
    }];
}
- (void)exportBackup { if (self.backupPath.length) [self presentExport:self.backupPath]; }
- (void)importSave {
    NSString *warning = [self clearImport];
    if (warning) { [self showError:warning]; return; }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.directoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    picker.allowsMultipleSelection = NO; picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (controller == self.exportPicker) {
        self.exportPicker = nil;
        // A destination chosen inside our export folder becomes the user's file.
        if (self.temporaryExportPath.length &&
            [urls.firstObject.URLByResolvingSymlinksInPath isEqual:[NSURL fileURLWithPath:self.temporaryExportPath].URLByResolvingSymlinksInPath]) self.temporaryExportPath = nil;
        NSString *warning = [self clearExport];
        [self showResult:@"备份已导出。" warning:warning];
        return;
    }
    NSURL *url = urls.firstObject; if (!url || self.busy) return;
    self.busy = YES; self.status.text = @"正在读取所选备份…"; [self updateButtons];
    dispatch_async(self.worker, ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *folder = [self.workRoot stringByAppendingPathComponent:@"imports"];
        NSString *path = [folder stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"s2asave"]];
        NSError *error = nil;
        BOOL copied = [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error] &&
            [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:path] error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.importPath = path;
            if (!copied) {
                NSString *warning = [self clearImport];
                [self showError:warning ? [NSString stringWithFormat:@"无法读取备份，请确认文件已下载且设备空间充足。\n%@", warning] : @"无法读取备份，请确认文件已下载且设备空间充足。"];
                return;
            }
            [self request:@{ @"operation": @"inspect", @"path": path } completion:^(NSDictionary *result) {
                self.preview = result; [self confirmRestore];
            }];
        });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller != self.exportPicker) { self.status.text = @"已取消选择备份。"; return; }
    self.exportPicker = nil;
    NSString *warning = [self clearExport];
    [self showResult:@"已取消导出。" warning:warning];
}
- (void)confirmRestore {
    NSDictionary *manifest = self.preview[@"manifest"];
    NSString *users = [manifest[@"users"][@"ids"] componentsJoinedByString:@"\n"];
    NSString *size = [NSByteCountFormatter stringFromByteCount:[self.preview[@"totalBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    NSString *message = [NSString stringWithFormat:@"%@\n版本：%@\n备份时间：%@\n账号：%@\n%@ 个文件，%@\n\n恢复会替换当前存档，并先保留恢复前备份。备份中的时钟、语言和地区信息不会自动修改本机设置。", manifest[@"game"][@"name"], manifest[@"game"][@"version"], manifest[@"createdAt"], users.length ? users : @"设备存档", self.preview[@"fileCount"], size];
    self.status.text = @"备份检查通过，等待确认。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复这份备份？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        (void)action; self.preview = nil;
        NSString *warning = [self clearImport];
        [self showResult:@"已取消恢复。" warning:warning];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"备份当前存档并恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [self request:@{ @"operation": @"restore", @"path": self.importPath, @"archiveSha256": self.preview[@"archiveSha256"], @"targetFingerprint": self.preview[@"targetFingerprint"] } completion:^(NSDictionary *result) {
            self.preview = nil; self.phase = s2a_save_next(self.phase, S2A_SAVE_EV_RESTORE_OK);
            self.backupPath = [result[@"previousBackup"] isKindOfClass:NSString.class] ? result[@"previousBackup"] : nil;
            self.hasSave = YES;
            NSString *warning = [self clearImport];
            NSString *message = @"存档已恢复。可开始游戏检查进度；恢复前备份已保留（此前无存档时不生成备份）。";
            [self showResult:message warning:warning];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *s2a_ios_save_manager(void (^start_game)(void)) {
    S2ASaveManager *manager = [S2ASaveManager new]; manager.startGame = start_game; return manager;
}
void s2a_ios_save_present(UIViewController *presenter) {
    if (!presenter || presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出游戏后管理存档" message:@"请先在游戏内保存进度。确认后将退出 App；下次打开时进入存档管理。尚未保存的进度会丢失。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回游戏" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"已保存，退出游戏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *item) {
        (void)item; [NSUserDefaults.standardUserDefaults setBool:YES forKey:ManageKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ s2a_host_shutdown("打开存档管理"); });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
