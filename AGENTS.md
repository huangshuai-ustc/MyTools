# MyTools 能力目录与开发准则

更新日期：2026-08-31

本文件是 MyTools 的项目级开发准则和可复用能力索引。`README.md` 说明产品行为，源码和测试定义真实契约，本文件负责回答两个问题：项目已经具备什么能力，以及开发新功能时应该先复用什么。

## 强制执行的复用流程

任何新功能、功能扩展或重构开始前，必须执行以下流程：

1. 从需求中列出所需能力，例如附件、认证、OCR、币种、地图、输入、备份或 CloudKit。
2. 先在本文件按中文能力名、英文关键词和类型名检索，再打开对应源码与测试确认真实接口。
3. 已有能力满足需求时直接复用；部分满足时优先向原有职责边界内扩展，不得创建同职责的第二套实现。
4. 业务模块专属规则保留在对应 `Features/<Module>` 内。多个模块都需要的能力放入 `Core`，通过窄协议或值对象提供，不得为了复用让一个 Feature 直接依赖另一个 Feature。
5. 确实不能复用时，先说明现有能力为什么不满足，再新增实现；新实现仍须遵守下文的模块边界。
6. 新增、删除、改名或明显扩展能力时，必须在同一改动中更新本文件的能力说明、入口和测试位置。

本文件是检索入口，不替代源码审查。不得只根据这里的摘要猜测 API、数据格式或线程约束。

## 不可破坏的架构规则

- “我的 > 首页功能”的开关只控制页面、后台刷新和通知；隐藏模块的数据仍参与 CloudKit 同步，但当前加密备份导出/导入按已编译且可见的模块裁剪。这是已确认的产品契约：隐藏模块不参与加密备份（`AppStoreFacadeTests.hiddenModuleIsExcludedFromBackup` 锁定），与 CloudKit 参与范围不同。只有“删除功能数据”的撤回窗口才会临时停止目标模块的 CloudKit 对账。
- `Config/Shared.xcconfig` 的 `MYTOOLS_COMPILED_FEATURES` 是唯一编译清单。未编译模块不得注册、显示、启动服务、导入导出或参与 CloudKit；其本地 Vault 数据必须以不透明载荷原样保留，避免精简版本覆盖或清理数据与附件。
- 模块显隐先读取本地 `UserDefaults`，没有显式本地值时使用编译配置声明的默认值；CloudKit 应用偏好同步优先于编译默认值。`MYTOOLS_DEFAULT_HIDDEN_FEATURES` 只能改变新安装或没有显式设置时的首页初始状态。
- 存储与数据设置中的“删除功能数据”只允许管理员操作。每层确认都必须等待 10 秒，执行后保留 10 秒撤回窗口；`AppStore` 以模块快照恢复目标字段，撤回期不删除附件且从 CloudKit 参与模块中暂时排除目标模块，过期后才删除未被其他模块引用的附件、模块专属缓存和提醒状态，并恢复正常对账。开启 iCloud 时最终删除会同步到其他设备，备份文件不回写。
- 存储与数据设置中的“本地缓存”只允许管理员操作，按功能调用 `ModuleLocalDataCacheClearing` 清理可重新下载的行情图、刷新状态、共享汇率和体彩赛果缓存；不得触碰业务 Vault、附件、提醒或 CloudKit 记录。股票与换汇的汇率缓存是共享资源，清理任一模块时必须同步重置共享内存状态。
- 存储统计必须区分业务档案/附件、CloudKit 同步状态、应用缓存和系统 CloudKit 本地缓存；同步状态、行情/赛果缓存和诊断日志必须设置 `isExcludedFromBackup`，不得把包含业务档案的 `Application Support/MyTools` 根目录标记为排除。系统 CloudKit 缓存只读展示，不由 App 直接删除。
- 同时服务多个业务模块的能力必须归入 `Core` 或 App 组合层；基础能力不得依赖任一业务模块是否开启。
- 业务模块按 `Domain / Application / Infrastructure / Presentation` 组织。领域层保存数据和确定性规则，应用层持有用例与状态，基础设施层访问网络、地图或文件等外部系统，展示层只编排界面交互。
- Feature 之间不直接持有彼此的 Store、View 或具体服务。跨模块通信使用 `AppStore` 组合、共享 Core 能力或窄协议。
- `AppStore` 只负责组合、加载、聚合快照、持久化、备份和同步协调，不接收模块内部 CRUD 或页面状态。
- 行数不是拆分依据。仅在出现独立变化原因、清晰所有权或可独立测试的规则时拆分，优先保证高内聚、低耦合。
- 没有真实历史数据兼容需求时，不添加旧字段、旧格式或迁移分支。存在真实兼容需求时必须用解码或迁移测试锁定。
- 页面不得直接写业务存档或附件目录；通过模块 Store、`SecureStore`、`VaultPersistenceCoordinator` 和 `AttachmentStore` 完成。

## 工程分层

| 目录 | 所有权 |
| --- | --- |
| `MyTools/App/Bootstrap` | App 启动、生产依赖创建、Environment 注入 |
| `MyTools/App/Composition` | 根状态协调、窄协议、备份合并与处理 |
| `MyTools/App/Modules` | 模块注册、能力声明、开关与顺序 |
| `MyTools/App/Navigation` | 根导航、首页和模块目的地 |
| `MyTools/App/Settings` | 全局设置页面和 OCR 临时测试入口 |
| `MyTools/Core` | 跨模块基础能力，不归属任何单一可关闭模块 |
| `MyTools/Features/<Module>/Domain` | 模块实体、值对象、纯业务规则 |
| `MyTools/Features/<Module>/Application` | 模块 Store、用例、状态协调 |
| `MyTools/Features/<Module>/Infrastructure` | 模块专属网络、地图、磁盘 Provider |
| `MyTools/Features/<Module>/Presentation` | SwiftUI 页面和展示模型 |
| `MyToolsTests` | 按 Core、AppStore、Store 和 Feature 组织的回归测试 |

当前仍是一个 App Target 和一个 Test Target，上述边界依靠目录、所有权、接口和测试约束，不是独立 Swift Package。

## 工程结构维护规则

- 本节以 `git ls-files` 为权威范围，逐项说明所有应提交的工程文件；Xcode 的 `xcuserdata`、`*.xcuserstate`、`DerivedData`、`build`、本地签名文件和运行日志不属于工程结构。
- 查找代码时先按下文的“修改场景入口”定位职责，再按文件路径打开源码；类型名和实际接口仍以源码及测试为准。
- 新增、删除、移动或改名文件时，必须在同一改动中更新本节对应目录和文件条目。新增目录时也必须写明所有权，不允许留下无法判断职责的杂项目录。
- `README.md` 的工程结构面向开发者快速导航，本节是完整、权威的逐文件索引；两处职责不能互相矛盾。

### 修改场景入口

| 要修改的内容 | 首选入口 | 通常还要检查 |
| --- | --- | --- |
| App 启动、依赖实例或全局 Environment | `MyTools/App/Bootstrap/` | `AppStoreDependencies.swift`、`ToolBoxApp.swift` |
| 首页模块、开关、顺序或模块编译裁剪 | `ToolModule.swift`、`ToolModuleSettings.swift` | `Config/Shared.xcconfig`、`ToolModuleDestination.swift`、`project.pbxproj` |
| 本地数据字段或持久化 | 对应 Feature 的 `Domain` 与 Store | `VaultData.swift`、`AppStore.swift`、备份、CloudKit、相关测试 |
| 备份导入导出 | `AppStoreBackupProcessor.swift`、`AppStoreBackupMerger.swift` | `VaultBackup.swift`、附件映射、模块开关测试 |
| iCloud 同步 | `Core/CloudSync/` | `VaultData.swift`、模块归属、快照/合并测试 |
| 附件生命周期 | `Core/Attachments/` 与对应 Feature Store | 备份、CloudKit、`StorageUsageService.swift` |
| 管理员权限或敏感内容 | `Core/Authentication/` | 具体页面的新增/编辑/查看入口 |
| OCR | `Core/OCR/` | 对应模块 Parser、确认页面、`OCRTests.swift` |
| 某个业务页面 | `Features/<Module>/Presentation/` | 同模块 `Application` Store 和 `Domain` 规则 |
| 业务规则或计算 | `Features/<Module>/Domain/` | 同模块 Store、展示模型和回归测试 |
| 外部接口或本地缓存 | 对应 Feature 的 `Infrastructure/` | Application 编排服务、Provider 解析测试 |
| 构建、签名、权限或 Target 文件归属 | `Config/`、Entitlements、`project.pbxproj` | 共享 Scheme、`Info.plist` |

## 完整目录与逐文件定位

下面路径均相对于仓库根目录。每个目录说明其整体所有权，表格说明修改什么行为时应进入哪个文件。

### 仓库根目录、配置、工程与文档

仓库根目录保存工程级规则和发布配置；`Config/` 保存可共享构建配置；`TestFlight/` 保存 Xcode Cloud 上传的本地化测试说明；`MyTools.xcodeproj/` 保存 Xcode Target、文件归属、构建阶段和共享 Scheme；`docs/` 保存对外发布的静态文档。

| 文件 | 职责与定位用途 |
| --- | --- |
| `.gitignore` | 定义 Xcode 用户状态、构建产物、本地签名和日志等不提交内容。 |
| `AGENTS.md` | 项目开发约束、可复用能力和本逐文件定位索引；架构或文件结构变化时更新。 |
| `ARCHITECTURE_REVIEW.md` | 历史架构审查结果与改进记录，用于理解既有技术决策，不作为实时 API 文档。 |
| `README.md` | 产品能力、运行方式、数据与安全边界及开发者快速导航。 |
| `TestFlight/WhatToTest.zh-Hans.txt` | Xcode Cloud 随下一次 TestFlight 构建自动上传的简体中文“测试内容”；每次发布前静态更新。 |
| `Config/Shared.xcconfig` | 全平台公共构建设置、`MYTOOLS_COMPILED_FEATURES` 模块编译清单和可选的 `MYTOOLS_DEFAULT_HIDDEN_FEATURES` 默认隐藏清单。 |
| `Config/Signing.local.xcconfig.example` | 本地签名配置模板；复制出的真实本地配置不提交。 |
| `MyTools.xcodeproj/project.pbxproj` | App/Test Target、源码和资源归属、Build Phases、编译设置及平台配置。 |
| `MyTools.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | Xcode 工程内置 Workspace 的基础引用。 |
| `MyTools.xcodeproj/xcshareddata/xcschemes/MyTools.xcscheme` | 团队共享的 `MyTools` 构建、测试、运行和归档 Scheme。 |
| `docs/privacy.html` | 对外发布的隐私政策网页。 |

### `MyTools/App/Bootstrap/`：启动与生产依赖

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/App/Bootstrap/AppMetadata.swift` | App 名称、版本等元数据和跨页面 `AppStorage` 键。 |
| `MyTools/App/Bootstrap/LiveAppDependencies.swift` | 创建真实持久化、行情、汇率、通知、备份和同步依赖；替换生产实现从这里开始。 |
| `MyTools/App/Bootstrap/ToolBoxApp.swift` | SwiftUI App 入口、平台生命周期、根对象创建和 Environment 注入。 |

