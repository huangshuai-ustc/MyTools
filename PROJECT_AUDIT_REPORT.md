# MyTools（方寸）全项目审计报告

- 基线：`main` @ `9ae7073`（审计开始时为 `2662d98` + 13 个未提交文件，审计期间由仓库所有者提交，内容一致）
- 日期：2026-10-13
- 性质：只做审计。业务代码一行未改，未提交、未推送。问题明细见 `AUDIT_ISSUES.md`，进度见 `AUDIT_PROGRESS.md`。

## 1. 执行摘要

- 共 94 个问题：P0 0、P1 12、P2 41、P3 38、P4 3。验证状态：已复现 11、静态确认 76、疑似风险 7。
- 整体判断：架构分层清晰，加密存储、模块隔离、裁剪构建这些基础设计扎实。风险集中在三处：
  1. 数据安全边界：CloudKit 用集合差推断删除（AUDIT-002）、Vault 不可读时仍能恢复备份（AUDIT-003）、附件文件名可路径穿越（AUDIT-004）、备份导入整模块替换（AUDIT-006）。
  2. 账本口径：美股成交时间跨日提前 24 小时（AUDIT-091）、合伙记账资金不守恒（AUDIT-008/009）、Finance “其他”机构账户被丢弃（AUDIT-005）。
  3. 测试工程：测试 target 当前无法编译（AUDIT-001）；屏蔽 7 个过时测试后，523 个里仍有 19 个失败。
- 文档：修正 2 个文件里的 5 处纯事实性错误，没有改写任何产品需求。另登记 34 组需求与实现的冲突（第 4.2 节），由所有者裁决。

优先处理的 5 个问题：

| 序 | 编号 | 级别 | 摘要 |
| --- | --- | --- | --- |
| 1 | AUDIT-002 | P1 | CloudKit 本地应用失败后，下次 reconcile 会删掉其他设备的云端记录 |
| 2 | AUDIT-003 | P1 | Vault 整体不可读时恢复备份，原密文被覆盖且无快照 |
| 3 | AUDIT-004 | P1 | 附件 storedFileName 未校验，备份或云端数据可写出、删除附件目录外的文件（已复现） |
| 4 | AUDIT-001 | P1 | 测试 target 无法编译，所有回归保护失效（已复现） |
| 5 | AUDIT-091 | P1 | 美股下午到盘后的成交时间被存早 24 小时，交易标记、成本台阶、导出全部错位 |

## 2. 项目概况

- iOS/macOS 26.0，Swift 6.0、SwiftUI，单 App target，无第三方依赖，pbxproj 显式引用文件。
- 体量：Swift 85,381 行，275 个文件；测试 14,396 行。
- 结构：`App`（启动、组合根、模块注册、导航、设置）+ `Core`（持久化、备份、CloudSync、附件、认证、汇率、诊断、格式化、定位、通知、OCR、UI）+ 10 个功能模块（Finance、Stocks、CurrencyExchange、Health、FoodMap、Secrets、Documents、Bills、SportsLottery、Partnership）。每个模块分 Domain / Application / Infrastructure / Presentation 四层。
- 功能开关在 `Config/Shared.xcconfig` 的 `MYTOOLS_FEATURE_*` / `MYTOOLS_HIDE_*`。Bills、FoodMap、SportsLottery、Partnership 默认隐藏。
- 数据：Vault 用 AES-GCM 加密，密钥放钥匙串（ThisDeviceOnly）；备份用 PBKDF2 + AES-GCM；同步用 CKSyncEngine；按模块隔离解码，统一由 `canPersistVault` 把关写盘。

## 3. 审计范围与方法

| 维度 | 覆盖 |
| --- | --- |
| 模块 | 18 个审计单元（App、Core 拆成 3 块、Stocks 拆成 3 块、9 个其他功能模块、构建测试、文档），全部完成静态检查，其中 7 个有动态验证 |
| 白盒 | 8 个只读子代理分模块通读源码；主线程把所有 P1 和多数 P2 回到源码逐条复核 |
| 动态 | 在审计副本 `/tmp/mytools-audit/src` 上，用 iOS 模拟器 iPhone 17 Pro 跑 `build-for-testing` + `test-without-building`，共 3 轮 |
| 复现 | 新增 `MyToolsTests/Audit/AuditReproTests.swift`（9 条，只在副本中），与业务代码隔离，用临时目录和桩数据，不接触真实数据 |
| 黑盒 | 不具备条件：没有 UI 自动化，也不连真实网络或 CloudKit。改为按 README 描述的用户流程，对照代码路径做推演 |
| 文档 | README、AGENTS、STOCKS GUIDE、FINANCE_MODEL、scripts/finance/README 共 5 份，逐段与代码对照 |

覆盖率：源码目录 100% 经过静态阅读（按文件抽读，大文件分段）。WebKit 页面结构、真实接口返回、CloudKit 服务端行为、macOS target 都没有覆盖。

## 4. 文档一致性评估

规则：代码是事实来源，但产品需求不由审计改写。只修正与需求无关的事实错误；其余不一致只登记，由所有者裁决。

### 4.1 本次修改（5 处，2 个文件）

