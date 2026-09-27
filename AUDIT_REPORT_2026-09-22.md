# MyTools 代码审计报告

审计日期：2026-09-22  
审计范围：当前工作区内 App、Core、全部业务 Feature 与测试；重点审计 Stocks。  
审计方式：静态阅读、依赖与重复模式检索、完整构建、功能裁剪构建、完整测试及失败用例复跑。审计期间未修改业务源码，工作区原有未提交改动均予保留。

## 1. 执行摘要

项目总体结构是健康的：业务模块采用 `Domain / Application / Infrastructure / Presentation` 分层，Feature 之间没有发现直接 import 或直接依赖另一 Feature 的 Store/View，Vault、附件、备份、CloudKit 和模块生命周期也有统一入口。完整功能、关闭 Stocks、关闭全部业务模块三种配置均能成功 `build-for-testing`，证明编译裁剪的主链路有效。

但当前不能判定为“无风险可发布”。本次确认了 3 项较高优先级问题、6 项中等风险及若干维护性问题。风险主要集中在股票模块的全局状态、并发快照、刷新生命周期，以及新诊断代码的 actor 隔离。完整测试套件还出现一次非确定性失败：`StockPortfolioEditorTests.dividendsCanBeInsertedUpdatedAndDeleted()` 在全量并行运行时失败，单独复跑通过。这不是稳定业务失败，但说明测试或日期全局状态尚未做到完全隔离。

建议顺序：先消除并发不安全和编译告警，再把股票刷新会话改成有所有权的状态模型，然后处理 View 直接联网及性能重复计算，最后拆分超大文件。

## 2. 实际验证结果

### 2.1 构建

应用 Target 的以下三组均成功（exit code 0）：

1. 完整功能：`xcodebuild build-for-testing ... MYTOOLS_COMPILED_FEATURES` 使用项目默认配置。
2. 去除 Stocks：命令行覆盖 `MYTOOLS_ENABLE_STOCKS=` 后执行 App `build`。
3. 零业务模块：命令行清空全部 `MYTOOLS_ENABLE_*` 后执行 App `build`。

这说明 App 源码中没有发现未受编译标记保护的 Stocks 引用，也没有发现 App/Core 对任一业务模块的硬链接泄漏。测试 Target 的股票测试文件本身没有用同一编译标记包裹，因此在关闭 Stocks 后执行 `build-for-testing` 会因测试继续引用已移除类型而失败；这不影响裁剪后的 App 构建，但属于测试工程配置缺口。

三组构建均重复产生 `DiagnosticsView.swift` 的 actor 隔离告警，位置集中在 283–336 行调用 341–357 行的 ZIP 辅助函数。该告警不是第三方依赖噪声，而是项目源码问题。

### 2.2 测试

- 共检索到 431 个 `@Test` 声明。
- 完整 macOS 测试套件真实启动并执行；绝大多数用例通过，最终因 1 个失败返回 exit code 65。
- 失败用例：`StockPortfolioEditorTests.dividendsCanBeInsertedUpdatedAndDeleted()`。
- 相同构建产物、相同用例单独复跑成功（exit code 0）。

判断：当前没有证据表明股息 CRUD 实现必然错误；更可能是并行测试下的日期/日历环境或测试隔离问题。它仍会使 CI 质量门禁不稳定，不能忽略。

## 3. 重点发现

### P1-1：A 股休市快照存在真实数据竞争窗口

证据：`MyTools/Features/Stocks/Infrastructure/AShareHolidayService.swift:29-49`。

`AShareHolidaySnapshot` 声明为 `@unchecked Sendable`，内部字典使用 `nonisolated(unsafe)`；actor 会在 `applyFile` 中原地调用 `snapshot.update(...)`，与此同时主线程及图表后台任务可同步调用 `isMandatedHoliday` 读取同一字典。注释称“发布前修改”，但实际对象在 Service 初始化时就已通过 `shared.snapshot` 对外公开，后续网络刷新仍原地修改，因此注释与实现不一致。

影响：并发读写 Swift Dictionary 属于未定义行为；轻则偶发读到不一致休市表，重则运行时崩溃。交易日历是报价刷新、图表分档和行情状态的公共基础，影响面大。

