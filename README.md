# KShot — 微信风格的 macOS 截图工具

菜单栏常驻的截图小工具，交互对标微信 Mac 版截图：全屏冻结、自动识别窗口、拖拽选区、标注、复制/保存/钉住。

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
| 工具条 | 矩形、椭圆、箭头、画笔、马赛克、文字、撤销、钉在屏幕上、保存、取消、完成 |
| 选项面板 | 选工具后出现：三档粗细/字号 + 8 色 |
| 文字工具 | 在选区内点击输入；点击别处、Esc 或 ⌘⏎ 结束 |
| `⏎` / 双击选区 / ⌘C | 完成，图片复制到剪贴板 |
| `⌘S` | 保存为 PNG |
| `⌘P` | 钉在屏幕上（悬浮图片：拖动移动、滚轮缩放、双击或 Esc 关闭、右键菜单） |
| `⌘Z` | 撤销上一步标注 |
| 右键 | 有选区时回到窗口识别状态；无选区时退出 |
| `Esc` | 退出截图 |

> 如果微信正在运行且占用了 `⌃⌘A`，全局快捷键可能注册失败（启动日志会提示），可先在微信里改掉其截图快捷键。

## 调试参数

```bash
open build/KShot.app --args --shoot      # 启动后立即截图
open build/KShot.app --args --shoot --selftest   # 自动跑完整交互脚本，截图存到 ~/Library/Logs/KShot-selftest/
open build/KShot.app --args --shoot --dump       # 每秒把遮罩渲染到 ~/Library/Logs/KShot-overlay.png
```

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
