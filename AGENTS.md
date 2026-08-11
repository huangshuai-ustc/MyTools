# MyTools 能力目录与开发准则

更新日期：2026-08-11

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

- “我的 > 首页功能”的开关是业务模块顶层边界。关闭模块后，该模块的页面、后台刷新、通知、备份导入导出、CloudKit 上传与远端合并都不得继续参与。
- `Config/Shared.xcconfig` 的 `MYTOOLS_COMPILED_FEATURES` 是唯一编译清单。未编译模块不得注册、显示、启动服务、导入导出或参与 CloudKit；其本地 Vault 数据必须以不透明载荷原样保留，避免精简版本覆盖或清理数据与附件。
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

## 已实现的业务模块

| 模块 | 已实现能力 | 主要入口 | 数据与状态 |
| --- | --- | --- | --- |
| 金融账户 | 境内外银行、支行、子账户、借记卡、信用卡、账单 PDF、筛选搜索排序、敏感字段验证和复制 | `Features/Finance/Presentation/FinanceHomeView.swift` | `FinanceStore`、`BankCard.swift` |
| 股票投资 | A/港/美股、买卖和分红、任意时点持仓校验、成本与盈亏、组合分析、实时行情、历史图表、技术指标、投资机会评分、提醒和涨跌色 | `Features/Stocks/Presentation/StocksView.swift` | `StockStore`、`Stock.swift` |
| 换汇记录 | 双报价口径、理论与实际买入、手续费、人民币损益、筛选分组、中国银行牌价、双向换算和汇率提醒 | `Features/CurrencyExchange/Presentation/CurrencyExchangeView.swift` | `CurrencyExchangeStore`、`CurrencyExchange.swift` |
| 健康档案 | 门诊、急诊、住院、购药、体检轮次、关联复诊、机构资料、费用分配、年度统计、搜索筛选、图片/PDF 附件 | `Features/Health/Presentation/HealthRecordsView.swift` | `HealthStore`、`HealthRecord.swift` |
| 美食地图 | 吃过/想吃/还没吃、店铺、中国省市、详细地址、地图坐标、图片、来源、标签、搜索筛选、总地图和第三方导航 | `Features/FoodMap/Presentation/FoodMapView.swift` | `FoodMapStore`、`FoodPlace.swift` |
| 保密资料 | 六类模板、自定义字段、单行/多行、字段遮罩、标签备注、独立查看认证和管理员编辑 | `Features/Secrets/Presentation/SecretVaultView.swift` | `SecretStore`、`Secret.swift` |
| 证照 | 身份证、护照、港澳通行证、驾驶证、学历/学位/房产证和自定义模板；身份证期限推导、到期提醒、多版本及证照状态、标签、自定义字段、图片/PDF 附件和 OCR 候选确认/字段填充；出生日期仅作为自定义字段，旧版固定值支持无损迁移 | `Features/Documents/Presentation/DocumentsView.swift` | `DocumentsStore`、`CredentialDocument.swift` |
| 账单 | 手工收支记录、图片区域 OCR、金额/日期/商户/支付方式候选、搜索筛选；记录/分析顶层分区与按月、按币种统计，提供收支对比、每日支出、分类、商户和付款方式图表；版本化 JSON 交换协议、导入预览及来源交易号去重；支持微信支付 XLSX 和支付宝 GB18030/UTF-8 CSV，自动跳过导出摘要 | `Features/Bills/Presentation/BillsView.swift` | `BillsStore`、`BillRecord.swift`、`BillAnalytics.swift`、`BillExchange.swift` |

八个模块都登记在 `App/Modules/ToolModule.swift`，持久化数据聚合在 `Core/Persistence/VaultData.swift`。当前八个模块均参与本地 Vault、加密备份和 CloudKit；金融、健康、美食、保密资料和证照拥有附件；股票和换汇共用汇率；股票、换汇和证照拥有提醒。

## App 级模块与组合能力