### `MyTools/App/Composition/`：根状态与跨模块编排

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/App/Composition/AppStore.swift` | 装配各模块 Store，加载/恢复 Vault，生成聚合快照并协调保存和 CloudKit。 |
| `MyTools/App/Composition/AppStoreAlertEvaluator.swift` | 根据股票行情和汇率快照评估价格提醒是否触发。 |
| `MyTools/App/Composition/AppStoreBackupMerger.swift` | 按模块与记录 ID 执行加密备份的增量数据合并。 |
| `MyTools/App/Composition/AppStoreBackupProcessor.swift` | 按已编译且可见模块裁剪备份、装配及恢复各模块附件；导入同样按当前可见模块过滤。 |
| `MyTools/App/Composition/AppStoreDependencies.swift` | AppStore 使用的窄协议、禁用实现和依赖容器；测试替身也遵循这些协议。 |
| `MyTools/App/Composition/ModuleAttachmentReferenceIndex.swift` | 跨模块附件引用规则索引：按模块枚举附件、按 ID 建索引、汇总引用存储文件名，供备份恢复、冗余清理和存储完整性扫描复用。 |
| `MyTools/App/Composition/ModuleStoreContracts.swift` | 数据变更、模块生命周期、汇率观察和冗余字段清理协议及注册表。 |

### `MyTools/App/Modules/`：模块目录与用户配置

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/App/Modules/ToolModule.swift` | 九个模块的唯一注册源，定义标题、图标、能力、备份/同步参与和编译可用性。 |
| `MyTools/App/Modules/ToolModuleSettings.swift` | 模块显隐与顺序、App 外观和字号偏好的持久状态。 |

### `MyTools/App/Navigation/`：根导航

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/App/Navigation/RootView.swift` | iOS Tab、macOS 分栏、初始加载和“工具/我的”根导航。 |
| `MyTools/App/Navigation/ToolModuleDestination.swift` | 将 `ToolModule` 穷举映射到各业务模块首页。 |
| `MyTools/App/Navigation/ToolboxView.swift` | 工具首页模块网格、模块顺序和入口展示。 |

### `MyTools/App/Settings/Presentation/`：全局设置页面

`MyTools/App/Settings/` 归属 App 级设置，当前只有 `Presentation/`，不持有业务模块领域数据。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/App/Settings/Presentation/AppearanceSettingsView.swift` | 外观、字号以及各股票市场涨跌颜色设置。 |
| `MyTools/App/Settings/Presentation/BackupSettingsView.swift` | 管理员密码修改、备份密码选择和加密备份导入导出表单。 |
| `MyTools/App/Settings/Presentation/CloudSyncSettingsView.swift` | iCloud 同步开关、账户/同步状态、手动同步和管理员云端数据重建入口。 |
| `MyTools/App/Settings/Presentation/DiagnosticsView.swift` | 诊断日志查看、导出和清理界面及日志文档包装。 |
| `MyTools/App/Settings/Presentation/HomeFeatureSettingsView.swift` | 首页模块显隐开关和拖动排序界面。 |
| `MyTools/App/Settings/Presentation/NotificationSettingsView.swift` | 通知权限状态、汇率提醒编辑，以及按 A/港/美股分组的股票价格提醒选择器。 |
| `MyTools/App/Settings/Presentation/OCRTestView.swift` | Core OCR 的临时图片/PDF/相机与区域识别验证入口。 |
| `MyTools/App/Settings/Presentation/ProfileSettingsView.swift` | “设置”列表的二级导航汇总，包括股票外观和账单导出等模块设置入口。 |
| `MyTools/App/Settings/Presentation/ProfileView.swift` | “我的”首页，组织管理员、备份、设置、关于等入口。 |
| `MyTools/App/Settings/Presentation/StorageSettingsView.swift` | 存储占用、附件完整性、孤立文件、模块冗余字段清理和模块数据删除界面。 |

### `MyTools/Core/Attachments/`：通用附件能力

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Attachments/AttachmentEditSession.swift` | 编辑过程中暂存新增/删除附件，并在保存或取消时提交/回滚。 |
| `MyTools/Core/Attachments/AttachmentPresentation.swift` | iOS Quick Look、macOS 系统打开、分享和预览 Sheet。 |
| `MyTools/Core/Attachments/AttachmentStore.swift` | 附件导入、原子保存、读取、改名、删除和备份恢复。 |
| `MyTools/Core/Attachments/FileAttachment.swift` | 通用附件元数据实体和附件类别定义。 |

### `MyTools/Core/Authentication/`：认证、权限和敏感展示

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Authentication/AdminModeViews.swift` | 统一管理员编辑入口、状态指示和 View modifier。 |
| `MyTools/Core/Authentication/AuthManager.swift` | 管理员加盐 PBKDF2 密码摘要（旧无盐 SHA-256 验证后自动迁移）、Keychain、生物识别/设备认证和会话自动锁定。 |
| `MyTools/Core/Authentication/AdminPasswordHash.swift` | 管理员密码加盐 PBKDF2-HMAC-SHA256 摘要、旧格式验证、恒定时间比较和存储格式。 |
| `MyTools/Core/Authentication/AuthenticationView.swift` | 进入管理员模式或执行认证回调的通用表单。 |
| `MyTools/Core/Authentication/ProtectedContent.swift` | 敏感值长按复制手势与跨平台复制提示（`.copyableText(...)`、`CopyToastCenter`）；标签/值遮罩展示行已迁移至 `Core/UI/FormRowComponents.swift` 的 `DetailValueRow`。 |
| `MyTools/Core/Authentication/SensitiveAccessView.swift` | 仅解锁当前敏感详情、不进入管理员编辑模式的验证页。 |

### `MyTools/Core/Backup/`：加密备份格式

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Backup/VaultBackup.swift` | `.mytools` 文件文档、版本化载荷、PBKDF2 密钥派生和 AES-GCM 加解密。 |

### `MyTools/Core/CloudSync/`：CloudKit 增量同步

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/CloudSync/CloudKitSyncWorker.swift` | CKSyncEngine 私有数据库/Zone、上传下载、账户变化、删除记录回收和增量游标执行器。 |
| `MyTools/Core/CloudSync/CloudSyncCoordinator.swift` | 面向 App 的同步生命周期、状态发布、对账和错误协调。 |
| `MyTools/Core/CloudSync/CloudSyncModels.swift` | 同步实体种类、快照编码、模块归属及远端 upsert/delete 合并规则。 |
| `MyTools/Core/CloudSync/CloudSyncPreferences.swift` | 模块顺序/显隐、外观、排序筛选和体彩赛事偏好等 App 设置的 CloudKit 编码和双向桥接。 |
| `MyTools/Core/CloudSync/CloudSyncStateStore.swift` | 同步状态、系统字段和游标的本地磁盘存储。 |

### `MyTools/Core/Currency/`：币种与共享汇率

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Currency/CurrencyCode.swift` | 全 App 统一币种枚举、标题、排序和中国银行名称。 |
| `MyTools/Core/Currency/ExchangeRateRepository.swift` | CNY 基准双报价快照、UserDefaults 缓存和旧缓存升级。 |
| `MyTools/Core/Currency/ExchangeRateStore.swift` | 股票/换汇共用汇率状态、刷新和模块启停生命周期。 |
| `MyTools/Core/Currency/ForeignExchangeRateService.swift` | 获取并解析中国银行现汇买入/卖出牌价。 |

### `MyTools/Core/Diagnostics/`、`Formatting/` 与 `Notifications/`

这些目录分别归属诊断日志、跨模块格式化/输入解析和本地通知投递；具体业务提醒规则仍留在拥有数据的模块。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Diagnostics/DiagnosticLogger.swift` | 分级分类日志、异步缓冲、两日保留、导出、清除和稳定错误码。 |
| `MyTools/Core/Formatting/AppDateFormatting.swift` | 跨页面统一日期与日期时间显示。 |
| `MyTools/Core/Formatting/AppAlphabeticalSort.swift` | 跨模块名称字典序：汉字转无声调拼音后与拉丁字母放入同一排序空间，并提供稳定次级键。 |
| `MyTools/Core/Formatting/DecimalTextParser.swift` | Decimal 与四则运算表达式的统一解析和错误处理。 |
| `MyTools/Core/Notifications/AppNotificationService.swift` | 通知权限、前台展示、即时去重和按前缀整体替换预约通知。 |
| `MyTools/Core/Notifications/NotificationRule.swift` | 股票价格与汇率提醒的方向、阈值和持久化模型。 |

### `MyTools/Core/OCR/`：Vision OCR

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/OCR/OCRCameraPicker.swift` | iOS 相机照片输入的 SwiftUI 包装。 |
| `MyTools/Core/OCR/OCRDocumentLoader.swift` | 图片/PDF 载入、方向修正、分页和最大像素渲染。 |
| `MyTools/Core/OCR/OCRModels.swift` | 语言、识别级别、归一化区域、识别行、结果和错误模型。 |
| `MyTools/Core/OCR/OCRRegionSelector.swift` | aspect-fit 图片上的区域框选和坐标转换 UI。 |
| `MyTools/Core/OCR/OCRService.swift` | `OCRRecognizing` 协议和 Vision 异步识别实现。 |

### `MyTools/Core/Persistence/` 与 `Storage/`：本地数据和存储治理

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/Persistence/SecureStore.swift` | 本地 Vault 载入/原子写入、AES-GCM 静态加密与旧明文档案原地升级、Keychain/受保护数据暂不可用时的延迟重试、禁止明文降级、失败保护和串行合并保存协调器。 |
| `MyTools/Core/Persistence/VaultCrypto.swift` | 本地 Vault 加密信封（格式 2.0）加解密、格式判断、PBKDF2-HMAC-SHA256 派生和系统安全随机字节；派生原语同时供备份加密和管理员密码摘要复用。 |
| `MyTools/Core/Persistence/VaultEncryptionKey.swift` | Vault 加密密钥提供者协议和 Keychain 生产实现；密钥 `WhenUnlockedThisDeviceOnly`，仅本机、不可迁移。 |
| `MyTools/Core/Persistence/VaultData.swift` | 所有已编译模块数据和五个用户标签库的 Codable 聚合根，以及未编译模块不透明 JSON 保留。 |
| `MyTools/Core/Storage/StorageUsageService.swift` | Vault/附件/缓存/日志占用、缺失引用、孤立附件扫描和清理。 |

