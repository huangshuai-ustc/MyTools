# MyTools 开发指令

更新日期：2026-09-23

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
- **读取失败绝不等于空数据。** Vault 存在但解密、解码、版本识别、迁移或完整性校验失败时，必须保留原始字节和当前已验证内存状态，进入显式 degraded/blocked 状态；禁止用 `try? ... ?? 空集合`、默认 `VaultData()` 或空快照吞掉错误，禁止把该状态保存回本地、导出为正常备份或交给 CloudKit 对账。UI 显示“数据无法读取/同步已暂停”，不得伪装成“暂无数据”。
- **CloudKit 只有在本地数据完整加载、迁移和校验成功后才可启动。** 加载状态至少区分 loading、ready、degraded/blocked；只有 ready 能 upsert、delete、生成同步快照或推进同步 token。某模块失败只阻断该模块，不得用空模块覆盖云端；诊断记录失败阶段、schema 版本和原始记录标识，不记录明文敏感内容。
- **缺失不代表删除。** 云端删除只能来自用户/业务明确产生并持久化的 deletion tombstone（实体 ID、操作 ID、时间、来源设备/版本）；“本地未出现”“模块未编译”“解码失败”“迁移失败”“文件暂不可用”均不得推导为删除。批量删除和模块数据清理沿用确认、撤回和审计流程。
- **Schema 演进是持久化改动的必做项。** 新增持久化字段必须明确旧数据的安全默认值或逐版本迁移；无法可靠推导时保留原始记录并阻断该记录/模块写回，不能猜值。字段改名或语义变化优先新增字段并双读过渡，不复用旧字段承载新语义；删除字段前考虑旧设备、降级版本、备份和 CloudKit 中的未知字段。未知/未编译模块载荷继续按不透明数据原样保留。
- **迁移必须事务化。** 按 `Vn → Vn+1` 顺序、幂等执行，在内存迁移后写临时文件，回读并做业务不变量校验，再创建迁移前快照并原子替换正式 Vault；任一步失败都不得覆盖原文件或开放同步。禁止“读出后原地修改正式文件”。
- 业务模块按 `Domain / Application / Infrastructure / Presentation` 分层；无真实兼容需求时不添加臆测性的旧字段或迁移分支，但任何已发布持久化格式的变化都属于真实兼容需求，必须由历史 Fixture 的解码/迁移测试锁定。

## 复用入口

