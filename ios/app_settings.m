#import "app_settings.h"
#import "settings.h"
// 弱链接[lab]：s2a_fps_cap_reason（runtime/src/fps.c：60 帧降档原因 0 无 / 1 热 / 2 低电量 / 3 A/B 测原帧率段；输入工作台不链原生核，取不到就不写降档副标题）
int s2a_fps_cap_reason(void) __attribute__((weak_import));
#import "vpad.h"
#import "vpad_settings.h"
#import "cpatch_settings.h"
#include "s2a_direct_prompt.h"   // 「换一款游戏」文案（与 launchers/shared/experience.v1.json prompts 逐字一致，中英同屏）
#include <math.h>

void s2a_diag_export(void);
// 弱链接[lab]：s2a_console_mode_set（runtime/src/os.c 接口 v2.15 提供；输入工作台不链原生核，取不到就不切）
void s2a_console_mode_set(int docked) __attribute__((weak_import));
BOOL s2a_diag_is_exporting(void);
@implementation S2ASettingsRuntime
@end
static S2ASettingsRuntime *g_runtime;
void s2a_settings_set_runtime(S2ASettingsRuntime *runtime) { g_runtime = runtime; }

@interface S2ASteppedSlider : UISlider
@end
@implementation S2ASteppedSlider
- (void)accessibilityIncrement { self.value = MIN(self.maximumValue, roundf(self.value) + 1); [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)accessibilityDecrement { self.value = MAX(self.minimumValue, roundf(self.value) - 1); [self sendActionsForControlEvents:UIControlEventValueChanged]; }
@end

@class S2ASettingsController;
@interface S2ASettingsPane : UITableViewController
@property(nonatomic, weak) S2ASettingsController *owner;
@property(nonatomic, copy) NSArray<NSNumber *> *groups;
@end
@interface S2ASettingsController : UIViewController
- (UITableViewCell *)cellForGroup:(NSInteger)group row:(NSInteger)row;
- (void)selectGroup:(NSInteger)group row:(NSInteger)row;
- (void)refresh;
- (NSInteger)rowsForGroup:(NSInteger)group;
@end

static NSArray *toggleKeys(void) {
    return @[@"S2ANS2ProAdapterEnabled", @"S2APhoneGyro", @"S2APhoneHaptics", @"S2ADiagExportOnOpen", @"S2ADevHUD", @"MetalHUDForceEnabled", @"S2AWidescreen", @"S2AFps60", @"S2A.touchHud", @"S2ADockedMode"];
}
static NSArray *toggleTitles(void) {
    return @[@"启用 Switch 2 Pro 手柄", @"手机陀螺仪", @"手机震动", @"下次打开时导出诊断包", @"显示 S2Arm 诊断浮层", @"显示 Metal 性能浮层", @"宽屏", @"60 帧", @"触屏诊断信息", @"主机模式"];
}
static UILabel *textLabel(UIFontTextStyle style) {
    UILabel *label = [UILabel new]; label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES; label.numberOfLines = 0; return label;
}

@implementation S2ASettingsPane
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 60;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.groups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.owner rowsForGroup:self.groups[section].integerValue];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger g = self.groups[section].integerValue;
    if (g == 5) return @S2A_DPROMPT_SWITCH_GAME_TITLE " · " S2A_DPROMPT_SWITCH_GAME_TITLE_EN;
    return @[@"画面", @"操作", @"诊断", @"开发", @"存档"][g];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (self.groups[section].integerValue) {
        case 0: return @"重新启动游戏后生效。游戏运行时，完成设置可选择立刻重启；请先在游戏内保存进度。\n主机模式对应 Switch 连接底座时的模式，关闭时使用掌机模式。实际分辨率和画质由游戏决定；与兼容 / 高性能运行模式分别设置。\n宽屏和 60 帧需资源包支持，开启后可能增加负载和耗电。";
        case 1: return @"未连接手柄时，可使用手机陀螺仪和震动。";
        case 2: return @"包含近期运行日志和诊断信息，不含游戏文件、密钥或存档。\n下次打开或切回游戏时导出，随后自动关闭此选项。";
        case 4: return @"请先在游戏内保存进度，退出并重新打开后管理存档。";
        case 5: return nil;
        default: return @"下次启动生效。\nS2Arm 浮层：显示目标帧率、慢帧比例、图形模式、首次编译、音频状态和包号。\nMetal 性能浮层：显示帧率、GPU 时间和帧间隔曲线。仅供开发设备上手动观察；开启时不使用截图、存帧、自动玩家或满屏判定。";
    }
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    return [self.owner cellForGroup:self.groups[path.section].integerValue row:path.row];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; [self.owner selectGroup:self.groups[path.section].integerValue row:path.row];
}
@end

