# MyTools 工程设计审查

审查日期：2026-09-13。依据当前工作树源码、Xcode 工程和测试；未提交的业务改动未回滚。

## 结论

工程采用单 App Target、单 Test Target、SwiftUI 多平台结构，App 负责组合，Core 提供跨模块能力，Feature 按 Domain/Application/Infrastructure/Presentation 分层。模块边界、本地优先存储、附件生命周期、编译裁剪和 CloudKit 记录级同步设计较成熟。

当前 iOS 产品构建、macOS 产品构建和完整 iOS 测试均已通过。主要长期风险是单 Target 的边界只能靠约定、`AppStore` 责任面较宽、大型 SwiftUI 文件较多，以及若干引用类型使用 `@unchecked Sendable`。

## 证据

- `xcodebuild -list -project MyTools.xcodeproj` 识别 `MyTools`、`MyToolsTests` 和共享 Scheme。
- iOS 26.5 Simulator 产品构建通过，设备为 `A63BC25E-8E4A-4FC7-9CFC-2AE4C551B74F`。
- macOS arm64 产品构建通过：`xcodebuild build -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO`。
- iOS 完整测试通过：`xcodebuild build-for-testing` 与 `xcodebuild test-without-building`，结果为 `TEST EXECUTE SUCCEEDED`。
- 已移除 `SensitiveAccessView.swift` 的 Xcode 工程孤立引用；测试初始化器已与当前 Store API 对齐。

## 优点

- `ToolModule`、`ToolModuleCatalog` 与 `Shared.xcconfig` 明确区分编译、备份和 CloudKit 参与范围。
- `AppStoreDependencies`、Provider 协议、Fake/Stub 和 `VaultPersistenceCoordinator` 提供了可测试边界。
- `SecureStore`、`VaultCrypto`、`AttachmentStore`、`CloudSyncSnapshotBuilder` 和 `CloudKitSyncWorker` 的职责基本清楚。
- Feature 之间没有发现直接持有彼此 Store、View 或具体 Provider 的依赖。

## 风险与建议

| 优先级 | 发现 | 建议 |
| --- | --- | --- |
| P1 | 单 Target 无法在编译期阻止 Feature 越界 | 增加静态依赖检查和至少一个裁剪变体构建；规模继续增长时再考虑 Swift Package。 |
| P2 | `AppStore.swift` 同时编排组合、持久化、备份、同步、删除撤回和缓存清理 | 将删除状态机、备份流程和 CloudKit 快照协调提为 App Composition 内部协作者。 |
| P2 | 多个 Presentation 文件超过 1000 行 | 按独立状态、手势、权限和测试边界渐进拆分。 |
| P2 | `@unchecked Sendable` 出现在 Vault、附件、日志和同步状态周围 | 优先改为 actor、值类型快照或明确串行 I/O，并增加并发测试。 |
| P3 | 未发现 CI 或依赖边界脚本 | 将 iOS/macOS 构建、测试、Xcode 文件归属和跨 Feature 引用检查纳入 CI。 |

## 结论等级

架构成熟度：中上。当前可构建和测试基线已恢复，后续重点应放在自动化门禁和降低组合层复杂度，而不是大规模重写。