| # | 文件 | 修改 | 依据 |
| --- | --- | --- | --- |
| 1 | README.md:59 | 链接 `docs/FINANCE_MODEL.md` → `FINANCE_MODEL.md` | 文件实际在仓库根目录 |
| 2 | README.md 测试目录树 | Core 描述改为“OCR、Vault 加密存储和排序”；补充 `Fixtures/Finance/`、`SportsLottery/`、`PartnershipTests.swift` | `MyToolsTests/` 实际结构 |
| 3 | README.md 根目录树 | 删掉已不存在的 docs 下两份评审 md（4c78509 删除）、`AUDIT_REPORT_2026-09-22.md`（2662d98 删除）、`ARCHITECTURE_REVIEW.md`（d50accc 删除）；docs 描述改为“营销页、技术支持与隐私政策”；补充 `scripts/finance/` 和 `FINANCE_MODEL.md` | git 历史与目录 |
| 4 | README.md 换汇币种 | 12 种 → 24 种全量列表 | `Core/Currency/CurrencyCode.swift` |
| 5 | scripts/finance/README.md | “# 券商操作回归检查”前补一个空行（Markdown 标题渲染） | 格式 |

AGENTS.md、STOCKS GUIDE、FINANCE_MODEL.md 没有修改。审计生成的 `AUDIT_ISSUES.md`、`AUDIT_PROGRESS.md` 和本报告是新增文件。

### 4.2 需求与实现冲突（2026-10-14 已逐条裁决，见表后“裁决与处理”）

“文档说法”列是摘要，行号以审计时的 `9ae7073` 为准。

| # | 主题 | 文档说法 | 代码现状 | 关联 |
| --- | --- | --- | --- | --- |
| 1 | 备份导入语义 | README：增量合并、按记录 ID 合并 | 按模块整体替换（FINANCE_MODEL.md:21 与代码一致） | AUDIT-006 |
| 2 | 冗余数据清理 | README：可清理金融冗余数据 | `cleanupRedundantData` 为空实现 | AUDIT-021 |
| 3 | 网点坐标兜底 | README 明确禁止回退到默认坐标 | 无坐标时回退天安门 | AUDIT-026 |
| 4 | 多组收款资料 | FINANCE_MODEL.md:10,27：可保存多组 | 一对一，只保留一组 | AUDIT-020 |
| 5 | 删除墓碑与熔断 | README/AGENTS：显式墓碑、记录数骤降熔断 | 只有集合差产生的 isDeleted，无熔断 | AUDIT-002 |
| 6 | 重建 iCloud 数据 | README 列为功能 | 未实现 | — |
| 7 | 汇率使用范围 | README:376 只有股票和换汇使用；AGENTS:64 合伙记账不做人民币折算 | `AppStore.swift:163` 把 partnership 纳入刷新，Partnership 视图读取人民币汇率 | AUDIT-073 |
| 8 | 原地写盘 | README：“原地升级”；AGENTS：禁止原地修改正式文件 | 明文迁移原地写 | AUDIT-031 |
| 9 | 后台保存 | README：进入后台等待保存完成 | 无 beginBackgroundTask | AUDIT-086 |
| 10 | 不可用状态 | AGENTS：不得伪装“暂无数据” | 全局失败后模块页显示为空；体彩失败也显示“暂无数据” | AUDIT-003、078 |
| 11 | 显隐优先级 | AGENTS:28 本地 UserDefaults 优先 | 云端偏好无条件覆盖 | AUDIT-033 |
| 12 | 诊断路径 | AGENTS:53 统一由 DiagnosticPaths 管理 | StorageUsageService 自行拼接 | AUDIT-084 |
| 13 | IME 安全输入 | AGENTS:81 持久化字段用 IMESafeTextField | 部分用 TextEditor/TextField | AUDIT-089 |
| 14 | 附件删除时机 | AGENTS:106 持久化完成后再删 | 多个 Store 立即删除 | AUDIT-017 |
| 15 | Team ID 来源 | README:262 由 Xcode Cloud 或本机签名提供 | pbxproj 写死 6Y8D****** | AUDIT-085 |
| 16 | 证照附件类型 | README：正面、反面、照片页、签证页、扫描件、其他 | 正面、反面、内页、扫描件、其他 | — |
| 17 | 证照 OCR | README：逐项确认 | 默认全选，一键覆盖已填值 | — |
| 18 | 模板字段显隐 | README：字段可单独显示或隐藏 | 详情页强制套用模板设置 | AUDIT-018 |
| 19 | Finance 首页与结构 | README:59-61,66：机构类型多选；不设父子层级；“机构/账户/借记卡/信用卡”四项总览；银行卡可选关联账户 | 单一 kind；有 subaccounts；总览为银行/借记卡/信用卡/子账户；无关联 UI | AUDIT-061 |
| 20 | 券商账户模型 | FINANCE_MODEL.md:11：券商和支付不再复用 FinancialAccount | 仍保留 `FinancialAccount.brokerage` 与 BrokerageAccountFieldsEditor | AUDIT-088 |
| 21 | 附件引用校验 | FINANCE_MODEL.md:23：校验附件引用完整 | validate 未校验 | AUDIT-062 |
| 22 | Stocks 资金页 | README:77,110 描述“资金”标签页 | 只有“持仓”“看盘”两页（`StocksHomePages.swift:9-12`） | — |
| 23 | Stocks 导出格式 | README:84、GUIDE:9 写 CSV | 实际导出 XLSX（`AppearanceSettingsView.swift:155`） | — |
| 24 | 成交时间口径 | README:87 市场当地时间；`Stock.swift:153-155,178-179` 注释“按市场时区解释” | 编辑器与实现按北京时间 | AUDIT-091 |
| 25 | 成本标签与成本线 | README:90 分时只标末段、日 K 及更粗周期连续折线 | 分时与 5 日每段标注；只有日 K 连续，周 K 及以上为台阶 | AUDIT-058 |
| 26 | 组合 K 线 | README:90 汇总开高低收 | 高低为各股包络 | AUDIT-060 |
| 27 | 成本算法 | README:88 移动加权平均（股票）；README:202（合伙） | 合伙记账按买入批次逐笔匹配结转 | — |
| 28 | Stocks 实现指南 | GUIDE：分时先于报价；不用 `.shared`；Double→Decimal 统一入口；基本面缓存在 Application Support；休市时按钮不联网；领域层不访问 `AShareHolidayService.shared`；显式 Calendar（GUIDE:207） | 自动刷新并发；多处 `URLSession.shared`；多处直接转换；基本面只有内存缓存；休市有补刷；日历默认读单例；`transactionIsEffective` 用 `autoupdatingCurrent` | AUDIT-016 |
| 29 | 合伙记账口径 | README:199-207、AGENTS：按可用资金比例冻结成本；不提供币种选择；按除息日批次；指定投资人；撤销均记审计日志；批量导入可整体撤销；取出不得超过可用现金 | 按资本权重分摊；有币种选择与人民币折算；用派息日；首个成员自动为投资人；取消撤回抹掉日志；股息无 operationID；只校验补录日期前余额 | AUDIT-008、009、036～040 |
| 30 | 换汇 | README:117 差额用于分析损耗；README:120“人民币总损耗/总盈利”标题 | 差额从未计算；卡片标题固定为“当前累计损耗”，两个标题只在死代码中 | AUDIT-045 |
| 31 | 体彩 | README:218 未开奖显示“暂无数据”；AGENTS:27 首页隐藏控制后台刷新 | 比分显示“-1:-1”、结果列“暂无”；隐藏时仍自动刷新 | AUDIT-046 |
| 32 | 账单 | README:185-192：显示本月人民币支出；“不计收支”统一映射；自动定位表头；协议含账户、交易号、退款关联；对比文案 | 显示所有币种；含“退款”字样映射为退款；必需表头缺一即报错；accounts 恒空、id 为本地 UUID、relatedTransactionID 恒 nil；文案固定“月度” | AUDIT-010、042、043 |
| 33 | 美食地图 | README:144-148：批量更新带收藏夹来源的店铺；店名和地址匹配；不覆盖标签；MapKit 匹配坐标；单店 URL 自动迁移；选点回填行政区 | 任何点评来源都刷新；店名加城市匹配；追加设施标签并覆盖店名/电话等；优先点评坐标；只迁移 `/shopinfo/`；区县被清空 | AUDIT-047、081 |
| 34 | 诊断挂载 | AGENTS：新增页面必须挂 `.diagnosticScreen` | Bills 只有主页挂载 | AUDIT-089 |

