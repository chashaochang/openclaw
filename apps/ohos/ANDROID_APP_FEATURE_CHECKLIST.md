# Android App 功能清单与鸿蒙对齐表

最后更新: 2026-04-28

这份文档放在 `apps/ohos` 里，专门作为 Android App -> HarmonyOS 的功能对齐清单。
以后每次拉取安卓新代码后，先更新这份表，再继续补 `apps/ohos`。

## 状态说明

- `Done`: 鸿蒙端已有可用实现，主流程已对齐。
- `Partial`: 鸿蒙端已有实现，但入口、交互、边界行为或平台覆盖还没完全对齐。
- `Missing`: 安卓端已有明确功能，鸿蒙端还没有。
- `Platform-Limited`: 安卓端能力强依赖 Android 平台，鸿蒙端目前只能做降级或替代实现。

## 每次同步时的更新流程

1. 拉取最新代码后，先检查 `apps/android/app` 下本次改动涉及哪些文件。
2. 对照下面的模块清单，更新“安卓能力”“鸿蒙状态”“下一步动作”。
3. 只在 `apps/ohos` 内实现缺口。
4. 实现后，更新本表的状态。
5. 至少跑一次 `apps/ohos` 的 `assembleApp`。

## 建议优先看的安卓源码

- `apps/android/app/src/main/java/ai/openclaw/app/MainViewModel.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/NodeRuntime.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/SecurePrefs.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/NotificationForwardingPolicy.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/ConnectTabScreen.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/OnboardingFlow.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/PostOnboardingTabs.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/SettingsSheet.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/VoiceTabScreen.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/CanvasScreen.kt`
- `apps/android/app/src/main/java/ai/openclaw/app/ui/chat/*`
- `apps/android/app/src/main/java/ai/openclaw/app/node/*`
- `apps/android/app/src/main/java/ai/openclaw/app/voice/*`

## 功能清单

