# 我的工具箱

SwiftUI Multiplatform MVP，支持 iOS、iPadOS 和 macOS。

## 打开与运行

1. 使用 Xcode 26 或更高版本打开 `我的工具箱.xcodeproj`。
2. 在 Signing & Capabilities 中选择自己的 Team，并按需修改 Bundle Identifier。
3. 选择 iPhone、iPad 或 My Mac 运行。

首页目前提供个人金融入口，支持银行卡档案的只读浏览、详情和搜索；“我的”页提供管理员入口，管理员可管理银行与卡片。首次进入“我的”页时设置管理员密码；之后可使用密码或 Face ID/Touch ID/设备密码进入管理模式。应用进入后台后会自动锁定管理员会话。

当前工程对应原“个人金融工具”Apple 版本规划的本地 MVP；CloudKit 同步、银行账户/文档/日志和 Python JSON 导入可以作为下一阶段扩展。原目录内容保持不变。

> 卡片数据使用本地 Keychain 保存的 AES-GCM 密钥加密后写入 UserDefaults。示例项目不会上传或记录卡号、CVV 等敏感字段。