| 能力与检索词 | 可复用实现 | 使用说明 |
| --- | --- | --- |
| 模块声明、能力元数据、开关边界 | `ToolModule`、`ToolModuleCapability`、`ToolModuleDefinition`、`ToolModuleCatalog` in `App/Modules/ToolModule.swift` | 新模块的唯一注册源；声明本地数据、附件、汇率、行情、图表、通知、备份和 CloudKit 参与情况 |
| 模块显隐、排序、偏好同步 | `ToolModuleSettings` in `App/Modules/ToolModuleSettings.swift` | 首页与设置共用；可见性变化会通知生命周期参与者并触发 CloudKit 偏好同步 |
| 模块启停生命周期 | `ModuleLifecycleParticipant`、`ModuleLifecycleRegistry` in `App/Composition/ModuleStoreContracts.swift` | 后台刷新或共享服务依赖模块开关时实现该协议；当前股票、共享汇率、换汇、健康和证照参与 |
| 模块冗余字段清理 | `ModuleDataCleanupParticipant`、`ModuleDataCleanupRegistry`、`RedundantDataCleanupReport` in `App/Composition/ModuleStoreContracts.swift` | 模块自己声明确定性的扫描和清理规则，设置页只聚合已编译且已开启模块；当前金融、健康、美食和证照参与 |
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
| 附件导入、保存、读取、改名、删除、恢复 | `AttachmentStore` in `Core/Attachments/AttachmentStore.swift` | Security-scoped URL 导入、原子写入、唯一存储名、路径恢复；iOS 写入使用完整文件保护，macOS 依赖 App Sandbox/系统磁盘保护；不要自行操作附件目录 |
| 编辑期提交与回滚 | `AttachmentEditSession` in `Core/Attachments/AttachmentEditSession.swift` | 区分原附件与临时新增附件，取消编辑时回滚，提交后清理被移除文件 |
| 附件预览与分享 | `AttachmentPreview`、`AttachmentPreviewSheet`、`AttachmentShareButton` in `Core/Attachments/AttachmentPresentation.swift` | iOS Quick Look、macOS 系统打开和跨平台分享 |
| 占用与完整性扫描 | `StorageUsageService` in `Core/Storage/StorageUsageService.swift` | Vault/附件/缓存/日志空间统计、缺失附件、孤立附件和清理；业务字段清理使用模块参与者接口，不放入 Core 文件扫描服务 |

附件加入新模块时还必须扩展备份附件映射、CloudKit 附件快照与合并、存储扫描引用集合，并测试模块关闭时附件不参与。

### 认证、权限与敏感展示

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 管理员模式 | `AuthManager` in `Core/Authentication/AuthManager.swift` | 至少 8 位密码、SHA-256 摘要、Keychain 备份密码、生物识别/设备密码、前台会话和后台自动锁定 |
| 管理员认证表单 | `AuthenticationView`、`IdentityVerificationForm` | 密码或系统认证 Sheet，可在成功后执行回调 |
| 统一编辑入口与状态 | `AdminEditAccessButton`、`AdminModeIndicator`、`.adminModeIndicator()` | 进入/退出管理员编辑模式和统一工具栏图标 |
| 敏感内容独立验证 | `SensitiveAccessView` | 只解锁当前查看流程，不进入管理员编辑模式 |
| 遮罩、复制、提示 | `ProtectedContent` 相关 View 与 `.copyableText(...)` in `Core/Authentication/ProtectedContent.swift` | 敏感值显隐、长按复制和跨平台复制反馈 |

新增、编辑、删除业务数据沿用管理员模式；只查看敏感值沿用独立验证，两种权限语义不得混用。

### 本地持久化、备份与 CloudKit

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 全业务持久化聚合 | `VaultData` in `Core/Persistence/VaultData.swift` | 七模块实体与提醒的 Codable 聚合根；未编译模块保留为不透明 JSON |
| 本地 Vault 读写 | `SecureStore` in `Core/Persistence/SecureStore.swift` | `Application Support/MyTools/local-vault.json`、原子替换、文件保护、读取失败时阻止覆盖原文件 |
| 合并和串行保存 | `VaultPersistenceCoordinator` | 合并高频变更、后台串行写入、立即保存和 `flush()` |
| 加密备份格式 | `VaultBackupDocument`、`VaultBackupPayload`、`VaultBackupCrypto` in `Core/Backup/VaultBackup.swift` | `.mytools`、PBKDF2-HMAC-SHA256、AES-GCM、格式 1.0、模块集合 |
| 备份裁剪与附件装配 | `AppStoreBackupProcessor` in `App/Composition/AppStoreBackupProcessor.swift` | 按已开启模块导出/导入、嵌入和恢复附件数据 |
| 增量备份合并 | `AppStoreBackupMerger` in `App/Composition/AppStoreBackupMerger.swift` | 只合并备份包含且当前开启的模块，按记录 ID 更新或追加 |
| CloudKit 快照和编码 | `CloudSyncSnapshotBuilder`、`CloudSyncCoding`、`CloudSyncEntityKind`、`CloudSyncItem` in `Core/CloudSync/CloudSyncModels.swift` | 模块归属、业务 JSON、CKAsset 附件和 App 偏好快照 |
| CloudKit 远端合并 | `CloudSyncMerger`、`CloudSyncChange` | 按实体类型与模块开关应用 upsert/delete，关闭模块的变更忽略 |
| CloudKit 生命周期 | `CloudSyncCoordinator`、`CloudKitSyncWorker` | 私有数据库、自定义 Zone、增量游标、上传/拉取、账户变化和对账 |
| 同步开关与状态 | `CloudSyncPreferences`、`CloudSyncStateStore`、`CloudSyncPreferencesBridge` | 默认关闭、Apple 账户状态、错误、游标、模块顺序/显隐与外观偏好同步 |

