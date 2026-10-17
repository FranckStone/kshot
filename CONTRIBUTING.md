# 参与贡献

欢迎通过 [Issues](https://github.com/FranckStone/kshot/issues) 报告问题、提出建议，或提交 Pull Request。

## 许可与贡献

本项目当前采用 [Apache License 2.0](LICENSE)，允许商业使用。分发时须按协议保留相关版权与来源声明，包括 [NOTICE](NOTICE) 中的 KShot 项目名称、作者和仓库地址。提交贡献时，请确认你有权将贡献按本项目当前许可证提供，并保留第三方代码原有的版权与许可声明。

## 本地开发

运行应用要求 macOS 14+。构建当前源码需要包含 **macOS 27 SDK** 的 Xcode / Command Line Tools（`GlassBackdrop.swift` 使用了该 SDK 的 API）；仅有 Swift 5.9 不够。使用 `xcrun --sdk macosx --show-sdk-version` 检查已选中的 SDK。

```bash
git clone https://github.com/FranckStone/kshot.git
cd kshot
swift test
./build.sh
open build/KShot.app
```

Swift Package Manager 会下载固定版本的 Sparkle。普通构建不需要维护者的证书或更新签名私钥：`build.sh` 在有 Apple Development 证书时使用该证书，否则使用 ad-hoc 签名。首次运行需授予屏幕录制权限；翻译需 macOS 15+，液态玻璃效果需 macOS 26+。

`swift test` 覆盖长截图拼接与帧处理。涉及截图交互的修改，请按 README 的调试参数手动验证，并在 PR 中说明系统 / SDK 版本、复现步骤和验证结果。提交截图前请使用 `--demo` 或确认画面不含个人信息。

## 提交修改

- 尽量让每个 PR 聚焦一个问题，沿用现有 Swift / AppKit 风格。
- 修复问题时说明复现步骤与修改后的行为，涉及算法时补充有意义的回归测试。
- 功能变化请同步更新 README；引入或移植第三方代码时保留其版权与许可证。
- 不要提交 `.env`、令牌、私钥、签名证书、真实截图日志或本地构建产物。

## 独立发布与官网部署

独立发布与官网部署须符合 Apache 2.0 的分发要求，并保留适用的 KShot 来源及第三方声明。`release.sh` 面向官方更新渠道，需要维护者钥匙串中的 Sparkle 私钥。Fork 独立发布时，请使用自己的 bundle identifier、签名密钥、公钥和更新源，并调整 README、`Resources/Info.plist` 与发布脚本中的仓库地址。

`site/` 是官网的 Cloudflare Worker 与静态资源。独立部署前请将 `site/wrangler.jsonc` 中的账户 ID、域名及下载入口改为自己的配置，并通过本机环境提供 Cloudflare 凭据。
