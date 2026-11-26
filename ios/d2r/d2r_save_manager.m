// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import "d2r_save_manager.h"
#import "d2r_saves.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *word(NSString *zh, NSString *en) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? zh : en;
}

@interface D2RSaveManager : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic) NSURL *save;
@property(nonatomic, copy) void (^play)(UIViewController *manager);
@property(nonatomic) UILabel *characters;
@property(nonatomic) UIStackView *actions;
@property(nonatomic, weak) UIDocumentPickerViewController *importPicker;
@end

@implementation D2RSaveManager

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:560],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    NSLayoutConstraint *fill = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40];
    fill.priority = UILayoutPriorityDefaultHigh;
    fill.active = YES;
    UILabel *title = [UILabel new];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 0;
    title.text = word(@"暗黑2存档管理", @"Diablo II Save Management");
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    [stack addArrangedSubview:title];

    self.characters = [UILabel new];
    self.characters.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.characters.adjustsFontForContentSizeCategory = YES;
    self.characters.numberOfLines = 0;
    [stack addArrangedSubview:self.characters];
    [self refreshCharacters];

    UILabel *location = [UILabel new];
    location.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    location.adjustsFontForContentSizeCategory = YES;
    location.textColor = UIColor.secondaryLabelColor;
    location.numberOfLines = 0;
    location.text = [word(@"文件 → 我的 iPad → S2Arm", @"Files → On My iPad → S2Arm")
        stringByAppendingFormat:@"\n%@", S2AD2RSaveLocation];
    [stack addArrangedSubview:location];

    self.actions = [UIStackView new];
    self.actions.axis = UILayoutConstraintAxisVertical;
    self.actions.spacing = 10;
    [stack addArrangedSubview:self.actions];
    [self addButton:word(@"导入角色文件夹…", @"Import Character Folder…") action:@selector(importCharacter) primary:NO];
    [self addButton:word(@"导出存档文件夹…", @"Export Save Folder…") action:@selector(exportSave) primary:NO];
    [self addButton:word(@"开始游戏", @"Play") action:@selector(startGame) primary:YES];
}

- (void)addButton:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButtonConfiguration *config = primary ? UIButtonConfiguration.filledButtonConfiguration
                                             : UIButtonConfiguration.grayButtonConfiguration;
    config.title = title;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.actions addArrangedSubview:button];
}

- (void)refreshCharacters {
    NSError *error = nil;
    NSArray<NSString *> *names = S2AD2RCharacterNames(self.save, &error);
    self.characters.text = error ? error.localizedDescription : names.count ?
        [names componentsJoinedByString:@"、"] : word(@"暂无角色", @"No characters");
}

- (void)show:(NSString *)message {
    UIAlertController *notice = [UIAlertController alertControllerWithTitle:word(@"暗黑2存档", @"Diablo II Saves")
                                                                     message:message preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:word(@"好", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:notice animated:YES completion:nil];
}

- (void)startGame {
    if (self.play) self.play(self);
}

- (void)importCharacter {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    self.importPicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)exportSave {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForExportingURLs:@[self.save] asCopy:YES];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (picker != self.importPicker || !urls.count) return;
    NSURL *url = urls[0];
    for (UIButton *button in self.actions.arrangedSubviews) button.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *coordinationError = nil;
        __block NSError *importError = nil;
        __block BOOL added = NO;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *ready) {
            added = S2AD2RImportCharacter(ready, self.save, &importError);
        }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIButton *button in self.actions.arrangedSubviews) button.enabled = YES;
            [self refreshCharacters];
            [self show:added ? word(@"已新增角色。", @"Character added.") :
                (importError ?: coordinationError).localizedDescription ?: word(@"导入失败。", @"Import failed.")];
        });
    });
}
@end

UIViewController *S2AD2RSaveManager(NSURL *save, void (^play)(UIViewController *manager)) {
    D2RSaveManager *controller = [D2RSaveManager new];
    controller.save = save;
    controller.play = play;
    return controller;
}