本地 Vault 是离线事实源。行情缓存、汇率缓存、诊断日志、认证状态和 OCR 临时结果不进入 Vault、备份或 CloudKit。

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
| 诊断日志 | `DiagnosticLogger` in `Core/Diagnostics/DiagnosticLogger.swift` | 分类/级别、异步缓冲、按日期保留今天与昨天、导出、清除、flush 和稳定错误码 |
| App 外观与字号 | `AppAppearanceMode`、`AppFontSize`、`ToolModuleSettings` | 系统/明/暗外观、Dynamic Type 档位、模块顺序和显隐 |
| 股票涨跌颜色 | `StockAppearanceSettings` in `Features/Stocks/Application/StockAppearanceSettings.swift` | 按 A/港/美市场保存颜色偏好并同步设置变更 |

通知属于跨模块投递能力，但具体提醒规则和计算仍归拥有该业务数据的模块。

### 输入、格式化与通用 SwiftUI

| 能力与检索词 | 可复用实现 | 已提供行为 |
| --- | --- | --- |
| 中文输入法安全输入与提交 | `commitPendingTextInput`、`IMESafeTextField`、`IMESafeMultilineTextField` in `Core/UI/IMETextInput.swift` | 持久化中文字段直接使用安全单行/多行控件，并在保存前结束 marked text；单行控件支持普通文本、ASCII 大写和 URL 键盘模式 |
| 数字和表达式解析 | `DecimalTextParser` in `Core/Formatting/DecimalTextParser.swift` | Decimal、可选值及 `+ - * / × ÷`、括号表达式，不要自行写金额字符串解析器 |
| 日期格式化 | `AppDateFormatting` helpers in `Core/Formatting/AppDateFormatting.swift` | 跨页面统一日期显示 |
| Markdown 展示 | `MarkdownText`、`MarkdownRenderer`、`MarkdownValueRow` in `Core/UI/MarkdownRendering.swift` | Swift Markdown、容错回退、常见 `$...^...$` 上标归一化和可复制值 |
| 列表和弹窗规范 | `AppListMetrics`、`.appListRowStyle()`、`.appListSpacing()`、`.iOSLargeSheet()`、`.iOSAuthenticationSheet()`、`.appReadableContent()` in `Core/UI/ListViewModifiers.swift` | 统一列表密度、iPhone/iPad/macOS Sheet 和宽屏可读宽度 |
| 隐藏项开关和排序方向 | `HiddenItemsVisibilityButton`、`SortDirection` | 统一显示/隐藏按钮与升降序语义 |
| 页面诊断 | `.diagnosticScreen(...)` | 自动记录页面进入和离开 |

所有可能输入中文或其他组合输入法文本的持久化字段都必须直接使用 `IMESafeTextField` 或 `IMESafeMultilineTextField`，保存动作同时调用 `commitPendingTextInput`。只调用提交函数不能替代安全输入控件；普通 SwiftUI `TextField`、`TextEditor` 仅用于不持久化的搜索或明确不接受组合输入的数值字段。

## 模块内部可复用能力

以下能力已经实现，但所有权仍属于单个 Feature。可以在该模块内部复用；其他模块需要同类能力时先判断是否应提炼为 Core，不要直接跨 Feature 引用。

