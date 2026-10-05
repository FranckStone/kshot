<p align="center">
  <img src="docs/icon.png" width="128" alt="KShot 图标">
</p>

<h1 align="center">KShot — macOS 截图工具</h1>

<p align="center">菜单栏常驻的截图小工具：全屏冻结、自动识别窗口、拖拽选区、标注、复制 / 保存 / 钉住。</p>

## 截图

界面上的浮层（工具条、粗细 / 颜色面板、尺寸标签、文字输入框、悬停边框、把手、钉住窗口）均为 macOS 26 的 Liquid Glass 液态玻璃风格，旧系统自动回退为毛玻璃。

鼠标悬停自动识别窗口，玻璃框贴合窗口圆角，左上角显示像素尺寸：

![窗口识别](docs/screenshot-hover.png)

单击选中窗口，出现玻璃把手与工具条：

![选中窗口](docs/screenshot-select.png)

工具条与粗细 / 颜色面板，支持矩形、椭圆、箭头、画笔、马赛克、文字：

![标注](docs/screenshot-annotate.png)

文字标注就地输入，输入框是会随内容伸缩的玻璃面板：

![文字标注](docs/screenshot-text.png)

鼠标在桌面上时整屏轻微压暗，屏幕边缘出现贴合屏幕圆角的玻璃框，提示正处于截图状态：

![整屏悬停](docs/screenshot-fullscreen-hover.png)

整屏选区时工具条水平居中贴近底部：

![整屏截图](docs/screenshot-fullscreen.png)

“钉在屏幕上”把截图变成带玻璃边框的悬浮卡片，可拖动、滚轮缩放、双击关闭：

![钉在屏幕上](docs/screenshot-pin.png)

“长截图”：自己滚动、程序实时拼接，完成后在编辑窗口里继续标注（工具与截图时一致）：

![长截图编辑](docs/screenshot-longshot-editor.png)

拼接结果示例（对 2600pt 高的示例内容滚动拼接，与真值逐像素比对一致，缩放显示）：

![长截图](docs/screenshot-longshot-full.png)

“提取文字”用系统 Vision 做中英文 OCR，结果自动复制到剪贴板，窗口里可以继续编辑；“翻译”在此基础上调用系统 Translation 框架离线翻译，译文显示在下方面板：

![提取文字](docs/screenshot-ocr.png)

## 构建与运行

```bash
./run.sh          # 编译 + 打包成 build/KShot.app + 启动
./build.sh        # 只编译打包
```

要求：macOS 14+、Xcode 命令行工具（Swift 5.9+）。首次启动会请求 **屏幕录制** 权限，
在「系统设置 › 隐私与安全性 › 录屏与系统录音」中勾选 KShot 后重新启动即可。
`build.sh` 会优先用本机的 Apple Development 证书签名，这样重新编译后权限不会失效。

## 使用

| 操作 | 效果 |
| --- | --- |
| `⌃⌘A`（或点菜单栏相机图标 › 截图） | 开始截图，屏幕冻结并压暗 |
| 移动鼠标 | 自动高亮鼠标下的窗口，左上角显示像素尺寸 |
| 单击 | 选中高亮的窗口 |
| 拖拽 | 自由框选 |
| 拖动选区 / 拖动 8 个把手 | 移动 / 调整选区 |
| 方向键（+⇧ 大步） | 微调选区位置 |
| 工具条 | 矩形、椭圆、箭头、画笔、马赛克、文字 ｜ 撤销、钉在屏幕上、长截图、保存 ｜ 提取文字、翻译 ｜ 取消、完成 |
| 选项面板 | 选工具后出现：三档粗细/字号 + 8 色 |
| 文字工具 | 在选区内点击输入；点击别处、Esc 或 ⌘⏎ 结束 |
| `⏎` / 双击选区 / ⌘C | 完成，图片复制到剪贴板 |
| `⌘S` | 保存为 PNG |
| `⌘P` | 钉在屏幕上（悬浮图片：拖动移动、滚轮缩放、双击或 Esc 关闭、右键菜单） |
| `⌘K` | 长截图（滚动截图）：你用触控板或滚轮在选区内正常向下滚动，程序持续抓帧并实时拼接，面板里有实时预览；往回滚不会重复，滚太快会提示往回一点。面板上的“自动滚动”可选（需要“辅助功能”权限）。回车完成后进入图片编辑窗口，可继续标注、提取文字、翻译，再复制或保存 |
| `⌘T` | 提取文字：对选区做中英文 OCR，结果自动复制到剪贴板并弹出可编辑的结果窗口 |
| `⌘L` | 翻译：识别选区文字后用系统翻译译成所选语言（中文译英、其他译中，可在结果窗口切换目标语言；macOS 15+，首次需按系统提示下载语言包） |
| `⌘Z` | 撤销上一步标注 |
| 右键 | 有选区时回到窗口识别状态；无选区时退出 |
| `Esc` | 退出截图 |

