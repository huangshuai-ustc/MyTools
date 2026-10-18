# 审计进度（2026-10-13，审计阶段已结束）

基线：`main` @ `9ae7073`。审计开始时为 `2662d98` + 13 个未提交文件；审计期间仓库所有者将其提交为 `9ae7073`，内容一致。

状态取值：未开始 / 审计中 / 已完成静态检查 / 已完成动态验证 / 部分完成 / 无法验证。

| # | 模块 | Swift 行数 | 主要入口 | 状态 | 问题数 |
| --- | --- | --- | --- | --- | --- |
| 1 | App（Bootstrap/Composition/Modules/Navigation/Settings） | 6,185 | `AppStore.swift`、`LiveAppDependencies.swift`、`ToolModule.swift` | 已完成动态验证（现有测试 + 复现测试） | 4 |
| 2 | Core/Persistence + Backup | 含于 Core | `SecureStore.swift`、`VaultData.swift`、`VaultBackup.swift` | 已完成动态验证（AUDIT-006 已复现） | 7 |
| 3 | Core/CloudSync | 含于 Core | `CloudKitSyncWorker.swift`、`CloudSyncModels.swift` | 已完成静态检查（未连真实 CloudKit） | 4 |
| 4 | Core 其他（Attachments/Auth/Currency/Diagnostics/Formatting/Location/Notifications/OCR/Storage/UI） | 10,942（Core 合计） | 各子目录 | 已完成动态验证（AUDIT-004、022 已复现） | 3 |
| 5 | Stocks 账本（Domain 交易/成本/资金/估值） | 24,099（Stocks 合计） | `Stock.swift`、`StockPortfolioAnalytics.swift`、`StockCashLedger.swift` | 已完成静态检查（现有测试已运行） | 5 |
| 6 | Stocks 行情/刷新/缓存 | 含于 Stocks | `StockStore.swift`、`StockChartService.swift`、`StockRefreshCoordinator.swift` | 已完成静态检查（未联网） | 7 |
| 7 | Stocks 图表/展示、交易日历 | 含于 Stocks | `StockChartPresentation.swift`、`PortfolioValueHistory.swift` | 已完成动态验证（AUDIT-013 已复现） | 6 |
| 8 | Finance | 6,606 | `FinancialInstitution.swift`、`FinanceStore.swift` | 已完成动态验证（AUDIT-005、020、021 已复现） | 13 |
| 9 | CurrencyExchange | 1,622 | `CurrencyExchange.swift` | 已完成静态检查（无现有测试） | 3 |
| 10 | Health | 3,857 | `HealthRecord.swift`、`HealthStore.swift` | 已完成静态检查 | 2（另含多模块项） |
| 11 | FoodMap | 3,842 | `FoodPlace.swift`、`DianpingImport.swift` | 已完成静态检查（WebKit/DOM 未实机） | 7 |
| 12 | Secrets | 1,943 | `Secret.swift`、`ApplePasswordImport.swift` | 已完成静态检查 | 1（另含多模块项） |
| 13 | Documents | 3,744 | `CredentialDocument.swift` | 已完成静态检查 | 1（另含多模块项） |
| 14 | Bills | 3,917 | `BillRecord.swift`、`BillImportAdapters.swift` | 已完成静态检查（现有测试已运行） | 6 |
| 15 | SportsLottery | 1,541 | `SportsLotteryService.swift` | 已完成静态检查（未联网） | 3 |
| 16 | Partnership | 2,543 | `PartnershipLedger.swift`、`PartnershipStore.swift` | 已完成动态验证（AUDIT-008、009 已复现） | 10 |
| 17 | 构建与测试（MyToolsTests 14,396 行） | — | `xcodebuild` | iOS：已完成动态验证；macOS：无法验证（无签名团队） | 5（含工程配置 2） |
| 18 | Markdown 文档（5 份） | — | README/AGENTS/STOCKS GUIDE/FINANCE_MODEL/scripts | 已完成（5 处事实性修正，需求冲突只登记） | 1 |

问题数按主模块粗略归属，跨模块问题（AUDIT-017、018、069、071、088、089 等）只计一次，以 `AUDIT_ISSUES.md` 为准。

## 方法

- 静态审计：按模块分派只读子代理通读源码，主线程对高风险结论逐条回到源码复核。
- 动态验证：在审计副本 `/tmp/mytools-audit/src` 上，iOS 模拟器 `iPhone 17 Pro` 执行 `build-for-testing` + `test-without-building`。
- 复现测试：`/tmp/mytools-audit/src/MyToolsTests/Audit/AuditReproTests.swift`，9 条，未进入真实工程。

## 测试执行

- r1 全量：523 个，通过 504，失败 19，跳过 0（另有 7 个过时测试在副本中以 `#if false` 屏蔽才能编译，见 AUDIT-001）。
- r2 SecureStoreEncryptionTests 套件复跑：14 个，通过 12，失败 2（Keychain 重试用例复跑通过，判定为时序抖动）。
- r3 审计复现：9 个，9 个按预期失败（即 9 个问题已复现）。

