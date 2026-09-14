# MyTools 开发指令

更新日期：2026-09-13

本文件记录会影响实现决策的项目约束、授权边界和复用入口。`README.md` 负责产品说明；源码和测试是 API、数据格式及线程行为的最终依据。路径清单以 `git ls-files` 为准，新增或移动文件时同步更新受影响的文档入口。

## 执行顺序与授权边界

1. 按需求列出所需能力，检索本文件和源码/测试中的既有入口。
2. 已有能力直接复用；部分满足时在原职责内扩展。跨模块能力放入 `Core` 或 App 组合层；Feature 不得依赖另一个 Feature 的 Store、View 或具体服务。
3. 只有现有接口确实不满足时才新增实现，并在同一改动中更新入口、测试和文档。
4. 读操作、诊断、构建、测试和工作区内常规编辑属于用户已授权范围。涉及外部写入、发布、发送消息、不可恢复删除或新权限时，先完成可审查的本地结果，再提出一次明确确认。
5. 不把文档摘要当作 API；修改前打开真实源码和相关测试，优先复用已有协议、Fake、Stub 和 Fixture。

## 模型协作行为

- 用户提出“修改、修复、构建、审计”等行动请求时，视为已授权开始工作；先推进可逆、只读和工作区内变更，不能停在复述计划或等待确认。
- 只有当缺失信息会改变结果，或操作涉及外部写入、发布、不可恢复删除或新增权限时才提问。提问前先完成已获授权且能独立完成的工作；确认应针对具体、可审查的结果。
- 后续用户消息是当前任务的增量要求，应保留已完成工作并调整方向。技能或本地指令与用户要求冲突时，用户要求优先；若技能导致暂停或改变方向，说明具体文件、相关原文和适用原因。
- 只在用户或更高层指令允许时委派子代理；获准后，仅对可独立并行且能节省时间或提升质量的工作委派。代理消息和最终答复保持可读。
- 测试按风险和改动范围选择：可逆、低影响文档改动不复制实现写测试；代码改动运行相关测试，只有新失败或未决风险才扩大范围。
- 回复先给结果，再给必要证据。默认使用简洁段落；只有并列或顺序信息确实更易扫描时才使用列表或表格，避免套话和未经请求的警告。

## 不可破坏的产品与数据约束

- `Config/Shared.xcconfig` 中的 `MYTOOLS_COMPILED_FEATURES` 是唯一编译清单。未编译模块不得注册、显示、启动服务、导入导出或参与 CloudKit；其 Vault 数据按不透明载荷原样保留。
- 首页隐藏只控制页面、后台刷新和通知。隐藏模块仍参与 CloudKit；当前加密备份导出/导入只包含已编译且可见模块。删除功能数据的撤回窗口才临时停止目标模块的 CloudKit 对账。
- 模块显隐优先使用本地 `UserDefaults`，无显式值时使用编译默认值；CloudKit 应用偏好优先于编译默认值。`MYTOOLS_DEFAULT_HIDDEN_FEATURES` 只影响新安装或未设置过的首页初始状态。
- “删除功能数据”由设置页提供确认流程：每层确认等待 10 秒，执行后保留 10 秒撤回窗口。撤回期保留附件并暂时排除目标模块同步；过期后删除未被其他模块引用的附件、模块缓存和提醒状态，再恢复对账。最终删除会在启用 iCloud 时同步到同账户其他设备；既有备份不回写。
- “本地缓存”由设置页提供清理流程，并通过 `ModuleLocalDataCacheClearing` 清理可重建数据；不得触碰业务 Vault、附件、提醒或 CloudKit。股票与换汇共享汇率缓存，清理任一模块都要重置共享内存和持久缓存。
- 存储统计分开显示业务 Vault/附件、CloudKit 同步状态、应用缓存和系统 CloudKit 缓存。同步状态、行情/赛果缓存和诊断日志设置 `isExcludedFromBackup`；包含业务档案的 `Application Support/MyTools` 根目录不得排除。系统 CloudKit 缓存只读展示。
- 页面不得直接写 Vault 或附件目录，必须经模块 Store、`SecureStore`、`VaultPersistenceCoordinator` 和 `AttachmentStore`。
- 业务模块按 `Domain / Application / Infrastructure / Presentation` 分层；无真实兼容需求时不添加旧字段或迁移分支，有兼容需求时用解码/迁移测试锁定。

## 复用入口

| 能力 | 入口 | 边界 |
| --- | --- | --- |
| App 启动与生产依赖 | `MyTools/App/Bootstrap/` | 生产绑定集中在 `LiveAppDependencies.swift`；Environment 在 `ToolBoxApp.swift` 注入。 |
| 模块注册、编译裁剪、显隐和顺序 | `App/Modules/ToolModule.swift`、`ToolModuleSettings.swift`、`Config/Shared.xcconfig` | 新模块只在 `ToolModule` 注册；页面目的地同步更新 `ToolModuleDestination`。 |
| 根组合与窄协议 | `App/Composition/AppStore.swift`、`AppStoreDependencies.swift`、`ModuleStoreContracts.swift` | `AppStore` 只组合、加载、快照、持久化、备份和同步，不承载模块 CRUD。 |
| 附件 | `Core/Attachments/AttachmentStore.swift`、`AttachmentEditSession.swift`、`FileAttachment.swift` | 不自行操作附件目录；新增附件模块同步补备份、CloudKit、引用索引和存储测试。 |
| 敏感查看 | `Core/Authentication/AuthManager.swift`、`ProtectedContent.swift`、`Core/UI/FormRowComponents.swift` | 使用系统设备身份验证临时揭示敏感值；当前没有管理员会话或应用自有密码体系。 |
| Vault、备份、CloudKit | `Core/Persistence/`、`Core/Backup/`、`Core/CloudSync/`、`App/Composition/AppStoreBackup*.swift` | CloudKit 使用显式字段白名单；派生缓存、日志、会话和 OCR 临时结果默认不上云。新同步字段同时覆盖快照、upsert、delete、兼容解码测试。 |
| OCR、地图、币种、通知 | `Core/OCR/`、`Core/Location/`、`Core/Currency/`、`Core/Notifications/` | 通用能力在 Core；业务 Parser、提醒计算和页面适配留在所属 Feature。 |
| 输入、格式化和 SwiftUI | `Core/UI/IMETextInput.swift`、`ListViewModifiers.swift`、`FormRowComponents.swift`、`Core/Formatting/` | 持久化中文字段使用 IME 安全输入并保存前提交 marked text；金额使用 `DecimalTextParser`，币种使用 `CurrencyCode`；列表、滑动操作、标签、字体、表单行和 Sheet 复用公共组件。 |
| Feature 规则 | `Features/<Module>/{Domain,Application,Infrastructure,Presentation}` | Feature 间通过 App 组合、Core 或窄协议通信。 |