审计时的建议（已被下方裁决取代）：1-5、14、29 关系到数据正确性，优先按需求改代码；15、16、22、23、30-32 中的纯描述项可按代码改文档；其余需逐条判断。

#### 裁决与处理（2026-10-14，阶段 3）

| # | 所有者裁决 | 处理结果 |
| --- | --- | --- |
| 1 | 整体替换 | 阶段 1 已按“所选模块整体替换”实现，README 与导入提示一致（AUDIT-006）。 |
| 2 | 实现 cleanupRedundantData | 阶段 2 已实现，扫描与清理共用同一规则（AUDIT-021）。 |
| 3 | 无坐标时回退手机当前定位 | 删除天安门默认坐标；导航按网点名称搜索，选点地图以当前定位为中心且不预选（AUDIT-026）。README 已同步。 |
| 4 | 一对一，只保留一组 | 2026-10-15 用户要求恢复同账户多套资料，现使用 schema v4 数组模型并兼容旧单套格式（AUDIT-020）。 |
| 5 | 显式墓碑、记录数骤降熔断 | 阶段 1 已实现；熔断阈值为至少 20 条且超过 25%（AUDIT-002）。 |
| 6 | 暂不实现，修正文档 | README 改为“不提供重建操作；服务器端数据区被删除时自动按本机快照重建并上传”（后者即 AUDIT-029）。 |
| 7 | Partnership 已删除 | 汇率刷新已不包含 partnership，无需处理。 |
| 8 | 自行判断 | 选择“快照 → 临时文件 → 解密回读 → 原子替换”，不再原地写正式文件（AUDIT-031）；README 已同步。 |
| 9 | 自行判断 | 进入后台的保存包在 `beginBackgroundTask` 中（AUDIT-086 第 3 项）。 |
| 10 | 不冲突，改描述 | README 说明：档案读取失败弹窗“本地档案读取失败”，模块数据无法解码时显示“此模块的数据暂时无法读取”，不显示成空列表；体彩单场缺失显示“暂无数据”是该场次暂无，获取失败另有弹窗。 |
| 11 | 自行判断 | 只同步显式设置，默认值不上传，空排序忽略（AUDIT-033）；AGENTS.md 已同步。 |
| 12 | 自行判断 | StorageUsageService 改用 `DiagnosticPaths.directoryURL` 并按整个目录统计（AUDIT-084）；AGENTS.md 已同步。 |
| 13 | 维持现状，记录 | 未修改，记录于 AUDIT-089。 |
| 14 | 自行判断 | 附件在 Vault 落盘后再删除（AUDIT-017）。 |
| 15 | 维持现状，记录 | pbxproj 中的 DEVELOPMENT_TEAM（6Y8D******）未改动，记录于 AUDIT-085。 |
| 16 | 以代码为准 | README 改为“正面、反面、内页、扫描件、其他”。 |
| 17 | 维持现状，记录 | 未修改；OCR 默认全选、一键覆盖已填值，与 README“逐项确认”的差异保留。 |
| 18 | 维持现状，记录 | 详情页套用模板显隐的行为不变；另修复了按 kind 回退误改自定义字段的问题（AUDIT-018）。 |
| 19 | 以代码为准（2026-10-15） | 代码未改；README 改为机构类型单选、银行分组内“银行/借记卡/信用卡/子账户”总览、银行归档以卡片为准、券商与支付不归档、银行账户可挂子账户、银行卡关联无编辑入口；FINANCE_MODEL 补充关联与归档规则；测试移除 `withKnownIssue`（AUDIT-061）。 |
| 20 | 券商是金融机构模型的一个实例 | 移除 `FinancialAccount.brokerage` 与 `BrokerageAccountFieldsEditor`；旧数据解码迁移为 `BrokerageAccount`；新建机构按类型进入专属编辑页（AUDIT-088）。FINANCE_MODEL 已同步。 |
| 21 | 应该校验 | validate 增加入金资料引用与附件 ID 唯一性校验，schemaVersion 允许旧版本（AUDIT-062）。 |
| 22 | 以代码为准 | README、AGENTS 删除“资金”页描述；`StockCashFlowRecord` 数据保留但无界面入口。 |
| 23 | 选 CSV 或 XLSX | 保留 XLSX：两张表分开原始记录与派生汇总，股票代码以文本单元格保留前导零，Excel/Numbers 直接打开不需选编码。README、GUIDE 已同步。 |
| 24 | 北京时间 | 阶段 2 已统一为北京时间（AUDIT-091），注释与 README 已同步。 |
| 25 | 重新设计成本线，整体协调 | 分时/5 日：台阶并标注，标签按屏幕宽度去重、末段必留；日K～年K：按每根 K 线成本画连续折线、不标注，长周期不再混用台阶（AUDIT-058）。README 已同步。 |
| 26 | 能画真实 K 线就画，否则包络近似（2026-10-15） | 日K历史没有分钟数据，画不出真实高低，采用包络近似并在 README 注明；补点只在市场交易日进行，并把高低扩到包含实时价（AUDIT-060）。 |
| 27 | Partnership 已删除 | 无需处理。 |
| 28 | 以代码为准 | STOCKS_IMPLEMENTATION_GUIDE 按代码改写：港股刷图时先分时后报价，其余并发；`.shared` 默认参数、Decimal 转换入口、基本面内存缓存、休市补刷、日历默认快照、北京时间日历均写成现状。 |
| 29 | Partnership 已删除 | 无需处理。 |
| 30 | 同一个东西，以代码为准 | README 改为：编辑页并列“理论买入/实际买入”，差额不单独计算；概览标题固定“当前累计损耗”，数值带正负号；缺牌价时显示已知合计与缺价笔数（AUDIT-045）。 |
| 31 | 以代码为准 | README 改为比分“暂无数据”、玩法“暂无”，并注明首页隐藏不停止前台定时刷新（AUDIT-046，SportsLottery 未编译）。 |
| 32 | 记录，暂不调整 | 未修改（AUDIT-010、042、043，Bills 未编译）。 |
| 33 | FoodMap 已删除 | 无需处理。 |
| 34 | 自行判断 | Bills 各页面补 `.diagnosticScreen`；AGENTS 注明未编译模块同样要挂载。Bills 未编译，未经构建验证。 |