### `MyTools/Core/UI/`：跨模块 SwiftUI 组件

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Core/UI/IMETextInput.swift` | 中文组合输入安全的单行/多行字段和保存前 marked text 提交。 |
| `MyTools/Core/UI/ListViewModifiers.swift` | 列表密度与包含系统内边距的统一单行高度地板、按功能配置页大小的 `AppListPagination` 增量列表状态（首屏/触底/上限/重置）、统一左滑删除/右滑操作样式配置（删除为红色“删除”）、模板字段显隐/改名滑动动作和拖动代理、跨模块标签解析/去重、灰色标签胶囊、标签筛选胶囊、历史标签建议编辑器、跨平台语义字体 `AppFontSpec`/`.appFont()`、可缩放导航标题 `.appNavigationTitle()`、Sheet、可读宽度、隐藏项按钮、排序方向和页面诊断 modifier。 |
| `MyTools/Core/UI/MarkdownRendering.swift` | Markdown 渲染、容错回退、常用上标归一化和可复制值行。 |
| `MyTools/Core/UI/FormRowComponents.swift` | 详情页/编辑页/新增页统一单行：底层 `AppLabeledContentRow` 承载标签与任意尾部内容并固定内容高度；`DetailValueRow` 提供展示态单行截断、复制、敏感遮罩和链接，leading 模式保留地址/备注多行；`FieldEditorRow`、`DateFieldRow`、`PickerFieldRow`、`ToggleFieldRow`、`NumericFieldRow` 分别承载文本、日期、选择、开关和数值输入，全部复用同一底层行。 |

### `MyTools/Features/Bills/`：收支账单

`Domain/` 保存账单实体、分析和导入协议规则；`Application/` 保存账单状态与用例；`Infrastructure/` 解析外部文件；`Presentation/` 组织记录、分析、编辑、OCR 和导入流程。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Bills/Application/BillsStore.swift` | 账单 CRUD、排序、交换文档导入、来源交易号幂等更新和账单标签库。 |
| `MyTools/Features/Bills/Domain/BillAnalytics.swift` | 周/月/季/年/自定义区间、上一周期、每日与各维度汇总规则。 |
| `MyTools/Features/Bills/Domain/BillExchange.swift` | 版本化 JSON 交换文档、来源账户、标准交易字段、导入校验，以及导出时间/来源/分类/收支筛选规则。 |
| `MyTools/Features/Bills/Domain/BillOCRParser.swift` | 从 OCR 行提取金额、日期、商户和支付方式候选并评分。 |
| `MyTools/Features/Bills/Domain/BillRecord.swift` | 账单方向、状态、分类、来源和记录实体及规范化规则。 |
| `MyTools/Features/Bills/Infrastructure/BillImportAdapters.swift` | 导入 Adapter 注册、格式识别及微信 XLSX/支付宝 CSV 到内部协议的映射。 |
| `MyTools/Features/Bills/Infrastructure/BillSpreadsheetReader.swift` | 无第三方依赖的 XLSX ZIP/XML、Excel 日期和 UTF-8/GB18030 CSV 读取。 |
| `MyTools/Features/Bills/Presentation/BillAnalysisView.swift` | 分析周期选择、日期导航、指标和每日/分类/商户/付款方式图表。 |
| `MyTools/Features/Bills/Presentation/BillEditorView.swift` | 手工新增/编辑账单字段、校验和保存。 |
| `MyTools/Features/Bills/Presentation/BillImportView.swift` | 外部文件选择、解析、错误展示、导入预览和确认。 |
| `MyTools/Features/Bills/Presentation/BillOCRImportView.swift` | 图片选择、区域 OCR、候选确认并进入账单编辑器。 |
| `MyTools/Features/Bills/Presentation/BillsView.swift` | 账单“记录/分析”顶层分区、默认 30 条的增量列表、搜索/收支/分类筛选，以及设置中的账单导出页面。 |

### `MyTools/Features/SportsLottery/`：体彩开奖

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/SportsLottery/Domain/SportsLotteryModels.swift` | 可扩展赛事值对象、默认五大联赛与欧冠、用户赛事偏好、按赛事保存的比赛展示顺序、比赛和五类竞彩足球开奖结果。 |
| `MyTools/Features/SportsLottery/Infrastructure/SportsLotteryService.swift` | 中国体育彩票赛果批量接口（按 `leagueId` 分页）、赛事名称目录匹配、单场固定奖金和比赛头信息补齐；独立 Application Support 快照、首次 30 天初始化及最近 3 天与未完整场次增量刷新；不进入 Vault、备份或 CloudKit。 |
| `MyTools/Features/SportsLottery/Application/SportsLotteryRefreshCoordinator.swift` | 北京时间 10:00/22:00 前台定时检查、激活补刷和 iOS `BGAppRefreshTask` 预约；后台实际执行时间由系统决定。 |
| `MyTools/Features/SportsLottery/Presentation/SportsLotteryView.swift` | 可增删赛事列表、添加赛事 sheet、赛事与比赛结果的 30 条增量展示、比赛默认时间/场次倒序与长按自定义顺序、进入赛事页单次强制刷新、开奖结果展示、刷新和暂无数据状态。 |

### `MyTools/Features/CurrencyExchange/`：换汇记录

该模块当前没有专属 `Infrastructure/`，外部牌价复用 `Core/Currency/`。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/CurrencyExchange/Application/CurrencyExchangeStore.swift` | 换汇 CRUD、汇率提醒、牌价更新观察和模块生命周期。 |
| `MyTools/Features/CurrencyExchange/Domain/CurrencyExchange.swift` | 双报价口径、换汇记录、理论金额和人民币损益计算。 |
| `MyTools/Features/CurrencyExchange/Presentation/BankOfChinaExchangeRatesView.swift` | 中国银行牌价列表和双向币种换算器。 |
| `MyTools/Features/CurrencyExchange/Presentation/CurrencyExchangeEditorView.swift` | 换汇记录字段输入、金额表达式解析和校验保存。 |
| `MyTools/Features/CurrencyExchange/Presentation/CurrencyExchangeView.swift` | 换汇概览、筛选搜索、月份分组、30 条增量列表和 CRUD 入口。 |

### `MyTools/Features/Documents/`：证照记录

该模块当前没有专属 `Infrastructure/`，附件和 OCR 分别复用 Core 服务。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Documents/Application/DocumentsStore.swift` | 证照 CRUD、附件、版本规范化、到期通知、模块生命周期、证照字段模板、冗余字段清理和证照标签库。 |
| `MyTools/Features/Documents/Domain/CredentialDocument.swift` | 证照类型模板、字段输入/展示模型、按实际换行自适应的单行/多行状态、字段模板、基本/扩展字段、签发及有效期规则、状态、版本和附件角色。 |
| `MyTools/Features/Documents/Domain/CredentialOCRParser.swift` | 按证照类型将 OCR 结果解析为待确认的基本字段和模板字段候选。 |
| `MyTools/Features/Documents/Presentation/CredentialDetailView.swift` | 认证后的证照详情、版本、状态、有效期、字段显隐和附件展示；包含证照字段模板编辑器。 |
| `MyTools/Features/Documents/Presentation/CredentialEditorView.swift` | 新增/编辑证照、类型-持有人显示规则、字段紧凑编辑、字段显隐/改名/删除/排序、模板字段、签发日期、有效期、附件和 OCR 入口。 |
| `MyTools/Features/Documents/Presentation/CredentialOCRView.swift` | 图片/PDF/相机区域识别、候选勾选确认和表单回填。 |
| `MyTools/Features/Documents/Presentation/CredentialPresentationSupport.swift` | 证照附件编辑、预览和共享等展示辅助组件；附件重命名分开编辑文件名和扩展名。 |
| `MyTools/Features/Documents/Presentation/DocumentsView.swift` | 证照 30 条增量聚合列表、类型/有效期/版本状态/标签筛选和搜索，以及持有人默认遮罩和临时认证揭示。 |

### `MyTools/Features/Finance/`：金融账户

该模块当前没有专属 `Infrastructure/`；附件和敏感展示复用 Core。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Finance/Application/FinanceStore.swift` | 银行、子账户、银行卡 CRUD，境内/境外登录字段模板，账单附件生命周期和冗余字段清理。 |
| `MyTools/Features/Finance/Domain/BankCard.swift` | 银行、账户级分行坐标、境内银行卡开卡网点坐标及未单独填写时继承账户开户网点的统一解析、境内/境外差异化子账户类型与自定义类型、登录字段模板、银行卡、账单及状态/卡组织领域模型。 |
| `MyTools/Features/Finance/Presentation/BankAccountViews.swift` | 银行详情与银行档案新增/编辑、银行卡固定字典序、分行地图选点/导航、登录字段左右滑操作和模板编辑，包括境内外扩展资料。 |
| `MyTools/Features/Finance/Presentation/BankCardDetailView.swift` | 无额外导航标题的银行卡敏感详情、直接编辑、账单附件和相关操作。 |
| `MyTools/Features/Finance/Presentation/BankCardEditorView.swift` | 借记卡/信用卡编辑、境内卡开卡网点选点和信用卡账单附件编辑。 |
| `MyTools/Features/Finance/Presentation/FinanceHomeView.swift` | 金融首页、地区筛选、搜索排序、随当前可见银行范围变化的统计，以及活跃/停用银行列表行。 |
| `MyTools/Features/Finance/Presentation/SubaccountEditorViews.swift` | 无额外导航标题的境内与境外子账户详情、管理员直接编辑及新增/编辑表单。 |

### `MyTools/Features/FoodMap/`：美食地图

`Infrastructure/` 只承载第三方地图跳转，地图搜索和点选是展示交互，位于 `Presentation/`。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/FoodMap/Application/FoodMapStore.swift` | 美食地点 CRUD、图片附件、数据规范化、冗余字段清理和美食标签库。 |
| `MyTools/Features/FoodMap/Domain/ChinaAdministrativeDivision.swift` | 中国省市目录、下级行政区字段、标准化和中文地址省市推断；兼容缺少下级行政区的旧记录。 |
| `MyTools/Features/FoodMap/Domain/DianpingImport.swift` | 大众点评单店分享文字与收藏夹页面条目的店名、星级、评论数、人均、主打特色、商圈地址、来源入口和独立单店链接解析及导入候选模型。 |
| `MyTools/Features/FoodMap/Domain/FoodPlace.swift` | 店名、推荐食物、地址、来源名称/来源链接、独立店铺链接、星级、评论数、人均消费及币种、主打特色、“吃过/想吃”状态、坐标、图片和旧字段兼容迁移。 |
| `MyTools/Features/FoodMap/Infrastructure/FoodNavigationService.swift` | Apple/高德/百度/腾讯/Google 地图 URL 生成与可用性判断。 |
| `MyTools/Core/Location/MapLocationSearchService.swift` | 美食地图、银行网点及后续地图功能共用的 `MapLocationPickerView`、MapKit 搜索服务和候选行；统一定位权限、地图展示、请求取消、国际地址兜底、反向地理编码、手动点选、保存/取消、整行点击和蓝色选中标记；搜索栏与保存按钮固定在键盘可见区，中间地图和候选列表独立滚动。 |
| `MyTools/Features/FoodMap/Presentation/FoodLocationPickerView.swift` | Core 公共地图选点组件的美食业务适配器，只负责把统一选点结果转换为地点名称、详细地址和中国行政区。 |
| `MyTools/Features/FoodMap/Presentation/DianpingImportView.swift` | 大众点评分享内容导入、iOS 移动端/macOS 桌面端自适应的仅本机持久 WebKit 登录、含单店 URL 的当前页面条目抽取、可左滑删除的紧凑候选卡、MapKit 自动匹配、公开封面落地和会话清除。 |
| `MyTools/Features/FoodMap/Presentation/FoodMapPresentationSupport.swift` | 店铺星级/评论/人均“图标 + 数值”紧凑指标、金额展示、地图卡片、导航菜单、来源链接和照片缩略图等共享组件。 |
| `MyTools/Features/FoodMap/Presentation/FoodMapView.swift` | 带店铺摘要指标的美食 30 条增量列表、状态/标签筛选、搜索和总地图入口。 |
| `MyTools/Features/FoodMap/Presentation/FoodPlaceDetailView.swift` | 店铺主要字段摘要卡、图片、标签、备注、地图与导航操作。 |
| `MyTools/Features/FoodMap/Presentation/FoodPlaceEditorView.swift` | 店名必填、推荐食物、评分/评论/人均/特色、来源与独立店铺链接、图片、行政区和地图位置编辑。 |
| `MyTools/Features/FoodMap/Presentation/FoodPlacesMapView.swift` | 所有已定位地点与用户当前位置的总地图、附近/全局视角切换、标记选择和详情跳转。 |

### `MyTools/Features/Health/`：健康档案

该模块当前没有专属 `Infrastructure/`；附件复用 Core。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Health/Application/HealthRecordSynchronizer.swift` | 加载后同步关联记录、机构资料和分类字段。 |
| `MyTools/Features/Health/Application/HealthStore.swift` | 医疗记录/机构 CRUD、附件、生命周期、冗余字段清理和健康标签库。 |
| `MyTools/Features/Health/Domain/HealthRecord.swift` | 就诊类型、机构、费用、体检和医疗记录领域模型及汇总值。 |
| `MyTools/Features/Health/Domain/MedicalRecordDraftValidator.swift` | 医疗草稿规范化、费用分配、关联关系和保存校验。 |
| `MyTools/Features/Health/Presentation/HealthRecordsView.swift` | 健康首页、年度概览、搜索/标签/年份筛选和 30 条增量记录入口。 |
| `MyTools/Features/Health/Presentation/HospitalDirectoryView.swift` | 医院、药房和体检机构资料库的搜索与编辑。 |
| `MyTools/Features/Health/Presentation/MedicalRecordDetailView.swift` | 就诊/体检详情、关联记录、费用项和附件展示。 |
| `MyTools/Features/Health/Presentation/MedicalRecordEditorView.swift` | 五类医疗记录、体检轮次、费用项和附件的统一编辑器。 |
| `MyTools/Features/Health/Presentation/MedicalRecordRow.swift` | 医疗类型徽标、记录行和列表视觉语义。 |
| `MyTools/Features/Health/Presentation/MedicalRecordsPresentation.swift` | 搜索、年份/事件分组、关联计数和统计快照等纯展示计算。 |