## 关键业务模块

模块注册以 `ToolModule.swift` 为准，当前包括 Finance、Stocks、CurrencyExchange、Health、FoodMap、Secrets、Documents、Bills、SportsLottery。各模块详细行为在对应 Store、Domain 和 Presentation 文件中维护，不在本文件复制完整产品功能清单。

- Finance：`FinanceStore.swift`、`BankCard.swift`；附件与敏感字段复用 Core。
- Stocks：`StockStore.swift`、`Stock.swift`、`StockPortfolioAnalytics.swift`、`StockChartService.swift`、`StockTechnicalAnalysis.swift`、`PortfolioValueHistory.swift`、`PortfolioChartCanvas.swift`；行情走 Provider 和缓存，页面不得直接请求第三方接口；持仓总价值图按真实日期对齐系列，统一使用市场时区和 Decimal 价值计算，分时与五日支持拖动选点，并可选择人民币合计、单一市场合计或该市场内的单只股票，折线与组合 K 线始终只绘制当前唯一目标。
- CurrencyExchange：`CurrencyExchangeStore.swift`、`CurrencyExchange.swift`；汇率复用 `Core/Currency`。
- Health：`HealthStore.swift`、`HealthRecord.swift`、`MedicalRecordDraftValidator.swift`。
- FoodMap：`FoodMapStore.swift`、`FoodPlace.swift`、`DianpingImport.swift`；地图选点复用 `Core/Location`，导航复用 `FoodNavigationService`。
- Secrets：`SecretStore.swift`、`Secret.swift`、`ApplePasswordImport.swift`。
- Documents：`DocumentsStore.swift`、`CredentialDocument.swift`、`CredentialOCRParser.swift`；证照模板、期限、附件、提醒和 OCR 确认规则属于本模块。
- Bills：`BillsStore.swift`、`BillRecord.swift`、`BillAnalytics.swift`、`BillExchange.swift`；导入适配器位于 `Infrastructure`。
- SportsLottery：`SportsLotteryService.swift`、`SportsLotteryPreferencesStore.swift`、`SportsLotteryRefreshCoordinator.swift`；赛果是独立缓存，赛事偏好才参与应用设置同步。

## 导入、界面与权限规则

- 低频导入不增加常驻按钮；添加按钮短按新建，长按打开导入二级菜单。
- 新增、编辑、删除业务数据由各页面直接提供；敏感值查看使用系统设备身份验证。当前没有管理员模式。
- 持久化中文或组合输入字段必须使用 `IMESafeTextField`/`IMESafeMultilineTextField`，保存时调用 `commitPendingTextInput`。搜索等临时字段可使用普通控件。
- Feature 不直接写 `.swipeActions`、裸金额解析或重复标签解析；使用 Core 公共 modifier 和值对象。

## 新模块接入清单

1. 在 `ToolModule`、`ToolModuleCatalog` 和 `Shared.xcconfig` 声明模块及编译标记。
2. 建立实际需要的分层目录；在 `VaultData`、Store、`AppStore` 和路由中接入。
3. 更新备份裁剪/合并、附件映射、CloudKit entity/快照/合并/删除和模块归属。
4. 用编译标记包裹 Feature 及 App 引用，验证完整、移除该模块和零业务模块构建。
5. 增加 Store、持久化、备份、CloudKit、生命周期和兼容性测试；复用已有 Fake/Stub/Fixture。
6. 更新 README 与本文件受影响的入口；不要维护易过期的测试数量或重复的完整能力表。

## 验证要求

根据改动范围运行相关 Swift 测试和构建；至少检查 `git ls-files` 路径、编译警告/错误、模块裁剪、权限边界和备份/CloudKit 隔离。外部网络服务测试使用 Stub 或可选冒烟测试。修改文档时用 `rg` 检查重复术语、失效路径和冲突语义，并以源码为准修正描述。

## 已知限制

- Vault 使用 AES-GCM 格式 2.0，密钥在 Keychain `WhenUnlockedThisDeviceOnly`；图片/PDF 附件尚无应用层静态加密。
- 敏感查看由 `AuthManager` 统一调用 LocalAuthentication；新模块不得另建认证流程。
- OCR 设置页是临时验证入口，Core OCR 服务独立保留。
- 公开行情、基本面、地图和体育赛果可能延迟或不可用；使用既有 Provider、缓存和错误状态，不伪造缺失数据。
- 当前为单 App Target，没有 Swift Package 提供模块级 import 访问控制；模块边界依靠目录、协议、代码审查和回归构建。