| 能力 | 入口 | 边界 |
| --- | --- | --- |
| App 启动与生产依赖 | `MyTools/App/Bootstrap/` | 生产绑定集中在 `LiveAppDependencies.swift`；Environment 在 `ToolBoxApp.swift` 注入。 |
| 模块注册、编译裁剪、显隐和顺序 | `App/Modules/ToolModule.swift`、`ToolModuleSettings.swift`、`Config/Shared.xcconfig` | 新模块只在 `ToolModule` 注册；页面目的地同步更新 `ToolModuleDestination`。 |
| 根组合与窄协议 | `App/Composition/AppStore.swift`、`AppStoreDependencies.swift`、`ModuleStoreContracts.swift` | `AppStore` 只组合、加载、快照、持久化、备份和同步，不承载模块 CRUD。 |
| 附件 | `Core/Attachments/AttachmentStore.swift`、`AttachmentEditSession.swift`、`FileAttachment.swift` | 不自行操作附件目录；新增附件模块同步补备份、CloudKit、引用索引和存储测试。 |
| 敏感查看 | `Core/Authentication/AuthManager.swift`、`ProtectedContent.swift`、`Core/UI/FormRowComponents.swift` | 使用系统设备身份验证临时揭示敏感值；当前没有管理员会话或应用自有密码体系。 |
| Vault、备份、CloudKit | `Core/Persistence/`、`Core/Backup/`、`Core/CloudSync/`、`App/Composition/AppStoreBackup*.swift` | CloudKit 使用显式字段白名单；派生缓存、日志、会话和 OCR 临时结果默认不上云。新同步字段同时覆盖版本声明、历史解码/迁移、临时文件回读、业务不变量、快照、upsert、显式 tombstone/delete 和“加载失败不启动同步”测试。 |
| OCR、地图、币种、通知 | `Core/OCR/`、`Core/Location/`、`Core/Currency/`、`Core/Notifications/` | 通用能力在 Core；业务 Parser、提醒计算和页面适配留在所属 Feature。 |
| 输入、格式化和 SwiftUI | `Core/UI/IMETextInput.swift`、`ListViewModifiers.swift`、`FormRowComponents.swift`、`Core/Formatting/` | 持久化中文字段使用 IME 安全输入并保存前提交 marked text；金额使用 `DecimalTextParser`，币种使用 `CurrencyCode`；列表、滑动操作、标签、字体、表单行和 Sheet 复用公共组件。 |
| 诊断与卡顿定位 | `Core/Diagnostics/DiagnosticLogger.swift`、`AppHangMonitor.swift`、`AppMemoryMonitor.swift`、`DiagnosticScreenModifier.swift`、`SystemLogCollector.swift`、`AppDiagnosticPayloadCollector.swift`、`DiagnosticFileSupport.swift` | 卡顿探测整条链路不得经过主线程：主队列心跳定时器只刷时间戳，后台定时器读时间戳并直接写日志，达到高档位时 `flushesImmediately` 立刻 `fsync`（2026-09-22 的 `0x8BADF00D` 看门狗崩溃一个字都没留下，就是因为所有日志都由被卡住的主线程发起）。主线程停住时主线程上的任何状态都读不到，定位只能靠 `DiagnosticLogger` 的页面栈，所以新增页面必须挂 `.diagnosticScreen("页面名")`，名字用固定页面名而不是随数据变化的标题。两个监控只在前台运行，进后台必须 `stop()`，否则挂起期间的空档会被误报成一次十几分钟的停顿。内存用 `phys_footprint`（jetsam 判定的那个值），卡顿日志同时带上热状态与低电量模式，避免把降频误判成代码回退。`SystemLogCollector` 用 `OSLogStore(scope: .currentProcessIdentifier)` 每 30 秒增量 drain 本进程统一日志（含系统框架条目）到独立文件，进后台时也抄一次再停；与 `DiagnosticLogger` 保持两份独立文件——后者是精挑的时间线，前者是海量原料，混合会把有用的行淹掉。`AppDiagnosticPayloadCollector` 订阅 MetricKit，把 hang／崩溃／CPU 异常的 `callStackTree` 和指标日报 JSON 落到 `Diagnostics/CallStacks/` 目录，启动时注册一次不随前后台启停（载荷投递时机不定）。目录、文件保护、备份排除和 7 天裁剪统一由 `DiagnosticFileSupport`（`DiagnosticPaths`、`DiagnosticTimestamp`、`DiagnosticLogPruner`）管理，不得在采集器内各自拼路径或各自写文件保护属性。调试页「导出诊断包」将三份产物打成 zip：iOS 用手写 zip（stored 格式）、macOS 用 `ditto`，不引入第三方依赖。 |
| Feature 规则 | `Features/<Module>/{Domain,Application,Infrastructure,Presentation}` | Feature 间通过 App 组合、Core 或窄协议通信。 |

## 关键业务模块

股票 2026-09-24 补充：成本规则改为 移动平均，`StockMovingAverageCostLedger` 是当前持仓与历史成本曲线的共同回放入口，禁止在视图或历史图中复制成本回放算法。`StockPerformanceCache` 缓存派生结果，业务交易格式不变；历史派生缓存以 `moving-average-cost-v2` 失效旧结果。顶部总览计价由 `StockAppearanceSettings.overviewUsesRenminbi` 本机偏好控制，默认市场货币，“全部”固定 CNY；分市场明细始终原币。投资分析入口及看盘页基本面/评分任务已移除，图层按钮直接显示，RSI 位于 K 线后。名称编辑经系统标题菜单进入 IME 安全表单，不使用 iOS 自定义 principal 输入控件。

模块注册以 `ToolModule.swift` 为准，当前包括 Finance、Stocks、CurrencyExchange、Health、FoodMap、Secrets、Documents、Bills、SportsLottery、Partnership。各模块详细行为在对应 Store、Domain 和 Presentation 文件中维护，不在本文件复制完整产品功能清单。

