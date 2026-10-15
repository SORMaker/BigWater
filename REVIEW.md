# Big Water 代码审查

- **审查范围**：`main` @ `329e5e9`（0.3.0，“Add pixel drink confirmations and customizable saved reminder routines”），覆盖全部源码、测试、脚本与文档
- **审查日期**：2026-10-15
- **审查方式**：逐文件阅读 + 运行项目自带检查 + 针对可疑点编写的临时探针程序（探针放在会话临时目录，未提交）

## 结论

计时核心（`ReminderSchedule`）设计扎实：使用持续单调时钟，每次检查只读取一次时间，状态整体保存，边界情况的测试也很密集。这次审查**没有在计时规则里发现错误**。

问题主要集中在三方面：持久化的前向兼容性、覆盖层窗口的交互和性能、少数异常环境下的健壮性。其中有一个高优先级问题：**存储格式一旦变化，本机的全部喝水记录会被静默清空**，建议在下一次修改任何 `Codable` 模型之前修复。

| 级别 | 数量 | 编号 |
| --- | --- | --- |
| 高 | 1 | H1 |
| 中 | 5 | M1–M5 |
| 低 / 细节 | 9 | L1–L9 |
| 测试与工程 | 4 | T1–T4 |
| 需实机确认 | 3 | V1–V3 |

## 已运行的验证

| 项目 | 结果 |
| --- | --- |
| `swift build`（独立 scratch 目录，未写入仓库） | 成功，0 个警告 |
| `BigWaterChecks` | 25/25 通过 |
| 会话检查（与 `Tools/check-session.sh` 等价的编译命令） | 16/16 通过 |
| 探针 P1：缺少字段或出现未知枚举值时解码 `AppPreferences` | 两种情况都抛出错误，见 H1 |
| 探针 P1′：模拟存储格式不匹配后启动保存一次 | 保存前有 5 条记录，保存后为 0，见 H1 |
| 探针 P2：到期但未能弹出提醒时 `nextCheckAt − now` | `0.0s`，见 M1 |
| 探针 P3：剩余 10 分钟时把间隔 +0.5h，再 −0.5h | 剩余时间变为 9000s，再变为 7200s，见 L1 |
| 探针 P4：提醒阶段角色位置的变化幅度，以及每帧的点击窗口数 | x 方向约 11.7pt，y 方向 6pt；Claude 每帧 14–15 个窗口，水滴 11 个，见 M2、M3 |
| 探针 P5：一年的喝水记录（每天 8 次） | 2920 条，约 29 KB JSON，见 L2 |

---

## 高

### H1. 存储格式不兼容时，全部状态（包括喝水记录）被静默清空

> **已修复**（分支 `fix-h1-storage-decode`）：设置、外观、作息和记录改为宽松解码，缺失、类型不符或未知的值回退到默认值，记录里读不出的单条会被跳过；三个部分各自独立解码；任何无法原样写回的存档，会在下一次保存前另存为 `appStateV1.unreadable.<时间>`。新增 3 项核心检查（含 0.3.0 真实存档样本）和 2 项会话检查，修复前失败、修复后通过：核心 28/28，会话 18/18。原复现探针：5 条记录 → 5 条（修复前为 0 条）。