建议：把快照改为不可变值，每次加载构造新快照后原子替换；或用锁保护读写。不要用 `@unchecked Sendable + nonisolated(unsafe)` 掩盖可变共享状态。增加并发读写压力测试。

### P1-2：诊断包 ZIP 辅助代码违反 actor 隔离，且会阻碍 Swift 6 严格并发

证据：`MyTools/App/Settings/Presentation/DiagnosticsView.swift:265-357`；三种构建均产生相同告警。

`makeZip` 是 `nonisolated`，但 `crc32`、`zipUInt16`、`zipUInt32` 因位于 `View` 类型内部而被推断为 MainActor 隔离，后台同步函数直接调用它们。当前语言模式只告警，严格并发模式会升级为错误。诊断导出的设计目标又明确要求不占用主线程，因此不能简单把整个 ZIP 过程拉回 MainActor。

建议：将纯 ZIP 编码移到独立的非 UI、`Sendable` 工具类型（例如 Core/Diagnostics 的 `DiagnosticZipWriter`），并为 CRC、目录结构和可解压性增加单元测试。

### P1-3：完整测试存在非确定性，股票日期语义未完全隔离

证据：全量运行中 `dividendsCanBeInsertedUpdatedAndDeleted()` 失败，单独复跑通过；实现位于 `StockPortfolioEditor.swift:162-180`，日期标准化位于 `Stock.swift:105-112`。

该测试比较完整 `StockDividend`，而 upsert 会通过 `Calendar.autoupdatingCurrent` 把 `receivedAt` 标准化到本地中午。实现和多项测试都隐式依赖进程当前日历/时区。并行运行时任何环境波动或共享全局状态都可能改变结果。

建议：让标准化函数显式接收 Calendar，生产注入 `.autoupdatingCurrent`，测试注入固定时区；测试应断言持久化后的规范值，而不是依赖创建瞬间恰好已在规范时间。整改后至少连续全量运行 5 次验证稳定性。

### P2-1：股票刷新可见性由全局布尔值管理，页面之间会互相覆盖

证据：`StockRefreshCoordinator.swift:17-88`、`StocksView.swift:380-399`、`StockDetailView.swift:175-177`。

`StockRefreshCoordinator.shared` 只有一个 `isStocksPageVisible` 布尔值。列表页出现时设 true，列表消失设 false；详情页出现又直接设 false。这个接口没有调用者身份或引用计数，无法表达“列表仍在导航栈中、详情正在显示”“多个窗口”“两个 Scene”等状态。页面直接依赖 singleton，也使生命周期测试困难。

影响：导航切换时轮询可能被错误停止或恢复；多窗口下最后一次调用者覆盖其他窗口。当前测试集中没有 `StockRefreshCoordinator` 生命周期测试。

建议：由 App/Scene 组合层注入 coordinator；可见性使用 token/owner 集合或由当前路由统一派生。详情页若应继续刷新，应登记自己的可见会话，而不是把全局值设 false。

### P2-2：异步行情派生结果缺少版本校验

证据：`StockStore.swift:405-566`。

`refreshExtendedHoursPerformance` 与 `refreshSparklines` 在开始时捕获股票快照，任务组结束后直接整体替换字典，只检查 `Task.isCancelled`，没有 generation、股票集合版本或当前 ID 校验。刷新过程中若删除、归档或更改股票，旧任务仍能把已过期 ID 的派生结果写回内存。由于 UI 通常按现有股票 ID 查询，短期多表现为脏缓存而非错误画面，但状态模型不再自洽。

建议：沿用 `PortfolioValueHistoryView` 已有的 generation 模式，或提交结果前与当前 eligible ID 集合求交；股票删除时取消关联刷新任务。

### P2-3：行情刷新使用“忙则丢弃”，没有合并待处理请求

证据：`StockStore.swift:329-373`。

`refreshQuotes` 遇到 `isRefreshingQuotes == true` 立即返回。自动刷新、手动刷新和市场定向刷新共用这个门闩，后到请求不会合并 forced markets，也不会在当前请求结束后补跑。若用户手动刷新恰逢后台刷新，用户操作可能看似完成但没有执行其要求的强制刷新。

建议：用单一刷新 actor/coordinator 合并请求集合；至少记录 pending force/markets，并在当前轮次结束后再执行一次。补充“自动刷新进行中触发手动强刷”的测试。

### P2-4：FoodMap 的 Presentation 直接进行网络下载并落附件

