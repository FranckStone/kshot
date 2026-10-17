# 第三方版权声明

KShot 自身代码使用根目录的 [MIT License](LICENSE)。以下第三方代码及依赖保留各自的许可证。

## ScrollSnap

- 项目：https://github.com/Brkgng/ScrollSnap
- 许可证：https://github.com/Brkgng/ScrollSnap/blob/main/LICENSE
- 使用位置：`Sources/KShot/VisionOffsetEstimator.swift`，移植并调整了基于 Vision 平移配准与横带多数投票的帧间位移估计算法。

```text
MIT License

Copyright (c) 2025 Berker Gungor

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle 2.10.0

- 项目：https://github.com/sparkle-project/Sparkle
- 许可证：https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE
- 用途：应用内更新，通过 Swift Package Manager 获取二进制框架。

Sparkle 使用 MIT 许可证，并在其 `LICENSE` 中包含所使用组件的版权及许可条款。`build.sh` 将下载产物中的完整许可证原样复制到 `KShot.app/Contents/Resources/Sparkle-LICENSE.txt`；同时保留框架内自带的版权声明。

KShot 的许可证与本文件也会复制到应用的 `Contents/Resources` 目录，随安装包分发。