#### 补充说明（#19、#26，2026-10-15 已裁决，见上表）

#19 金融首页与结构。README 的描述与代码有四处不同：(1) README 说机构类型可多选，代码里每个机构只有一个 `kind`（银行、券商、支付或其他），决定它用哪种专属资料；(2) README 说“不设父子层级”，代码中银行账户下可以挂子账户（社保、公积金、个人养老金等，`FinancialAccount.subaccounts`）；(3) README 的四项总览是“机构/账户/借记卡/信用卡”，代码首页显示“银行/借记卡/信用卡/子账户”（`FinanceHomeView.swift:190-192`）；(4) 模型里银行卡有 `linkedFinancialAccountIDs`，详情页能按它显示关联卡片，但编辑页没有设置关联的入口，只有删除账户时会解除关联。需要决定的是：以代码为准改 README，还是让代码回到 README 的设计（多选类型、去掉子账户或补上关联编辑）。

#26 组合 K 线。组合 K 线把每只持仓的日 K 按股数折算后相加。开盘和收盘可以直接相加，但最高、最低不行：组合当天的最高价是“同一时刻”各股价值之和的最大值，而代码用的是“各股各自最高价”之和。不同股票往往在不同时间见顶，所以代码画出的最高偏高、最低偏低，K 线影线比真实组合更长（属于上下包络）。另一个小问题：用实时价补“今天”这根 K 线时没有判断今天是否交易日，周末也会多出一根，且只替换收盘、不调整高低，可能出现收盘落在高低区间之外。可选处理：(a) 文档注明“高低为包络近似”，只修补点问题；(b) 用分钟数据逐分钟汇总出真实高低，计算和缓存成本更高，且分钟数据只覆盖最近几天。建议 (a)。


