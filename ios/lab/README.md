# F01 真机输入工作台

独立 UIKit App，直接编译生产的 `vpad.m`、`vpad_layout.m`、`vpad_settings.m`、`controller.m`、`pad.c`，以及现有 `diag.m` / `diagzip.m`。没有加载游戏、模拟器地址窗口、Metal 游戏渲染器或商业资源；不绕过正式游戏的启动自检。它用于在设备上操作布局管理、系统文件选择器、触点和前后台路径，不能代替完整游戏验收。

工作台的显示宽度来自自身视口几何；渲染器的 `nxgal_present_frame` 保持可选弱导入。这里没有游戏出图，触屏直通的游戏像素坐标映射仍须在真实游戏中单独验证。

需要完整 Xcode、现有 XcodeGen、Apple 开发签名与已经配对/解锁的 iPad 或 iPhone。指定自己的独立包名，勿覆盖已有游戏或其他测试 App。

```sh
bash ios/lab/build.sh \
  --device '<设备 UDID>' --team-id '<Apple Team ID>' \
  --bundle-id '<独立诊断包名>' --install --launch
```

默认使用 `xcode-select -p`，可传 `--developer-dir`。`--launch` 包含安装刚构建的 App，避免启动设备上的旧副本。默认只使用已有签名资产；只有明确允许 Xcode 在线更新签名时才传 `--allow-provisioning-updates`。构建项目和产物全部在 `build/f01-lab/`；不改游戏出包入口和默认目标。

四指同时长按至少 1.5 秒打开生产的应用内设置，可操作画面偏好、触屏布局和诊断导出。画面设置保存后在下次启动游戏时生效。工作台不启动游戏，运行模式显示“未启动游戏”，也不注册正式 App 的 MetricKit 启动订阅；游戏模式和启动生效需要在完整游戏 App 中验证。

工作台中央显示通过生产 reader 读取的按键位和四轴。`Documents/input-events.jsonl` 追加实际状态变化、布局窗口/安全区和前后台事件；每次启动带独立 run id、单调时钟与 seq。displayTicks 是本工作台显示回调次数，不是游戏上屏帧；工作台关闭手柄录制，不生成伪游戏回放或存档标记。日志和导入方案留在独立沙盒，可用 devicectl 的 appDataContainer 拷回。

可用已有的 iOS 原生 UI 控制工具探索。此次验证使用上游未修改的 Appium WebDriverAgent，通过 pymobiledevice3 的 XCTest 服务启动，仅将服务端口转发到本机回环地址。控件优先按 `vpad.layouts.*`、`vpad.layout.<id>`、`vpad.button.<id>` 定位；坐标仅用已观测的屏幕/控件 frame。系统文件选择器切换后应等待目标控件出现并稳定，再继续操作。不要在没有探索页面的情况下猜导航或编写回归测试。

没有改造 ARTEMIS 的 Android 通道来操作 iOS，也未向它发送设备内容。当前用户的“必须先 ARTEMIS 探索再编写测试”规则仍适用于新增测试代码；本工作台是交互式诊断 App，本轮复用既有 WDA 控制桥，没有新增自动测试用例。

实际验证与未测边界见 [F01 验证记录](../../docs/validation/f01-touch-layout.md)。