### `MyTools/Features/Secrets/`：保密资料

该模块当前没有专属 `Infrastructure/`，页面集中在一个完整流程文件中。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Secrets/Application/SecretStore.swift` | 保密条目 CRUD、附件生命周期、标签规范化/标签库、分类模板字段生成、普通模式有效显隐解析和备份恢复状态。 |
| `MyTools/Features/Secrets/Domain/Secret.swift` | 六类模板、个人/工作用途、自定义字段、内容遮罩、标签、备注和附件实体；登录模板包含 URL。 |
| `MyTools/Features/Secrets/Domain/ApplePasswordImport.swift` | Apple 密码 CSV 的 UTF-8/引号/换行解析、字段映射、导入预览和重复数据校验。 |
| `MyTools/Features/Secrets/Presentation/SecretVaultView.swift` | 30 条增量列表与筛选、个人/工作用途标签、Apple 密码 CSV 导入、独立查看认证、字段模板长按拖动排序、普通模式按模板显隐、切换分类重建模板字段、字段紧凑编辑、字段及模板右滑显隐/改名、详情、编辑和附件交互；模板滑动动作复用 Core UI。 |

### `MyTools/Features/Stocks/Domain/`：股票领域与确定性计算

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Stocks/Domain/Stock.swift` | 市场、交易、分红、持仓实体及持仓/成本/盈亏基础计算。 |
| `MyTools/Features/Stocks/Domain/StockChartSeriesProcessor.swift` | 图表序列类型、范围裁剪、成立时间边界、增量合并、休市点过滤和降采样。 |
| `MyTools/Features/Stocks/Domain/StockInvestmentScoreModel.swift` | 基本面快照、评分输入、因子覆盖度和投资机会评分规则。 |
| `MyTools/Features/Stocks/Domain/StockMarketTradingCalendar.swift` | A/港/美股交易日、节假日、交易时段和最终时段判断。 |
| `MyTools/Features/Stocks/Domain/StockPortfolioAnalytics.swift` | 市场组合汇总、持仓成本、市值、盈亏、资产分配和按持仓成本计算的股票占比快照。 |
| `MyTools/Features/Stocks/Domain/StockQuoteModels.swift` | 实时报价值对象、券商本地化简称元数据和行情错误。 |
| `MyTools/Features/Stocks/Domain/StockTechnicalAnalysis.swift` | MA、布林带、MACD、RSI、KDJ、W%R、CCI、DMI、MTM、TRIX、OBV、MFI、A/D、Chaikin、PSY、ROC 技术指标计算。 |
| `MyTools/Features/Stocks/Domain/StockValueFormatter.swift` | 股票金额、价格、比率和汇率的统一文本格式。 |

### `MyTools/Features/Stocks/Application/`：股票用例与状态

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Stocks/Application/StockAppearanceSettings.swift` | 股票涨跌颜色偏好的本地状态和设置读取。 |
| `MyTools/Features/Stocks/Application/StockChartService.swift` | 多 Provider 图表编排、缓存读取/写入、范围增量请求和回退。 |
| `MyTools/Features/Stocks/Application/StockFundamentalService.swift` | A/港/美股基本面 Provider 编排、合并和 24 小时内存缓存。 |
| `MyTools/Features/Stocks/Application/StockPortfolioEditor.swift` | 股票、交易、分红增删改、持仓/看盘/存档状态转换及任意时点负持仓校验。 |
| `MyTools/Features/Stocks/Application/StockQuoteRefreshReducer.swift` | 将新报价与旧缓存合并并判定变更的纯 Reducer。 |
| `MyTools/Features/Stocks/Application/StockQuoteService.swift` | 按市场批量优先、多数据源回退的实时报价编排。 |
| `MyTools/Features/Stocks/Application/StockRefreshCoordinator.swift` | iOS 后台任务注册、收市完整行情补刷、前台报价轮询和 AppDelegate 桥接；分时图仍由看盘页按当前交易时段负责。 |
| `MyTools/Features/Stocks/Application/StockStore.swift` | 持仓与存档状态、行情缓存、自动刷新、休市也可用的手动强制刷新、提醒和模块生命周期。 |

### `MyTools/Features/Stocks/Infrastructure/Charts/`：历史与分时图表

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Stocks/Infrastructure/Charts/EastmoneyStockChartProvider.swift` | 东方财富 A/港股图表请求与响应解析。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/NasdaqStockChartProvider.swift` | Nasdaq 美股分时和历史图表请求与解析。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/StockChartDiskStore.swift` | 盘中分钟和日线 OHLCV 原始序列、5 日/周/月/季/年派生序列及分钟/日线技术指标缓存；派生缓存由原始数据变化时重建，指标算法使用独立版本从本地 OHLCV 一次性迁移并写回，只有原始时段语义变化才提升文件版本使旧缓存失效。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/StockChartModels.swift` | 市场标准七档图表周期、OHLCV 点、可见序列与独立日线技术参考序列的快照和错误模型。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/StockChartProvider.swift` | 图表 Provider/HTTP Client 协议、生产 URLSession 实现和 Provider 容器。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/TencentStockChartProvider.swift` | 腾讯 A/港/美股分时及 K 线图表请求与解析。 |
| `MyTools/Features/Stocks/Infrastructure/Charts/YahooStockChartProvider.swift` | Yahoo 图表请求、时区和 OHLCV 响应解析。 |

### `MyTools/Features/Stocks/Infrastructure/Quotes/` 与 `Fundamentals/`

`Quotes/` 保存实时报价数据源；`Fundamentals/` 保存估值、盈利能力和增长数据源。新增外部源时在这里实现协议，在 Application 服务中决定优先级。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Stocks/Infrastructure/Quotes/EastmoneyStockQuoteProvider.swift` | 东方财富单股行情请求和弹性数字解析。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/NasdaqStockQuoteProvider.swift` | Nasdaq 美股报价请求和价格字段解析。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/OfficialAShareStockQuoteProvider.swift` | 沪深交易所公开接口的 A 股行情请求与解析。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/SinaStockQuoteProvider.swift` | 新浪批量行情请求、分批和响应解析。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/StockQuoteProvider.swift` | 单股/批量行情 Provider、HTTP Client 协议、股票候选搜索 Provider/结果解析、券商简称和排序支持工具。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/TencentStockQuoteProvider.swift` | 腾讯批量行情请求、分批和响应解析，并保留美股券商返回的中文简称元数据。 |
| `MyTools/Features/Stocks/Infrastructure/Quotes/YahooStockQuoteProvider.swift` | Yahoo Chart 元数据方式的单股最新报价解析。 |
| `MyTools/Features/Stocks/Infrastructure/Fundamentals/StockFundamentalProvider.swift` | 基本面 Provider 协议及东方财富、Yahoo 两套生产实现。 |

### `MyTools/Features/Stocks/Presentation/`：股票界面

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Features/Stocks/Presentation/StockChartCanvas.swift` | Swift Charts 盘中/K 线/指标/成交量绘制、单击/拖动选点、长按拖动平移、缩放手势和横轴布局。 |
| `MyTools/Features/Stocks/Presentation/StockChartPresentation.swift` | 图表模式、选中点和技术图层的展示模型构建；模式无关的行情筛选、指标投影和交易标记先准备一次，盘前/盘中/盘后拼接切换只重排坐标。 |
| `MyTools/Features/Stocks/Presentation/StockDetailView.swift` | 股票详情、交易/分红时间线、编辑和看盘入口。 |
| `MyTools/Features/Stocks/Presentation/StockDividendEditorView.swift` | 分红数量、每股分红、税费和备注编辑。 |
| `MyTools/Features/Stocks/Presentation/StockEditorView.swift` | 股票基础资料、紧凑候选搜索（正式名称右侧代码标签、券商中文简称/交易所信息）、默认首次买入与“仅看盘”新增方式编辑。 |
| `MyTools/Features/Stocks/Presentation/StockTransactionEditorView.swift` | 买卖流水日期、数量、价格和费用编辑。 |
| `MyTools/Features/Stocks/Presentation/StockTrendColor.swift` | 按市场偏好把涨跌数值映射为 SwiftUI 颜色。 |
| `MyTools/Features/Stocks/Presentation/StockWatchView.swift` | 看盘页、范围/图层、长周期行情图选点、长按平移与缩放、刷新、基本面和投资评分详情。 |
| `MyTools/Features/Stocks/Presentation/StocksView.swift` | 股票首页、市场筛选、排序、组合概览、当前持仓/看盘/历史股票分区、存档恢复，以及行情刷新。 |

### App 资源、本地化与权限

`MyTools/Assets.xcassets/` 是 Asset Catalog；`AppIcon.appiconset/` 保存不同平台/外观的图标源文件；`en.lproj/` 和 `zh-Hans.lproj/` 保存系统元数据本地化。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyTools/Assets.xcassets/Contents.json` | Asset Catalog 根清单。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/Contents.json` | iOS/macOS AppIcon 槽位、尺寸、外观和文件映射。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/White.png` | iOS 默认浅色 App 图标源图。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/Dark.png` | iOS 深色外观 App 图标源图。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/Tinted.png` | iOS 着色外观 App 图标源图。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_16.png` | macOS 16×16 App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_16@2x.png` | macOS 16 pt @2x App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_32.png` | macOS 32×32 App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_32@2x.png` | macOS 32 pt @2x App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_128.png` | macOS 128×128 App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_128@2x.png` | macOS 128 pt @2x App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_256.png` | macOS 256×256 App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_256@2x.png` | macOS 256 pt @2x App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_512.png` | macOS 512×512 App 图标。 |
| `MyTools/Assets.xcassets/AppIcon.appiconset/mac_512@2x.png` | macOS 512 pt @2x App 图标。 |
| `MyTools/Info.plist` | 展示名、版本、场景、相机/照片权限说明和平台 Info 配置。 |
| `MyTools/en.lproj/InfoPlist.strings` | 英文 App 名称和系统权限说明本地化。 |
| `MyTools/zh-Hans.lproj/InfoPlist.strings` | 简体中文 App 名称和系统权限说明本地化。 |
| `MyToolsRelease.entitlements` | iOS/iPadOS 生产签名的 App Sandbox、iCloud/CloudKit 等能力声明。 |
| `MyToolsMacRelease.entitlements` | macOS 生产签名的 Sandbox、文件访问、网络和 iCloud/CloudKit 能力声明。 |