证据：`MyTools/Features/FoodMap/Presentation/DianpingImportView.swift:785-815`。

View 同时负责地图搜索、`URLSession.shared` 图片下载、HTTP 校验、附件保存和 Store upsert，违反现有的 Presentation → Application → Infrastructure 边界，也难以做超时、重试、取消和 Stub 测试。

建议：提取 `DianpingImportCoordinator`/应用服务，注入图片客户端与地点搜索协议；View 只提交候选项并展示进度。附件仍通过 Store/AttachmentStore 保存。

### P2-5：持仓总价值页面重复回放交易历史

证据：`PortfolioValueHistoryView.swift:265-279`。

单只股票结果构建时先读 `currentShares`，再读 `holdingCost`，随后对每个图点调用 `PortfolioValueHistoryBuilder.holdingCost`。其中 `holdingCost` 会走完整 performance 重放；历史较长时，这条路径会重复排序/回放。项目已在其他列表和聚合处改为一次计算 performance 后逐层传递，此处尚未完全遵守同一原则。

建议：加载任务中预先生成持仓 performance/cost timeline 快照，让当前成本和各日期成本复用一次扫描结果；增加长交易历史基准测试。

### P2-6：股票 Domain 默认参数反向依赖 Infrastructure singleton

证据：`StockMarketTradingCalendar.swift:66-101` 及后续同类 API。

交易日历属于 Domain，但默认参数直接引用 `AShareHolidayService.shared.snapshot`（Infrastructure）。虽然调用者可注入测试快照，默认路径仍形成 Domain → Infrastructure 的反向依赖和隐藏全局输入。

建议：Domain 只接收不可变 `TradingHolidayCalendar` 值/协议；生产默认值在 Application/Composition 层组装。这样既修正分层，也可与 P1-1 一起解决。

## 4. 维护性与冗余发现

1. Stocks 约 2.1 万行，是复杂度最高模块。`StockChartPresentation.swift`（约 1741 行）、`StockWatchView.swift`（约 1574 行）、`StockChartCanvas.swift`（约 1488 行）、`StockInvestmentScoreModel.swift`（约 1287 行）已达到高变更冲突区。后两者部分体积来自绘图和模型规则，不能仅凭行数判定错误；但 `StockWatchView` 同时持有服务、异步加载、方向控制、展示与交互状态，适合先提取 ViewModel。
2. `AppStore.swift` 约 1163 行，职责多但主要是组合与 facade；备份处理已拆文件，暂未发现 Feature CRUD 被搬入 AppStore。建议继续按生命周期/持久化/模块 facade 用 extension 文件拆分，降低多人冲突，不必重写架构。
3. Double → Decimal 转换至少有三套：`StockStore`、`StockQuoteService`、`PortfolioValueHistory` 使用 POSIX 字符串转换，而 Yahoo/Eastmoney provider 部分直接 `Decimal(Double)`。金融数据边界语义不统一，建议集中为一个 Core/Stocks 转换函数并明确精度与舍入规则。
4. 多个详情 View 重复使用 `FileManager.default.fileExists` 后再打开附件（Finance、Health、FoodMap、Secrets、Documents）。这不是业务数据直写，但属于重复平台适配，建议形成 AttachmentPresenter/OpenableAttachment 公共入口，以统一缺失文件提示和安全范围。
5. `StockRefreshCoordinator.shared`、`StockChartService.shared`、`StockFundamentalService.shared` 的默认注入较多。服务本身已有协议，是好基础；应由 `LiveAppDependencies` 完成生产绑定，View 不直接选择 singleton。

## 5. 逐功能审计结论

