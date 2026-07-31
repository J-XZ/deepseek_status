# DeepSeekBalance

纯 Swift 原生 macOS 菜单栏应用，实时显示 DeepSeek API 剩余余额。常驻系统顶部菜单栏，不显示 Dock 图标，无第三方依赖。

## 功能介绍

- 菜单栏同时显示单色 DeepSeek 图标和余额文字（如 `¥110.00`，多币种为 `¥110.00 · $2.50`）
- 点击菜单栏项目弹出窗口，展示总余额、充值余额、赠送余额和最后更新时间
- 状态指示：可用 / 余额不足 / 未配置 / 请求失败
- 支持在界面中把 API Key 保存到 macOS Keychain，或清除后回退到环境变量
- 启动自动刷新、每 5 分钟自动刷新、打开菜单时距上次成功超过 60 秒自动刷新
- 请求失败时保留上一次成功余额，错误信息可选中复制
- 使用 Swift Concurrency（`async/await` + `URLSession`）、SwiftUI `MenuBarExtra`、Security.framework

## 系统要求

- macOS 13 或更高版本
- Xcode 15 或更高版本（本工程在 Xcode 26.6 下验证构建与测试通过）

## Xcode 构建步骤

1. 打开工程：`open DeepSeekBalance.xcodeproj`
2. 选择 `DeepSeekBalance` scheme（已共享）
3. 选择本机 Mac 作为目标，点击 Run，或使用 Cmd+B 构建

也可以使用命令行构建：

```bash
xcodebuild \
  -project DeepSeekBalance.xcodeproj \
  -scheme DeepSeekBalance \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 如何运行

从 Xcode 直接 Run 即可。应用启动后不会出现在 Dock，只在顶部菜单栏显示图标和余额文字。从 Finder 双击 `DeepSeekBalance.app` 也可以运行。

## 配置 API Key 的两种方式

1. **应用界面（推荐）**：点击菜单栏图标，在弹出窗口的 API Key 区域输入密钥并点击「保存」。密钥会写入 macOS Keychain，输入框不会回显已保存的密钥。
2. **环境变量**：在启动应用的终端中先设置环境变量再运行：

```bash
export DEEPSEEK_API_KEY="sk-xxxxxxxx"
open /path/to/DeepSeekBalance.app
```

## 环境变量名称

- `DEEPSEEK_API_KEY`

## 环境变量与 Keychain 的优先级

1. Keychain 中保存的 API Key（最高优先级）
2. 环境变量 `DEEPSEEK_API_KEY`
3. 未配置

点击「清除已保存密钥」只会删除 Keychain 中的值；如果环境变量存在，应用会自动回退到环境变量并刷新余额。

## Finder 启动与 shell 环境变量

macOS 从 Finder 启动 GUI 应用时，通常不会继承终端 shell 中设置的环境变量。因此如果通过 Finder 双击启动，环境变量可能读取不到。推荐通过应用界面把 API Key 保存到 Keychain，这样与启动方式无关。

## 运行测试

```bash
xcodebuild \
  -project DeepSeekBalance.xcodeproj \
  -scheme DeepSeekBalance \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

测试不访问真实 DeepSeek API，也不写入真实 Keychain：网络请求通过自定义 `URLProtocol` 模拟，Keychain 通过内存 Fake 注入。覆盖解析、鉴权头、状态码处理、超时、格式化、密钥优先级、失败保留缓存等场景。

## 如何替换 DeepSeekIcon

菜单栏图标是本地矢量资源，位于：

```text
DeepSeekBalance/Assets.xcassets/DeepSeekIcon.imageset/deepseek_icon.pdf
```

当前是脚本生成的单色鲸鱼占位图标（脚本见 `scripts/generate_deepseek_icon.swift`，可运行 `swift scripts/generate_deepseek_icon.swift` 重新生成）。如需使用官方品牌资源：

1. 将官方图标（PDF/SVG 转换的 PDF，单色轮廓、透明背景）替换 `deepseek_icon.pdf`
2. 保持 Asset 名称为 `DeepSeekIcon`
3. 保持 `template-rendering-intent` 为 `template`（浅色/深色菜单栏自适应）
4. 重新构建

不要使用彩色大图作为菜单栏图标。

## 安全说明

- API Key 只保存在 macOS Keychain，绝不写入 `UserDefaults` 或源码
- 不要在日志、错误信息或界面中打印、展示完整 API Key
- 不要提交、截图或转发包含 API Key 的界面与日志
- 本项目中的环境变量与 Keychain 内容均属于机密信息，请妥善保管