### `MyToolsTests/AppStore/`：组合层与跨模块测试

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyToolsTests/AppStore/AppStoreAlertEvaluatorTests.swift` | 股票和汇率阈值提醒评估及去重行为。 |
| `MyToolsTests/AppStore/AppStoreBackupMergerTests.swift` | 备份按模块、记录 ID 和当前可见模块的增量合并。 |
| `MyToolsTests/AppStore/AppStoreBackupProcessorTests.swift` | 备份模块裁剪、附件装配/恢复和错误行为。 |
| `MyToolsTests/AppStore/AppStoreFacadeTests.swift` | AppStore 加载、依赖调用、快照、持久化和模块组合行为。 |
| `MyToolsTests/AppStore/CloudSyncMergerTests.swift` | CloudKit 各实体 upsert/delete、模块隔离和合并规则。 |
| `MyToolsTests/AppStore/ExchangeRateRepositoryTests.swift` | 双报价汇率缓存、加载保存和旧格式升级。 |
| `MyToolsTests/AppStore/HealthRecordSynchronizerTests.swift` | 健康记录、关联关系和机构资料加载同步。 |

### 各业务模块与 Core 测试目录

`MyToolsTests/Bills/`、`Documents/`、`FoodMap/`、`Health/`、`Stocks/` 分别归对应 Feature；`Core/` 验证跨模块能力；`Stores/` 集中验证多个轻量 Store 和模块协议边界。

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyToolsTests/Bills/BillsTests.swift` | 账单规范化、分析、OCR、交换协议、微信/支付宝导入、备份和 CloudKit。 |
| `MyToolsTests/Core/OCRTests.swift` | OCR 区域坐标、阅读顺序、图片/PDF 加载和渲染。 |
| `MyToolsTests/Core/AppAlphabeticalSortTests.swift` | 中英文混排、拼音首字母、大小写和数字自然顺序。 |
| `MyToolsTests/Documents/DocumentsTests.swift` | 证照模板、签发/有效期、OCR、版本、附件、通知、备份和 CloudKit。 |
| `MyToolsTests/FoodMap/FoodMapTests.swift` | 美食字段往返与旧食物名称迁移、大众点评评分/评论/人均/单店链接解析、规范化、附件、行政区、导航、清理、备份和 CloudKit。 |
| `MyToolsTests/Health/MedicalRecordEditingTests.swift` | 医疗草稿、费用分配、关联关系和附件编辑会话。 |
| `MyToolsTests/Health/MedicalRecordsPresentationTests.swift` | 健康搜索、年份/事件分组、统计和关联计数。 |
| `MyToolsTests/Stores/ModuleStoreTests.swift` | 金融、秘密、换汇、健康等 Store 及生命周期/清理隔离，包括信用卡银行的启用状态判定和地图候选网点名称回填。 |

