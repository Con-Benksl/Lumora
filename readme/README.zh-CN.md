# Lumora

<p align="center">
  <img src="../Lumora/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png" alt="Lumora 应用图标" width="112" />
</p>

<p align="center">
  <strong>把 MacBook 刘海变成 agent、音乐和系统状态的桌面工作层。</strong>
</p>

<p align="center">
  <a href="../README.md">English</a>
</p>

Lumora 会把 MacBook notch 变成一个轻量的桌面控制层。主页集中展示 Mac 性能、音乐播放和 AI coding agent 会话，让这些状态保持可见，但不额外占用一个聊天窗口或播放器窗口。

Lumora（灵屿）是一款本地开发的 macOS 刘海应用，提供中文界面、交互优化和菜单栏避让功能。

## 主要能力

| 模块 | 功能 |
| --- | --- |
| Agent 会话 | 通过本地 hook 监控 Claude Code、Codex、OpenCode、Cursor。 |
| 会话详情 | 展示 prompt、thinking、工具调用、工具结果、审批、问题、完成状态和 token 用量。 |
| 音乐 | 展示封面、来源 App、歌曲信息、进度、播放暂停、上一首/下一首和打开来源 App。 |
| 系统状态 | 展示 CPU、内存、电池、网络概览，并提供可配置的性能详情页。 |
| 设置 | 支持屏幕选择、提示音、agent hooks、快捷键、glow、开机启动和辅助功能入口。 |
| 外观 | 支持 Music 动态配色、macOS 26+ Glass、纯黑 Black 三种 notch 样式。 |

## Agent 支持

Lumora 会把不同 agent 的本地事件整理成统一的会话时间线。

- Claude Code：hook、transcript 解析、状态追踪、中断检测、权限处理、tmux 终端聚焦。
- Codex：hook、transcript 解析、terminal approval 状态、compacting/subagent 事件、完成会话保留。
- OpenCode：事件流接入、实时工具占位、用户输入状态、subagent 追踪、idle/完成状态转换。
- Cursor：会话生命周期、processing/compacting 状态、thought/response 更新、工具调用和会话清理。

## 外观样式

设置页可以切换三种 notch 样式：

- `Music`：播放音乐时使用封面提取的动态颜色。
- `Glass`：在 macOS 26+ 且系统支持时使用 Liquid Glass。
- `Black`：保持展开面板为干净的纯黑样式。

收起状态的小 notch 保持低干扰外观；玻璃效果只作用于展开面板。

## 安装

请从本仓库构建 `Lumora.app`。目前尚未配置公开下载地址。

1. 按下面的说明从源码构建。
2. 将 `Lumora.app` 放入 `Applications`。
3. 从 `Applications` 打开 `Lumora`。

如果 macOS 首次启动时拦截，可以到 `系统设置` -> `隐私与安全性` 中允许 Lumora 运行，然后重新打开。

## 环境要求

- macOS 15.6 或更高版本。
- Glass 外观需要 macOS 26 或更高版本。
- 菜单栏图标自动避让需要 macOS 27 或更高版本。
- 需要安装 Claude Code、Codex、OpenCode 或 Cursor，才能启用对应 agent 集成。
- 菜单栏避让检测、全局快捷键和窗口聚焦需要辅助功能权限。

## 从源码构建

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Debug build
```

```bash
xcodebuild test -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

测试说明见 [docs/testing.md](../docs/testing.md)。Lumora 的版本说明见 [LUMORA_RELEASE_NOTES.md](../LUMORA_RELEASE_NOTES.md)。

## 项目结构

- `Lumora/Core`：设置、几何计算、快捷键、活动优先级和视图状态。
- `Lumora/Services/Hooks`：agent hook 安装和本地 Unix socket 事件接入。
- `Lumora/Services/Session`：transcript 解析、状态监听和会话监控。
- `Lumora/Services/State`：中心化会话状态和工具事件处理。
- `Lumora/Services/Music`：音乐状态、播放控制和封面颜色提取。
- `Lumora/Services/System`：性能采样。
- `Lumora/UI`：notch 外壳、会话列表、聊天详情、音乐、性能和设置界面。

## 致谢

Lumora 按 GPL-3.0 发行。许可证和第三方声明见 [LICENSE](../LICENSE) 与 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