## 5. 架构评估

- 分层：Domain / Application / Infrastructure / Presentation 边界整体清晰；Domain 层基本无 UI 依赖。偏离点：FoodMap 导入编排（AUDIT-088）、Finance 保存规则、Bills 分析计算（AUDIT-044）放在 View 中，均缺测试。
- 组合根：`AppStore` 统一加载、保存、删除、备份、云端应用，是数据安全的单点。好处是 `canPersistVault` 一处把关；问题是若干入口绕过了它（AUDIT-003、011、032）。
- 模块化：功能开关在编译期裁剪，页面路由全部有编译条件包裹，裁剪构建是完整的。模块之间有少量隐性耦合：推送注册只在 Stocks（AUDIT-034），合伙记账依赖汇率刷新（4.2 #7）。
- 数据模型：Vault 按模块隔离解码、未知载荷原样回写，是本项目最有价值的设计。迁移策略不一致：Finance/Health/FoodMap 有兼容解码，CurrencyExchange 去掉了（AUDIT-077），FoodMap 旧枚举无迁移（AUDIT-083）。
- 时间模型：没有统一的“营业日 + 市场时区 + 时钟时间”抽象，Stocks、CurrencyExchange、Documents 各自用设备日历或北京日历，跨时区与跨日问题成簇出现（AUDIT-013、015、016、076、091～094）。这是最值得统一的架构点。
- 同步：CKSyncEngine 接入方式规范，但删除语义靠集合差推断（AUDIT-002），缺少墓碑、熔断和 schema 版本协商（AUDIT-030），与文档承诺差距最大。

## 6. 功能正确性审计

按模块列出 P1/P2，P3/P4 见 `AUDIT_ISSUES.md`。

| 模块 | P1 | P2 | 要点 |
| --- | --- | --- | --- |
| 备份 / Persistence | 003、006 | 027、028、031、050 | 不可读时恢复覆盖原文件；整模块替换；隔离模块恢复后不落盘；一只非法股票整批静默回退 |
| CloudSync | 002 | 029、030 | 集合差删除；zone 重建后无法补全；schemaVersion 只写不读 |
| Core / App | 004、011 | 022、032、033、034、035 | 路径穿越；persist 无加载守卫；金额解析接受“100元”；删除撤回只在内存；云端显隐覆盖本机 |
| Stocks | 091 | 013～016、092、093 | 成交时间跨日 −24h；周六假日误判周五休市；设备时区决定“同一天”；日内负股数 |
| Finance | 005 | 020、021、023～026 | “其他”机构账户丢弃；多组收款资料只留一组；冗余清理空实现；天安门兜底 |
| Partnership | 008、009 | 036～041 | 负收益池可取回导致资金凭空增加（9100→10500）；成员现金可为负（−300）；撤销与审计日志不完整 |
| Secrets / Documents / Health | 007 | 017、018、019 | 锁定态编辑页可见明文；模板显隐误改自定义字段；CSV 重复表头崩溃；附件先删后存 |
| Bills | 010 | 042、043、044 | 本机 JSON 往返产生重复 ID；重复导入覆盖用户补充；分析页重算 |
| CurrencyExchange | — | 045 | 4 个币种永远“待同步” |
| SportsLottery | — | 046 | 隐藏时仍联网刷新 |
| FoodMap | — | 047、048、049 | 城市名未归一导致刷新失败和重复导入；WebView 弱引用失效；非 http 导航强跳登录页 |
| 测试工程 | 001 | 012 | 测试 target 不能编译；屏蔽后 19 个失败 |

已复现的 11 个问题：AUDIT-001、004、005、006、008、009、012、013、020、021、022（其中 9 个由 AuditReproTests 复现，001、012 由构建与全量测试复现）。

## 7. 代码质量评估

- 优点：命名与注释风格统一；金额全部用 `Decimal`；解码普遍 `decodeIfPresent`；无强制解包滥用；并发上大量使用 `@MainActor` 与 actor，Swift 6 严格并发下只有 1 条警告（`StockHomeRows.swift:36`）。
- 主要问题：
  - 测试与实现脱节：schema 3 重构后 7 个测试无法编译、11 个测试断言过时（AUDIT-001、012），说明重构未同步测试，CI 也未拦截。
  - View 层业务逻辑：FoodMap 导入（65 行 `importCandidate`、88 行 `refreshAll`）、Finance 保存规则、Bills 分析统计在 View 中，无法单测。
  - 重复实现：Documents 与 Secrets 两套模板匹配、Health 费用聚合两份、点评 URL 提取两份、两套券商账户编辑器（AUDIT-088）。修一处漏一处的风险已经出现（AUDIT-018 两处同错）。
  - 死代码：`FinanceInstitutionsView`、`FinancialProviderViews.swift`、`ExchangeRateStore.history`、换汇旧标题、`executionInstant` 的 `market` 参数。
  - 魔法字符串：“初始出资”、“大众点评”等用于逻辑判断（AUDIT-073、088）。