| 所有者 | 能力 | 入口 |
| --- | --- | --- |
| Finance | 银行/卡片/子账户 CRUD、账单附件生命周期 | `Features/Finance/Application/FinanceStore.swift` |
| Stocks | 校验式股票、交易和分红增删改，防止任意日期负持仓 | `StockPortfolioEditor.swift` |
| Stocks | 持仓成本、已实现/未实现盈亏、市场与组合分配 | `Stock.swift`、`StockPortfolioAnalytics.swift` |
| Stocks | 交易日和交易时段 | `StockMarketTradingCalendar.swift` |
| Stocks | 报价 Provider 编排、批量优先和多源回退 | `StockQuoteService.swift`、`Infrastructure/Quotes` |
| Stocks | 图表缓存、范围增量合并、采样、多源回退；休市占位点过滤并回退最近有效交易日 | `StockChartService.swift`、`StockChartSeriesProcessor.swift`、`Infrastructure/Charts` |
| Stocks | MA、布林带、MACD、RSI 等指标 | `StockTechnicalAnalysis.swift` |
| Stocks | 版本化投资机会评分：技术时机、PE/PB/股息率、ROE/净利率、收入/盈利增长、波动回撤，缺失数据按覆盖度向中性收缩 | `StockInvestmentScoreModel.swift` |
| Stocks | 基本面 Provider 编排与 24 小时内存缓存；A/港股合并东方财富与 Yahoo，美股使用 Yahoo，手动刷新绕过缓存 | `StockFundamentalService.swift`、`Infrastructure/Fundamentals/StockFundamentalProvider.swift` |
| Stocks | 图表坐标、交易标记、选点和展示降采样 | `Presentation/StockChartPresentation.swift` |
| CurrencyExchange | 换汇记录、汇率提醒与损益展示状态 | `Features/CurrencyExchange/Application/CurrencyExchangeStore.swift`、`Domain/CurrencyExchange.swift` |
| Health | 医疗草稿规范化、费用分配和校验 | `MedicalRecordDraftValidator.swift` |
| Health | 关联记录、机构资料和分类同步 | `HealthRecordSynchronizer.swift` |
| Health | 搜索、年份分组、事件关联和统计快照 | `Presentation/MedicalRecordsPresentation.swift` |
| FoodMap | 中国 34 个省级行政区、城市目录和中文地址推断 | `Domain/ChinaAdministrativeDivision.swift` |
| FoodMap | 地图搜索、点选和地址回填 | `Presentation/FoodLocationPickerView.swift` |
| FoodMap | Apple/高德/百度/腾讯/Google 地图导航 URL | `Infrastructure/FoodNavigationService.swift` |
| FoodMap | 地图卡片、导航菜单、来源链接、照片缩略图 | `Presentation/FoodMapPresentationSupport.swift` |
| Secrets | 秘密分类模板、自定义字段、遮罩和附件状态 | `Domain/Secret.swift`、`Application/SecretStore.swift` |
| Documents | 证照模板、自定义字段、身份证期限推导、有效期状态、多版本关系与状态、到期提醒、附件角色和数据规范化 | `Domain/CredentialDocument.swift`、`Application/DocumentsStore.swift` |
| Documents | 按证照类型从 Core OCR 结果提取待确认字段候选；确认后更新已有字段并自动创建缺失自定义字段 | `Domain/CredentialOCRParser.swift`、`Presentation/CredentialOCRView.swift` |
| Bills | 账单实体规范化、收支/状态/分类、外部来源和按来源交易号幂等导入 | `Domain/BillRecord.swift`、`Application/BillsStore.swift` |
| Bills | 图片 OCR 金额、日期、商户和支付方式候选；复用 Core OCR 和 `DecimalTextParser` | `Domain/BillOCRParser.swift`、`Presentation/BillOCRImportView.swift` |
| Bills | `com.fjwyz.mytools.bill-exchange` 版本 2 JSON 交换协议、导入校验和 Adapter 注册；微信支付 XLSX、支付宝 CSV 先转换为该协议，银行卡 CSV、OFX 和 ISO 20022 camt.053 作为后续外部适配格式 | `Domain/BillExchange.swift`、`Infrastructure/BillImportAdapters.swift` |
| Bills | 无第三方依赖读取 XLSX ZIP/XML、Excel UTC+08 序列日期，以及 UTF-8/GB18030 CSV 和带引号字段 | `Infrastructure/BillSpreadsheetReader.swift` |

## 新业务模块接入清单

新增可关闭业务模块时，按实际能力逐项检查，不适用的项目可以跳过但必须确认过：