- Partnership：`Features/Partnership/Domain/PartnershipLedger.swift`（可扩展账本类型、统一记录流 `PartnershipRecord`+`kind` 判别器、买卖关联、收益池计算、审计日志、旧三键 JSON 迁移解码）、`Application/PartnershipStore.swift`（注资、买入、卖出、股息税费、清账重投/取回、审计日志、原子导入及资金校验、单步撤销）、`Presentation/PartnershipView.swift` / `PartnershipEditorViews.swift`。产品名为“合伙记账”，默认编译但首页关闭；普通查看和记账不认证，复用 Vault/备份/CloudKit，不依赖 Stocks。账本固定美元计价，不提供币种选择与人民币折算；`PartnershipStockMarket` 仅暴露美股（枚举保留 A 股/港股以备将来）。账户总现金分为可用资金与收益池：买入按当时可用资金比例冻结成本，卖出只把本金返还可用资金、盈利套抽成/补偿后入收益池（默认 5%），股息净额亦入收益池。清账时每位成员就收益池余额选择重投（转入可用资金、抬高其后续买入比例）或取回（流出账户）；历史分配已冻结，重投只影响其后交易。个人取出不得超过当前可用现金。每次新增/撤销/清账追加不可变审计日志（时间+操作+摘要），随账本进备份/CloudKit。`PartnershipBook` 是持久化/CloudKit/备份原子实体；未来跨账户共享需独立设计，不能把当前私有同步称为 Sharing。
- Finance：`FinanceStore.swift`、`BankCard.swift`；附件与敏感字段复用 Core。
- Stocks：`StockStore.swift`、`Stock.swift`、`StockPortfolioAnalytics.swift`、`StockChartService.swift`、`StockTechnicalAnalysis.swift`、`PortfolioValueHistory.swift`、`PortfolioChartCanvas.swift`、`StockSparkline.swift`、`StockSparklineView.swift`、`StocksHomePages.swift`、`StockHomeRows.swift`、`StockPortfolioOverviewRow.swift`；行情走 Provider 和缓存，页面不得直接请求第三方接口；**港股报价源整体延迟约 15 分钟**（实测 2026-09-21 11:30 前后：`qt.gtimg.cn` 时间戳停在 11:15、`hq.sinajs.cn` 停在 11:11，同族分时接口给出 11:31 的当前分钟柱；同一时刻 A 股两个报价源都实时），两个延迟源之间怎么择优都选不出实时价，所以 `StockQuoteService` 收一个只读缓存的 `intradayChart` 闭包（生产实参是 `StockChartService.shared.cachedChart(for:range:.intraday)`，由 `LiveAppDependencies` 注入，不发网络请求），把分时末点当作港股报价的又一个数据源参与同一套「时间戳较新者胜出」比较——**仅 `.hongKong` 走这条路径**，A 股与美股报价本身实时（美股另有 `StockExtendedHoursPerformance` 负责盘前盘后）；采用分时末点时价格、`changePercent` 必须一起替换（`previousClose` 沿用报价源的已结算值，`changePercent` 用 `StockQuoteProviderSupport.percentageChange` 就地重算），只换价格会造出「4.328 却 +0.006」这种自相矛盾的显示，这正是修复前顶部价格取报价链路、涨跌取图表链路的表现；不需要额外的「当天校验」，时间戳比较已经隐含处理（收盘后报价源追上收盘价，隔夜分时缓存自然落选），规则由 `StockQuoteServiceTests` 锁定。因为落点在报价链路，`stock.latestPrice` 本身就是实时的，顶部大字、列表行、组合总览、「当期数据」全部自动同源，`StockActiveQuote` 及下游聚合类型无需新增参数。交易日历集中在 `StockMarketTradingCalendar`：每个市场由 `rules(for:)` 生成一份 `Rules`（市场时区的 `Calendar` + 时段区间 + 交易日谓词），`isOpen`、`session`、`isTradingDay`、`previousTradingDay`、`sessionEnded`、`finalSessionEnded`、`latestCompletedFinalSessionEnd` 全部复用它，每种算法只有一份实现——不得再为某个市场复制一份变体（上一版因为通用算法收的是「是否节假日」闭包而无法表达 A 股的休市表查询，衍生出四个 `aShare*` 副本，A 股调休 bug 就出在其中一份）；谓词问的是**是否开市**而不是是否节假日，周一至周五的判定包含在谓词内部，任何市场都绕不过。A 股交易日只有周一至周五里不休市的那些天，**调休补班日不交易**，`AShareHolidayService` 只消费 holiday-cn 的休市日、`isOffDay == false` 的补班标记在解析时就被丢弃，不得把补班日当成交易日（那会让调休的周末显示「交易中」却永远刷不出数据——行情源那天不发数据）；收盘时刻统一取 `regularRanges.last.end`，不要另写分钟常数；市场时区只有 `StockChartSeriesProcessor.marketTimeZone` 一份。上述规则由 `StockTradingCalendarTests` 锁定，它同时用注入的 `AShareHolidaySnapshot` 覆盖 `isOpen`/`session`/`sessionEnded`/`latestCompletedFinalSessionEnd`；分钟柱按结束时刻标注，收盘集合竞价那一根因此落在收盘时刻本身（A 股 15:00、港股 16:00，午休前的 11:30 与 12:00 同理），`StockChartSeriesProcessor.regularSessionPoints` 必须走 `StockMarketTradingCalendar.regularChartMinuteRanges`（把常规区间右端 +1）把这些定盘柱收进常规时段，否则分时末点、「当期数据」收盘价和持仓总价值走势末点都会停在收盘前一分钟、与报价对不上；美股例外，Yahoo 美股分钟柱按区间起点标注且 16:00 起属于盘后，`regularChartMinuteRanges` 用 `postMarketMinuteRange(for:) == nil` 把它挡在外面，测试夹具里美股常规时段的最后一分钟一律写 15:59；盈亏类金额一律用 `StockValueFormatter.signedMoney` 带正负号，不能只靠颜色表达方向（各市场涨跌配色可配）；持仓总价值图按真实日期对齐系列，统一使用市场时区和 Decimal 价值计算，分时与五日支持拖动选点，并可选择人民币合计、单一市场合计或该市场内的单只股票，折线与组合 K 线始终只绘制当前唯一目标。首页 `StocksView.swift` 只做容器：底部「持仓/看盘」栏用系统 `TabView` + `Tab` 绘制（与 `PartnershipView` 一致，iOS 26 直接得到 Liquid Glass 标签栏），`searchable`、`refreshable`、导航目标和全部生命周期钩子只在 `TabView` 之外挂一次，子页面只描述布局；看盘迷你图由 `StockStore.refreshSparklines()` 从分时缓存派生，只调 `cachedChart`，不得触发网络请求，画哪一段与横坐标域必须来自 `StockSparklineSeries.resolve` 的同一次判定（同一个 `now`）：`resolve` 画的必须是行内报价所属的时段，因此与 `StockActiveQuote` 的回退逐条对齐——盘前只接受与 `now` 同一市场交易日的盘前序列，盘后要求当天盘后与当天盘中同时存在（后者是盘后涨跌的参照），盘中只接受当天的盘中序列且缺数据就留空（旁边的价格是实时的）；行内因缺当天数据回退到常规报价时（`.preMarket` 无当天盘前、`.closed`），`resolve` 也回退到 `pointsOnLatestTradingDay`，但必须通过 `acceptsSettledDay`：只接受当天或 `latestCompletedFinalSessionEnd` 那一天，更早的缓存配不上刚刷新过的报价（A 股午休落在 `.closed`，最近交易日即今天）。扩展时段报价的当天校验在源头：`StockChartPresentation.preMarketPerformance/postMarketPerformance(at:)` 数据不是当天就返回 nil，`StockStore` 里价格字段跟着这对派生值一起放行或一起为 nil，否则行内会出现「昨天的盘前价 + 涨跌 --」。虚线零轴不进 `StockSparklineSeries`：由 `StockWatchlistRow.sparklineBaseline` 用「`StockActiveQuote.price` − `changeAmount`」现算，和色块、涨跌文案共用同一个基准；禁止改回快照的 `previousClose`，盘前零轴是 `StockChartPresentation.intradayPreviousClose(isPreMarketChart:)` 特判出的上一结算收盘，两者差一个交易日。横坐标由 `StockSparklineDomain` 生成（域长 = 本时段全部交易分钟，x 用累计在盘分钟以跳过 A 股午休），`offset` 会夹到 0...1，因此点集与域必须配套，否则折线会塌到边缘。手动刷新与下拉刷新走 `refreshIntradayCharts(for:)` → `refreshQuotes(forceRefresh:)` → `refreshExtendedHoursPerformance()` → `refreshSparklines()`（分时先行，以便 `StockQuoteService` 的港股分时择优拿到本轮数据），`isRefreshingCharts` 与 `isRefreshingQuotes` 一起决定指示器与禁用态。持仓页在没有任何持仓时整个不出现，`TabView` 也随之不建，工具栏条件一律读 `effectivePage` 而不是 `selectedPage`。行内报价统一走 `StockActiveQuote.make(stock:extendedHours:at:)`（定义在 `Domain/StockPortfolioAnalytics.swift`）：价格、涨跌额、涨跌幅必须同时来自常规报价或同时来自 `StockExtendedHoursPerformance`（其 `change` 与 `percent` 由 `StockChartPresentation` 的同一基准派生），扩展时段缺价时整组回退，禁止在视图层用 `previousClose` 另算金额。页面上所有金额都必须经过 `StockHoldingValuation`（市值、昨收市值、当日盈亏、持仓盈亏都由那一份报价派生）：`StockPositionRow`、`StockPortfolioSummary`、`StockConvertedPortfolioSummary`、`StockAllocationSnapshot` 一律接收 `extendedHours: [UUID: StockExtendedHoursPerformance]` 与 `at:` 并转交给它，所以「总览 = 各行之和」是构造上成立的；聚合时禁止直接读 `StockHolding.marketValue`/`todayProfitLoss`/`holdingProfitLoss`/`previousClose`（那几个只看常规报价，美股盘前是 T−1 收盘对 T−2 收盘，会把前一交易日的涨跌标成「当日」）。代价是盘前流动性稀薄时顶部大字会跟着跳，这是刻意接受的取舍。`StockCostAllocationSnapshot` 按成本计算，不需要报价。列表行的移除操作只有一条规则：`hasHistoricalActivity` 为真的股票不给删除（删除会连交易与分红一起抹掉，无撤销且同步到 iCloud），零持仓时给「存档」、还有持仓时连存档也不给（`StockPortfolioEditor.archiving` 只接受零持仓）；纯看盘股票才挂 `appDeleteSwipeAction`。「历史股票」分组同一条规则，所以彻底删除一只误录股票的唯一路径是先在详情页删净它的记录。`StockHolding` 是结构体，`holdingCost`/`realizedProfitLoss`/`marketValue` 这些便利属性每读一次就把该股票的全部交易重排重放一遍，所以**聚合与列表行必须先取一份 `stock.performance()` 并逐层传下去**（`StockHoldingValuation`、`StockPortfolioSummary`、`StockConvertedPortfolioSummary`、`StockAllocationSnapshot`、`StockCostAllocationSnapshot` 都收 `performance:`，详情页与持仓总览各取一份 `metrics()`/`convertedSummary` 快照），禁止在一次 body 里反复读那些属性——2026-09-22 的 scene-update 看门狗崩溃就是这样把主线程喂满 10 秒的。只需要股数/累计买入/首次买入日时走 `sharePosition(asOf:)`，它不排序，列表过滤器（`isArchived`、`hasPurchaseRecord`、`currentShares`）因此是廉价的。
- Stocks 刷新调度补充：前台以 60 秒为唯一自动节拍，报价按 Provider 既有能力批量请求；逐标的分钟图只能由 `StockRefreshCoordinator` → `StockStore.refreshIntradayCharts` 进入，每只股票自动请求 60 秒去重。不同股票和独立 Provider 使用有界高并发获取/解析；同一股票的缓存合并、写盘、版本提交和广播保持有序。实时刷新直接从返回的内存快照并行派生迷你图与盘前盘后数据，冷启动/错过广播才重读本地缓存。成功提交后由 `StockStore.chartCacheUpdate` 携带股票 ID 广播，View、迷你图、盘前盘后派生和持仓价值图不得另建页面轮询或直接触发分钟网络请求。看盘页登记当前市场的股票；持仓页常规盘只登记批量报价，但美股盘前/盘后报价由分钟缓存派生，因此这两个时段还要登记当前美股实际持仓的分钟数据；持仓价值分钟图登记当前目标股票集合。手动刷新复用同一队列和广播并可显式强刷。日 K 是唯一网络 K 线源，周/月/季/年 K 只从本地日 K 聚合；常规盘收盘补齐分时和日 K 后同样发送缓存广播。
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