> 如果其他应用占用了 `⌃⌘A`，全局快捷键可能注册失败（启动日志会提示），可先在那个应用里改掉对应的快捷键。

## 调试参数

```bash
open build/KShot.app --args --shoot      # 启动后立即截图
open build/KShot.app --args --shoot --selftest   # 自动跑完整交互脚本，截图存到 ~/Library/Logs/KShot-selftest/
open build/KShot.app --args --shoot --dump       # 每秒把遮罩渲染到 ~/Library/Logs/KShot-overlay.png
open build/KShot.app --args --shoot --demo --selftest   # 用绘制的示例桌面代替真实抓屏，生成不含隐私的演示截图
open build/KShot.app --args --shoot --demo --selftest --pause-at 18   # 停在第 18 步并用 ScreenCaptureKit 抓一张真实合成的屏幕（含玻璃效果）
open build/KShot.app --args --shoot --demo --selftest --pin-test      # 最后一步改为“钉住”并抓屏
open build/KShot.app --args --shoot --demo --selftest --ocr-test      # 最后一步改为“提取文字”并抓屏
open build/KShot.app --args --shoot --demo --selftest --translate-test   # 最后一步改为“翻译”并抓屏
open build/KShot.app --args --longshot-demo      # 弹一个可滚动的示例窗口并对它跑完整长截图流程（自动滚动），结果存到 ~/Library/Logs/KShot-selftest/longshot.png
open build/KShot.app --args --longshot-demo --manual   # 同上，但由示例窗口模拟人手滚动（步长不一、会往回滚），验证手动模式
open build/KShot.app --args --stitch-test        # 用合成长图验证拼接算法的像素精度
open build/KShot.app --args --longshot x,y,w,h   # 直接对主屏指定区域（pt，左上原点）启动长截图
```

安装到“应用程序”并开机自启：`./install.sh`（首次从 /Applications 启动时自动注册登录项，可在菜单里关闭）。

日志：`~/Library/Logs/KShot.log`

## 代码结构

- `AppDelegate.swift` 菜单栏图标、全局快捷键、权限
- `HotKey.swift` Carbon 全局快捷键封装
- `ScreenCapturer.swift` ScreenCaptureKit 抓取每块屏幕
- `WindowFinder.swift` 屏幕上窗口列表，用于悬停识别
- `CaptureSession.swift` 一次截图会话，管理多屏遮罩与收尾
- `OverlayWindow.swift` / `OverlayView.swift` 遮罩窗口与全部交互（选区、把手、标注、键鼠）
- `ToolbarView.swift` 工具条与粗细/颜色面板
- `TextEditorView.swift` 文字标注就地编辑器
- `Annotations.swift` 标注模型与渲染
- `Exporter.swift` 裁剪合成、剪贴板、保存
- `PinWindow.swift` 钉在屏幕上的悬浮图片窗口
- `TextRecognizer.swift` / `OCRResultWindow.swift` 文字识别与结果窗口
- `Translator.swift` 基于系统 Translation 框架的翻译器（通过隐藏的 SwiftUI 宿主视图驱动）
- `LongScreenshot.swift` / `RegionStream.swift` / `ImageStitcher.swift` / `VisionOffsetEstimator.swift` 长截图：SCStream 60fps 区域捕获、实时预览面板、可选自动滚动；帧间位移用 Vision 平移配准做 5 横带多数投票（移植自 [ScrollSnap](https://github.com/Brkgng/ScrollSnap)，MIT），再用行签名精修到整像素，自动识别固定顶栏/底栏，支持往回滚
- `ImageEditorWindow.swift` 图片编辑窗口（长截图完成后的标注画布，复用工具条与标注渲染）
- `MenuBarIcon.swift` 菜单栏模板图标
- `DemoScene.swift` 演示模式的示例桌面
- `tools/make-icon.swift` App 图标生成脚本（含多种备选风格）

## 致谢

- 长截图的帧间位移估计（Vision 平移配准 + 横带多数投票）移植自 [ScrollSnap](https://github.com/Brkgng/ScrollSnap)（MIT License）。