@implementation S2ASettingsController {
    NSDictionary *_entryGraphics;
    NSInteger _entryMode;
    NSArray<S2ACPatchGroup *> *_patchGroups;
    NSSet<NSString *> *_entryPatches;
    S2ASettingsRuntime *_runtime;
    UIVisualEffectView *_material;
    UIStackView *_columns;
    S2ASettingsPane *_left, *_right;
    BOOL _restarting;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _runtime = g_runtime;
    _entryGraphics = s2a_ios_graphics_snapshot(NSUserDefaults.standardUserDefaults);
    _entryMode = _runtime.nextMode ? _runtime.nextMode() : -1;
    _patchGroups = s2a_cpatch_bundled_groups();
    _entryPatches = S2ACPatchEnabled(_patchGroups, NSUserDefaults.standardUserDefaults);
    self.title = @"设置"; return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _material = [[UIVisualEffectView alloc] initWithEffect:nil]; _material.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_material];
    [NSLayoutConstraint activateConstraints:@[
        [_material.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_material.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_material.topAnchor constraintEqualToAnchor:self.view.topAnchor], [_material.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    _left = [S2ASettingsPane new]; _right = [S2ASettingsPane new]; _left.owner = _right.owner = self;
    for (S2ASettingsPane *pane in @[_left, _right]) { [self addChildViewController:pane]; [pane didMoveToParentViewController:self]; }
    _columns = [[UIStackView alloc] initWithArrangedSubviews:@[_left.view, _right.view]];
    _columns.axis = UILayoutConstraintAxisHorizontal; _columns.distribution = UIStackViewDistributionFillEqually;
    _columns.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_columns];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_columns.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [_columns.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_columns.topAnchor constraintEqualToAnchor:safe.topAnchor], [_columns.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"settings.done";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:NSUserDefaultsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"S2ADiagExportChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMaterial) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateColumns) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self updateMaterial]; [self updateColumns];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self updateColumns]; }
- (void)updateMaterial {
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    _material.effect = solid ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    _material.backgroundColor = solid ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    if (solid) { [appearance configureWithOpaqueBackground]; appearance.backgroundColor = UIColor.systemGroupedBackgroundColor; }
    else { [appearance configureWithTransparentBackground]; appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]; }
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
    [self refresh];
}
- (void)updateColumns {
    BOOL compact = self.view.bounds.size.width < 650 || UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    NSArray *secondary = _runtime.manageSaves ? @[@1, @4, @2, @3] : @[@1, @2, @3];
    if (_runtime.multiGameContainer) secondary = [@[@5] arrayByAddingObjectsFromArray:secondary];   // 多款容器：「换一款游戏」放第二栏最上（找回游戏库的玩家先看到）
    NSArray *groups = compact ? [@[@0] arrayByAddingObjectsFromArray:secondary] : @[@0];
    if (![_left.groups isEqual:groups]) { _left.groups = groups; _right.groups = secondary; _right.view.hidden = compact; [self refresh]; }
}
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    self.navigationItem.rightBarButtonItem.enabled = !_restarting && !s2a_diag_is_exporting();
    // Startup becoming ready while this page is open is not a user mode edit.
    if (_entryMode < 0 && _runtime.nextMode) _entryMode = _runtime.nextMode();
    // Do not replace a UISlider while it is tracking a finger.
    for (UITableViewCell *cell in _left.tableView.visibleCells) {
        if ([cell.contentView viewWithTag:100] && [(UISlider *)[cell.contentView viewWithTag:100] isTracking]) return;
    }
    [_left.tableView reloadData]; [_right.tableView reloadData];
}
- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未完成" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回设置" style:UIAlertActionStyleCancel handler:nil]];
    [self.navigationController.topViewController presentViewController:alert animated:YES completion:nil];
}
- (UITableViewCell *)baseCell:(NSString *)title {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0.75];
    return cell;
}
- (UITableViewCell *)dropdown:(NSString *)title labels:(NSArray *)labels selected:(NSInteger)selected enabled:(BOOL (^)(NSInteger))enabled choose:(void (^)(NSInteger))choose identifier:(NSString *)identifier {
    UITableViewCell *cell = [self baseCell:title]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = selected >= 0 ? labels[selected] : @"未启动游戏";
    config.image = [UIImage systemImageNamed:@"chevron.down"]; config.imagePlacement = NSDirectionalRectEdgeTrailing; config.imagePadding = 6;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.accessibilityLabel = title; button.accessibilityValue = config.title; button.accessibilityIdentifier = identifier;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
        UIAction *action = [UIAction actionWithTitle:labels[i] image:nil identifier:nil handler:^(UIAction *action) { choose(i); }];
        action.state = i == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (!enabled(i)) action.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:action];
    }
    button.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:actions];
    button.showsMenuAsPrimaryAction = YES; button.enabled = selected >= 0;
    [button sizeToFit]; CGRect frame = button.frame; frame.size.height = MAX(44, frame.size.height); button.frame = frame;
    cell.accessoryView = button; return cell;
}
- (UITableViewCell *)sliderCell:(NSDictionary *)option {
    UITableViewCell *cell = [self baseCell:@""]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *values = option[@"values"], *labels = option[@"labels"];
    NSInteger selected = [values indexOfObject:s2a_ios_graphics_snapshot(NSUserDefaults.standardUserDefaults)[option[@"key"]]];
    UILabel *title = textLabel(UIFontTextStyleBody); title.text = option[@"title"];
    UILabel *value = textLabel(UIFontTextStyleBody); value.text = labels[selected]; value.textColor = self.view.tintColor;
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title, value]]; heading.spacing = 12;
    S2ASteppedSlider *slider = [S2ASteppedSlider new]; slider.tag = 100;
    slider.minimumValue = 0; slider.maximumValue = values.count - 1; slider.value = selected;
    slider.accessibilityLabel = option[@"title"]; slider.accessibilityValue = labels[selected];
    slider.accessibilityIdentifier = [@"settings." stringByAppendingString:option[@"key"]];
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *control = (UISlider *)action.sender; NSInteger index = lroundf(control.value); control.value = index;
        value.text = labels[index]; control.accessibilityValue = labels[index];
        [NSUserDefaults.standardUserDefaults setObject:values[index] forKey:option[@"key"]];
    }] forControlEvents:UIControlEventValueChanged];
    [slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *ticks = [UIStackView new]; ticks.distribution = UIStackViewDistributionEqualSpacing;
    for (NSString *label in labels) { UILabel *tick = textLabel(UIFontTextStyleCaption2); tick.text = label; tick.textColor = UIColor.secondaryLabelColor; tick.isAccessibilityElement = NO; [ticks addArrangedSubview:tick]; }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, slider, ticks]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack]; UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor], [stack.topAnchor constraintEqualToAnchor:m.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor]]];
    return cell;
}
- (UITableViewCell *)toggleCell:(NSInteger)index {
    NSString *key = toggleKeys()[index]; UITableViewCell *cell = [self baseCell:toggleTitles()[index]];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *control = [UISwitch new]; id saved = [NSUserDefaults.standardUserDefaults objectForKey:key];
    control.on = saved ? [saved boolValue] : (index == 1 || index == 2 || index == 6 || index == 7);
    control.accessibilityLabel = toggleTitles()[index]; control.accessibilityIdentifier = [@"settings." stringByAppendingString:key];
    // 本款原生 60 帧（运行时判定后记在 S2AFpsNative60，app.m s2a_ios_fps_native60）：开关改不动帧率，显示原因、置灰（11-02 jhz 丝之歌关了照样 60 帧、以为没生效）
    if ([key isEqualToString:@"S2AFps60"] && [NSUserDefaults.standardUserDefaults boolForKey:@"S2AFpsNative60"]) {
        control.on = YES; control.enabled = NO; cell.detailTextLabel.text = @"本款原生 60 帧"; control.accessibilityValue = @"本款原生 60 帧";
        cell.accessoryView = control; return cell; }
    // 包里 60 帧是关的（强信号：逻辑速度红 / 崩溃 / 卡死 / 帧率达不到；11-02 起全引擎默认开，只有强信号才关）：开关显示玩家手动开没开（S2AFps60Manual，缺省关、不跟 S2AFps60 的缺省开），打开时先提示（11-02 总指挥 / jhz 定的文案）；下次启动生效（settings.m）
    // 包里满屏是关的（强信号：满屏画面坏 / 崩溃归因，tools/caps_policy.py）：设置开关改不动，如实显示关、置灰、写原因（不再缺省显示开、按了没用）
    if ([key isEqualToString:@"S2AWidescreen"] && s2a_ios_caps_value("widen") == 0) {
        control.on = NO; control.enabled = NO; cell.detailTextLabel.text = @"本款满屏有已知问题，暂不可开"; control.accessibilityValue = cell.detailTextLabel.text;
        cell.accessoryView = control; return cell; }
    if ([key isEqualToString:@"S2AFps60"] && s2a_ios_caps_value("fps60") == 0) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        control.on = [d boolForKey:@"S2AFps60Manual"]; cell.detailTextLabel.text = @"本款 60 帧有已知问题";
        __weak S2ASettingsController *weakSelf = self;
        [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).on;
            [d setBool:on forKey:@"S2AFps60Manual"];
            if (!on) return;
            [d setBool:YES forKey:@"S2AFps60"];   // 先前关过 60 帧（存着 NO）会压过手动开（settings.m 关的分支在前）
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"60 帧" message:@"此游戏开 60 帧有已知问题，若游戏速度异常请关闭" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf.navigationController.topViewController presentViewController:alert animated:YES completion:nil];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control; return cell; }
    // 60 帧开着、此刻因发热 / 低电量降档（runtime/src/fps.c）：开关仍是玩家选的开，副标题写清楚画面暂时是原生帧率（审计 P1-80）
    if ([key isEqualToString:@"S2AFps60"] && control.on) { int cap = s2a_fps_cap_reason ? s2a_fps_cap_reason() : 0; if (cap == 1 || cap == 2) cell.detailTextLabel.text = cap == 1 ? @"已暂时回到原生帧率（手机发热）" : @"已暂时回到原生帧率（低电量模式）"; }
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
        BOOL enabled = ((UISwitch *)action.sender).on;
        if ([key isEqualToString:@"S2A.touchHud"]) s2a_vpad_set_touch_hud(enabled);
        else [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = control; return cell;
}
- (NSInteger)rowsForGroup:(NSInteger)group {
    if (group == 4 || group == 5) return 1;
    return group == 0 ? 8 + (_patchGroups.count > 0) : [@[@0, @4, @3, @2][group] integerValue];
}
- (UITableViewCell *)cellForGroup:(NSInteger)group row:(NSInteger)row {
    __weak S2ASettingsController *weakSelf = self;
    if (group == 5) {   // 多款容器换游戏：只读说明（中英两段），不可点、不退出进程
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @S2A_DPROMPT_SWITCH_GAME_BODY "\n\n" S2A_DPROMPT_SWITCH_GAME_BODY_EN;
        cell.textLabel.numberOfLines = 0; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityIdentifier = @"settings.switchGame";
        return cell;
    }
    if (group == 4) {
        UITableViewCell *cell = [self baseCell:@"管理存档…"];
        cell.textLabel.textColor = self.view.tintColor; cell.accessibilityIdentifier = @"settings.manageSaves";
        return cell;
    }
    if (group == 0) {
        if (row == 8) {
            UITableViewCell *cell = [self baseCell:@"社区补丁"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.accessibilityIdentifier = @"settings.communityPatches";
            return cell;
        }
        if (row == 7) return [self toggleCell:9];
        if (row >= 5) return [self toggleCell:row + 1];
        if (row == 0) return [self dropdown:@"运行模式" labels:@[@"兼容模式", @"高性能模式"] selected:_runtime.nextMode ? _runtime.nextMode() : -1 enabled:^BOOL(NSInteger mode) {
            S2ASettingsController *owner = weakSelf;
            return owner && owner->_runtime.canSelectMode && owner->_runtime.canSelectMode(mode);
        } choose:^(NSInteger mode) {
            S2ASettingsController *owner = weakSelf;
            if (!owner || !owner->_runtime.selectMode) return;
            if (!owner->_runtime.selectMode(mode)) [owner showError:@"运行模式未保存，请查看诊断日志后重试。"];
            [owner refresh];
        } identifier:@"settings.mode"];
        NSDictionary *option = s2a_ios_graphics_options()[row - 1];
        if (row != 3) return [self sliderCell:option];
        NSArray *values = option[@"values"];
        NSInteger selected = [values indexOfObject:s2a_ios_graphics_snapshot(NSUserDefaults.standardUserDefaults)[option[@"key"]]];
        return [self dropdown:option[@"title"] labels:option[@"labels"] selected:selected enabled:^BOOL(NSInteger index) { return YES; } choose:^(NSInteger index) {
            [NSUserDefaults.standardUserDefaults setObject:values[index] forKey:option[@"key"]]; [weakSelf refresh];
        } identifier:@"settings.filter"];
    }
    if (group == 1 && row == 0) {
        UITableViewCell *cell = [self baseCell:@"触屏布局"]; cell.detailTextLabel.text = s2a_vpad_layout_name();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.accessibilityIdentifier = @"settings.layouts";
        cell.userInteractionEnabled = s2a_vpad_has_layouts(); if (!cell.userInteractionEnabled) cell.textLabel.textColor = UIColor.secondaryLabelColor;
        return cell;
    }
    if (group == 2 && row == 0) { UITableViewCell *cell = [self baseCell:@"导出诊断包"]; cell.textLabel.textColor = self.view.tintColor; cell.accessibilityIdentifier = @"settings.export"; return cell; }
    if (group == 2 && row == 2) return [self toggleCell:8];
    return [self toggleCell:group == 1 ? row - 1 : group == 2 ? 3 : row + 4];
}
- (void)selectGroup:(NSInteger)group row:(NSInteger)row {
    if (group == 0 && row == 8) {
        UIViewController *patches = s2a_cpatch_settings_controller(_patchGroups);
        if (patches) {
            patches.navigationItem.rightBarButtonItem = self.navigationItem.rightBarButtonItem;
            [self.navigationController pushViewController:patches animated:YES];
        }
    } else if (group == 1 && row == 0) {
        UIViewController *layouts = s2a_vpad_layout_controller();
        if (layouts) {
            layouts.navigationItem.rightBarButtonItem = self.navigationItem.rightBarButtonItem;
            [self.navigationController pushViewController:layouts animated:YES];
        }
    } else if (group == 2 && row == 0) s2a_diag_export();
    else if (group == 4 && row == 0) _runtime.manageSaves(self.navigationController.topViewController);
}
- (void)close {
    [self.navigationController dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{ s2a_vpad_set_settings_open(NO); }];
}
- (void)done {
    if (_restarting || s2a_diag_is_exporting() || self.navigationController.topViewController.presentedViewController) return;
    NSInteger mode = _runtime.nextMode ? _runtime.nextMode() : -1;
    // 掌机 / 主机改成运行中直接切（缺口扫描族 2，接口 v2.15）：服务层调 ChangeDockedModeState，按游戏的通知开关发模式消息、点亮分辨率事件；
    //   不再算进「要重启才生效」的画面设置
    BOOL graphicsRestart = NO;
    NSInteger docked = s2a_ios_settings_docked_change(_entryGraphics, s2a_ios_graphics_snapshot(NSUserDefaults.standardUserDefaults), &graphicsRestart);
    if (docked >= 0) {
        if (s2a_console_mode_set) s2a_console_mode_set((int)docked);
        _entryGraphics = [s2a_ios_graphics_snapshot(NSUserDefaults.standardUserDefaults) copy];
    }
    BOOL changed = graphicsRestart ||
        (_entryMode >= 0 && mode != _entryMode) ||
        ![_entryPatches isEqual:S2ACPatchEnabled(_patchGroups, NSUserDefaults.standardUserDefaults)];
    if (!changed) { [self close]; return; }
    BOOL canRestart = _runtime.restart && _runtime.canRestart && _runtime.canRestart();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"画面设置需要重启后生效"
        message:canRestart ? @"是否立刻重启游戏？未保存的进度会丢失，请确认已在游戏内保存进度。" : @"保存的设置将在下次启动游戏时生效。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:canRestart ? @"稍后自行重启" : @"完成" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [self close]; }]];
    if (canRestart) {
        __weak UIAlertController *weakAlert = alert;
        UIAlertAction *restart = [UIAlertAction actionWithTitle:@"立刻重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // An immediate provider rejection must not try to present an error
            // over a confirmation that is still dismissing.
            UIAlertController *confirmation = weakAlert;
            if (confirmation.presentingViewController)
                [confirmation dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{ [self restart]; }];
            else dispatch_async(dispatch_get_main_queue(), ^{ [self restart]; });
        }];
        [alert addAction:restart]; alert.preferredAction = restart;
    }
    [self.navigationController.topViewController presentViewController:alert animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
- (void)restart {
    _restarting = YES; self.navigationItem.rightBarButtonItem.enabled = NO;
    _columns.userInteractionEnabled = NO;
    UIViewController *top = self.navigationController.topViewController;
    NSString *title = top.title; BOOL hiddenBack = top.navigationItem.hidesBackButton;
    UIGestureRecognizer *back = self.navigationController.interactivePopGestureRecognizer;
    BOOL backEnabled = back.enabled; back.enabled = NO;
    top.view.userInteractionEnabled = NO; top.navigationItem.hidesBackButton = YES;
    self.title = top.title = @"正在重启游戏…";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.title);
    _runtime.restart(^(NSString *error) {
        self->_restarting = NO; self->_columns.userInteractionEnabled = YES;
        top.view.userInteractionEnabled = YES; top.navigationItem.hidesBackButton = hiddenBack;
        back.enabled = backEnabled;
        top.title = title;
        self.title = @"设置"; [self refresh];
        if (error) [self showError:error]; else [self close];
    });
}
@end

@interface S2ASettingsNavigation : UINavigationController
@end
@implementation S2ASettingsNavigation
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

void s2a_settings_present(UIViewController *presenter) {
    if (!presenter || presenter.presentedViewController) return;
    s2a_vpad_set_settings_open(YES);
    S2ASettingsNavigation *navigation = [[S2ASettingsNavigation alloc] initWithRootViewController:[S2ASettingsController new]];
    navigation.modalPresentationStyle = UIModalPresentationOverFullScreen; navigation.modalInPresentation = YES;
    navigation.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [presenter presentViewController:navigation animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