1. 在 `ToolModule` 增加 case、标题、图标、颜色、设置标记，在 `ToolModuleCatalog` 声明能力和备份/CloudKit 参与状态，并在 `Config/Shared.xcconfig` 增加独立编译标记。
2. 建立 `Features/<Module>/{Domain,Application,Infrastructure,Presentation}`；没有外部基础设施时可以不创建空目录。
3. 在 `VaultData` 增加持久化字段，并在模块 Store 内持有数据和 CRUD。
4. 在 `AppStore` 创建 Store、注入 `VaultMutationNotifying`、处理加载/快照/恢复；需要启停服务时实现并注册 `ModuleLifecycleParticipant`。
5. 在 `ToolBoxApp` 注入所需 Store，在 `ToolModuleDestination` 增加页面入口。
6. 在 `AppStoreBackupProcessor` 和 `AppStoreBackupMerger` 增加模块裁剪与合并；带附件时扩展附件映射。
7. 在 `CloudSyncEntityKind`、快照构建、远端合并和模块归属中登记实体；验证关闭模块不上传、不合并、不误删远端数据。
8. 带附件时登记 CloudKit CKAsset、备份附件和 `StorageUsageService` 的引用集合。
9. 用该模块编译标记包裹整个 Feature 源码及 App 组合引用，并验证完整版、移除该模块版和零业务模块版都能构建。
10. 将源码和测试同步加入 `MyTools.xcodeproj/project.pbxproj`，不得只在文件系统创建文件。
11. 增加 Store 行为、持久化、备份和 CloudKit 开关隔离回归测试；有外部服务时增加生命周期测试。
12. 模块存在会因类型或状态变化而隐藏的持久化字段时，实现 `ModuleDataCleanupParticipant` 的显式规则；不得扫描关闭模块或按字段名模糊猜测。
13. 更新本文件的业务模块、Core 能力或模块内部能力条目。

## 已有测试资产

| 范围 | 位置与覆盖 |
| --- | --- |
| App 组合 | `MyToolsTests/AppStore`：提醒规则、备份处理/合并、CloudKit 合并、根 Store、汇率缓存、健康同步 |
| Core OCR | `MyToolsTests/Core/OCRTests.swift`：区域坐标、阅读顺序、图片/PDF 载入和渲染 |
| 模块 Store | `MyToolsTests/Stores/ModuleStoreTests.swift`：金融、秘密、换汇、健康等 Store 行为、开关生命周期和冗余字段清理隔离 |
| 美食地图 | `MyToolsTests/FoodMap/FoodMapTests.swift`：规范化、附件、行政区推断、导航、冗余字段清理、备份和 CloudKit 隔离 |
| 证照 | `MyToolsTests/Documents/DocumentsTests.swift`：身份证期限推导、OCR 字段提取/应用、版本关系与兼容解码、规范化、冗余字段清理、附件与提醒生命周期、空 Vault 解码、备份和 CloudKit 隔离 |
| 账单 | `MyToolsTests/Bills/BillsTests.swift`：规范化、OCR 候选、交换协议、重复导入、微信 XLSX、支付宝 GB18030 CSV、真实样本可选集成验证、银行卡待接状态、空 Vault、备份和 CloudKit 隔离 |
| 健康 | `MyToolsTests/Health`：医疗草稿、附件编辑、筛选分组和统计 |
| 股票 | `MyToolsTests/Stocks`：组合编辑、报价、图表、缓存、解析、展示、技术指标和评分 |
| 测试替身 | `MyToolsTests/TestSupport`：行情 Fixture、Fake Provider、报价和图表 HTTP Stub |

新增测试前先检查对应目录是否已有 Fake、Stub、Fixture 或构造器可复用。测试数量会变化，不在本文件维护易过期的总数。

## 当前明确限制

- 本地 Vault JSON 和附件尚无应用层静态加密；App 沙盒与系统文件保护不能替代该能力。导出的 `.mytools` 备份已加密。
- 管理员密码当前使用无独立盐的 SHA-256 摘要保存；这是已知安全边界，不要在新模块另建密码体系。
- OCR 的设置测试页是临时入口，OCR 本身是可复用 Core 服务；临时页面被移除时不得删除 Core OCR 能力。
- 股票公开行情和图表可能延迟或不可用；已有 Provider 回退与缓存，不要在页面内直接请求第三方接口。
- 股票公开基本面数据可能延迟、缺失或口径不同；评分必须展示来源与覆盖度，缺失值不得按 0 伪造，基本面快照不进入 Vault、备份或 CloudKit。
- 股票收盘补刷按各市场实际最终交易时段去重，不使用固定 12 小时限流；图表服务同样按最终交易时段避免休市重复请求。
- 当前仍是单 App Target，编译标记会从产物中移除 Feature 实现，但没有独立 Swift Package 提供模块级 import 访问控制；Feature 间依赖禁令仍需由代码审查和回归构建持续执行。