## 持久化格式变更清单

任何修改 `Codable` 业务模型、Vault/备份结构、CloudKit 字段或实体删除语义的改动，在提交前逐项完成：

1. 标明受影响的 Vault、模块和实体 schema 版本；确认字段属于可安全默认、可迁移推导或必须阻断三类中的哪一类。
2. 保留至少一个修改前真实格式的脱敏 Fixture；测试旧版 → 当前版、当前版往返，以及缺字段、未知字段、单条损坏和不支持的未来版本。
3. 验证迁移前后实体 ID、记录数量、关键金额、关联和附件引用不意外减少；迁移写临时文件并回读成功后才原子替换。
4. 验证解密/解码/迁移/校验任一失败时：正式 Vault 不变、内存不清空、不自动保存、目标模块 CloudKit 不启动、不产生 tombstone/delete、可导出诊断材料。
5. CloudKit 新字段先按可缺省、向后兼容方式上线；字段改名/改语义采用新增字段与双读过渡。删除只消费明确持久化的 tombstone，不从集合差异推断。
6. 对记录数量骤降或无 tombstone 的大规模云端删除增加 fail-closed 防线；命中时暂停目标模块同步并记录诊断，不能自动确认风险操作。

## 新模块接入清单

1. 在 `ToolModule`、`ToolModuleCatalog` 和 `Shared.xcconfig` 声明模块及编译标记。
2. 建立实际需要的分层目录；在 `VaultData`、Store、`AppStore` 和路由中接入。
3. 更新备份裁剪/合并、附件映射、CloudKit entity/快照/合并/删除和模块归属。
4. 用编译标记包裹 Feature 及 App 引用，验证完整、移除该模块和零业务模块构建。
5. 增加 Store、持久化、备份、CloudKit、生命周期和兼容性测试；复用已有 Fake/Stub/Fixture，并覆盖“加载失败不会被当作空数据同步”。
6. 更新 README 与本文件受影响的入口；不要维护易过期的测试数量或重复的完整能力表。