- 大文件热点（行数）：`StockChartPresentation.swift` 2,015、`PortfolioChartCanvas.swift` 1,233、`CloudKitSyncWorker.swift` 1,097、`DianpingImportView.swift` 1,082。未做工具化圈复杂度测量。
- 防御性：App target 中没有 `try!`，`fatalError` 只有 `init(coder:)` 一处；崩溃风险主要来自 `Dictionary(uniqueKeysWithValues:)`（AUDIT-019）和整数溢出（AUDIT-074）。

## 8. 性能、安全与稳定性

### 8.1 安全

- 加密：Vault AES-GCM + 钥匙串 ThisDeviceOnly 随机 256 位密钥；写盘走临时文件 → 解密回读比对 → `replaceItemAt`，失败不降级为明文。设计正确。
- 主要风险：
  - 路径穿越（AUDIT-004，已复现）：`storedFileName` 来自备份或 CloudKit，未校验即拼路径，可覆盖、删除或导出附件目录外的沙盒文件。
  - 锁定态明文（AUDIT-007）：Secrets/Documents 编辑页不经验证即显示明文；Finance 的 CVV、登录密码明文编辑（AUDIT-066）。
  - 侧信道泄露（AUDIT-069）：锁定态下搜索命中、按真实姓名排序、列表显示到期日与标签、锁屏通知含持有人姓名。
  - 剪贴板：敏感值未设 `localOnly`/过期（AUDIT-089）。
  - 备份口令：PBKDF2 21 万轮，低于 OWASP 现行建议，且轮数未写入信封（AUDIT-086）。
- 凭据：审计未在源码中发现硬编码密钥或 token；pbxproj 中的 Team ID 只记位置并遮蔽（6Y8D******，AUDIT-085）。日志只记录 ID 与数量。
- 网络：未新增无鉴权服务端点（App 无服务端）。点评注入 JS 为静态字符串，无插值注入面。

### 8.2 稳定性与数据完整性

- 数据丢失路径：AUDIT-002（云端误删）、003（恢复覆盖）、006（导入替换）、011（空库写盘，疑似）、017（附件先删后存）、027（隔离模块恢复不落盘）、032（撤回期被杀）、080（FoodMap 旧快照覆盖，疑似）。
- 崩溃路径：AUDIT-019（CSV 重复表头）、074（XLSX 列号溢出、行号放大内存）。
- 旧数据兼容：AUDIT-077、083 会使整个模块被隔离（原始数据保留，可恢复）。

### 8.3 性能

- 主线程重算：Bills 分析 snapshot 一次 body 数十次（AUDIT-044）；存储设置页全量重算引用索引（AUDIT-084）；FoodMap 列表过滤排序多次重算（AUDIT-089）。
- I/O 放大：分钟数据每次提交整份重编码写盘（AUDIT-057）；同步状态每事件全量重写（AUDIT-086）；备份附件全量入内存并多次 base64/GCM（AUDIT-050）。
- 网络放大：跨市场合并请求升级为全市场强刷（AUDIT-052）；停牌股收盘补刷无上限（AUDIT-056）；体彩隐藏仍刷新（AUDIT-046）。
- 未做 Instruments 实测，以上均为静态判断。

## 9. 测试执行结果

环境：Xcode 26 / iOS 模拟器 iPhone 17 Pro，审计副本 `/tmp/mytools-audit/src`，DerivedData `/tmp/mytools-audit/dd`。

| 轮次 | 范围 | 总数 | 通过 | 失败 | 跳过 | 结果文件 |
| --- | --- | --- | --- | --- | --- | --- |
| r0 | 原始工程 `build-for-testing` | — | — | — | — | 编译失败（EXIT 65），AUDIT-001 |
| r1 | 全量（副本：补 3 处参数、屏蔽 7 个过时测试） | 523 | 504 | 19 | 0 | `r1.xcresult` |
| r2 | SecureStoreEncryptionTests 套件复跑 | 14 | 12 | 2 | 0 | `r2.xcresult` |
| r3 | AuditReproTests | 9 | 0 | 9（均为预期失败，即已复现） | 0 | `r3.xcresult` |

副本中的改动（仅测试代码）：
- 参数补齐：`SecureStoreEncryptionTests:97`（`accounts` → `financialInstitutions`）、`StockChartServiceTests:15,20` 与 `StockChartDiskStoreTests:14`（补 `indicatorPoints: nil`）。
- 以 `#if false` 屏蔽：AppStoreFacadeTests 1 个、AppStoreBackupMergerTests 1 个、ModuleStoreTests 5 个。

r1 的 19 个失败按原因分类：

| 类别 | 数量 | 说明 |
| --- | --- | --- |
| schema 3 后测试过时 | 10 | CloudSyncMergerTests 3、ModuleStoreTests 5、AppStoreBackupProcessorTests 1、SecureStoreEncryptionTests 1；断言仍按旧模型 |
| 需求变更未更新测试 | 1 | `performanceCacheExpiresWhenFutureTransactionBecomesEffective` |
| 依赖真实时钟 | 2 | StockHoldingValuationTests 盘前用例，结果随运行时刻变化 |
| 真实问题、需求冲突或疑似抖动 | 6 | 备份按 ID 合并 2 个（`AppStoreBackupMergerTests`、`BillsTests`，AUDIT-006）、金融冗余清理（AUDIT-021）、归档规则（AUDIT-061）、严格解码口径（AUDIT-089）、Keychain 重试（疑似时序抖动，AUDIT-089） |