- **位置**：[AppStorage.swift:36-39](Sources/BigWater/AppStorage.swift#L36)、[AppDelegate.swift:52-53](Sources/BigWater/AppDelegate.swift#L52)、[AppDelegate.swift:234](Sources/BigWater/AppDelegate.swift#L234)
- **现象**：`load()` 用 `try? JSONDecoder().decode(State.self, …)` 解码。Swift 自动合成的 `Codable` 要求每个键都存在，属性的默认值（例如 `soundEnabled: Bool = false`）**不会**用来补缺失的键；遇到未知的枚举值也会直接失败。只要解码失败，`loadHistory()` 就返回空记录。随后启动流程中的 `checkReminder()` 会无条件调用 `persistProgress()`，用空记录覆盖 `appStateV1`。
- **触发条件**：
  1. 以后给 `AppPreferences`、`ReminderSnapshot` 或 `HydrationHistory` 新增一个非可选字段，老用户升级后第一次启动；
  2. 用新版本存入了新的枚举值（例如新增配色 `ocean`），之后回退到旧版本。
- **证据**：探针 P1、P1′。保存 5 条记录后删掉一个字段，重新加载得到 0 条；模拟启动保存一次后，存储里的记录也变成 0 条。
- **影响**：用户“只保存在本机”的喝水记录永久丢失，而且没有任何提示。键名 `appStateV1` 说明作者预期以后要升级格式，但目前没有迁移路径。
- **建议**：
  - 为这些模型手写 `init(from:)`，用 `decodeIfPresent` 加默认值；枚举解码失败时回退到默认值；
  - 解码失败时**不要覆盖**原数据，先把原始数据另存一份（例如 `appStateV1.unreadable.<时间戳>`），再写入新状态；
  - 至少让 `history` 能独立于 `preferences` 和 `progress` 解码，一部分损坏不影响其他部分；
  - 增加一个“旧格式样本 → 新代码”的兼容性测试（见 T4）。

---

## 中

### M1. 提醒到期但覆盖层无法启动时，以 10 Hz 忙等并反复写入 UserDefaults

> **已修复**（分支 `fix-m1-m4-overlay`）：仍处于到期状态说明没能弹出提醒，此时改为 30 秒后重试；退场动画结束时覆盖层回调 `onFinished`，立即重新检查，下一次提醒不必等待重试。会话检查覆盖“到期时上一个退场动画仍在播放”的场景。

- **位置**：[AppDelegate.swift:198-202](Sources/BigWater/AppDelegate.swift#L198)、[AppDelegate.swift:247-248](Sources/BigWater/AppDelegate.swift#L247)、[OverlayController.swift:36](Sources/BigWater/OverlayController.swift#L36)、[OverlayController.swift:321-323](Sources/BigWater/OverlayController.swift#L321)
- **现象**：`overlay.start()` 在 `preferredScreen()` 返回 nil 时会失败，此时 `presentReminder` 直接返回，`schedule` 仍处于到期状态。到期状态下 `nextCheckAt` 等于当前时间（探针 P2），于是定时器按 `max(…, 0.1)` 每 0.1 秒触发一次 `checkReminder()`，而每次都会执行 `persistProgress()`，整块写入状态。
- **触发条件**：`NSScreen.screens` 为空，或 `NSScreen.main` 为 nil，但 `isScreenAwake` 仍为 true。例如无显示器的 Mac mini、合盖后拔掉外接显示器但被 caffeinate 等工具保持唤醒、显示器重新配置的过程中。预览被挂起时恰好到期，也会走到同一条路径。
- **建议**：把“没有可用屏幕”算进 `canPresentReminder`；`start()` 失败后退避重试，例如等 `didChangeScreenParametersNotification` 或 30 秒后再试；`persistProgress()` 只在状态确实变化时写入。

### M2. 动画模式的按钮跟着角色持续晃动（约 12×6pt），点击可能落空

> **已修复**：按钮锚定在固定的 `scene.target`，位置不再逐帧变化，未变化时也不再调用 `setFrame`。会话检查在真实动画中确认，一个扔水周期内按钮位置完全不变。

- **位置**：[OverlayControls.swift:26-30](Sources/BigWater/OverlayControls.swift#L26)、[ReminderScene.swift:70-74](Sources/BigWaterCore/ReminderScene.swift#L70)、[OverlayControls.swift:198-203](Sources/BigWater/OverlayControls.swift#L198)
- **现象**：按钮的位置由 `scene.characterPosition` 计算，而角色在提醒阶段有正弦摆动和扔水后坐力，按钮每帧（30fps）都随之移动。探针 P4 测得水平移动约 11.7pt，垂直约 6pt。`mouseUp` 用“按钮当前位置”判断光标是否仍在按钮内，如果按下和松开之间窗口移动了，在按钮边缘附近点击会被静默忽略。光标不动时，按钮也会在其下方移进移出，悬停状态随之闪烁。
- **建议**：按钮锚定在固定的 `scene.target`，不跟随动画偏移；只在位置真的变化时才调用 `setFrame`。

### M3. 动画提醒期间每秒 30 次全屏重绘，并移动约 18 个窗口

> **已修复**：动画帧只重绘上一帧和本帧各元素（绳子、角色、气泡、每个水瓶和水花）所在的矩形，覆盖范围由 `SceneRenderer.paintedRegions` 计算，并用逐像素渲染检查保证不漏画；位置没变的点击窗口和按钮窗口跳过 `setFrame`。按 1440×900 屏幕测算，每帧重绘面积从 100% 降到约 10%（Claude）和 7%（水滴）。**未做**：长时间无人点击时降低帧率，这次也没有实测 CPU 和功耗。

- **位置**：[OverlayController.swift:176-196](Sources/BigWater/OverlayController.swift#L176)、[OverlayController.swift:235-236](Sources/BigWater/OverlayController.swift#L235)、[OverlayController.swift:261](Sources/BigWater/OverlayController.swift#L261)、[OverlayController.swift:294](Sources/BigWater/OverlayController.swift#L294)
- **现象**：每帧执行 `canvas.needsDisplay = true`，整块与屏幕同尺寸的画布都要重绘；同时对 14–15 个角色点击窗口（探针 P4）和 3 个按钮窗口逐一 `setFrame`，按钮窗口还带 `display: true`。提醒在用户点击之前不会消失，人离开但屏幕常亮时（例如关闭了自动熄屏），这个开销会一直持续。这里没有实测 CPU 和功耗。
- **建议**：只重绘角色、水瓶和水花外接矩形的并集（`setNeedsDisplay(_:)`）；帧之间矩形没变就跳过 `setFrame`；提醒持续几分钟后降低帧率；或者改用 CALayer 绘制精灵，并设置 `magnificationFilter = .nearest`。

### M4. 轻量卡片和对话气泡看得见但点不到，点击会穿透到下面的应用

> **已修复**：轻量卡片主体和提醒阶段的对话气泡下方新增吞掉点击的输入面板，区域与实际绘制的像素一致（逐像素检查），面板被画面完全覆盖、看不见。README 已同步说明。

- **位置**：[OverlayController.swift:43](Sources/BigWater/OverlayController.swift#L43)、[OverlayController.swift:221-228](Sources/BigWater/OverlayController.swift#L221)
- **现象**：画布窗口设置了 `ignoresMouseEvents = true`。轻量模式下只有三个按钮有输入窗口，卡片本身（标题、图标、说明文字）没有。用户点卡片时，点击会落到它下面的应用：可能把光标放进编辑器、点中链接或者选中文件。动画模式的“WATER TIME”气泡也是这样。README 写的是“透明区域允许鼠标穿透”，但卡片和气泡都不透明。
- **建议**：为卡片（以及气泡）的区域加一个吞掉点击的输入面板，做法和按钮面板相同；至少在 README 里说明这个行为。

### M5. 屏幕和会话状态只靠通知维护，漏掉一次通知就会长期错位（风险，未实测）

> **已修复**（分支 `fix-m5-low-items`）：系统唤醒、会话恢复、亮屏和显示器变化时，都会重新读取真实的会话与显示器状态（`AppDelegate.SystemState`，测试中可注入）。会话检查模拟了“漏掉熄屏通知”和“漏掉亮屏通知”两种情况；换回只依赖通知的旧写法时检查失败。真实物理休眠仍未实测。

- **位置**：[AppDelegate.swift:54-58](Sources/BigWater/AppDelegate.swift#L54)（只在启动时查询一次）、[AppDelegate.swift:309-332](Sources/BigWater/AppDelegate.swift#L309)
- **现象**：`isScreenAwake` 和 `isSessionActive` 只在启动时实际查询一次，之后完全靠通知切换。可能出现两种情况：
  - 某次系统休眠前没有收到 `screensDidSleep`，唤醒时屏幕仍黑着，App 已经开始计时，甚至在黑屏上弹出提醒；
  - 在其他用户的会话里错过了 `screensDidWake`，回来后一直显示“休眠暂停”，直到下一次熄屏再亮屏才恢复。
- **背景**：VERIFICATION.md 已注明“真实物理休眠/唤醒本次未执行”，现有会话检查只验证了通知按预期顺序到达的情况。
- **建议**：在 `didWake`、`sessionDidBecomeActive`、`screensDidWake` 时，或者干脆在每次 `checkReminder()` 时，用 `CGDisplayIsAsleep` 和 `CGSessionCopyCurrentDictionary` 重新查询真实状态，不依赖通知的历史顺序。

---

## 低 / 细节

### L1. 调整提醒间隔会丢弃已累计的进度

> **已修复**：修改间隔时保留已计入的使用时间，“+ 再 −”不再清零；新间隔短于已用时间时立即到期。原测试的期望已按新规则更新。

- **位置**：[ReminderSchedule.swift:191-199](Sources/BigWaterCore/ReminderSchedule.swift#L191)、[AppDelegate.swift:137-139](Sources/BigWater/AppDelegate.swift#L137)
- **证据**：探针 P3。剩余 10 分钟时点一次 +，剩余变为 2.5 小时；再点一次 −，剩余变为 2 小时。间隔最后没变，进度却清零了。
- **说明**：测试 `invalidPreferencesAndIntervalChange` 断言了“空闲时修改间隔会重置”，所以这是有意的设计。但“+ 再 −”也会清零，很可能出乎用户意料。
- **建议**：改成保留已用时间，`remaining = max(0, 新间隔 − 已用时间)`；或者在界面上说明“修改间隔会重新开始计时”。

### L2. 喝水记录无限增长，并且每 30 秒整块重写

> **已修复**：只保留最近 90 天的记录（`HydrationHistory.retentionDays`），新记录按顺序插入，不再整体排序。

- **位置**：[HydrationHistory.swift:11-14](Sources/BigWaterCore/HydrationHistory.swift#L11)、[AppDelegate.swift:238-241](Sources/BigWater/AppDelegate.swift#L238)
- **现象**：记录从不清理，每次新增都对整个数组重新排序；计时期间每 30 秒的检查点都会把全部记录重新编码写入。探针 P5：一年约 2900 条、29 KB。界面只显示当天的记录。
- **建议**：只保留最近 N 天，或者旧数据按天汇总；新记录按顺序插入，不再整体排序；配合 M1，只在内容变化时写入。

### L3. 水滴角色也会做 Claude 的扔水后坐动作

> **已修复**：只有 Claude 计算扔水后坐，水滴的水平摆幅从 11.7pt 降到 6pt 以内。

- **位置**：[ReminderScene.swift:70-74](Sources/BigWaterCore/ReminderScene.swift#L70)
- **现象**：后坐偏移只看 `throwCycle`，没有区分角色。水滴并不扔水（`throwBottle` 对水滴直接返回），却每 1.35 秒横向抖一下。探针 P4 测得水滴的水平摆幅和 Claude 一样，都是 11.7pt。
- **建议**：仅在 `appearance.character == .claude` 时计算后坐。

### L4. 预览时对话气泡仍显示“按钮记录喝水”

> **已修复**：场景记录是否为预览，预览时气泡显示“这是预览效果”。

- **位置**：[PixelArt.swift:359](Sources/BigWaterArt/PixelArt.swift#L359)
- **现象**：预览时唯一的按钮是“结束预览”，气泡文案和实际按钮不一致。
- **建议**：`speech(...)` 增加一个 `isPreview` 参数，预览时换成预览文案。

### L5. 周末判定写死为周六、周日

> **已修复**：改用 `calendar.isDateInWeekend`，检查覆盖周五、周六休息的地区。

- **位置**：[ReminderSchedule.swift:295-301](Sources/BigWaterCore/ReminderSchedule.swift#L295)
- **现象**：周末写死为 `weekday == 1 || weekday == 7`，在周五、周六休息的地区判断会出错。
- **建议**：改用 `calendar.isDateInWeekend(date)`。

### L6. 菜单面板里无法处理正在显示的提醒

> **已修复**：等待确认时，面板显示“我刚喝过水 / 10 分钟后 / 20 分钟后”，动作经由屏幕上的提醒执行，退场动画和记录与直接点击一致。

- **位置**：[SettingsView.swift:185-197](Sources/BigWater/SettingsView.swift#L185)、[AppDelegate.swift:292-295](Sources/BigWater/AppDelegate.swift#L292)
- **现象**：等待确认时，面板只提示“喝水后点像素按钮”，本身没有“我刚喝过水”或“稍后提醒”按钮。覆盖层窗口无法成为键盘焦点，只用键盘的用户、VoiceOver 用户，以及提醒出现在另一块屏幕上的用户都不容易操作。
- **建议**：等待确认时，在面板里也放上这三个动作，复用 `acknowledged` 和 `snooze`。

### L7. “预览当前效果”按钮的可用状态可能过期

> **已顺带修复**：M1 新增的 `onFinished` 回调会触发 `checkReminder()`，设置面板随之刷新。

- **位置**：[AppDelegate.swift:278](Sources/BigWater/AppDelegate.swift#L278)、[OverlayController.swift:191-192](Sources/BigWater/OverlayController.swift#L191)
- **现象**：`canPreview` 只在 `updateSettings()` 里刷新。真实提醒的退场动画结束后，`stop()` 不会通知 AppDelegate。如果在角色爬绳的约 2.6 秒内打开面板，预览按钮会一直保持禁用，直到下一次检查点（最长 30 秒）。
- **建议**：给 `OverlayController` 加一个 `onFinished` 回调，结束时刷新设置面板。

### L8. 首次启动就自动注册登录项

> **保留**：README 明确把默认开启登录启动作为个人偏好，这次不改。以后要分发时再改成首次询问。

- **位置**：[AppDelegate.swift:342-345](Sources/BigWater/AppDelegate.swift#L342)
- **说明**：README 已说明这是默认行为，个人使用没有问题。如果以后要分发，静默开启登录项通常需要征得用户同意，建议改成首次启动时询问。

### L9. 死代码与只为测试保留的接口

> **已修复**：删除 `startHour`、`stopHour` 和 `claudeHitRegions(in:)`（测试改用 `characterHitRegions(in:)`）；`timeDate` 改为与 `localTime` 一致的回退写法。`OverlayController.isAwaitingAcknowledgment` 现在也被菜单动作使用，予以保留。

- `ReminderSchedule.startHour` 和 `stopHour`（[ReminderSchedule.swift:9-11](Sources/BigWaterCore/ReminderSchedule.swift#L9)）已经没有任何引用。
- `PixelArt.claudeHitRegions(in:)`（[PixelArt.swift:205](Sources/BigWaterArt/PixelArt.swift#L205)）和 `OverlayController.isAwaitingAcknowledgment` 只有测试在用。
- `SettingsModel.timeDate` 对 `date(bySettingHour:…)` 强制解包（[SettingsView.swift:60-63](Sources/BigWater/SettingsView.swift#L60)），而 `ReminderSchedule.localTime` 对同一个调用有回退处理。建议两处保持一致。

---

## 测试与工程

### T1. 会话检查通过反射读取私有属性，名字一改就直接崩溃

- **位置**：[SessionChecks.swift:20](Tests/BigWaterSessionTests/SessionChecks.swift#L20)
- **现象**：`Mirror(...).first { $0.label == label }!.value as! T` 依赖属性名，任何一次重命名都会让检查程序崩溃，而不是给出清楚的失败信息。
- **建议**：给 AppDelegate 加一个只在测试中使用的状态访问接口，或者把状态逻辑抽到可测试的类型里。

### T2. 会话检查的通过数是写死的，并且遇到第一个失败就停止

- **位置**：[SessionChecks.swift:277](Tests/BigWaterSessionTests/SessionChecks.swift#L277)
- **现象**：`"16/16"` 是固定字符串，增删检查后不会自动更新；所有步骤串成一条长场景，前面一步失败，后面全部不跑。
- **建议**：参照 `BigWaterChecks`，改成计数器加独立用例。

### T3. `check-session.sh` 直接链接 SwiftPM 的中间产物

- **位置**：[check-session.sh:16](Tools/check-session.sh#L16)
- **现象**：脚本依赖 `.build/.../BigWaterCore.build/*.swift.o` 这种内部目录结构，工具链升级就可能失效。
- **建议**：把 `BigWater` 里的业务类拆成一个 library target（例如 `BigWaterApp`），会话检查作为 `Package.swift` 里的普通 executable target 依赖它。

### T4. 缺少几个关键回归测试

- 存储格式兼容：旧格式样本、缺字段、未知枚举（对应 H1）；
- `overlay.start()` 失败时的重试节奏（对应 M1）；
- 按钮在多帧之间的位置稳定性（对应 M2）。

另外，会话检查会在真实桌面上弹出窗口，并且要求屏幕亮着，无法在 CI 或无显示器环境运行，仓库目前也没有 CI。建议至少让 `BigWaterChecks` 能在 CI 中自动运行。

---

## 需实机确认

以下三点从代码看有风险，但这次没有在真实桌面上复现，结论需要实机验证。

### V1. 时间输入框逐键校验，可能导致无法直接输入某些时间

- **位置**：[SettingsView.swift:40-51](Sources/BigWater/SettingsView.swift#L40)、[SettingsView.swift:335-347](Sources/BigWater/SettingsView.swift#L335)
- **疑点**：`.field` 样式的 DatePicker 在输入每一位数字时都可能写回绑定，而 `change()` 会拒绝不合法的中间值，绑定随即回弹。例如把结束时间从 22:00 改成 23:00，输入第一位 “2” 时的中间值 02:00 早于开始时间，会被拒绝，可能导致无法直接键入这个时间。
- **另一个影响**：每个合法的中间值都会触发一次 `setHours`，编辑过程中可能误收起正在显示的提醒，或者重置倒计时。

### V2. 点击面板的陶土色可能在边缘闪现

- **位置**：[OverlayController.swift:431-435](Sources/BigWater/OverlayController.swift#L431)
- **疑点**：点击面板先移动到新位置，画布要到下一帧才重绘，角色每次以 4px 为单位跳动时，边缘可能露出一帧陶土色。水滴配薄荷或海蓝配色时会更显眼。
- **建议**：改用接近透明（但 alpha 不为 0）的填充色，这样仍能接收点击。

### V3. 系统设置里关闭登录项后，开关可能仍显示“开”

- **位置**：[AppDelegate.swift:366-371](Sources/BigWater/AppDelegate.swift#L366)
- **疑点**：如果用户在“系统设置 › 登录项”里关闭了 Big Water，`SMAppService` 很可能报告 `.requiresApproval`。代码把这个状态当作“已开启”，面板开关就会显示为开，同时提示“请允许”。

---

## 审查后用户反馈的问题

### F1. 展开设置分组后，整页内容向侧面偏移

- **位置**：[SettingsView.swift:110-115](Sources/BigWater/SettingsView.swift#L110)
- **原因**：内容宽度写死为 312pt。展开分组使内容超出弹窗高度后，系统显示 15pt 宽的滚动条，可见宽度变为 341pt，而 356pt 宽（含边距）的内容被居中放置，左右各偏约 7.5pt。用户截图中卡片距左边约 14pt、距右边约 29pt，与此吻合。
- **修复**（分支 `fix-m5-low-items`）：内容改为跟随可见宽度（`maxWidth: .infinity`）。用户已在重新构建的 App 中确认，展开分组后不再偏移。

## 做得好的地方

- **计时核心**：纯值类型，可以注入时钟和日历；用 `mach_continuous_time` 计时，不受校时影响；时区、夏令时、跨日、截止时间都有针对性的测试。
- **一次时间观测**：`checkReminder()` 只读取一次时间，状态更新、窗口处理和保存共用这次观测（[AppDelegate.swift:213-217](Sources/BigWater/AppDelegate.swift#L213)），避免了保存过程中跨过截止时间的竞态，并有专门的回归测试。
- **按像素计算点击区域**：只有角色本身的像素接收点击，并且裁剪在当前屏幕内，多屏下不会漏到其他显示器。
- **状态整体保存**：设置、进度和记录作为一个值写入，不会出现一半新一半旧的情况（但见 H1 的副作用）。
- **记录诚实**：VERIFICATION.md 把通知模拟和实机验证分开记录，也写明了哪些验证没有执行。