## 验证要求

金融编辑冲突通过编辑开始时的值快照比较保护，不添加持久化版本字段。`FinanceStore.replaceAccount(...expected:expectedCards:)` 校验整个档案草稿，单卡直接编辑用 `updateCard(_:expected:)`；冲突不得标记草稿已保存。附件删除经 `VaultMutationNotifying.scheduleAttachmentRemovalAfterPersistence` 交由 App 层等待持久化并校验全局文件引用；`flush` 有待写入或错误时不得作为删除许可。模板已有数组字段：缺键兼容默认模板、明确空数组保持空，不在 UserDefaults 单独维护同步语义。

股票刷新新增回归入口：`StockChartServiceTests` 覆盖共享请求取消、忽略取消的 Provider 超时和迟到结果不写回；`StockChartDiskStoreTests` 覆盖五日覆盖判定与原始行情内存缓存上限。`AppStoreFacadeTests.swift` 中的 `DiagnosticMaintenanceTests` 使用临时文件验证反复日志裁剪及清理不阻塞主线程，不能用真实用户诊断目录做破坏性测试。

根据改动范围运行相关 Swift 测试和构建；至少检查 `git ls-files` 路径、编译警告/错误、模块裁剪、权限边界和备份/CloudKit 隔离。涉及持久化格式时必须执行上面的持久化格式变更清单，不能只验证最新版 round-trip。外部网络服务测试使用 Stub 或可选冒烟测试。修改文档时用 `rg` 检查重复术语、失效路径和冲突语义，并以源码为准修正描述。

## 已知限制

- Vault 使用 AES-GCM 格式 2.0，密钥在 Keychain `WhenUnlockedThisDeviceOnly`；图片/PDF 附件尚无应用层静态加密。
- 敏感查看由 `AuthManager` 统一调用 LocalAuthentication；新模块不得另建认证流程。
- OCR 设置页是临时验证入口，Core OCR 服务独立保留。
- 公开行情、基本面、地图和体育赛果可能延迟或不可用；使用既有 Provider、缓存和错误状态，不伪造缺失数据。
- 当前为单 App Target，没有 Swift Package 提供模块级 import 访问控制；模块边界依靠目录、协议、代码审查和回归构建。