未运行：macOS target（无签名团队）、UI 测试（工程无 UI 测试 target）、需要真实网络或 CloudKit 的测试、`BillsTests` 真实样本测试（缺环境变量时直接 return，显示为通过）。

## 10. 问题统计

| 严重程度 | 数量 | 编号 |
| --- | --- | --- |
| P0 致命 | 0 | — |
| P1 严重 | 12 | 001～011、091 |
| P2 中等 | 41 | 012～050、092、093 |
| P3 轻微 | 38 | 051～087、094 |
| P4 建议 | 3 | 088～090 |
| 合计 | 94 | |

| 验证状态 | 数量 |
| --- | --- |
| 已复现 | 11 |
| 静态确认 | 76 |
| 疑似风险 | 7（011、014、035、043、056、079、080） |

按模块（主归属）：Finance 13、Stocks 18（账本 5、行情 7、图表 3、日历 2、组合走势 1）、Partnership 10、备份/Persistence 6、FoodMap 7、Bills 6、App 4、CloudSync 4、Core 3、CurrencyExchange 3、SportsLottery 3、测试与工程 5、Health/Documents/Secrets 8、多模块与文档 4。处理状态全部为“待确认”。

## 11. 修复路线图（审计建议；阶段 0～4 已于 2026-10-14～15 执行）

阶段 0：恢复回归保护（前置）
- AUDIT-001、012：修复测试编译，逐条处理 19 个失败（区分“改测试”与“改代码”，后者需对应问题的裁决）。
- 将 AuditReproTests 迁入真实工程，作为修复的验收用例。

阶段 1：数据安全（P1，建议立即）
- AUDIT-004 文件名白名单 + 目录约束（改动小、收益大，最先做）。
- AUDIT-003、011：`restoreBackup` 与 `persist` 加 `canPersistVault` / 加载完成守卫，恢复前快照原文件。
- AUDIT-002：显式墓碑 + 应用失败不推进 token + 删除数量熔断。
- AUDIT-006：先由所有者裁决“整体替换”还是“按 ID 合并”，再改代码或文档。
- AUDIT-007：编辑前验证身份。

阶段 2：账本正确性（P1/P2）
- AUDIT-091、092、093、016：引入“营业日 + 市场时区 + 时钟时间”统一模型，附数据迁移评估。
- AUDIT-008、009、036～041：Partnership 口径需先与 README 对齐需求。
- AUDIT-005、020、010：Finance 与 Bills 的数据丢失与重复。

阶段 3：P2 其余项与一致性
- AUDIT-017（附件删除时机，多 Store 统一走 `scheduleAttachmentRemovalAfterPersistence`）、018、019、022、027～034、042～049。
- 报告第 4.2 节需求冲突逐条裁决。

阶段 4：P3/P4 与技术债
- 性能项（044、057、084）、兼容解码（077、083）、重复与死代码（088）。
- 执行情况（2026-10-15）：044、057、077、084 已修复；088 删除了无人读取的汇率历史（含旧 UserDefaults 键清理）并合并 Health 费用汇总，Documents/Secrets 模板逻辑按“不单独重构”保留，仍为修复中；083 随 FoodMap 删除不予处理。057 未拆分分钟数据文件（会变更缓存格式），改为合并只含分钟数据变化的写入（最多延迟 5 分钟）并缓存日期解析器。084 的冗余/遗留数据扫描仍在主线程，但每次扫描只算一次。iOS 全量 494 项：491 通过、3 项 `withKnownIssue` 预期失败（013×2、061）、0 失败；macOS 构建通过；临时开启 Bills 编译后 `BillsTests` 16 项通过。

每个阶段完成后跑全量测试，并在 `AUDIT_ISSUES.md` 更新处理状态。

### 11.1 剩余问题与处理结果（2026-10-15）

本节原列出 38 个未关闭问题（待确认 35、修复中 2、未验证 1）及建议。2026-10-15 已按建议逐项处理，结果如下；各条细节见 `AUDIT_ISSUES.md` 的处理记录。

| 原分组 | 编号 | 处理结果 |
| --- | --- | --- |
| 高优先级 | 023、024、025、063、069、086(1)、053 | 已修复。063 按所有者要求：未知开户日期默认 1970-01-01（北京时间），不再写成今天 |
| 中优先级 | 013、014、059、051–056、094(2)(3)、064–068、070、071、076、086(4)(5)(7) | 已修复。013 的 2 条 `withKnownIssue` 已转为正向断言，项目中不再有 `withKnownIssue` |
| 低优先级 | 086(2)(6)、035、087、089 | 已修复。备份格式 2.0（60 万轮写入信封 + AAD，兼容 1.0），主库信封 2.1（AAD，兼容 2.0）；035 需真机验证；089 的 IME 维持现状 |
| 暂缓 | Bills 010、042、043、074、075；体彩 046、078、079 | 已修复。临时开启两模块编译后构建与测试通过，默认构建仍关闭；043 需真实支付宝样本复核 |