| 功能 | 结论 | 主要证据/风险 |
| --- | --- | --- |
| App 组合、设置、诊断 | 基本合格，1 项高优先级技术债 | 模块裁剪三种构建均通过；AppStore 仍偏大；诊断 ZIP actor 告警需先修。 |
| Stocks | 业务规则覆盖强，但并发与协调层风险最高 | 行情、图表、交易日历、盘前盘后、估值测试丰富；存在休市快照数据竞争、刷新可见性全局布尔、忙时丢请求、异步旧结果回写、重复交易回放及巨型 View。 |
| Partnership | 规则内聚度较好 | Domain/Store 边界清晰；注资、买卖、股息税费、清账、撤销、兼容迁移、Cloud/Backup 有测试。本次未发现跨 Feature 依赖。 |
| Finance | 总体合格 | Store 经统一持久化/附件入口；模块行为测试散落在 ModuleStore/AppStore 测试，独立测试目录不足；附件打开逻辑与其他模块重复。 |
| CurrencyExchange | 总体合格但专项覆盖偏弱 | 共享汇率能力放在 Core，方向正确；主要依靠 ModuleStore/Repository 测试，应补编辑校验、清缓存和提醒生命周期专项测试。 |
| Health | 边界较清晰 | Store 与 synchronizer 已拆分，编辑/展示测试存在；附件打开适配重复。 |
| FoodMap | 存在明确分层问题 | Domain 导入解析有测试，但 Dianping Import View 直接联网、地图检索、保存附件和写 Store，耦合过高。 |
| Secrets | 总体合格 | 敏感认证与附件复用 Core；Store 有备份恢复写保护测试；超大 `SecretVaultView` 增加维护成本，附件打开逻辑重复。 |
| Documents | 规则复杂但测试较完整 | OCR、模板、版本、附件、Cloud/Backup 覆盖较好；Domain 文件较大但主要承载同一证照模型；Presentation 的附件打开重复。 |
| Bills | 内聚度较好 | 导入适配器位于 Infrastructure，分析在 Domain；CSV/XLSX/OCR、分页、Cloud/Backup 有测试，未见跨 Feature 耦合。 |
| SportsLottery | 总体合格 | 网络/缓存位于 Infrastructure，偏好与刷新协调分离；使用 `URLSession.shared` 作为默认实现可接受，但建议继续保留协议注入与离线测试。 |
| Core（持久化、附件、Cloud、备份、格式化） | 架构主干健康 | Feature 大多复用统一入口；需吸收附件打开适配、Decimal 转换和诊断 ZIP 这三类重复横切能力。 |

## 6. 已验证的正向结论

- 未发现 Feature 直接 import 另一 Feature，也未发现直接依赖另一 Feature 的具体 Store/View。
- 模块裁剪可工作：关闭 Stocks 和关闭全部业务模块都能编译。
- 股票的报价一致性、图表区间、交易日历、收盘柱、盘前盘后、估值与 sparkline 已有大量针对性测试；这部分并非“无人约束的巨型模块”。
- Partnership、Documents、Bills 对备份/CloudKit 边界已有明确测试。
- 股票行与聚合多数路径已采用一次 performance 快照的优化方向；发现的问题是少数遗留路径，而不是全模块普遍回放。
- 没有发现页面直接写 Vault 目录的证据；FoodMap 图片最终仍经 Store 保存，问题在于网络与流程编排放错层。

## 7. 建议整改路线

### 第一阶段：正确性与质量门禁

1. 修复 `AShareHolidaySnapshot` 并发模型。
2. 将 ZIP writer 移出 View，消除全部项目源码编译告警。
3. 固定股票日期/日历依赖，连续多次运行全量测试。
4. 为 StockRefreshCoordinator 增加页面/Scene 生命周期测试。

### 第二阶段：股票协调与性能

1. 用 owner/token 或路由派生替代刷新可见性布尔值。
2. 将自动、手动、定向刷新统一到可合并请求的 actor。
3. 给派生行情任务增加 generation 校验与取消。
4. 为 Portfolio History 建立一次扫描的成本时间线。

### 第三阶段：降耦合与拆分

1. 把 Dianping 导入流程移至 Application/Infrastructure。
2. 从 StockWatchView 提取状态与加载协调器；按“行情摘要、图表控制、基本面、评分”拆子视图。
3. 统一 Double/Decimal 边界转换与附件打开能力。
4. 仅做职责拆分，不在同一批次重写已经有充分测试的图表算法。

## 8. 审计边界

本报告基于当前工作区（包含用户已有未提交改动），不是某个干净 Git commit 的审计。未调用真实第三方行情、地图或体育网络服务；外部 Provider 的判断依据为实现与 Stub/解析测试。UI 生命周期问题通过源码状态机审计得出，仍建议用 iOS 真机/模拟器覆盖导航、多窗口、前后台切换。完整测试已真实执行，但只执行一轮全量加一次失败用例复跑，尚不足以量化偶发率。