## 剩余任务（需所有者决定）

1. 审阅 `PROJECT_AUDIT_REPORT.md` 与 `AUDIT_ISSUES.md`，对“待确认”问题逐条确认严重程度与处理意向。
2. 裁决报告第 4 节列出的需求冲突（改代码还是改文档）。
3. 决定是否把 AuditReproTests 迁入真实工程（当前只在 /tmp 副本中）。
4. 未覆盖项：macOS target、UI/黑盒自动化、真实网络接口、真实 CloudKit 同步、WebKit 页面结构。
5. 修复阶段需另行授权，本次未修改任何业务代码。

## 修复记录

- 2026-10-14 阶段 0、1：001/002/003/004/006/007/011/012 已修复，见 `AUDIT_ISSUES.md` 顶部处理记录。
- 2026-10-14 阶段 2：005/015/016/020/021/091/092/093 已修复；008/009/036–041（Partnership 已删除）不予处理；010（Bills 未编译）跳过、标记为未验证。股票模块统一为“本地日期与时间一律按北京时间，市场当地时间经 `StockMarketClock` 换算”。iOS 全量测试 476 项：472 通过、4 项为 `withKnownIssue` 预期失败（013×2、022、061），0 失败；macOS 构建通过。
- 2026-10-14 阶段 3：已修复 017/018/019/022/026/027/028/029/030/031/032/033/034/045/058/062/090，部分修复 084/086/088；报告 4.2 的 34 条需求冲突已逐条裁决，裁决与处理结果见报告 4.2，README、AGENTS、FINANCE_MODEL、STOCKS_IMPLEMENTATION_GUIDE 已同步。#19、#26 已在报告中补充说明，待所有者裁决。iOS 全量测试 490 项：487 通过、3 项为 `withKnownIssue` 预期失败（013×2、061），0 失败；macOS 构建通过。Bills、SportsLottery 未编译，其中的改动（诊断挂载）未经构建验证。
- 2026-10-15 阶段 4：已修复 044/057/077/084，088 部分收敛（汇率历史死代码、Health 费用汇总；Documents/Secrets 模板逻辑保留），083 不予处理。Bills 通过临时开启 `MYTOOLS_FEATURE_BILLS` 构建验证，`BillsTests` 16 项通过（其中过时的按 ID 合并断言已按 AUDIT-006 改为整体替换）。iOS 全量测试 494 项：491 通过、3 项为 `withKnownIssue` 预期失败（013×2、061），0 失败；macOS 构建通过。
- 2026-10-15 #19/#26 裁决：AUDIT-061 以代码为准修正 README/FINANCE_MODEL 并移除对应 `withKnownIssue`；AUDIT-060 采用包络近似（日K历史无分钟数据），修复休市日补点与收盘越出高低区间；README（证照 OCR、签名 Team ID）与 AGENTS（体彩刷新、IME 例外）按代码修正。iOS 全量 495 项：493 通过、2 项 `withKnownIssue` 预期失败（AUDIT-013×2）、0 失败；macOS 构建通过。剩余问题的分类与优先级见报告 §11.1。
- 2026-10-15 报告 §11.1 剩余问题：38 项中 35 项已修复（含暂缓的 Bills 010/042/043/074/075 与体彩 046/078/079，临时开启两模块编译验证）；063 默认 1970-01-01；050 只给出建议（需备份格式 3.0），085 维持现状，088 模板编辑器重复保留。035（macOS Release entitlements）需真机验证，043 需真实支付宝样本复核。项目已无 `withKnownIssue`。iOS 默认模块全量 515 项通过；两模块开启后全量 553 项通过；macOS 两种配置均构建通过、无警告。
- 2026-10-15 AUDIT-088：按所有者要求把 Documents/Secrets 模板编辑器与匹配逻辑抽到 `Core/UI/FieldTemplateEditor.swift`，088 已修复；仍未关闭的只剩 050、085。iOS 默认模块全量 516 项通过；两模块开启后全量 554 项通过；macOS 构建通过、无新增警告。
- 2026-10-15 真机诊断包修复（审计范围外）：股票图表缓存 v9 拆分日线/分钟文件、派生数据不落盘、写盘合并；CloudKit 部分失败子错误脱敏记录、可自愈时不提示错误、自动同步不与 `start()` 交叠；Keychain 锁屏 -25308 降为每会话一次 INFO（可访问性保持 `WhenUnlockedThisDeviceOnly`）；-999 取消不记 WARN，行情数据源按 host 熔断退避；系统日志 drain 分块写盘并记录内存变化。iOS 默认模块全量 521 项通过（首轮 1 项 0.7 s 截止时间断言以 0.703 s 超限，单独复跑 3 次及全量复跑均通过，判定为负载抖动）；两模块开启后全量 559 项通过；macOS 构建通过。