仍未关闭：

| 编号 | 状态 | 说明与建议 |
| --- | --- | --- |
| 050 | 待确认 | 未改实现。根治内存峰值需把附件移出 JSON 载荷：附件分块（如 1 MB）逐块 AES-GCM 加密写入流式容器，或导出为目录包（`payload.json` + 逐个加密的附件）。两者都需要备份格式 3.0 与新旧兼容读取，建议在附件规模成为实际问题时再做 |
| 085 | 待确认 | 按裁决维持现状 |

088 已修复（2026-10-15，所有者要求）：Documents/Secrets 的模板编辑器与匹配逻辑统一到 `Core/UI/FieldTemplateEditor.swift`（`FieldTemplateEditorView`、`FieldTemplateMatching`），两模块只提供字段一致性实现；此前已删除 `FinanceInstitutionsView` 与 `FinancialProviderViews.swift`。收敛后 iOS 默认模块全量 516 项、两模块开启 554 项通过。

验证：iOS 默认模块全量 515 项通过；开启 Bills 与体彩后全量 553 项通过；macOS 默认与两模块开启均构建通过、无警告。

文档：README 与 AGENTS.md 已同步本轮行为变化（备份/主库格式版本、体彩隐藏后停止刷新与失败隔离）；此前写入 AGENTS 的“体彩刷新例外”已删除。AGENTS.md 与 FINANCE_MODEL 中“编辑使用打开时快照”的要求保持不变，代码已按其修正（024）。

## 12. 保留建议（值得保留的设计）

- Vault 按模块隔离解码，未知与被隔离载荷原样回写；`opaqueAttachmentStoredFileNames` 覆盖隔离模块、未知载荷和未编译模块的附件引用。
- 写盘流程：临时文件 → 解密回读比对 → `replaceItemAt`，失败不降级明文；钥匙串临时不可用时退避重试并保留待写快照。
- `canPersistVault` 统一把关保存、导出与同步；备份严格解码，导出拒绝被隔离模块。
- 编译期功能开关 + 页面路由全量条件编译，裁剪构建完整。
- 打开时快照做冲突检测（Finance 券商、卡片）；附件编辑会话支持回滚。
- 金额统一 `Decimal`；导航 URL 统一 `URLComponents` 编码；点评注入脚本为静态字符串。
- AppHangMonitor 心跳加锁并在后台检测；诊断日志只记 ID 与错误码。
- 通知批量替换按前缀串行并用令牌防旧任务覆盖；IME 输入在 marked text 期间不提交。

## 13. 未解决疑问与未验证事项

未覆盖：
- macOS target：缺签名团队，未构建、未运行；AUDIT-035（entitlements）为疑似。
- UI / 黑盒自动化：工程无 UI 测试 target，用户流程只做了代码路径推演。
- 真实网络：行情、汇率、体彩、点评接口均未联网，返回格式相关结论（AUDIT-054、079 等）基于代码推断。
- CloudKit：未连真实容器，AUDIT-002、029、030 为静态确认，未做多设备复现。
- WebKit / DOM：点评页面结构未实机验证（AUDIT-048、049、082 中的 DOM 部分）。
- 性能：未用 Instruments 实测。

需所有者确认的疑问：
1. 备份导入应为“整体替换”（FINANCE_MODEL.md:21、当前代码）还是“按 ID 增量合并”（README）？决定 AUDIT-006 是代码缺陷还是文档错误。
2. 股票成交时间应按北京时间还是市场当地时间录入（AUDIT-091，README:87 与 UI 文案冲突）？已存数据如何迁移？
3. 合伙记账的成本分摊口径（资本权重还是可用资金比例）、是否保留币种选择。
4. AUDIT-011 是否存在实际触发路径（加载期间的变更来源）未找到，需结合运行日志确认。
5. 是否有用户持有 `notTried`（FoodMap）或旧换汇枚举的数据（AUDIT-077、083 的实际影响面）。

过程说明：
- 审计期间仓库所有者提交了 `9ae7073`，内容与审计开始时的工作区一致；审计未执行任何 git 写操作。
- 一个只读子代理违规在 `/tmp` 创建了 3 个临时文件（`audit_git.txt`、`audit_pbx_all.txt`、`audit_gittest.txt`，内容为文件列表），已检查并删除，未接触项目目录。
- 复现测试与副本测试补丁只存在于 `/tmp/mytools-audit/src`，真实工程的 `MyToolsTests/` 未改动。

## 14. 最终结论

项目的基础设施设计（加密存储、模块隔离、裁剪构建、冲突快照）质量较高，日常使用路径大多正确。但当前不宜在缺少回归保护的情况下继续迭代：测试 target 无法编译（AUDIT-001），而 12 个 P1 中有 4 个直接关系到数据丢失或越界写入（AUDIT-002、003、004、006），1 个使美股交易时间系统性错位（AUDIT-091），2 个使合伙记账资金不守恒（AUDIT-008、009）。

建议顺序：先恢复测试并迁入复现用例（阶段 0），再处理数据安全类 P1（阶段 1），然后统一时间模型与账本口径（阶段 2）。第 4.2 节的 34 条需求冲突需所有者先裁决，再决定改代码还是改文档。

本次审计到此结束，未进入修复阶段。
