# Petal Checklist Widget · 花瓣清单

一个面向 macOS 14 及以上版本的 Widget-first 清单应用。桌面上只使用中号和大号小组件展示卡片与待办；轻量 App 负责编辑、搜索、提醒、导入导出、主题和同步设置，不创建悬浮便签窗口。

## 产品能力

- 在桌面小组件中查看卡片、直接完成待办，并快速打开对应编辑器。
- 混合文字行和待办行，支持排序、删除、搜索、归档、30 天回收站与完成区。
- `⌥⌘N` 快速记录到收集箱；支持自定义或关闭快捷键。
- 单次和每日提醒，默认静音，可稍后提醒。
- 本地优先：SwiftData 是本地真相来源；可选使用 Apple 私人 CloudKit 跨设备同步。
- JSON 备份/完整恢复、Markdown 导出，以及旧 Windows SchemaVersion 1 数据导入。
- 奶油手帐、薄荷清新、樱花粉、天空蓝、极简纸张五套主题。
- 简体中文和英语；无账号、广告、分析 SDK、订阅或开发者内容服务器。

## 当前状态

原 Windows/WPF 客户端源码与旧验证材料已经移除。仓库现在只维护原生 macOS 产品；Windows 兼容代码仅用于把旧数据导入 macOS App。

本地发布门禁已经通过：

- 233 个 Swift Package 测试。
- 118 个 macOS Hosted XCTest。
- 85 个发布、本地化、隐私、辅助功能和上架准备脚本测试。
- UI 测试目标可成功编译。
- Release 性能三轮通过，App 与 Widget 可生成 `arm64` + `x86_64` 通用无签名归档。

尚未宣称完成的项目包括：Apple Developer Program 与生产标识注册、分发签名、真实桌面 Widget/通知/VoiceOver 运行、macOS 14 与 Intel 真机、双 Mac CloudKit、生产 schema、Pages 发布、TestFlight 四周验证和 App Review。

## 开发与验证

需要 macOS、Xcode 27，以及 Swift 6.4 工具链。项目部署目标为 macOS 14.0。

```bash
open apple/PetalChecklist.xcodeproj
zsh apple/scripts/test.sh
zsh apple/scripts/verify-release.sh
```

`test.sh` 运行 Swift Package 测试、Hosted tests，并无签名编译 UI 测试目标。`verify-release.sh` 还会核对本地化、静态支持站、隐私清单、辅助功能、诊断边界、三轮 Release 性能以及通用架构归档；构建证据写入临时目录，不提交到仓库。

发布配置中的 Team ID、支持邮箱和候选 identifiers 在所有者确认前保持未冻结状态。不要把无签名本地归档当作可提交到 App Store 的分发构建。

## 仓库结构

- `apple/PetalChecklist`：SwiftUI macOS App、编辑器、快速记录、设置与本地化资源。
- `apple/PetalWidgets`：WidgetKit 扩展与 App Intents。
- `apple/Packages/PetalKit`：领域模型、SwiftData 持久化、CloudKit 同步、通知、导入导出、设计系统及测试。
- `apple/scripts`：测试、发布门禁、本地化、隐私与上架准备验证。
- `docs/product`、`docs/architecture`：产品需求与技术架构。
- `docs/legal`、`docs/support`、`site`：双语隐私、帮助和静态支持站。
- `docs/release`、`docs/validation`：App Store 文案草案、审核说明和验证矩阵。
- `design/app-icon`：原始五瓣花 App 图标设计。

## 关键文档

- [产品需求](docs/product/petal-checklist-widget-prd.md)
- [架构说明](docs/architecture/petal-checklist-widget-architecture.md)
- [发布验证矩阵](docs/validation/apple-release-checklist.md)
- [上架准备状态](docs/release/release-readiness.md)
- [简体中文帮助](docs/support/faq-zh-Hans.md) / [English Help](docs/support/faq-en.md)
- [简体中文隐私政策](docs/legal/privacy-policy-zh-Hans.md) / [Privacy Policy](docs/legal/privacy-policy-en.md)

## 数据与隐私

用户内容默认保存在 App Group 的本地沙盒。启用同步后，内容复制到用户 Apple 账户的私人 CloudKit 数据库。诊断采用封闭的类型化事件，不接受卡片标题、行文本、路径、用户标识或任意错误消息；导出诊断必须由用户主动触发。

“删除全部数据”会替换本地数据集、清理小组件缓存与 Petal 通知，并在同步可用时跨代扫描私人 CloudKit 区域以发送内容脱敏记录。云端处理是异步的，真实服务行为仍需在生产配置和双机环境中验证。