### `MyToolsTests/Stocks/`：股票测试

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyToolsTests/Stocks/StockChartDiskStoreTests.swift` | 图表磁盘存储、范围元数据、当前序列合并，以及旧指标缓存从本地 OHLCV 重建并持久化的迁移。 |
| `MyToolsTests/Stocks/StockChartPresentationTests.swift` | 图表展示点、交易标记、选择和坐标数据。 |
| `MyToolsTests/Stocks/StockChartProviderParsingTests.swift` | 腾讯、东方财富、Yahoo、Nasdaq 图表响应解析。 |
| `MyToolsTests/Stocks/StockChartSeriesProcessorTests.swift` | 范围裁剪、合并、采样、休市过滤和最近交易日回退。 |
| `MyToolsTests/Stocks/StockChartServiceTests.swift` | 图表缓存、增量请求、Provider 优先级和错误回退。 |
| `MyToolsTests/Stocks/StockChartSmokeTests.swift` | 公开图表接口的可选网络冒烟验证。 |
| `MyToolsTests/Stocks/StockInvestmentScoreModelTests.swift` | 投资评分、因子权重、缺失值收缩和覆盖度。 |
| `MyToolsTests/Stocks/StockPortfolioEditorTests.swift` | 股票/流水/分红编辑、持仓/看盘/存档状态转换和任意时点负持仓防护。 |
| `MyToolsTests/Stocks/StockQuoteProviderParsingTests.swift` | 各实时报价与基本面 Provider 的响应解析。 |
| `MyToolsTests/Stocks/StockQuoteRefreshReducerTests.swift` | 报价刷新合并与是否发生变更判定。 |
| `MyToolsTests/Stocks/StockQuoteServiceTests.swift` | 行情批量优先、市场路由、多源回退和调用次序。 |
| `MyToolsTests/Stocks/StockTechnicalIndicatorsTests.swift` | 价格、趋势、动能和量价技术指标计算及旧缓存兼容。 |

### `MyToolsTests/TestSupport/`：股票测试替身与样本

| 文件 | 职责与定位用途 |
| --- | --- |
| `MyToolsTests/TestSupport/FakeStockChartProvider.swift` | 可记录调用并返回固定结果的图表 Fake Provider。 |
| `MyToolsTests/TestSupport/StockChartFixtures.swift` | 多市场、多范围图表测试样本和构造器。 |
| `MyToolsTests/TestSupport/StubStockChartHTTPClient.swift` | 图表 Provider 解析测试使用的 HTTP Stub。 |
| `MyToolsTests/TestSupport/StubStockQuoteHTTPClient.swift` | 行情 Provider 解析测试使用的并发安全 HTTP Stub。 |

## 已实现的业务模块

| 模块 | 已实现能力 | 主要入口 | 数据与状态 |
| --- | --- | --- | --- |
| 金融账户 | 境内外银行、网络银行无网点标记、支行地图链接/导航、境内/境外差异化子账户预设与其他账户自定义类型、借记卡、信用卡、账单 PDF、登录字段模板与左右滑管理、筛选搜索排序、敏感字段验证和复制 | `Features/Finance/Presentation/FinanceHomeView.swift` | `FinanceStore`、`BankCard.swift` |
| 股票投资 | A/港/美股、买卖和分红、任意时点持仓校验、成本与盈亏、组合分析、按当前持仓/看盘/历史股票分区、清仓历史保留与存档恢复、按中文/英文/代码模糊搜索股票（按市场与交易所过滤、同代码多源合并、美股原生正式名称/券商中文简称/规范代码回填、正式名称右侧代码标签和紧凑候选行、中文名称完整/后缀/前缀/包含匹配、普通股优先于相近 ETF、主板交易所优先于 OTC、数据源相关排序和热门代码稳定兜底、证券类型标识和无结果提示）、实时行情、市场标准七档图表周期（分时/5日分钟线固定近期窗口，日K/周K/月K/季K/年K默认仅盘中并可平移缩放，内部切换保持用户图层选择，底层由原始序列重新计算，新上市股票按实际可用 K 线柱绘制）、区间切换加载蒙版与进度状态、分时与5日均线/布林/MACD使用跨交易日分钟历史预热后仅投影可见柱，分时分钟级/其他范围交易日级 RSI14/RSI30、按交易价格和可见盘中定位交易标记、仅美股提供连续盘前/盘后图表模式，A 股和港股竞价阶段不绘制为扩展时段曲线、投资机会评分、按市场分组的提醒选择和涨跌色 | `Features/Stocks/Presentation/StocksView.swift` | `StockStore`、`Stock.swift`、`StockQuoteProvider.swift` |
| 换汇记录 | 双报价口径、理论与实际买入、手续费、人民币损益、筛选分组、中国银行牌价、双向换算和汇率提醒 | `Features/CurrencyExchange/Presentation/CurrencyExchangeView.swift` | `CurrencyExchangeStore`、`CurrencyExchange.swift` |
| 健康档案 | 门诊、急诊、住院、购药、体检轮次、关联复诊、机构资料、费用分配、年度统计、标签胶囊、标签建议/筛选/搜索、图片/PDF 附件 | `Features/Health/Presentation/HealthRecordsView.swift` | `HealthStore`、`HealthRecord.swift` |
| 美食地图 | 吃过/想吃、店铺、中国省市、详细地址、地图坐标、图片、来源、标签胶囊、标签建议/筛选/搜索、大众点评单店/收藏夹本机登录导入、图片地图标记、总地图和第三方导航 | `Features/FoodMap/Presentation/FoodMapView.swift` | `FoodMapStore`、`FoodPlace.swift`、`DianpingImport.swift` |
| 保密资料 | 六类模板、个人/工作用途、自定义字段、字段模板名称/类型编辑、普通模式按当前模板显隐、切换分类重建目标模板字段、模板字段右滑内容显隐、左滑删除与长按拖动排序、按换行自动单行/多行、默认字段遮罩、条目字段右滑内容显隐/改名、左滑删除、标签胶囊、标签建议/筛选/搜索、Apple 密码 CSV 导入、独立查看认证和管理员编辑 | `Features/Secrets/Presentation/SecretVaultView.swift` | `SecretStore`、`Secret.swift`、`ApplePasswordImport.swift` |
| 证照 | 首页显示名称统一为“证照类型-持有人”，不使用自定义显示名称；附件展示名允许重复，内部磁盘名保持独立，重命名分开编辑文件名和扩展名；身份证、护照、港澳通行证、驾驶证、学历/学位/房产证、出生医学证明、预防接种证、职业资格证书和自定义模板；其他信息字段支持文本/网址/日期、按值中实际换行自适应单行/多行、显隐、改名、删除和拖动排序；每种证照独立字段模板，模板随 Vault、备份和 CloudKit 同步；所有证照必填签发日期，固定期限从签发日期起算；身份证、港澳通行证和驾驶证使用年限届满日，普通护照的到期日为年限届满日前一日；到期提醒、多版本及证照状态、标签胶囊、标签建议/筛选/搜索、自定义字段、图片/PDF 附件和 OCR 候选确认/字段填充；出生日期仅作为自定义字段，旧版固定值支持无损迁移 | `Features/Documents/Presentation/DocumentsView.swift` | `DocumentsStore`、`CredentialDocument.swift` |
| 账单 | 手工收支记录、图片区域 OCR、金额/日期/商户/支付方式候选、默认 30 条增量列表和搜索/收支/分类/标签筛选；记录/分析顶层分区与按周、月、季、年或自定义区间、按币种统计，提供上一周期对比、每日支出、分类、商户和付款方式图表；标签以胶囊显示并支持历史建议复用；设置中可按预设/自定义区间、来源、分类和收支方向导出 JSON；版本化交换协议、导入预览及来源交易号去重；支持微信支付 XLSX 和支付宝 GB18030/UTF-8 CSV，自动跳过导出摘要 | `Features/Bills/Presentation/BillsView.swift` | `BillsStore`、`BillRecord.swift`、`BillAnalytics.swift`、`BillExchange.swift` |
| 体彩开奖 | 默认五大联赛与欧冠；进入管理员（编辑）模式后可按官方赛事简称或全称添加，赛事行使用统一配置的红色“删除”左滑动作；按赛事批量获取近期开赛结果并补齐比赛头信息与五类竞彩固定奖金；官方结果缺失时显示暂无数据；比赛行支持长按拖动并持久化自定义顺序，进入赛事比赛页自动强制刷新一次；赛果独立持久化，首次加载近 30 天、后续增量刷新，并在北京时间 10:00/22:00 自动检查；网络赛果不参与 Vault、备份或 CloudKit 业务同步，但赛事选择和自定义顺序作为应用偏好同步 | `Features/SportsLottery/Presentation/SportsLotteryView.swift` | `SportsLotteryService`、`SportsLotteryModels.swift`、`SportsLotteryRefreshCoordinator.swift` |

九个模块都登记在 `App/Modules/ToolModule.swift`，其中八个业务数据模块参与本地 Vault、加密备份和 CloudKit；体彩开奖的网络赛果缓存不参与本地数据、备份或 CloudKit，赛事选择和自定义顺序作为应用偏好同步；金融、健康、美食、保密资料和证照拥有附件；股票和换汇共用汇率；股票、换汇和证照拥有提醒。

## App 级模块与组合能力

| 能力与检索词 | 可复用实现 | 使用说明 |
| --- | --- | --- |
| 模块声明、能力元数据、开关边界 | `ToolModule`、`ToolModuleCapability`、`ToolModuleDefinition`、`ToolModuleCatalog` in `App/Modules/ToolModule.swift` | 新模块的唯一注册源；声明本地数据、附件、汇率、行情、图表、通知、备份和 CloudKit 参与情况 |
| 模块显隐、排序、偏好同步 | `ToolModuleSettings` in `App/Modules/ToolModuleSettings.swift` | 首页与设置共用；可见性变化会通知生命周期参与者并触发 CloudKit 偏好同步 |
| 模块启停生命周期 | `ModuleLifecycleParticipant`、`ModuleLifecycleRegistry` in `App/Composition/ModuleStoreContracts.swift` | 后台刷新或共享服务依赖模块开关时实现该协议；当前股票、共享汇率、换汇、健康和证照参与 |
| 模块冗余字段清理 | `ModuleDataCleanupParticipant`、`ModuleDataCleanupRegistry`、`RedundantDataCleanupReport` in `App/Composition/ModuleStoreContracts.swift` | 模块自己声明确定性的扫描和清理规则，设置页只聚合已编译且首页可见模块；当前金融、健康、美食和证照参与 |
| 模块数据变更通知 | `VaultMutationNotifying` in `App/Composition/ModuleStoreContracts.swift` | Store 修改数据后通知根 Store 持久化及 CloudKit 对账，使用弱引用避免环 |
| 根组合与持久化协调 | `AppStore` in `App/Composition/AppStore.swift` | 装配八个 Store、加载 Vault、生成聚合快照、协调备份和同步；不要加入模块 CRUD |
| 外部依赖抽象 | `AppStoreDependencies` 及 `VaultInitialLoading`、`VaultPersisting`、`StockQuoteRefreshing`、`ExchangeRateProviding`、`AlertNotificationRouting`、`LocalNotificationScheduling`、`StockRefreshInvalidating`、`VaultBackupProcessing` | 测试和生产实现共用的窄协议；生产绑定集中在 `App/Bootstrap/LiveAppDependencies.swift` |
| 模块页面路由 | `ToolModuleDestination` in `App/Navigation/ToolModuleDestination.swift` | 新模块增加首页目的地时更新穷举 switch |
| 全局对象注入 | `ConfiguredRootView` in `App/Bootstrap/ToolBoxApp.swift` | Store 或全局设置需要 Environment 注入时在组合根完成 |

## 可跨模块复用的 Core 能力

### 附件与文件

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 附件元数据、分类 | `FileAttachment`、`AttachmentKind` in `Core/Attachments/FileAttachment.swift` | 文件名、存储名、UTType、大小、类别、创建时间和备份临时数据 |
| 附件导入、保存、读取、改名、删除、恢复 | `AttachmentStore` in `Core/Attachments/AttachmentStore.swift` | Security-scoped URL 导入、原子写入、唯一内部存储名、可重复的展示文件名、路径恢复；iOS 写入使用完整文件保护，macOS 依赖 App Sandbox/系统磁盘保护；不要自行操作附件目录 |
| 编辑期提交与回滚 | `AttachmentEditSession` in `Core/Attachments/AttachmentEditSession.swift` | 区分原附件与临时新增附件，取消编辑时回滚，提交后清理被移除文件 |
| 附件预览与分享 | `AttachmentPreview`、`AttachmentPreviewSheet`、`AttachmentShareButton` in `Core/Attachments/AttachmentPresentation.swift` | iOS Quick Look、macOS 系统打开和跨平台分享 |
| 占用与完整性扫描 | `StorageUsageService` in `Core/Storage/StorageUsageService.swift` | Vault/附件/缓存/日志空间统计、缺失附件、孤立附件和清理；业务字段清理使用模块参与者接口，不放入 Core 文件扫描服务 |
| 模块本地缓存清理 | `ModuleLocalDataCacheClearing`、`AppStore.clearLocalCache(for:)` | 设置页按功能清理可重新下载缓存；不改业务数据和 CloudKit；股票/换汇共享汇率缓存需同时清除内存与 UserDefaults |

附件加入新模块时还必须扩展备份附件映射、CloudKit 附件快照与合并、存储扫描引用集合，并测试模块关闭时附件不参与。

### 认证、权限与敏感展示

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 管理员模式 | `AuthManager` in `Core/Authentication/AuthManager.swift` | 至少 8 位密码、加盐 PBKDF2-HMAC-SHA256（210,000 轮）摘要（旧无盐 SHA-256 验证成功后自动迁移）、Keychain 备份密码、生物识别/设备密码；支持认证有效期、永久会话和“进入后台锁定”选项 |
| 管理员认证表单 | `AuthenticationView`、`IdentityVerificationForm` | 密码或系统认证 Sheet，可在成功后执行回调 |
| 统一编辑入口与状态 | `AdminEditAccessButton`、`AdminModeIndicator`、`.adminModeIndicator()` | 进入/退出管理员编辑模式和统一工具栏图标 |
| 敏感内容独立验证 | `SensitiveAccessView` | 只解锁当前查看流程，不进入管理员编辑模式 |
| 遮罩、复制、提示 | `.copyableText(...)`、`CopyToastCenter` in `Core/Authentication/ProtectedContent.swift`；敏感值遮罩展示行用 `DetailValueRow.protected(...)` in `Core/UI/FormRowComponents.swift` | 敏感值显隐、长按复制和跨平台复制反馈 |

新增、编辑、删除业务数据沿用管理员模式；只查看敏感值沿用独立验证，两种权限语义不得混用。

### 本地持久化、备份与 CloudKit

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 全业务持久化聚合 | `VaultData` in `Core/Persistence/VaultData.swift` | 八模块实体、提醒和健康/美食/证照字段模板/账单/保密资料标签库的 Codable 聚合根；未编译模块保留为不透明 JSON |
| 本地 Vault 读写 | `SecureStore` in `Core/Persistence/SecureStore.swift` | `Application Support/MyTools/local-vault.json`、原子替换、AES-GCM 静态加密（格式 2.0，密钥在 Keychain 仅本机）、旧明文档案首次读取后原地升级、文件保护、读取失败时阻止覆盖原文件；`errSecInteractionNotAllowed` 等受保护数据临时不可用状态会等待设备解锁/场景激活并退避重试，写入保留最新待写快照且绝不降级明文；读写、启动恢复与并发保护测试见 `MyToolsTests/Core/SecureStoreEncryptionTests.swift`、`MyToolsTests/AppStore/AppStoreFacadeTests.swift` |
| 合并和串行保存 | `VaultPersistenceCoordinator` | 合并高频变更、后台串行写入、立即保存和 `flush()`；并发 `schedule` 保护测试见 `MyToolsTests/Core/SecureStoreEncryptionTests.swift` |
| 加密备份格式 | `VaultBackupDocument`、`VaultBackupPayload`、`VaultBackupCrypto` in `Core/Backup/VaultBackup.swift` | `.mytools`、PBKDF2-HMAC-SHA256、AES-GCM、格式 1.0、模块集合 |
| 备份裁剪与附件装配 | `AppStoreBackupProcessor` in `App/Composition/AppStoreBackupProcessor.swift` | 按已编译且可见模块导出/导入、嵌入和恢复附件数据；隐藏模块不会进入当前备份 |
| 增量备份合并 | `AppStoreBackupMerger` in `App/Composition/AppStoreBackupMerger.swift` | 只合并备份包含且当前开启的模块，按记录 ID 更新或追加 |
| CloudKit 快照和编码 | `CloudSyncSnapshotBuilder`、`CloudSyncCoding`、`CloudSyncEntityKind`、`CloudSyncItem` in `Core/CloudSync/CloudSyncModels.swift` | 主线程只复制当前业务状态；JSON 编码和附件读取必须在 utility 后台任务执行，再按摘要生成记录级增量 |
| CloudKit 远端合并 | `CloudSyncMerger`、`CloudSyncChange` | 按实体类型与已编译且允许同步的模块应用 upsert/delete；首页隐藏不会停止同步，删除功能数据的撤回窗口才会临时排除模块 |
| CloudKit 生命周期 | `CloudSyncCoordinator`、`CloudKitSyncWorker`、`CloudSyncStateStore` | 私有数据库、自定义 Zone、增量游标、上传/拉取、账户变化和对账；本地变更用 2 秒防抖合并差异计算，股票报价等本地派生变化不触发 CloudKit 快照，成功同步后清除活动记录的重复 payload 和 CloudKit system fields（仅待上传/重试记录保留）；管理员重建入口只删除本 App 的自定义 Zone，重置本地同步游标后用本机快照重新上传，不触碰本地 Vault/附件；同步状态使用压缩本地格式并排除系统备份，自动发送交给 `CKSyncEngine` 系统调度，手动同步才强制 fetch/send；附件在业务记录应用后后台逐个恢复且禁止整文件读入内存。创建 worker 前必须检查当前构建包的 iCloud 容器 entitlement；无有效签名 entitlement 的 macOS Debug 包和 XCTest 宿主直接禁用同步，不能触发 `CKContainer(identifier:)`，正式签名的 iOS/iPadOS/macOS 包仍正常启用 |
| 同步开关与状态 | `CloudSyncPreferences`、`CloudSyncStateStore`、`CloudSyncPreferencesBridge` | 默认关闭、Apple 账户状态、错误、游标、模块顺序/显隐与外观偏好同步 |

本地 Vault 是离线事实源。行情缓存、汇率缓存、诊断日志、认证状态和 OCR 临时结果不进入 Vault、备份或 CloudKit。

同步状态容量准则：已成功同步的活动记录只保留稳定记录键、摘要、版本时间和删除标记；payload 只为待发送/冲突重试记录保留，未编译模块的不透明数据才允许作为恢复所需的离线 payload 留存。数据量增长后本地状态按记录数线性增加轻量元数据，而不会按业务 JSON 大小重复增长；CloudKit 服务端仍需保存完整业务 payload，这是跨设备恢复的必要数据，不应改成一个巨型聚合记录。

同步状态的读取、解压和旧格式迁移必须在 utility 后台任务执行，不能阻塞主线程创建首屏；同步 Worker 创建阶段不得直接读取几十 MB 的状态文件。

#### 新增字段与 iCloud 同步准则

CloudKit 快照采用显式白名单，新增字段不能因为已经写入 `VaultData` 就默认进入 iCloud。修改数据模型时按以下规则分类：

1. 用户主动创建或修改、跨设备应保持一致的业务数据（例如持仓、账户位置、模板、标签、备注和排序设置）必须进入 `VaultData` 或 `CloudSyncAppPreferences`，并在 `CloudSyncSnapshotBuilder` 与 `CloudSyncMerger` 中同时加入 upsert/delete 路径。
2. 记录内部新增字段沿用 Codable 载荷，但解码必须使用 `decodeIfPresent` 或显式默认值，保证旧设备上传的旧载荷仍可读取；字段重命名必须保留兼容键或提供迁移。
3. 新增顶层数组、模板库、标签库或设置集合必须使用独立稳定的 CloudSync entity（或扩展 App Preferences），不能把多个模块数据隐式塞进某一条业务记录；新增 entity 要声明模块归属、快照、合并、删除和空值语义。
4. 行情、汇率、地图搜索候选、刷新时间、诊断日志、临时 OCR、设备授权、管理员会话和通知运行状态属于派生或设备级数据，默认不进入 iCloud；若需求要跨设备保留，必须先将其重新定义为用户业务数据并单独评审。
5. 每个新增可同步字段至少补四类检查：本地快照包含测试、远端 upsert 合并测试、远端 delete/清理测试、旧载荷兼容解码测试；若模块可隐藏，还要验证隐藏模块仍参与同步。
6. 变更完成后必须检查 `CloudSyncEntityKind` 的模块映射、备份与存储清理引用、文档同步边界，并在构建日志中检查 `deprecated`、编译错误和测试构建结果。

### OCR 文字识别

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| OCR 配置与结果模型 | `OCRLanguage`、`OCRRecognitionLevel`、`OCRConfiguration`、`OCRRecognizedLine`、`OCRResult` in `Core/OCR/OCRModels.swift` | 内置简体中文和英语，语言列表可扩展；准确/快速模式、语言纠正、置信度、边界框和阅读顺序 |
| Vision 识别接口 | `OCRRecognizing`、`VisionOCRService` in `Core/OCR/OCRService.swift` | async 识别 `CGImage`，支持指定语言和归一化兴趣区域 |
| 图片/PDF 输入 | `OCRDocumentLoader`、`OCRDocument` in `Core/OCR/OCRDocumentLoader.swift` | 文件或 Data 输入、图片方向修正、PDF 多页、页码校验和最大像素渲染 |
| 区域选择 | `OCRNormalizedRegion`、`OCRRegionSelector` | 顶左坐标与 Vision 坐标转换、全图默认值、拖动框选和 aspect-fit 映射 |
| 相机拍摄 | `OCRCameraPicker` in `Core/OCR/OCRCameraPicker.swift` | iOS 相机照片输入；调用前仍需检查设备和权限 |
| 临时测试界面 | `OCRTestView` in `App/Settings/Presentation/OCRTestView.swift` | 图片/PDF/相机、PDF 翻页、区域截取、语言与模式选择、结果复制；这是临时入口，不是业务模块 |

快速模式优先速度，中文识别能力受 Vision 快速模型支持限制；需要中文可靠性时默认使用准确模式。新增语言通过 `OCRLanguage` 配置，不复制 OCR 服务。

### 币种与汇率

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 统一币种值对象 | `CurrencyCode` in `Core/Currency/CurrencyCode.swift` | CNY、HKD、USD、CAD、CHF、EUR、GBP、JPY、NZD、SGD、THB、AUD，含标题、选择顺序和中国银行名称 |
| 中国银行牌价抓取 | `ForeignExchangeRateService` | 获取并解析现汇买入/卖出价 |
| 汇率快照与缓存 | `ExchangeRateSnapshot`、`ExchangeRateRepository` | CNY 基准的买入/卖出汇率、UserDefaults 缓存、旧单向缓存升级 |
| 共享汇率状态 | `ExchangeRateStore` | 股票和换汇任一开启时才刷新；缓存加载、手动刷新、并通知换汇 Store |

任何新增币种使用场景先复用 `CurrencyCode`。同时被多个模块消费的汇率仍留在 Core，不在 Feature 内创建独立缓存。

### 通知、诊断与设置

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 本地通知 | `AppNotificationService`、`LocalNotificationScheduling`、`ScheduledLocalNotification` in `Core/Notifications/AppNotificationService.swift` | 权限状态、请求权限、打开系统设置、前台展示、即时提醒去重，以及按标识前缀整体替换预约通知 |
| 价格提醒模型 | `PriceAlertDirection`、`StockPriceAlert`、`CurrencyRateAlert` in `Core/Notifications/NotificationRule.swift` | 高于/低于阈值、启用状态、股票和汇率提醒 |
| 诊断日志 | `DiagnosticLogger` in `Core/Diagnostics/DiagnosticLogger.swift` | 分类/级别、异步缓冲、按日期滚动保留最近 7 天、导出、清除、flush 和稳定错误码 |
| App 外观与字号 | `AppAppearanceMode`、`AppFontSize`、`ToolModuleSettings`、`AppFontSpec`、`.appFont()`、`.appNavigationTitle()` | 系统/明/暗外观、iOS/iPadOS 原生 Dynamic Type、macOS 全局语义字体倍率、随字号增长的列表行和不重复的常规字重导航标题、模块顺序和显隐；展示代码使用 `.appFont()`/`.appNavigationTitle()`，不得新增会绕过 macOS 字号设置的显式 `.font()` 或 `.navigationTitle()` |
| 股票涨跌颜色 | `StockAppearanceSettings` in `Features/Stocks/Application/StockAppearanceSettings.swift` | 按 A/港/美市场保存颜色偏好并同步设置变更 |

通知属于跨模块投递能力，但具体提醒规则和计算仍归拥有该业务数据的模块。

### 输入、格式化与通用 SwiftUI

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 中文输入法安全输入与提交 | `commitPendingTextInput`、`IMESafeTextField`、`IMESafeMultilineTextField` in `Core/UI/IMETextInput.swift` | 持久化中文字段直接使用安全单行/多行控件，并在保存前结束 marked text；单行控件支持普通文本、ASCII 大写和 URL 键盘模式 |
| 标签输入、展示、复用与筛选 | `AppTagSupport`、`AppTagCapsules`、`AppTagFilterCapsules`、`AppTagEditor` in `Core/UI/ListViewModifiers.swift` | 五个用户标签模块统一使用中文逗号输入、灰色标签胶囊、分功能持久化标签库、历史标签点击复用、标签搜索和标签筛选；新增标签功能不得自行解析分隔符或拼接展示文本 |
| 数字和表达式解析 | `DecimalTextParser` in `Core/Formatting/DecimalTextParser.swift` | Decimal、可选值及 `+ - * / × ÷`、括号表达式，不要自行写金额字符串解析器 |
| 日期格式化 | `AppDateFormatting` helpers in `Core/Formatting/AppDateFormatting.swift` | 跨页面统一日期显示 |
| Markdown 展示 | `MarkdownText`、`MarkdownRenderer`、`MarkdownValueRow` in `Core/UI/MarkdownRendering.swift` | Swift Markdown、容错回退、常见 `$...^...$` 上标归一化和可复制值 |
| 列表和弹窗规范 | `AppListMetrics`（`minimumRowHeight(fontScale:)` 定义接近裸 `LabeledContent` 的紧凑单行内容高度，`listRowHeightFloor(fontScale:)` 加入系统上下边距后作为全局 List/Form 整行地板；`rowVerticalInset(fontScale:)`/`recordContentSpacing(fontScale:)` 用于记录卡片，均随字体缩放）、`AppSwipeActions`、`.appListRowStyle()`、`.appListSpacing()`、`.appTemplateFieldSwipeActions(...)`、`.appSwipeActions(...)`、`.appDeleteSwipeAction(...)`、`.iOSLargeSheet()`、`.iOSAuthenticationSheet()`、`.appReadableContent()` in `Core/UI/ListViewModifiers.swift` | 单行文本、输入、日期、Picker、Badge 和按钮具有统一且接近系统原生的紧凑行高，多行内容按需增高；`.iOSLargeSheet()` 会在新的 Sheet 展示层重新应用列表密度，保证新增/编辑表单不依赖父页面环境继承；同时统一滑动动作、iPhone/iPad/macOS Sheet 和宽屏可读宽度 |
| 隐藏项开关和排序方向 | `HiddenItemsVisibilityButton`、`SortDirection` | 统一显示/隐藏按钮与升降序语义 |
| 页面诊断 | `.diagnosticScreen(...)` | 自动记录页面进入和离开 |
| 详情页/编辑页/新增页统一行 | `AppLabeledContentRow`、`DetailValueRow`、`FieldEditorRow`、`DateFieldRow`、`PickerFieldRow`、`ToggleFieldRow`、`NumericFieldRow` in `Core/UI/FormRowComponents.swift` | Badge、状态、菜单或自定义按钮等任意单行尾部内容使用 `AppLabeledContentRow`；普通值、敏感值和链接使用 `DetailValueRow`；文本、日期、Picker、Toggle、数值输入使用对应编辑组件。所有组件共享同一内容高度，新页面不得再手搓混排的裸 `LabeledContent`/Picker/DatePicker/Toggle；地址、备注、算式预览和记录卡片等真实多行内容可以自适应增高 |

所有可能输入中文或其他组合输入法文本的持久化字段都必须直接使用 `IMESafeTextField` 或 `IMESafeMultilineTextField`，保存动作同时调用 `commitPendingTextInput`。只调用提交函数不能替代安全输入控件；普通 SwiftUI `TextField`、`TextEditor` 仅用于不持久化的搜索或明确不接受组合输入的数值字段。

## 模块内部可复用能力

### 外部数据导入入口规范

- 低频外部数据导入不设置长期可见的独立按钮，避免占用首页或工具栏空间。
- 同一模块同时支持新建和导入时，右上角添加按钮短按保持新建；长按进入“从文件导入”入口。
- “从文件导入”使用二级菜单承载具体来源，例如账单文件、图片识别、Apple 密码 CSV；新增来源时只扩展该二级菜单。
- 不要在分类区域、列表空状态或工具栏增加重复的常驻导入按钮。

以下能力已经实现，但所有权仍属于单个 Feature。可以在该模块内部复用；其他模块需要同类能力时先判断是否应提炼为 Core，不要直接跨 Feature 引用。

| 所有者 | 能力 | 入口 |
| --- | --- | --- |
| Finance | 银行/卡片/子账户 CRUD、账单附件生命周期 | `Features/Finance/Application/FinanceStore.swift` |
| Stocks | 校验式股票、交易和分红增删改，防止任意日期负持仓 | `StockPortfolioEditor.swift` |
| Stocks | 持仓成本、已实现/未实现盈亏、市场与组合分配 | `Stock.swift`、`StockPortfolioAnalytics.swift` |
| Stocks | 交易日和交易时段 | `StockMarketTradingCalendar.swift` |
| Stocks | 报价 Provider 编排、批量优先和多源回退 | `StockQuoteService.swift`、`Infrastructure/Quotes` |
| Stocks | 图表缓存、范围增量合并、采样、多源回退；只为美股保留连续盘前/盘后曲线，A 股和港股竞价阶段不作为扩展时段图表；休市占位点过滤并回退最近有效交易日；看盘页当期数据统一由当前或最近有效交易日的分钟分时汇总，长周期行情图复用独立分时快照；所有长周期图层支持单击选最近行情柱、普通拖动连续选点、长按拖动平移时间窗口与双指缩放 | `StockChartService.swift`、`StockChartSeriesProcessor.swift`、`Infrastructure/Charts` |
| Stocks | MA、布林带、MACD、RSI、KDJ、W%R、CCI、DMI、MTM、TRIX、OBV、MFI、A/D、Chaikin、PSY、ROC；相关多线指标在同一图层叠加，量价指标缺少成交量时不伪造结果 | `StockTechnicalAnalysis.swift` |
| Stocks | V4 版本化投资机会评分：均线/DMI/TRIX 趋势组、MACD/MTM/ROC 动能组、RSI/KDJ/W%R/CCI/MFI/PSY 强弱组、布林位置、成交量/OBV/A·D/Chaikin 资金组与 K 线先组内降相关，再校验技术一致性；基本面覆盖 PE/PB/PEG/PCF/PS/EV/EBITDA/EPS/股息率、ROE/净利率、收入/盈利增长，并以波动回撤和数据覆盖度向中性收缩 | `StockInvestmentScoreModel.swift` |
| Stocks | 基本面 Provider 编排与 24 小时内存缓存；A/港股合并东方财富与 Yahoo，美股使用 Yahoo，手动刷新绕过缓存 | `StockFundamentalService.swift`、`Infrastructure/Fundamentals/StockFundamentalProvider.swift` |
| Stocks | 图表坐标、交易标记、选点和展示降采样 | `Presentation/StockChartPresentation.swift` |
| CurrencyExchange | 换汇记录、汇率提醒与损益展示状态 | `Features/CurrencyExchange/Application/CurrencyExchangeStore.swift`、`Domain/CurrencyExchange.swift` |
| Health | 医疗草稿规范化、费用分配和校验 | `MedicalRecordDraftValidator.swift` |
| Health | 关联记录、机构资料和分类同步 | `HealthRecordSynchronizer.swift` |
| Health | 搜索、年份分组、事件关联和统计快照 | `Presentation/MedicalRecordsPresentation.swift` |
| FoodMap | 中国 34 个省级行政区、城市目录、区县/街道/乡镇等下级行政区和中文地址推断 | `Domain/ChinaAdministrativeDivision.swift` |
| FoodMap | 定位权限、附近地图、候选选中状态、地图搜索/点选和 MapKit 地址回填 | `Presentation/FoodLocationPickerView.swift` |
| FoodMap | Apple/高德/百度/腾讯/Google 地图导航 URL | `Infrastructure/FoodNavigationService.swift` |
| FoodMap | 星级/评论/人均紧凑指标、金额格式化、地图卡片、导航菜单、来源链接、照片缩略图 | `Presentation/FoodMapPresentationSupport.swift` |
| FoodMap | 大众点评单店分享文字、收藏夹店铺字段与单店 URL、iOS 移动端/macOS 桌面端自适应的仅本机 WebKit 会话、MapKit 自动定位和公开封面导入 | `Domain/DianpingImport.swift`、`Presentation/DianpingImportView.swift` |
| Secrets | 秘密分类模板、自定义字段、遮罩和附件状态 | `Domain/Secret.swift`、`Application/SecretStore.swift` |
| Documents | 证照模板、字段输入/展示和显隐、自定义字段、身份证/护照/港澳通行证/驾驶证期限推导（区分年限届满日和前一日规则）、有效期状态、多版本关系与状态、到期提醒、附件角色和数据规范化 | `Domain/CredentialDocument.swift`、`Application/DocumentsStore.swift` |
| Documents | 按证照类型从 Core OCR 结果提取待确认字段候选；确认后更新已有字段并自动创建缺失自定义字段 | `Domain/CredentialOCRParser.swift`、`Presentation/CredentialOCRView.swift` |
| Bills | 账单实体规范化、收支/状态/分类、外部来源和按来源交易号幂等导入 | `Domain/BillRecord.swift`、`Application/BillsStore.swift` |
| Bills | 图片 OCR 金额、日期、商户和支付方式候选；复用 Core OCR 和 `DecimalTextParser` | `Domain/BillOCRParser.swift`、`Presentation/BillOCRImportView.swift` |
| Bills | `com.fjwyz.mytools.bill-exchange` 版本 2 JSON 交换协议、导入校验和导出筛选；微信支付 XLSX、支付宝 CSV 先转换为该协议，银行卡 CSV、OFX 和 ISO 20022 camt.053 作为后续外部适配格式 | `Domain/BillExchange.swift`、`Infrastructure/BillImportAdapters.swift` |
| Bills | 无第三方依赖读取 XLSX ZIP/XML、Excel UTC+08 序列日期，以及 UTF-8/GB18030 CSV 和带引号字段 | `Infrastructure/BillSpreadsheetReader.swift` |
| SportsLottery | 官方赛事目录匹配、按 `leagueId` 分页批量赛果、单场头信息/固定奖金补齐、独立磁盘快照、最近 3 天与未完整场次增量刷新，以及北京时间 10:00/22:00 自动刷新调度 | `Features/SportsLottery/Infrastructure/SportsLotteryService.swift`、`Features/SportsLottery/Application/SportsLotteryRefreshCoordinator.swift` |

## 新业务模块接入清单

新增可关闭业务模块时，按实际能力逐项检查，不适用的项目可以跳过但必须确认过：

1. 在 `ToolModule` 增加 case、标题、图标、颜色、设置标记，在 `ToolModuleCatalog` 声明能力和备份/CloudKit 参与状态，并在 `Config/Shared.xcconfig` 增加独立编译标记。
2. 建立 `Features/<Module>/{Domain,Application,Infrastructure,Presentation}`；没有外部基础设施时可以不创建空目录。
3. 在 `VaultData` 增加持久化字段，并在模块 Store 内持有数据和 CRUD。
4. 在 `AppStore` 创建 Store、注入 `VaultMutationNotifying`、处理加载/快照/恢复；需要启停服务时实现并注册 `ModuleLifecycleParticipant`。
5. 在 `ToolBoxApp` 注入所需 Store，在 `ToolModuleDestination` 增加页面入口。
6. 在 `AppStoreBackupProcessor` 和 `AppStoreBackupMerger` 增加模块裁剪与合并；带附件时扩展附件映射。
7. 在 `CloudSyncEntityKind`、快照构建、远端合并和模块归属中登记实体；验证未编译模块不上传、不合并、不误删远端数据，首页隐藏只停止页面、提醒和专属后台任务，删除功能数据的撤回窗口才临时排除目标模块的 CloudKit 对账。
8. 带附件时登记 CloudKit CKAsset、备份附件和 `StorageUsageService` 的引用集合。
9. 用该模块编译标记包裹整个 Feature 源码及 App 组合引用，并验证完整版、移除该模块版和零业务模块版都能构建；如果产品变体需要“编译但默认隐藏”，在 `Shared.xcconfig` 的 `MYTOOLS_HIDE_*` 中声明对应 `MYTOOLS_DEFAULT_HIDDEN_*` 条件。
10. 将源码和测试同步加入 `MyTools.xcodeproj/project.pbxproj`，不得只在文件系统创建文件。
11. 增加 Store 行为、持久化、备份和 CloudKit 开关隔离回归测试；有外部服务时增加生命周期测试。
12. 模块存在会因类型或状态变化而隐藏的持久化字段时，实现 `ModuleDataCleanupParticipant` 的显式规则；不得扫描首页隐藏或未编译模块，也不得按字段名模糊猜测。
13. 更新本文件的业务模块、Core 能力或模块内部能力条目。

## 已有测试资产

| 范围 | 位置与覆盖 |
| --- | --- |
| App 组合 | `MyToolsTests/AppStore`：提醒规则、备份处理/合并、CloudKit 合并、根 Store、汇率缓存、健康同步 |
| Core OCR | `MyToolsTests/Core/OCRTests.swift`：区域坐标、阅读顺序、图片/PDF 载入和渲染 |
| 模块 Store | `MyToolsTests/Stores/ModuleStoreTests.swift`：金融、秘密、换汇、健康等 Store 行为、模块显隐的本地持久化/编译默认值、开关生命周期和冗余字段清理隔离 |
| 美食地图 | `MyToolsTests/FoodMap/FoodMapTests.swift`：吃过/想吃状态集合、规范化、附件、大众点评单店/收藏夹解析、行政区推断、导航、冗余字段清理、备份和 CloudKit 隔离 |
| 证照 | `MyToolsTests/Documents/DocumentsTests.swift`：证照字段模板与旧字段兼容解码、身份证、护照、港澳通行证和驾驶证期限推导（含两种到期日规则）、OCR 字段提取/应用、版本关系与兼容解码、规范化、冗余字段清理、附件与提醒生命周期、空 Vault 解码、备份和 CloudKit 隔离 |
| 账单 | `MyToolsTests/Bills/BillsTests.swift`：规范化、分析周期、导出预设/自定义区间与来源/分类/收支筛选、OCR 候选、交换协议、重复导入、微信 XLSX、支付宝 GB18030 CSV、真实样本可选集成验证、银行卡待接状态、空 Vault、备份和 CloudKit 隔离 |
| 健康 | `MyToolsTests/Health`：医疗草稿、附件编辑、筛选分组和统计 |
| 股票 | `MyToolsTests/Stocks`：组合编辑、报价、图表、缓存、解析、展示、技术指标和评分 |
| 保密资料 | `MyToolsTests/Secrets/SecretsTests.swift`：Apple 密码 CSV 字段映射、引号/换行解析、旧数据用途兼容、分类模板字段生成和普通模式模板显隐解析；字段模板右滑显隐/改名交互由 Core UI 复用 |
| 体彩开奖 | `MyToolsTests/SportsLottery/SportsLotteryTests.swift`：赛事名称映射、欧冠默认项、赛事偏好增删、比赛分组和时间/场次倒序、自定义比赛顺序、本地快照持久化及 10:00/22:00 刷新时段 |
| 测试替身 | `MyToolsTests/TestSupport`：行情 Fixture、Fake Provider、报价和图表 HTTP Stub |

新增测试前先检查对应目录是否已有 Fake、Stub、Fixture 或构造器可复用。测试数量会变化，不在本文件维护易过期的总数。

## 当前明确限制

- 本地 Vault JSON 已使用 AES-GCM 静态加密（格式 2.0），随机 256 位密钥保存在 Keychain（`WhenUnlockedThisDeviceOnly`，仅本机、不可迁移）；密钥丢失时只能通过 `.mytools` 加密备份恢复。图片与 PDF 附件尚无应用层静态加密，App 沙盒与系统文件保护不能替代该能力。导出的 `.mytools` 备份已加密。
- 管理员密码使用加盐 PBKDF2-HMAC-SHA256（210,000 轮）摘要保存，旧无盐 SHA-256 摘要验证成功后自动迁移；不要在新模块另建密码体系。
- OCR 的设置测试页是临时入口，OCR 本身是可复用 Core 服务；临时页面被移除时不得删除 Core OCR 能力。
- 股票公开行情和图表可能延迟或不可用；已有 Provider 回退与缓存，不要在页面内直接请求第三方接口。
- 股票公开基本面数据可能延迟、缺失或口径不同；评分必须展示来源与覆盖度，缺失值不得按 0 伪造，基本面快照不进入 Vault、备份或 CloudKit。看盘“当期数据”可展示 PE、PB、PEG、PCF、PS、EV/EBITDA、EPS、ROE、股息率、成交额和换手率；接口未直接提供成交额或换手率时只能在具备分钟成交量和市值的前提下显示明确标注的估算值。
- 股票行情图只在活跃交易时段自动刷新对应序列：美股盘前只刷新盘前分时，盘中刷新盘中和 K 线，盘后只刷新盘后分时，A 股/港股只在正式交易时段刷新盘中和 K 线；分时每 30 秒、5 日和 K 线正式交易时段每 60 秒轮询；各市场正式交易时段结束后按交易日去重执行一次完整行情收口，刷新分时、5 日分钟和日线基础序列，重新计算全部技术指标并派生周/月/季/年 K 线，失败后每 5 分钟允许重试。手动刷新忽略交易时段并强制请求所选市场；分时和 5 日显示粒度为 `max(1 分钟, 行情源实际间隔)`，不人为补造缺失分钟；当期数据独立使用分钟分时快照，不随 K 线范围请求。
- 当前仍是单 App Target，编译标记会从产物中移除 Feature 实现，但没有独立 Swift Package 提供模块级 import 访问控制；Feature 间依赖禁令仍需由代码审查和回归构建持续执行。