| 模块 | 安卓现状 | 主要安卓源码 | 鸿蒙状态 | 鸿蒙现状 / 下一步 |
| --- | --- | --- | --- | --- |
| 应用壳层与导航 | Connect / Chat / Voice / Screen / Settings 五个主入口，顶部状态栏，Chat/Screen 首次进入后常驻 | `ui/PostOnboardingTabs.kt`, `ui/RootScreen.kt` | `Partial` | 鸿蒙现为 Connect / Chat / Screen / Settings 四入口，语音入口已并入聊天详情，这是当前产品决策；壳层能力已稳定，但与安卓导航结构存在刻意差异。 |
| 首次引导 Onboarding | 多步引导、权限摘要、连接前检查、按平台显示可选权限项 | `ui/OnboardingFlow.kt` | `Partial` | 鸿蒙已有完整 onboarding 主流程；SMS / Call Log / Default Assistant 等 Android 专属能力未纳入。 |
| 网关连接 | 支持二维码/Setup Code/Manual，局域网发现，TLS，重连刷新，诊断文案 | `ui/ConnectTabScreen.kt`, `ui/GatewayConfigResolver.kt`, `ui/GatewayDiagnostics.kt` | `Partial` | 鸿蒙现已补上 Connect / Onboarding 的首次 TLS 指纹信任提示、证书本地持久化、自签证书连接兜底、错误诊断报告复制和配对失败提示；剩余更多是继续跟安卓做边角提示和连接文案打磨。 |
| 认证与配对状态持久化 | token / bootstrapToken / password 优先级、手动端点持久化、重连复用 | `MainViewModel.kt`, `SecurePrefs.kt`, `NodeRuntime.kt` | `Done` | 当前鸿蒙已按安卓优先级对齐。 |
| 聊天主流程 | 会话列表/详情、session 切换、thinking level、流式回复、tool 状态、abort、refresh | `ui/chat/*`, `ui/ChatSheet.kt`, `chat/*` | `Done` | 鸿蒙聊天主链路已基本和安卓一致。 |
| 聊天附件 | 图片选择、图片压缩/编码、发送前预览、数量限制 | `ui/chat/ChatComposer.kt`, `ui/chat/ChatImageCodec.kt` | `Done` | 鸿蒙已支持图片附件与发送限制。 |
| 语音对话 | 实时转写、分段入队、停止发送、扬声器开关、助手回复 TTS | `ui/VoiceTabScreen.kt`, `voice/TalkModeManager.kt`, `voice/MicCaptureManager.kt` | `Partial` | 鸿蒙已支持录音转写、发送、取消待发、TTS；但入口已改到聊天详情，不再保留安卓式独立 Voice Tab。 |
| 语音唤醒 / Wake Words | Voice Wake 模式、唤醒词同步、语音唤醒后直接发起命令 | `voice/VoiceWakeManager.kt`, `voice/VoiceWakeCommandExtractor.kt`, `VoiceWakeMode.kt`, `WakeWords.kt` | `Partial` | 鸿蒙已补前台 voice wake、唤醒词持久化、网关 `voicewake.get/set/changed` 同步，以及唤醒后直接走现有聊天语音链路；`Always` 目前在 HarmonyOS 上降级为前台模式。 |
| Talk Mode 深度语音链路 | 安卓复用了 TalkModeManager 处理语音指令、回复朗读、网关语音配置 | `voice/TalkModeManager.kt`, `voice/TalkModeGatewayConfig.kt`, `voice/TalkDirectiveParser.kt` | `Partial` | 鸿蒙已补 `talk.config` 的静音超时和 `interruptOnSpeech` 读取、TalkMode prompt 包装、停顿自动发送、回复后自动重听、多轮连续对话、播报时点按麦克风打断并继续收听；剩余缺口主要是安卓那种真正“检测到用户说话就自动打断播报”的更深层 barge-in 行为，以及少量生命周期边角。 |
| Screen / Canvas | 原生 WebView Canvas、默认 Home Scaffold、URL 切换、JS eval、snapshot、A2UI bridge | `ui/CanvasScreen.kt`, `node/CanvasController.kt`, `node/A2UIHandler.kt`, `protocol/OpenClawCanvasA2UIAction.kt` | `Partial` | 鸿蒙 ArkWeb Canvas、A2UI push/reset/trust、snapshot 已有；现已补 `canvas rehydrate` 自动恢复、主帧加载失败 / HTTP 错误 / render exited 的状态展示、reload/restore 入口、target/current URL 调试信息，以及 debug 开关下的 page start/finish/reload/failure 日志。剩余缺口主要是继续核对 Android 是否还有更多 Web 调试钩子或更细的生命周期边角。 |
| 通知监听与通知转发 | listener、quiet hours、allowlist/blocklist、速率限制、session key、应用选择器 | `node/DeviceNotificationListenerService.kt`, `NotificationForwardingPolicy.kt`, `ui/SettingsSheet.kt` | `Partial` | 鸿蒙已补齐通知转发、quiet hours、allow/blocklist、session key、rate limit；还没有安卓那种已安装应用选择器，只提供包名输入和最近通知来源快捷添加。 |
| 相机工具能力 | 拍照、录像、大小限制、回传结果 | `node/CameraHandler.kt`, `node/CameraCaptureManager.kt` | `Done` | 主能力已在鸿蒙侧实现，并补齐了 `deviceId` 请求校验与按目标前后摄选择的基础对齐。 |
| 相机 HUD 反馈 | 拍照/录像中的前台提示浮层、成功/失败状态回显 | `CameraHudState.kt`, `ui/CameraHudOverlay.kt`, `node/CameraHandler.kt` | `Partial` | 鸿蒙已补全局 Camera HUD 浮层、拍照瞬时闪白反馈和拍照/录像成功失败反馈；但由于使用系统 camera picker，拍摄中的前台覆盖感仍弱于安卓自管相机流。 |
| 设备能力总线 | camera / calendar / contacts / location / motion / notifications / photos / system 等 node.invoke 能力 | `node/InvokeDispatcher.kt`, `node/*Handler.kt`, `node/InvokeCommandRegistry.kt` | `Done` | 这些主能力鸿蒙端已有实现。 |
| SMS | 发送短信、查询短信、设置页权限、onboarding 权限项 | `node/SmsHandler.kt`, `node/SmsManager.kt`, `ui/SettingsSheet.kt`, `ui/OnboardingFlow.kt` | `Platform-Limited` | HarmonyOS SDK 虽有短信发送 API，但 `ohos.permission.SEND_MESSAGES` 官方文档标注仅系统应用可申请；短信查询也未见面向普通应用的完整公开能力，当前不适合承诺可用实现。 |
| Call Log | 读取通话记录、设置页权限、onboarding 权限项 | `node/CallLogHandler.kt`, `ui/SettingsSheet.kt`, `ui/OnboardingFlow.kt` | `Platform-Limited` | 当前 HarmonyOS 公开能力更偏受限/特定场景选择器，未看到可替代安卓普通通话记录读取的稳定公开方案。 |
| Default Assistant / Assistant Launch | 支持被系统 Assistant 手势拉起，并把请求直接导向聊天 | `AssistantLaunch.kt`, `MainActivity.kt`, `ui/SettingsSheet.kt` | `Missing` | 鸿蒙暂无对应入口。 |
| 设置页与诊断 | 权限集中管理、gateway refresh、prevent sleep、debug canvas、通知转发配置 | `ui/SettingsSheet.kt` | `Partial` | 鸿蒙设置页主结构已经对齐；Android 上的 Default Assistant、SMS、Call Log、安装应用选择器仍未覆盖。 |

## 当前优先补齐建议

按当前 Android 源码和鸿蒙现状，建议后续优先级如下:

1. `Default Assistant / Assistant Launch`。
2. `Screen / Canvas` 的异常恢复与调试细节继续跟安卓增量对齐。
3. `Camera HUD overlay` 细节打磨。
4. `TalkMode` 最后一段自动语音打断播报与生命周期边角。
5. `Connect` 页继续核 Android 新增的连接边角和错误文案。
6. `SMS / Call Log` 若后续确认可申请权限或存在新公开 API，再重新评估。

## 备注

- 这份表的目标是“功能对齐”，不是强行做完全相同 UI。
- 像“语音入口从底部 tab 挪到聊天详情”这种明确产品决策，可以保留差异，但要保证能力不掉。
- 每次 Android 有新增能力时，先加到这张表，再决定是 `Done`、`Partial`、`Missing` 还是 `Platform-Limited`。
