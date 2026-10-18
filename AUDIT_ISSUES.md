# 审计问题清单（AUDIT_ISSUES）

- 基线：`main` @ `9ae7073`（审计开始时为 `2662d98` + 13 个未提交文件，审计期间由仓库所有者提交为 `9ae7073`，内容一致）。
- 审计日期：2026-10-13。审计阶段只读，未修改任何业务代码。
- 编号稳定：AUDIT-001 起，后续增删只追加，不重排。
- 严重程度：P0 致命 / P1 严重 / P2 中等 / P3 轻微 / P4 建议。
- 验证状态：已复现 / 静态确认 / 疑似风险 / 未验证 / 测试通过。
- 处理状态：待确认 / 待修复 / 修复中 / 已修复 / 已验证 / 不予处理。
- 2026-10-14 处理记录：阶段 0、阶段 1 已修复（001/002/003/004/006/007/011/012），全量测试 468 项通过、7 项为 `withKnownIssue` 已知问题；复现用例已迁入 `MyToolsTests/Audit/AuditReproTests.swift`。AUDIT-006 裁决为“所选模块整体替换”，已同步 README、导入提示与测试。美食地图、合伙记账实现已删除，其专属问题标记为“不予处理”；收支账单、体彩开奖仅关闭编译，相关问题保持“待确认”。
- 2026-10-14 阶段 2 处理记录：已修复 005/015/016/020/021/091/092/093；股票模块统一为“本地日期与时间一律按北京时间，市场当地时间经 `StockMarketClock` 换算”，同时消除了 AUDIT-094 第 1 项（分红在现金账本与收益回放中统一按北京日期生效）。Partnership 专属问题（008/009/036–041）不予处理；AUDIT-010 所在的 Bills 未编译，本阶段跳过、标记为未验证。存储与数据页的扫描新增“遗留数据”（已删除或关闭模块的不透明数据、隔离/无法识别的载荷），并逐条列出冗余字段、无效附件与孤立附件文件。
- 2026-10-14 阶段 3 处理记录：已修复 017/018/019/022/026/027/028/029/030/031/032/033/034/045/058/062/090，部分修复 084/086/088（剩余项见各条处理记录）；报告 4.2 的 34 条需求冲突已逐条裁决并同步文档。按裁决维持现状并记录：4.2 #13（IME，AUDIT-089）、#15（Team ID，AUDIT-085）、#17（证照 OCR）、#18（模板显隐，AUDIT-018）、#32（账单）；#19（AUDIT-061）与 #26（AUDIT-060）待所有者看过补充说明后再裁决。
- 2026-10-15 阶段 4 处理记录：已修复 044/057/077/084；088 收敛了汇率历史死代码与 Health 费用汇总的重复实现，Documents/Secrets 模板逻辑按“不单独重构”保留，状态维持修复中；083（FoodMap 已删除）不予处理。Bills 默认不编译，044 通过临时开启 `MYTOOLS_FEATURE_BILLS` 构建验证，同时把 `BillsTests` 中按 ID 合并的过时断言改为 AUDIT-006 的整体替换口径。
- 2026-10-15 #19/#26 裁决处理记录：AUDIT-061 以代码为准修正 README 与 FINANCE_MODEL，移除对应 `withKnownIssue`；AUDIT-060 采用包络近似（日K历史没有分钟数据，画不出真实高低），并修复休市日补点与收盘越出高低区间。README 证照 OCR（#17 维持现状）与签名 Team ID（#15）描述按代码修正，AGENTS.md 注明体彩刷新（046）与 IME（089）的现有例外。iOS 全量 495 项：493 通过、2 项 `withKnownIssue` 预期失败（AUDIT-013×2）、0 失败。剩余问题的分类与优先级见报告第 11 节“剩余问题与建议”。
- 2026-10-15 剩余问题处理记录：按报告 11.1 处理全部生效项。已修复 010/013/014/023/024/025/035/042/043/046/051–056/059/063–071/074–076/078/079/086/087/089/094；063 按所有者要求默认 1970-01-01。暂缓的 Bills（010/042/043/074/075）与体彩（046/078/079）临时开启 `MYTOOLS_FEATURE_BILLS`、`MYTOOLS_FEATURE_SPORTS_LOTTERY` 构建并测试，默认构建仍关闭两模块。仍未关闭：050 只给出建议（需备份格式 3.0）；085 维持现状；088 模板编辑器重复保留。需真机或真实样本复核：035（macOS Release 签名）、043（支付宝退款配对）。项目已无 `withKnownIssue`。iOS 默认模块全量 515 项通过；两模块开启后全量 553 项通过；macOS 默认与两模块开启均构建通过、无警告。
- 2026-10-15 AUDIT-088 处理记录：按所有者要求把 Documents/Secrets 两套几乎相同的模板编辑器与匹配逻辑抽到 `Core/UI/FieldTemplateEditor.swift`，088 改为已修复；仍未关闭的只剩 050（只给建议）与 085（维持现状）。iOS 默认模块全量 516 项通过；两模块开启后全量 554 项通过；macOS 构建通过、无新增警告。
- 复现测试位于审计副本 `/tmp/mytools-audit/src/MyToolsTests/Audit/AuditReproTests.swift`（未进入真实工程），结果 `/tmp/mytools-audit/r3.xcresult`。
- 路径省略前缀 `MyTools/`；`Features/` 下的路径写作 `模块/...`。

## 一、汇总表

| 编号 | 严重程度 | 模块 | 问题摘要 | 验证状态 | 处理状态 |
| --- | --- | --- | --- | --- | --- |
| AUDIT-001 | P1 | 测试工程 | 测试 target 无法编译（7 处测试相对当前 API 过时） | 已复现 | 已修复 |
| AUDIT-002 | P1 | CloudSync | 用集合差推断删除，本地应用失败会删除云端其他设备数据 | 静态确认 | 已修复 |
| AUDIT-003 | P1 | 备份/Persistence | Vault 整体不可读时仍允许恢复备份，原密文被覆盖 | 静态确认 | 已修复 |
| AUDIT-004 | P1 | Core/Attachments | 附件 storedFileName 未校验，可路径穿越写出附件目录 | 已复现 | 已修复 |
| AUDIT-005 | P1 | Finance | “其他”类机构写入的账户被静默丢弃 | 已复现 | 已修复 |
| AUDIT-006 | P1 | 备份 | 导入按模块整体替换，仅本地存在的记录丢失（与 README“增量合并”冲突） | 已复现 | 已修复 |
| AUDIT-007 | P1 | Secrets/Documents | 锁定状态下进入编辑页即可看到敏感明文 | 静态确认 | 已修复 |
| AUDIT-008 | P1 | Partnership | 负收益池可选“取回”，清账后资金凭空增加 | 已复现 | 不予处理 |
| AUDIT-009 | P1 | Partnership | 买入按资本权重分摊，成员可用现金可为负 | 已复现 | 不予处理 |
| AUDIT-010 | P1 | Bills | 导入本机导出的 JSON 产生 ID 重复的记录 | 静态确认 | 已修复 |
| AUDIT-011 | P1 | App/Composition | persist() 无“初始数据已加载”守卫，可能把空库写盘 | 疑似风险 | 已修复 |
| AUDIT-012 | P2 | 测试工程 | 屏蔽过时测试后仍有 19/523 个测试失败 | 已复现 | 已修复 |
| AUDIT-013 | P2 | Stocks/日历 | 美股周六元旦、港股周六假日把前一周五判为休市 | 已复现 | 已修复 |
| AUDIT-014 | P2 | Stocks/日历 | A 股农历兜底规则与官方表取并集，疑似误判 2024-02-08 与闰月 | 疑似风险 | 已修复 |
| AUDIT-015 | P2 | Stocks/组合走势 | 组合日线在交易当日持股与成本口径错位 | 静态确认 | 已修复 |
| AUDIT-016 | P2 | Stocks/账本 | transactionIsEffective 按设备时区判断“同一天” | 静态确认 | 已修复 |
| AUDIT-017 | P2 | 多模块 | 附件在持久化完成前被删除（违反 AGENTS.md:106） | 静态确认 | 已修复 |
| AUDIT-018 | P2 | Secrets/Documents | 模板显隐按“同 kind 唯一字段”回退匹配，误改自定义字段 | 静态确认 | 已修复 |
| AUDIT-019 | P2 | Secrets | Apple 密码 CSV 表头重复时崩溃 | 静态确认 | 已修复 |
| AUDIT-020 | P2 | Finance | 同一账户的多组收款资料只保留一组 | 已复现 | 已修复 |
| AUDIT-021 | P2 | Finance | cleanupRedundantData 为空实现，扫描结果无法清理 | 已复现 | 已修复 |
| AUDIT-022 | P2 | Core/Formatting | DecimalTextParser 接受“100元”“12abc”等带后缀文本 | 已复现 | 已修复 |
| AUDIT-023 | P2 | Finance | 支付编辑器吞掉保存错误，删除账户留下悬挂引用 | 静态确认 | 已修复 |
| AUDIT-024 | P2 | Finance | 支付账户详情保存缺少打开时快照，冲突检测失效 | 静态确认 | 已修复 |
| AUDIT-025 | P2 | Finance | 子账户直接从数组移除导致无法保存；replaceAccount 结果被忽略 | 静态确认 | 已修复 |
| AUDIT-026 | P2 | Finance | 网点无坐标时回退到天安门（README 明确禁止） | 静态确认 | 已修复 |
| AUDIT-027 | P2 | 备份 | 被隔离模块恢复后不落盘；Finance/Documents 模板恢复丢失 | 静态确认 | 已修复 |
| AUDIT-028 | P2 | 备份 | 一只股票非法则整批原样返回本地数据，界面仍提示成功 | 静态确认 | 已修复 |
| AUDIT-029 | P2 | CloudSync | zone 被删后已丢弃 payload 的记录无法重新上传 | 静态确认 | 已修复 |
| AUDIT-030 | P2 | CloudSync | 远端 schemaVersion 只写不读，旧客户端可覆盖新字段 | 静态确认 | 已修复 |
| AUDIT-031 | P2 | Persistence | 明文迁移直接写正式文件，无回读校验，快照晚于替换 | 静态确认 | 已修复 |
| AUDIT-032 | P2 | App/Composition | 删除功能数据立即落盘，撤回快照只在内存 | 静态确认 | 已修复 |
| AUDIT-033 | P2 | App/Modules | 云端偏好无条件覆盖本机显隐，默认值也被当作显式值上传 | 静态确认 | 已修复 |
| AUDIT-034 | P2 | App/CloudSync | 远程推送注册只存在于 Stocks 模块 | 静态确认 | 已修复 |
| AUDIT-035 | P2 | 工程配置 | macOS Release entitlements 疑似缺少用户选择文件、定位，APS 键名不符 | 疑似风险 | 已修复 |
| AUDIT-036 | P2 | Partnership | 补录较早日期的流出时只校验该日期前的余额 | 静态确认 | 不予处理 |
| AUDIT-037 | P2 | Partnership | 撤销只删最后一条记录，重命名/新成员/按比例注资撤销错误 | 静态确认 | 不予处理 |
| AUDIT-038 | P2 | Partnership | 导入含股息时撤销不是原子的 | 静态确认 | 不予处理 |
| AUDIT-039 | P2 | Partnership | 取消撤回抹掉“撤销”审计日志 | 静态确认 | 不予处理 |
| AUDIT-040 | P2 | Partnership | 卖出分成比例未保存，流水显示账本比例 | 静态确认 | 不予处理 |
| AUDIT-041 | P2 | Partnership | 单价超过两位小数的股票交易无法导入且整批失败 | 静态确认 | 不予处理 |
| AUDIT-042 | P2 | Bills | 重复导入整条替换，覆盖用户补充的分类、标签、备注 | 静态确认 | 已修复 |
| AUDIT-043 | P2 | Bills | 支付宝“交易关闭”映射为取消，可能与退款行重复冲减 | 疑似风险 | 已修复 |
| AUDIT-044 | P2 | Bills | 分析页 snapshot 为计算属性，一次 body 重算数十次 | 静态确认 | 已修复 |
| AUDIT-045 | P2 | CurrencyExchange | 4 个可选币种永远取不到现汇价，总损耗一直“待同步” | 静态确认 | 已修复 |
| AUDIT-046 | P2 | SportsLottery | 模块默认隐藏时自动刷新仍照常联网 | 静态确认 | 已修复 |
| AUDIT-047 | P2 | FoodMap | 城市名未归一（“北京市”≠“北京”），刷新失败且重复导入 | 静态确认 | 不予处理 |
| AUDIT-048 | P2 | FoodMap | 浏览器 sheet 关闭后 weak webView 为 nil，单店解析失败 | 静态确认 | 不予处理 |
| AUDIT-049 | P2 | FoodMap | 任何非 http 导航（含 iframe）都会强制跳转登录页 | 静态确认 | 不予处理 |
| AUDIT-050 | P2 | 备份 | 备份/恢复时附件全量读入内存并多次 base64/GCM 放大 | 静态确认 | 待确认 |
| AUDIT-051 | P3 | Stocks/行情 | 删除股票后在途请求仍把旧图表缓存写回磁盘 | 静态确认 | 已修复 |
| AUDIT-052 | P3 | Stocks/行情 | 不同市场的合并请求被放大为全市场强刷 | 静态确认 | 已修复 |
| AUDIT-053 | P3 | Stocks/行情 | 队列执行者被取消时丢弃其他调用方的待办请求 | 静态确认 | 已修复 |
| AUDIT-054 | P3 | Stocks/行情 | 报价解析不到时间戳时伪造为当前时间，挤掉真实报价 | 静态确认 | 已修复 |
| AUDIT-055 | P3 | Stocks/行情 | 图表共享请求 key 不含 forceRefresh | 静态确认 | 已修复 |
| AUDIT-056 | P3 | Stocks/行情 | 停牌等无法完成的股票收盘补刷每 5 分钟强刷且无上限 | 疑似风险 | 已修复 |
| AUDIT-057 | P3 | Stocks/行情 | 分钟数据每次提交都整份重编码写盘；DateFormatter 逐点新建 | 静态确认 | 已修复 |
| AUDIT-058 | P3 | Stocks/图表 | 成本标签去重以柱序号为单位，末尾标签可重叠 | 静态确认 | 已修复 |
| AUDIT-059 | P3 | Stocks/图表 | 周 K 的周起始日在三处不一致 | 静态确认 | 已修复 |
| AUDIT-060 | P3 | Stocks/图表 | 组合 K 线高低为各股包络；休市日也用实时价补“今天” | 静态确认 | 已修复 |
| AUDIT-061 | P3 | Finance | 归档规则：abnormal 计为不活跃，券商/支付机构永不归档 | 静态确认 | 已修复 |
| AUDIT-062 | P3 | Finance | validate 漏校验收款路由、附件引用；schemaVersion 严格相等 | 静态确认 | 已修复 |
| AUDIT-063 | P3 | Finance | 未知开户日期在编辑时被改成今天 | 静态确认 | 已修复 |
| AUDIT-064 | P3 | Finance | 子账户编辑入口只在顶层账户中查找，点击无效 | 静态确认 | 已修复 |
| AUDIT-065 | P3 | Finance | 支付与其他机构没有删除入口 | 静态确认 | 已修复 |
| AUDIT-066 | P3 | Finance | CVV、登录密码明文编辑，券商账号全文显示，验证要求不一致 | 静态确认 | 已修复 |
| AUDIT-067 | P3 | Health | 住院日记录被计入就诊次数 | 静态确认 | 已修复 |
| AUDIT-068 | P3 | Health | 删除仍被引用的医疗机构后重启会恢复 | 静态确认 | 已修复 |
| AUDIT-069 | P3 | Documents/Secrets | 锁定状态下搜索、排序、到期日、标签、通知正文泄露信息 | 静态确认 | 已修复 |
| AUDIT-070 | P3 | Documents | 闰日签发期限计算疑似偏差；已进入提醒窗口时不发提醒 | 静态确认 | 已修复 |
| AUDIT-071 | P3 | Health/Documents/Secrets | 滑动删除无确认且级联删除关联记录与附件 | 静态确认 | 已修复 |
| AUDIT-072 | P3 | Partnership | 卖出盈利未舍入到分；零头导致清账可无限重复 | 静态确认 | 不予处理 |
| AUDIT-073 | P3 | Partnership | “初始出资”魔法字符串、清账日期、汇率来源、导入日志 ID 等 | 静态确认 | 不予处理 |
| AUDIT-074 | P3 | Bills | XLSX 列号溢出崩溃、行号放大内存；CSV/文件读取无大小上限 | 静态确认 | 已修复 |
| AUDIT-075 | P3 | Bills | 上期为负时对比方向反；0 元导入记录无法编辑保存 | 静态确认 | 已修复 |
| AUDIT-076 | P3 | CurrencyExchange | 跨时区时月份分组、年份筛选与行内日期不一致 | 静态确认 | 已修复 |
| AUDIT-077 | P3 | CurrencyExchange | 换汇模型无缺键兼容与旧枚举映射，旧数据会导致模块隔离 | 静态确认 | 已修复 |
| AUDIT-078 | P3 | SportsLottery | 补全请求失败用降级数据覆盖缓存；一个联赛失败中断其余 | 静态确认 | 已修复 |
| AUDIT-079 | P3 | SportsLottery | 赛果单行字段为 null 整页解码失败 | 疑似风险 | 已修复 |
| AUDIT-080 | P3 | FoodMap | 批量刷新基于开始时快照写回，可能覆盖同步修改并删除照片 | 疑似风险 | 不予处理 |
| AUDIT-081 | P3 | FoodMap | 地图选点回填的区县被省份 onChange 立即清空 | 静态确认 | 不予处理 |
| AUDIT-082 | P3 | FoodMap | 店名中的 0–5 数字被当成星级；封面不校验实际类型 | 静态确认 | 不予处理 |
| AUDIT-083 | P3 | FoodMap | 旧状态 notTried 无迁移，含该值的数据使模块被隔离 | 静态确认 | 不予处理 |
| AUDIT-084 | P3 | Core/Storage | 存储统计漏算诊断目录内两类文件；设置页主线程全量重算 | 静态确认 | 已修复 |
| AUDIT-085 | P3 | 工程配置 | pbxproj 写死 DEVELOPMENT_TEAM（6Y8D******），覆盖本机签名配置 | 静态确认 | 待确认 |
| AUDIT-086 | P3 | CloudSync/备份 | 同步状态不可读回落为空文档；PBKDF2 轮数偏低且未写入信封；后台 flush 无后台任务 | 静态确认 | 已修复 |
| AUDIT-087 | P3 | 测试工程 | 关键路径缺测试（换汇、DecimalTextParser、XLSX deflate、日历特例等） | 静态确认 | 已修复 |
| AUDIT-088 | P4 | 多模块 | 死代码、重复实现与 View 层业务逻辑 | 静态确认 | 已修复 |
| AUDIT-089 | P4 | 多模块 | 零散建议项（IME、剪贴板、NaN、格式化器复用、诊断挂载等） | 静态确认 | 已修复 |
| AUDIT-090 | P4 | 文档 | 文档与代码不一致（需求冲突类，未改文档，见报告第 4 节） | 静态确认 | 已修复 |
| AUDIT-091 | P1 | Stocks/账本 | 美股成交时间在北京跨日后被提前 24 小时 | 静态确认 | 已修复 |
| AUDIT-092 | P2 | Stocks/账本 | 美股无成交时间的交易在冬令时被映射到前一交易日 | 静态确认 | 已修复 |
| AUDIT-093 | P2 | Stocks/账本 | 日内生效子集可出现负股数，卖空校验未覆盖 | 静态确认 | 已修复 |
| AUDIT-094 | P3 | Stocks/账本 | 分红生效日历不一致；旧外币入金重复计入；反推单价截断 4 位 | 静态确认 | 已修复 |

> AUDIT-091～094 来自最后返回的 Stocks 账本子代理，为保持编号稳定按追加顺序编号，未插入到同级位置。

## 二、详细记录

> 字段顺序：编号、标题、严重程度、模块、文件位置、描述、预期、实际、触发/复现、证据、验证状态、根因、影响范围、修复方案、修复风险、回归测试方案、关联问题/依赖、处理状态。

### AUDIT-001 测试 target 无法编译
- 编号：AUDIT-001｜严重程度：P1｜模块：测试工程｜验证状态：已复现｜处理状态：已修复
- 文件位置：`MyToolsTests/Core/SecureStoreEncryptionTests.swift:97`；`MyToolsTests/Stocks/StockChartServiceTests.swift:15,20`；`MyToolsTests/Stocks/StockChartDiskStoreTests.swift:14`；`MyToolsTests/AppStore/AppStoreBackupMergerTests.swift:53-118`；`MyToolsTests/AppStore/AppStoreFacadeTests.swift:72-99`（含 :92）；`MyToolsTests/Stores/ModuleStoreTests.swift` 5 处（含 :133、:500）
- 描述：测试代码仍使用已删除或已改签名的 API：`VaultData.accounts`（现为 `financialInstitutions`）、`StockChartCacheEntry` 缺 `indicatorPoints:`、`FinanceStore.replaceAccount(_:cards:)` 缺 `expected:`，以及 schema 3 前的金融模型。
- 预期：`xcodebuild build-for-testing` 成功，CI 可跑全量测试。／实际：iOS 模拟器上 `build-for-testing` 以 EXIT 65 失败，整个测试 target 不可用。
- 触发/复现：在 9ae7073 上对 `MyTools` scheme 执行 `build-for-testing`（destination：iPhone 17 Pro 模拟器）。
- 证据：编译错误列表；`FinanceStore.swift:53` 是 `replaceAccount` 的唯一签名，`expected` 无默认值。
- 根因：金融 schema 3、图表缓存加指标字段等改动未同步更新测试。／影响范围：全部 523 个测试无法在原工程运行，回归保护失效。
- 修复方案：按当前 API 改写 2 处参数补全，并重写 7 个依赖旧金融模型的用例（`financeAttachmentCleanupRequiresSuccessfulPersistenceAndNoGlobalReferences`、`onlyIncludedModulesAreMerged`、`financialFoundationAllowsMultipleServicesAndPreservesLegacyIDs`、`financialCustomFieldsRoundTripAndKeepSensitiveFlag`、`financeDraftConflictDoesNotOverwriteUpdatedCardsOrRecreateDeletedAccount`、`explicitEmptyFinanceTemplatesSurviveReloadAndVaultRoundTrip`、`financeStoreRetainsAttachmentsUntilPersistenceConfirmsRemoval`）。／修复风险：低，只改测试；需注意不要为了编译通过而删掉原有断言意图。
- 回归测试方案：`build-for-testing` 通过，并纳入每次提交前检查。
- 关联问题/依赖：AUDIT-012（编译通过后仍有失败）、AUDIT-006。审计副本中这 7 个用例已用 `#if false // AUDIT: stale vs current API` 屏蔽，2 处参数已补全。

### AUDIT-002 CloudKit 用集合差推断删除，可能删除其他设备数据
- 编号：AUDIT-002｜严重程度：P1｜模块：Core/CloudSync｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/CloudSync/CloudKitSyncWorker.swift:207-226`、`:575-579`、`:354-357`、`:635`；`Core/CloudSync/CloudSyncModels.swift:553,566-573,602`
- 描述：reconcile 时，凡是 `document.entries` 中存在、但当前本地快照 `currentKeys` 中没有的 key，一律标记 `isDeleted` 并发送 `.deleteRecord`。远端记录先写进 entries；本地应用失败只上报错误，同步状态照样前进。合并器遇到一条无法解码的记录会整批 throw，非法股票会被直接跳过。
- 预期：只有用户明确删除的记录才在云端删除。／实际：任何“本地没能应用”的远端记录，下次 reconcile 都会被当成本地删除并推送到云端，其他设备随之删除。
- 触发/复现：注入一条本地无法解码（或被跳过）的远端 upsert，然后触发 reconcile。
- 证据：`for (key, entry) in document.entries where ... !currentKeys.contains(key)` → `changes.append(.deleteRecord(...))`；`saveDocument()` 在 changeHandler 之前执行。
- 根因：没有持久化的显式墓碑（带操作 ID），没有“记录数骤降”熔断，应用失败时不回滚状态。／影响范围：所有参与 iCloud 同步的模块，跨设备不可逆数据丢失。
- 修复方案：删除只来自显式墓碑；本地应用失败时回滚 change token 或把该 key 标为待重试；单次删除数超过阈值时暂停并提示。／修复风险：中高，涉及同步协议，需兼容旧状态文件。
- 回归测试方案：注入不可解码 upsert 后执行 reconcile，断言没有 `deleteRecord`；构造本地记录数骤降，断言熔断。
- 关联问题/依赖：AUDIT-029、AUDIT-030、AUDIT-086（状态文件读不出时回落为空文档）；README/AGENTS 对墓碑与熔断的描述见报告第 4 节。

### AUDIT-003 Vault 整体不可读时仍允许恢复备份，原密文被覆盖
- 编号：AUDIT-003｜严重程度：P1｜模块：备份/Persistence｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Composition/AppStore.swift:556-606`（`restoreBackup`）；`Core/Persistence/SecureStore.swift:152-154,386`
- 描述：`restoreBackup` 入口不检查 `canPersistVault`。合并结果用 `saveImmediately` 写盘，然后把 `canPersistVault` 置为 true。整体解密/解码失败时，内存中是空库，写盘内容是“空库 + 备份内模块”。
- 预期：本地库不可读时拒绝恢复，或先保存原始密文字节。／实际：原文件被覆盖；全局失败路径不生成恢复快照，备份未包含、或当前构建未编译的模块原始密文永久丢失。
- 触发/复现：Keychain 密钥与文件不匹配（或文件损坏）导致整体加载失败，用户在设置中恢复备份。
- 证据：入口无 `canPersistVault` 判断；`persist()`（:790）有该守卫，但 restore 路径直接调用 `saveImmediately`。
- 根因：恢复路径绕开了统一的写入守卫。／影响范围：所有模块；属于用户最可能去“用备份自救”的场景，后果不可逆。
- 修复方案：`canPersistVault == false` 时拒绝恢复并提示，或先把原文件复制为带时间戳的恢复副本再写入。／修复风险：低。
- 回归测试方案：用错误密钥加载后调用恢复，断言原文件字节不变（或恢复副本存在）。
- 关联问题/依赖：App+Core 与 Persistence 两份审计各自独立发现，已合并；AUDIT-011。

### AUDIT-004 附件 storedFileName 可路径穿越
- 编号：AUDIT-004｜严重程度：P1｜模块：Core/Attachments｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Core/Attachments/AttachmentStore.swift:74-133`；`App/Composition/AppStoreBackupProcessor.swift:304-311`
- 描述：`storedFileName` 来自备份文件或 CloudKit 记录，未校验就与附件目录拼接。
- 预期：只接受 UUID 形式的文件名，最终路径必须位于附件目录内。／实际：`../escaped.bin` 被写到附件目录的上一级。
- 触发/复现：`AuditReproTests.auditAttachmentStoreRejectsPathTraversal`（失败＝复现）。恶意或损坏的备份/云端记录即可触发。
- 证据：r3.xcresult 中 `escaped.bin` 出现在 root 目录。
- 根因：信任外部输入的文件名。／影响范围：可覆盖或删除沙盒内附件目录之外的文件（如 `local-vault.json`）；导出备份时也可读入任意沙盒文件。
- 修复方案：解码时校验 UUID 格式；拼接后 `standardizedFileURL` 必须以附件目录为前缀，否则拒绝。／修复风险：低；需确认历史数据的文件名全部为 UUID。
- 回归测试方案：沿用复现测试；再加一个含 `../x` 的备份恢复用例，断言被拒绝。
- 关联问题/依赖：AUDIT-017。

### AUDIT-005 “其他”类机构写入的账户被静默丢弃
- 编号：AUDIT-005｜严重程度：P1｜模块：Finance｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Finance/Domain/FinancialInstitution.swift:79-82`、`:236`
- 描述：`accounts` 的 setter 只写 `bank?.accounts`；kind 为 `.other` 时什么都不做。`validate` 的 accountIDs 也不包含 `other.accounts`。
- 预期：添加“其他”机构并填写账户后保存，账户保留。／实际：读回时 `accounts.count == 0`、`other?.accounts.count == 0`。
- 触发/复现：`AuditReproTests.auditOtherInstitutionKeepsAccounts`（失败＝复现）。
- 证据：r3.xcresult 断言失败值为 0。
- 根因：聚合根按 kind 拆分后，计算属性的 setter 没有按 kind 分派。／影响范围：“其他”类机构的全部账户输入；用户无报错提示。
- 修复方案：setter 按 kind 分派到 `bank`/`other`；`validate` 纳入 `other.accounts`。／修复风险：低。
- 回归测试方案：沿用复现测试，并加 Vault 往返用例。
- 关联问题/依赖：AUDIT-062。
- 处理记录（2026-10-14，阶段 2）：`accounts` 在 kind 为 `.other` 时读写 `other.accounts`，validate 随之覆盖；`AuditReproTests.auditOtherInstitutionKeepsAccounts` 断言保留。

### AUDIT-006 备份导入按模块整体替换，与“增量合并”文档冲突
- 编号：AUDIT-006｜严重程度：P1｜模块：备份（`App/Composition/AppStoreBackupMerger.swift`）｜验证状态：已复现｜处理状态：已修复
- 文件位置：`App/Composition/AppStoreBackupMerger.swift` 整体；README“存储与数据/备份”节
- 描述：README 写“导入为增量合并、按记录 ID 合并”；代码对 `includedModules` 中的模块整体替换为备份内容。`FINANCE_MODEL.md:21` 与代码一致。
- 预期（按 README）：仅本地存在的记录保留，同 ID 记录被更新。／实际：仅本地存在的 FoodPlace 丢失。
- 触发/复现：`AuditReproTests.auditBackupImportKeepsLocalOnlyRecords`（失败＝复现）；原工程 `AppStoreBackupMergerTests.selectedModuleReplacesMatchingIDsAndAppendsNewIDs`、`BillsTests.vaultBackupAndCloudRespectBillsModuleBoundary` 也因此失败。
- 证据：r1、r3 结果。
- 根因：产品语义已改为“整体覆盖”，但 README 和两条测试未同步，或者反过来是代码偏离需求，需要产品确认。／影响范围：恢复备份时用户在备份之后新增的记录全部丢失，界面无预警。
- 修复方案：先确认产品语义。若保留整体覆盖：恢复前明确提示“将替换所选模块全部数据”，同时更新 README 和测试；若恢复增量合并：按 ID 合并并保留本地新增。／修复风险：中，改变用户可见的数据语义。
- 回归测试方案：按确认后的语义改写上述三条测试。
- 关联问题/依赖：AUDIT-027、AUDIT-028、AUDIT-012。属需求冲突，未改文档。

### AUDIT-007 锁定状态下进入编辑页即可看到敏感明文
- 编号：AUDIT-007｜严重程度：P1｜模块：Secrets、Documents｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Secrets/Presentation/SecretVaultView.swift:684-689,1013`；`Documents/Presentation/CredentialDetailView.swift:194`；`Documents/Presentation/CredentialEditorView.swift:189-190`
- 描述：详情页在未验证时遮罩敏感字段，但“编辑”按钮直接 `editingItem = item`，前面没有 `canReveal`/生物识别判断。编辑页字段用 `IMESafeTextField`，没有遮罩模式。
- 预期：未验证身份时，任何页面都不显示密码、证件号等敏感值。／实际：锁定状态点“编辑”即可看到全部明文。
- 触发/复现：保密资料或证照处于锁定状态，点右上角编辑图标。
- 证据：`Button { editingItem = item }` 与旁边的 `verifyWithBiometrics()` 按钮并列，无条件可点。
- 根因：把“编辑不需要验证”实现成了“编辑页显示明文”。／影响范围：保密资料、证照的全部敏感字段；手机被他人拿到时的主要防线失效。
- 修复方案：进入编辑前要求验证；或编辑页对敏感字段默认遮罩，验证后才可见。／修复风险：低，可能影响编辑流程体验。
- 回归测试方案：UI 测试或 ViewModel 测试：锁定状态打开编辑，断言敏感文本不出现。
- 关联问题/依赖：AUDIT-066（Finance 同类）、AUDIT-069。

### AUDIT-008 Partnership 负收益池可选“取回”，清账后资金凭空增加
- 编号：AUDIT-008｜严重程度：P1｜模块：Partnership｜验证状态：已复现｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:379,383`；`Partnership/Domain/PartnershipLedger.swift:450,496`；`Partnership/Presentation/PartnershipEditorViews.swift:342-348`
- 描述：成员收益池为负时仍能选“取回”。清账把收益池清零，但只有选择重投的才写回可用资金（`where choice.reinvest`），亏损因此从账面消失。
- 预期：“可用现金 + 收益池”合计在清账前后守恒；README:201“负收益池按重投语义抵减可用资金”。／实际：70 股 @100 买入、@80 卖出，全员取回后合计由 9100 变为 10500。
- 触发/复现：`AuditReproTests.auditNegativeProfitPoolTakeBackConservesValue`（失败＝复现）。
- 证据：`let settledAmount = shouldReinvest ? $0.actual : money($0.actual)` 不检查正负。
- 根因：规则只写在文档，Store 层未强制。／影响范围：亏损后的每次清账，成员可取出超过真实现金的金额，账户透支。
- 修复方案：Store 层 `actual < 0` 时强制按重投处理或拒绝；UI 对负余额隐藏“取回”。／修复风险：低。
- 回归测试方案：沿用复现测试。
- 关联问题/依赖：AUDIT-009、AUDIT-072。

### AUDIT-009 Partnership 买入按资本权重分摊，成员可用现金可为负
- 编号：AUDIT-009｜严重程度：P1｜模块：Partnership｜验证状态：已复现｜处理状态：不予处理
- 文件位置：`Partnership/Domain/PartnershipLedger.swift:571-572`（`allocateByCapitalWeight`/`memberCapitalWeights`）；`Partnership/Application/PartnershipStore.swift:234-239`
- 描述：权重＝注资 − 取出 + 重投，不扣除持仓成本。持仓期间有人单独取出后，权重比例与可用现金比例不一致；买入只校验账户总可用资金。
- 预期：README:200“买入按当时可用资金比例冻结成本”，任何成员可用现金不为负。／实际：A 9000/B 1500 出资，买 7000，B 取出 500，再买 3000，B 被分摊 300，可用现金为 −300。
- 触发/复现：`AuditReproTests.auditPurchaseNeverMakesMemberCashNegative`（失败＝复现）。
- 证据：r3.xcresult。
- 根因：实现与文档的分摊口径不同，且缺少逐成员校验。／影响范围：多成员账本的成本归属与可取现金；可导致账户总现金为负。
- 修复方案：按交易时点的成员可用现金分摊；至少逐成员校验分摊额不超过其可用现金。需产品确认口径。／修复风险：中，已冻结的历史分配不应重算。
- 回归测试方案：沿用复现测试；加“历史快照不变”用例。
- 关联问题/依赖：AUDIT-036；文档冲突见报告第 4 节。

### AUDIT-010 Bills 导入本机导出的 JSON 产生 ID 重复的记录
- 编号：AUDIT-010｜严重程度：P1｜模块：Bills｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Bills/Domain/BillExchange.swift:206`、`:255-257`；`Bills/Application/BillsStore.swift:111-118`（`matchingIndex`）
- 描述：导出时 `id: record.id.uuidString.lowercased()` 作为外部交易号，来源写成方寸；导入时来源为方寸就 `UUID(uuidString: externalID)` 还原为本地 ID。`matchingIndex` 有 externalID 时只按“来源 + externalID”匹配，本机原记录来源是 manual/微信/支付宝，匹配不到，于是追加一条 ID 相同的记录。
- 预期：本机导出再导入是幂等的。／实际：每条记录出现两份，且 ID 相同。
- 触发/复现：`upsert` 一条手工记录 → `document(from:)` → `importExchange`，`records.count` 预期 1（未在副本中编写测试）。
- 证据：上述三处代码。
- 根因：导出丢失原始来源与平台交易号；匹配逻辑不回退到 ID。／影响范围：`ForEach` id 冲突（列表异常）、`delete(ids:)` 一次删两条、CloudKit upsert 与备份合并按 ID 互相覆盖。
- 修复方案：来源为方寸时先按 `id` 匹配；导出增加原始来源与原始交易号字段。／修复风险：低；需兼容已导出的 v2 文件。
- 回归测试方案：上面的往返用例；再加一次重复导入断言幂等。
- 关联问题/依赖：AUDIT-042。
- 处理记录（2026-10-15）：`BillsStore.matchingIndex` 在来源为方寸（`BillExchangeSource.myTools`）时先按 `id` 匹配，本机导出再导入幂等；合并经 `BillsStore.merged(_:into:)` 保留原 id、createdAt 与原始来源。临时开启 `MYTOOLS_FEATURE_BILLS` 构建并测试；`BillsTests.reimportingOwnExportIsIdempotentAndKeepsUserEdits`。

### AUDIT-011 persist() 无“初始数据已加载”守卫
- 编号：AUDIT-011｜严重程度：P1｜模块：App/Composition｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`App/Composition/AppStore.swift:116`（`canPersistVault = true` 初始值）、`:790-803`（`persist()`）
- 描述：`persist()` 只检查 `!isRestoringBackup, canPersistVault`；`canPersistVault` 初值为 true。加载完成前（或 protectedDataUnavailable 期间）若有任何 Store 变更触发 persist，会把空 store 写盘。同文件 :658、:692 等其他入口都检查了 `isInitialDataLoaded`。
- 预期：初始加载完成前不写盘。／实际：守卫缺失；未找到具体触发路径。
- 触发/复现：未复现。可能路径：启动早期的通知回调、CloudKit 回调或后台刷新写入 Store。
- 证据：守卫条件对比。
- 根因：防御依赖“加载前没人写”的时序假设。／影响范围：若触发，覆盖全部本地数据。
- 修复方案：`persist()` 增加 `isInitialDataLoaded` 判断。／修复风险：低。
- 回归测试方案：加载挂起期间修改一个 Store，断言没有写盘调用。
- 关联问题/依赖：AUDIT-003。

### AUDIT-012 屏蔽过时测试后仍有 19/523 个测试失败
- 编号：AUDIT-012｜严重程度：P2｜模块：测试工程｜验证状态：已复现｜处理状态：已修复
- 文件位置：`MyToolsTests/` 下 9 个测试文件（明细见报告第 9 节）
- 描述：在审计副本中修好 AUDIT-001 后，全量运行结果为 504 通过 / 19 失败 / 0 跳过。按原因分四类：
  - (a) schema 3 后测试过时（10 条）：`AppStoreBackupProcessorTests.financeAndSecretAttachmentsSurviveBackupRestore`、`CloudSyncMergerTests` 3 条、`ModuleStoreTests` 的 `financeV2CanSaveAndRoundTrip…`/`financeCardReplacementCyclesAreRejected`/`financeLoginTemplatesAreRegionSpecificAndPersistent`/`removedDomesticPresetRemainsEditableAsACustomType`/`financeSubaccountTypesMatchTheirBankRegion`、`SecureStoreEncryptionTests.unreadableFinanceIsQuarantined…`；
  - (b) 需求变更未更新测试（1 条）：`StockPortfolioEditorTests.performanceCacheExpiresWhenFutureTransactionBecomesEffective`；
  - (c) 依赖真实时钟（2 条）：`StockHoldingValuationTests.overviewTotalsEqualTheSumOfRowsDuringPreMarket`、`todayChangeRateFallsBackWholesaleWhenAPieceIsMissing`；
  - (d) 真实问题、需求冲突或疑似抖动（6 条）：`AppStoreBackupMergerTests.selectedModuleReplacesMatchingIDsAndAppendsNewIDs` 与 `BillsTests.vaultBackupAndCloudRespectBillsModuleBoundary`（AUDIT-006）、`ModuleStoreTests.financeCleanupRemoves…`（AUDIT-021）、`financeArchiveFollowsAccountAndCardClosure`（AUDIT-061）、`SecureStoreEncryptionTests.strictBackupDecode…`（多出空键，P4）、`persistenceCoordinatorRetriesTemporaryKeychainFailure`（r2 单独复跑通过，判定为时序抖动，疑似）。
- 预期：全部通过，或失败均对应已登记的问题。／实际：19 条失败，其中 14 条是测试自身问题。
- 触发/复现：`test-without-building`，结果 `/tmp/mytools-audit/r1.xcresult`；SecureStore 套件单独重跑结果 r2。
- 证据：xcresult 汇总 `totalTestCount 523, passed 504, failed 19`。
- 根因：测试维护滞后于模型升级；部分测试未注入时钟。／影响范围：失败噪声掩盖真实回归。
- 修复方案：(a)(b) 按当前语义改写；(c) 注入 `now`；(d) 随对应问题处理。／修复风险：低。
- 回归测试方案：全量通过，且 (c) 类在任意本地时间重复运行稳定。
- 关联问题/依赖：AUDIT-001、AUDIT-006、AUDIT-021、AUDIT-061；记忆中已有“本地时间早于 12:00 时日期归一”的既有失败记录，与 (c) 同类。

### AUDIT-013 美股周六元旦、港股周六假日把前一周五判为休市
- 编号：AUDIT-013｜严重程度：P2｜模块：Stocks/交易日历｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Stocks/Domain/StockMarketTradingCalendar.swift:514-539`、`:435`
- 描述：通用“周六假日挪到周五”规则被用于美股元旦与港股。NYSE 规则是元旦落在周六时不补休；港股没有周六假日挪到周五的规则。
- 预期：2021-12-31（美股）、2023-06-30（港股）为交易日。／实际：`isTradingDay` 均返回 false。
- 触发/复现：`AuditReproTests.auditUSNewYearSaturdayDoesNotCloseFriday`、`auditHongKongSaturdayHolidayDoesNotCloseFriday`（失败＝复现）。
- 证据：r3.xcresult。
- 根因：调休规则未按市场区分。／影响范围：休市判断影响刷新调度、收盘补刷、迷你图横轴、交易日回放。
- 修复方案：在各市场 Rules 中分别定义周末假日的调休策略。／修复风险：低。
- 回归测试方案：沿用复现测试，并补 2022-12-31、2027-01-01 等边界。
- 关联问题/依赖：AUDIT-014。
- 处理记录（2026-10-15）：`isObservedFixedHoliday` 增加 `saturdayObservedOnFriday`，港股固定假日与美股元旦逢周六不再把周五判为休市；港股农历假日抽为 `isHongKongLunarHoliday`，闰月跳过。`AuditReproTests` 两条 AUDIT-013 已移除 `withKnownIssue` 并补断言（美股 2021-12-24 休市、港股 2023-01-02 休市）。

### AUDIT-014 A 股农历兜底规则与官方表取并集
- 编号：AUDIT-014｜严重程度：P2｜模块：Stocks/交易日历｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`Stocks/Domain/StockMarketTradingCalendar.swift:403-425`
- 描述：内置“腊月 29 及以后”等规则与 `AShareHolidayService` 官方休市表取并集，只能多休不能纠正。按推算 2024-02-08（腊月廿九，正常交易）会被判休市；闰月未处理，如 2028 年闰五月初五可能被误判。
- 预期：有官方表时以表为准，内置规则只做兜底。／实际：并集。
- 触发/复现：未编写测试（审计期间未确认官方表在测试环境中的加载状态）。
- 证据：规则代码。
- 根因：兜底逻辑与权威数据合并方式不当。／影响范围：A 股个别交易日被当作休市。
- 修复方案：官方表存在时跳过内置规则；内置规则排除闰月。／修复风险：低。
- 回归测试方案：注入官方表后断言 2024-02-08 为交易日；无表时断言闰五月初五不休市。
- 关联问题/依赖：AUDIT-013；实现指南要求领域层不直接访问 `AShareHolidayService.shared`，见报告第 4 节。
- 处理记录（2026-10-15）：A 股：周末直接休市；`AShareHolidaySnapshot.hasData(forYear:)` 为真时只认官方表，另加 `isAdditionalAShareClosure` 与 `isLunarNewYearEve`（holiday-cn 不把除夕标为休息日，交易所当天休市）；无官方数据时才走农历兜底，兜底跳过闰月，“腊月≥29”改为“次日为正月初一”。`AuditReproTests.auditAShareOfficialTableOverridesLunarRules`。

### AUDIT-015 组合日线在交易当日持股与成本口径错位
- 编号：AUDIT-015｜严重程度：P2｜模块：Stocks/组合走势｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/PortfolioValueHistory.swift:221,256,694`；`Stocks/Domain/Stock.swift:351`
- 描述：日线 date 为市场时区 0 点。持股用 `transactionIsEffective`，成本直接比较 `tradedAt <= date`。
- 预期：交易当日那根日线的股数与成本同步变化。／实际：A 股未填成交时间时股数当天计入、成本晚一天；填了成交时间时两者都晚一天；美股填成交时间时股数晚一天、成本当天计入。
- 触发/复现：同一笔交易分别填与不填成交时间，观察当日日线（未编写测试）。
- 证据：两处判定条件。
- 根因：持股与成本使用两套口径。／影响范围：持仓总价值走势的当日收益率、成本线跳变。
- 修复方案：统一按“市场交易日”判定持股与成本。／修复风险：中，需同步修改图表测试。
- 回归测试方案：上述两种交易，断言当日股数与成本。
- 关联问题/依赖：AUDIT-016。
- 处理记录（2026-10-14，阶段 2）：组合日线按 `StockMarketClock.marketBusinessDayStart` 的市场交易日同时计入股数与成本（成本点用同一张交易日表）；`AuditReproTests.auditDailySeriesCountsSharesAndCostOnTheSameMarketDay`。

### AUDIT-016 transactionIsEffective 按设备时区判断“同一天”
- 编号：AUDIT-016｜严重程度：P2｜模块：Stocks/账本｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/Stock.swift:351-354`；`Stock.swift:155`（注释）
- 描述：无成交时间的交易用 `Calendar.autoupdatingCurrent.isDate(tradedAt, inSameDayAs: now)` 判断是否当天生效，依赖设备时区；而 `tradedAt` 按北京时间录入（:155 注释称“按市场时区解释”，与代码均不一致）。
- 预期：生效判断只依赖市场交易日。／实际：设备不在东八区时，交易会提前或推迟一天生效，持股、成本、收益随设备时区变化。
- 触发/复现：把设备时区设为 America/New_York，录入一笔未来日期为“今天北京时间”的交易（未编写测试）。
- 证据：代码。
- 根因：使用 `.autoupdatingCurrent`。／影响范围：持仓汇总、组合走势、Partnership 导入。
- 修复方案：传入市场 Calendar（或 Asia/Shanghai），并修正注释。／修复风险：低。
- 回归测试方案：固定 `now` 与时区的参数化测试。
- 关联问题/依赖：AUDIT-015、AUDIT-012(c)、AUDIT-091。账本审计补充：设备在北京时区录美股时不会漏判生效，最多是用户手选北京“今天”而美股尚未到该日时提前生效；风险主要在设备位于市场时区以西时（如在美国录 A 股，默认业务日为本地明天，`DateFieldRow` 上限 `Date()` 可能截断日期——后者为疑似）。`StockPerformanceCache` 的 validUntil 与本函数在默认日历下等价，但本函数未使用传入的 calendar 参数（P4）。
- 处理记录（2026-10-14，阶段 2）：生效判断改为 `StockHolding.effectiveInstant(of:)`：有成交时间取成交时刻，否则取北京日期零点；`normalizedDate`、`isSameDay`、`orderedTransactions`、分红 `isReceived` 默认日历统一为 `StockMarketClock.beijingCalendar`；`AuditReproTests.auditDateOnlyTradeBecomesEffectiveAtBeijingMidnight`。

### AUDIT-017 附件在持久化完成前被删除
- 编号：AUDIT-017｜严重程度：P2｜模块：App/Composition、Health、Documents、Secrets｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Composition/AppStore.swift:918-925`；`Health/Application/HealthStore.swift:138,262`；`Documents/Application/DocumentsStore.swift:178,202`；`Secrets/Application/SecretStore.swift:124,140`
- 描述：先 `attachmentStore.delete`，后 `persistence.schedule`。FinanceStore 使用的 `scheduleAttachmentRemovalAfterPersistence` 在这些位置未使用。
- 预期：AGENTS.md:106，删除附件须等持久化成功。／实际：写盘失败（Keychain 不可用、磁盘满）时 Vault 仍引用已删除文件。
- 触发/复现：Fake persistence 让 flush 失败后编辑记录移除附件（未编写测试）。
- 证据：上述代码顺序。
- 根因：只有 Finance 迁移到了延迟删除机制。／影响范围：健康、证照、保密资料附件，以及云端变更应用路径。
- 修复方案：统一改用 `scheduleAttachmentRemovalAfterPersistence`。／修复风险：低。
- 回归测试方案：flush 失败时断言附件文件仍在。
- 关联问题/依赖：AUDIT-004。
- 处理记录（2026-10-14，阶段 3）：Health、Secrets、Documents 的附件删除改为在 Vault 落盘后执行（`scheduleAttachmentRemovalAfterPersistence`），没有 Vault 的独立 Store 仍立即删除；AppStore 层的跨模块附件清理同样等落盘后再删。

### AUDIT-018 模板显隐回退匹配误改自定义字段
- 编号：AUDIT-018｜严重程度：P2｜模块：Secrets、Documents｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Secrets/Application/SecretStore.swift:227-230`（`effectiveFields` 显示时也用）；`Documents/Application/DocumentsStore.swift:368-371`；`Documents/Presentation/CredentialEditorView.swift:456`
- 描述：名称不匹配时，若模板中同 kind+inputType 的字段只有一个，就套用它的显隐设置。
- 预期：只影响同名模板字段。／实际：把“软件授权”模板的“授权姓名”设为可见后，该分类下用户自建的文本字段在锁定状态也显示明文；证照编辑器在内容出现换行时会把字段 kind 改为多行，从而匹配到模板唯一的多行字段。
- 触发/复现：添加自定义字段后修改模板显隐（未编写测试）。
- 证据：`kindMatches.count == 1 ? kindMatches.first : nil`。
- 根因：为兼容改名而设计的模糊匹配。／影响范围：敏感字段意外显示。
- 修复方案：只按名称精确匹配（或给模板字段稳定 ID）。／修复风险：低，旧数据改名场景需迁移。
- 回归测试方案：修改模板后断言自定义字段 `isSensitive` 不变。
- 关联问题/依赖：AUDIT-007。
- 处理记录（2026-10-14，阶段 3）：Secrets/Documents 的模板显隐只匹配同名字段，不再按 kind 回退，自定义字段保持自身设置；`SecretsTests.templateSensitivityIgnoresCustomFieldsOfTheSameKind`。README“字段可单独显示或隐藏”与“详情页套用模板显隐”的差异按裁决维持现状并记录（报告 4.2 #18）。

### AUDIT-019 Apple 密码 CSV 表头重复时崩溃
- 编号：AUDIT-019｜严重程度：P2｜模块：Secrets｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Secrets/Domain/ApplePasswordImport.swift:61`
- 描述：`Dictionary(uniqueKeysWithValues:)` 遇到重复键会 trap。
- 预期：导入失败给出提示或忽略重复列。／实际：App 崩溃。
- 触发/复现：表头 `Title,URL,Username,Password,,`（两个空列）。
- 证据：代码。／根因：表头未去重。／影响范围：用户导入外部 CSV。
- 修复方案：改用 `Dictionary(_:uniquingKeysWith:)` 保留第一个值。／修复风险：低。
- 回归测试方案：上述表头的解析用例。
- 关联问题/依赖：无。
- 处理记录（2026-10-14，阶段 3）：重复表头取第一列，不再触发 Dictionary 崩溃；`SecretsTests.applePasswordCSVWithDuplicateHeadersKeepsFirstColumn`。

### AUDIT-020 同一账户的多组收款资料只保留一组
- 编号：AUDIT-020｜严重程度：P2｜模块：Finance｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Finance/Domain/FinancialInstitution.swift:42-52`（`normalizePaymentReceivingProfiles`）
- 描述：normalize 在 init/replace 中、validate 之前执行，每个账户只保留第一份 profile，`receivingMethods` 被清空。
- 预期：`FINANCE_MODEL.md:10,27` 写“多组收款资料”。／实际：两组写入后只剩 1 组。
- 触发/复现：`AuditReproTests.auditPaymentAccountKeepsMultipleReceivingProfiles`（失败＝复现）。
- 证据：r3.xcresult。
- 根因：模型已改为一对一（`receivingProfile`），文档仍写多组；也可能是有意简化，需产品确认。／影响范围：Wise 等多币种收款信息被静默丢弃。
- 修复方案：确认需求后，要么恢复数组模型，要么修改 FINANCE_MODEL.md 并在 UI 上明确一对一。／修复风险：中（模型变更需迁移）。
- 回归测试方案：沿用复现测试或改为断言一对一并在丢弃时报错。
- 关联问题/依赖：需求冲突，未改文档。
- 处理记录（2026-10-14，阶段 2）：按代码口径裁决为“一个支付账户一份收款资料”，`FINANCE_MODEL.md` 已同步；复现测试当时改为单套断言。
- 后续需求（2026-10-15）：用户明确要求同一支付币种账户支持多套资料，已以 schema v4 和 `receivingProfiles` 数组替代上述裁决；回归入口为 `auditPaymentAccountKeepsMultipleReceivingProfilesPerAccount` 与 `paymentProfilesMigrateAndRoundTripWithoutLosingIdentity`。

### AUDIT-021 FinanceStore.cleanupRedundantData 为空实现
- 编号：AUDIT-021｜严重程度：P2｜模块：Finance｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Finance/Application/FinanceStore.swift:35`
- 描述：`func cleanupRedundantData() {}`。存储设置页的“冗余数据扫描”能列出 Finance 的发现，但执行清理后什么都不变。
- 预期：清理后扫描结果为空。／实际：`ModuleStoreTests.financeCleanupRemovesOnlyFieldsThatDoNotApplyToTheCurrentType` 失败。
- 触发/复现：r1.xcresult。
- 证据：代码与测试。
- 根因：schema 3 重写时移除了清理实现。／影响范围：用户点击清理后误以为已清理。
- 修复方案：按 schema 3 字段重新实现，或在扫描中不再报告 Finance 项。／修复风险：低，注意不能误删用户数据。
- 回归测试方案：现有测试按新模型改写。
- 关联问题/依赖：AUDIT-012。
- 处理记录（2026-10-14，阶段 2）：`FinanceStore.cleanupRedundantData` 按 schema 3 实现（非自定义账户类型的 customType、银行境内/境外不适用字段），扫描与清理共用同一规则；`ModuleStoreTests` 已按新模型改写。

### AUDIT-022 DecimalTextParser 接受带后缀文本
- 编号：AUDIT-022｜严重程度：P2｜模块：Core/Formatting｜验证状态：已复现｜处理状态：已修复
- 文件位置：`Core/Formatting/DecimalTextParser.swift:6-13`（全项目约 43 处调用）
- 描述：直接返回 `Decimal(string:locale:)`，它只要求前缀合法。
- 预期：整串必须是合法数字，否则 nil。／实际：“100元”→100，“12abc”→12。
- 触发/复现：`AuditReproTests.auditDecimalParserRejectsTrailingText`（失败＝复现）。
- 证据：r3.xcresult。
- 根因：Foundation API 的前缀解析语义。／影响范围：所有金额、价格、股数输入的校验；用户误输入不报错而被截断。
- 修复方案：用 `Scanner` 并要求 `isAtEnd`，或先正则校验。／修复风险：中，需检查调用方是否依赖宽松行为（如带货币符号）。
- 回归测试方案：沿用复现测试，补“1.2.3”“1e5”“-0”“.5”等。
- 关联问题/依赖：AUDIT-087。
- 处理记录（2026-10-14，阶段 3）：DecimalTextParser 改为整串校验，“100元”“12abc”被拒绝；`AuditReproTests` 中对应用例已移除 `withKnownIssue`。

### AUDIT-023 支付编辑器吞掉保存错误，删除账户留下悬挂引用
- 编号：AUDIT-023｜严重程度：P2｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/FinancialArchiveEditors.swift:619`、`:639`
- 描述：保存用 `do { try store.saveInstitution(...); dismiss() } catch {}`；删除账户直接 `paymentAccounts.removeAll`，logins/documents 中的 accountID 未清理。
- 预期：失败有提示；删除账户同时清理引用。／实际：冲突或校验失败时页面不关闭也无提示；删除后保存必然抛 `invalidRelationships`。
- 触发/复现：给支付账户绑定登录信息 → 删除账户 → 保存。
- 证据：代码。／根因：未使用 `institution.removeAccount`，错误被吞。／影响范围：支付机构编辑。
- 修复方案：改用 `removeAccount`；catch 中弹 alert。／修复风险：低。
- 回归测试方案：Domain 层测试 removeAccount 后 validate 通过；UI 错误提示手测。
- 关联问题/依赖：AUDIT-025。
- 处理记录（2026-10-15）：支付机构编辑器保存失败时弹出错误提示；滑动删除与 `FinancialInstitution.removeAccount` 同时清理 `paymentAccounts` 中的悬挂引用。

### AUDIT-024 支付账户详情保存缺少打开时快照
- 编号：AUDIT-024｜严重程度：P2｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/FinancialArchiveViews.swift:608-620`
- 描述：保存时 `expected` 取自当前 store，而非页面打开时的快照；失败只返回 false。
- 预期：AGENTS.md:106、`FINANCE_MODEL.md:23` 要求打开时快照做冲突检测。／实际：并发修改（如 CloudKit 同步）被静默覆盖。
- 触发/复现：打开详情期间另一设备修改同一机构并同步。
- 证据：代码。／根因：未复用 `BrokerageAccountSaveView` 的模式。／影响范围：支付账户编辑。
- 修复方案：参照 BrokerageAccountSaveView 保存打开时快照，失败提示。／修复风险：低。
- 回归测试方案：Store 层：用旧快照保存应抛冲突。
- 关联问题/依赖：AUDIT-025。
- 处理记录（2026-10-15）：新增 `PaymentAccountSaveView(original:accountID:)`，以打开编辑时的快照作为 expected；详情页改用 `editingInstitution`。

### AUDIT-025 子账户直接从数组移除导致无法保存；replaceAccount 结果被忽略
- 编号：AUDIT-025｜严重程度：P2｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/BankAccountViews.swift:108,737,753`；`Finance/Presentation/FinancialArchiveEditors.swift:775`；`Finance/Presentation/SubaccountEditorViews.swift:87,295`
- 描述：子账户删除直接改数组，卡片 `linkedFinancialAccountIDs`、logins、documents、收款资料中的引用保留；多处 `_ = store.replaceAccount(...)` 丢弃返回值。
- 预期：删除子账户后可正常保存；冲突时提示。／实际：有关联登录时删除子账户再保存抛 `invalidRelationships`；冲突时编辑内容静默丢失。
- 触发/复现：子账户有关联登录 → 删除 → 保存。
- 证据：代码。／根因：绕过聚合根的 removeAccount；忽略结果。／影响范围：银行子账户编辑。
- 修复方案：统一走 removeAccount；处理 replaceAccount 返回值并提示。／修复风险：低。
- 回归测试方案：Domain 测试删除带引用子账户后 validate 通过。
- 关联问题/依赖：AUDIT-023、AUDIT-024。
- 处理记录（2026-10-15）：新增 `FinancialInstitution.upsertAccount`：写回顶层账户并对被移除的子账户调用 `removeAccount`；子账户滑动删除改走 `removeSubaccount`，同时清理银行卡的关联账户；`replaceAccount` 失败时三个详情页弹出“无法保存 / 编辑期间资料已变化”。机构档案保存同时写回被清理关联的卡片。

### AUDIT-026 网点无坐标时回退到天安门
- 编号：AUDIT-026｜严重程度：P2｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/BankAccountViews.swift:14,18,1164,1180`；`Finance/Domain/BankCard.swift:418`
- 描述：无坐标时地图中心与默认坐标使用天安门。
- 预期：README:65 写明不预填天安门。／实际：预填。
- 触发/复现：新建无坐标网点并打开地图。
- 证据：代码。／根因：保留了旧默认值。／影响范围：用户若直接保存会写入错误坐标。
- 修复方案：无坐标时使用当前位置或不显示标注，且不写入默认坐标。／修复风险：低。
- 回归测试方案：新建网点不设坐标，保存后坐标为 nil。
- 关联问题/依赖：无。
- 处理记录（2026-10-14，阶段 3）：移除 `BankBranchLocation.defaultLocation`；无有效坐标时导航改为按网点名称在地图 App 中搜索（`MapNavigationSupport.searchURL`），选点地图以手机当前定位为中心且不预选坐标；`ModuleStoreTests` 断言无坐标网点生成名称搜索链接。

### AUDIT-027 被隔离模块恢复后不落盘；Finance/Documents 模板恢复丢失
- 编号：AUDIT-027｜严重程度：P2｜模块：备份｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Composition/AppStoreBackupMerger.swift:26-36,84-89,97-119`；`Core/Persistence/SecureStore.swift:84`；`Core/Persistence/VaultData.swift:511-605`
- 描述：(1) 非 Finance 模块被隔离（unavailable）时恢复备份，Merger 不清除 `unavailableModules` 与 preserved 载荷，编码时 preserved 优先，导入数据不会写入；(2) Finance 恢复删除了 preserved 模板 key，但没把备份中的模板赋回；Documents 未恢复 `credentialFieldTemplates`。
- 预期：恢复后数据与模板持久化。／实际：重启后导入的数据或模板消失。
- 触发/复现：先让某模块解码失败被隔离，再从备份恢复该模块，重启。
- 证据：代码路径。／根因：恢复逻辑未覆盖隔离状态与模板字段。／影响范围：自救恢复场景、自定义模板。
- 修复方案：恢复模块时清除对应隔离状态与 preserved 载荷；补齐模板赋值。／修复风险：中。
- 回归测试方案：隔离 → 恢复 → 重新加载，断言数据与模板存在。
- 关联问题/依赖：AUDIT-006。
- 处理记录（2026-10-14，阶段 3）：恢复被隔离的模块时清除隔离状态与原始载荷并落盘，Finance/Documents 模板随模块恢复；`AppStoreBackupMergerTests`。

### AUDIT-028 一只股票非法则整批原样返回本地数据，界面仍提示成功
- 编号：AUDIT-028｜严重程度：P2｜模块：备份｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Composition/AppStoreBackupMerger.swift:58`；`App/Composition/AppStore.swift:609`
- 描述：备份中任意一只股票校验失败，Merger 返回本地原数据，但上层照常提示恢复成功。
- 预期：失败应报错并说明原因。／实际：用户以为已恢复。
- 触发/复现：构造一只市场/代码非法的股票的备份并恢复。
- 证据：代码。／根因：错误被转化为“无变更”。／影响范围：股票模块恢复。
- 修复方案：抛出可展示的错误，或跳过非法条目并提示数量。／修复风险：低。
- 回归测试方案：上述备份恢复断言抛错。
- 关联问题/依赖：AUDIT-006。
- 处理记录（2026-10-14，阶段 3）：备份中存在会导致负持仓的股票时整体报错（`VaultBackupError.invalidStockHoldings`），本地数据不变，界面不再提示成功；`AppStoreBackupMergerTests`。

### AUDIT-029 zone 被删后无 payload 的记录无法重新上传
- 编号：AUDIT-029｜严重程度：P2｜模块：Core/CloudSync｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/CloudSync/CloudKitSyncWorker.swift:462,487-494,840-843`
- 描述：zone 被删除后重新入队，但为省空间已丢弃 payload 的记录被跳过。
- 预期：zone 重建后云端得到完整数据。／实际：云端缺失这些记录，新设备拿不到。
- 触发/复现：在 iCloud 设置中删除 App 数据后继续使用（未测试）。
- 证据：代码。／根因：重传依赖缓存的 payload。／影响范围：多设备一致性。
- 修复方案：zone 重建时从当前本地快照重新生成全部记录。／修复风险：中。
- 回归测试方案：模拟 zoneNotFound，断言所有本地实体被重新入队并带 payload。
- 关联问题/依赖：AUDIT-002；README 中的“重建 iCloud 数据”功能代码未实现。
- 处理记录（2026-10-14，阶段 3）：检测到 zone 被删后清空同步令牌，按当前本地快照重建全部条目并重新入队上传（`CloudSyncStateStore` 重建入口）；`CloudSyncMergerTests`。

### AUDIT-030 远端 schemaVersion 只写不读
- 编号：AUDIT-030｜严重程度：P2｜模块：Core/CloudSync｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/CloudSync/CloudKitSyncWorker.swift:456`
- 描述：上传时写入 schemaVersion，接收时从不检查。
- 预期：旧客户端遇到更高版本记录时不覆盖。／实际：旧版本解码后丢失新字段，再上传会覆盖新设备的数据。
- 触发/复现：两台设备 App 版本不同（未测试）。
- 证据：全文无读取。／根因：版本协商未实现。／影响范围：版本不一致的多设备。
- 修复方案：接收时版本高于本地支持则保留原始记录、不回写。／修复风险：中。
- 回归测试方案：注入高版本记录，断言不产生 saveRecord。
- 关联问题/依赖：AUDIT-002。
- 处理记录（2026-10-14，阶段 3）：上传时写入并在拉取时读取记录 schemaVersion；更高版本的记录标记为“需新版客户端”，原样保留，不回写也不删除，升级后由待应用重试处理；`CloudSyncMergerTests`。

### AUDIT-031 明文迁移直接写正式文件
- 编号：AUDIT-031｜严重程度：P2｜模块：Core/Persistence｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/Persistence/SecureStore.swift:152,284`
- 描述：旧明文库迁移为加密库时直接写正式文件，没有“临时文件 → 解密回读比对 → 替换”，恢复快照在替换之后才生成。
- 预期：AGENTS 禁止原地修改正式文件。／实际：迁移中断或加密结果异常时无可回退副本。
- 触发/复现：仅旧版本升级用户；未测试。
- 证据：代码。／根因：迁移路径未复用常规安全写入。／影响范围：升级用户的全部数据。
- 修复方案：迁移前先备份明文文件，再走常规写入流程。／修复风险：低。
- 回归测试方案：迁移中注入写失败，断言原明文文件仍在。
- 关联问题/依赖：文档冲突：README 写“原地升级”，AGENTS 禁止原地修改。
- 处理记录（2026-10-14，阶段 3）：明文迁移改为“保存 `pre-encryption-*.snapshot` → 写临时文件 → 解密回读比对 → 原子替换”，失败时保留原文件；`SecureStoreEncryptionTests`。README 已同步。

### AUDIT-032 删除功能数据立即落盘，撤回快照只在内存
- 编号：AUDIT-032｜严重程度：P2｜模块：App/Composition｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Composition/AppStore.swift:718-728`
- 描述：开始删除时立即 `persist()`，撤回用的 `pendingModuleLocalDataDeletion` 只存于内存。
- 预期：README:232 承诺的撤回期内可撤销。／实际：撤回窗口内 App 被杀，撤回能力丢失；重启后该模块恢复参与同步；附件不会被最终清理，成为孤立文件。
- 触发/复现：删除功能数据后立即强杀 App。
- 证据：代码。／根因：撤回状态未持久化。／影响范围：设置页“删除功能数据”。
- 修复方案：撤回期内不落盘（延迟到窗口结束），或持久化待删除状态。／修复风险：中。
- 回归测试方案：删除后重建 AppStore，断言数据仍在或待删除状态被恢复。
- 关联问题/依赖：无。
- 处理记录（2026-10-14，阶段 3）：撤回窗口内的每次写盘都把待删除模块的快照数据合并回去，清空状态在窗口结束前不会落盘；App 在窗口内被杀，重启后数据仍在。

### AUDIT-033 云端偏好覆盖本机显隐，默认值被当作显式值上传
- 编号：AUDIT-033｜严重程度：P2｜模块：App/Modules｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`App/Modules/ToolModuleSettings.swift:142-179`
- 描述：`applySyncedPreferences` 无条件写回 UserDefaults；`syncedModuleVisibility` 把编译默认值也作为显式值上传。
- 预期：AGENTS:28“本地 UserDefaults 优先”。／实际：新设备首次同步会用默认值覆盖其他设备的显隐选择。
- 触发/复现：设备 A 显示某默认隐藏模块，安装到设备 B 首次同步。
- 证据：代码。／根因：未区分“未设置”与“显式设置”。／影响范围：首页模块显隐与排序。
- 修复方案：只上传显式设置；应用时本地已有显式值则保留。／修复风险：低。
- 回归测试方案：两份 UserDefaults 模拟双设备。
- 关联问题/依赖：AUDIT-046。
- 处理记录（2026-10-14，阶段 3）：只同步显式设置：未自定义的排序上传空数组，显隐只含显式值；收到的显式值应用到本机，空排序忽略；`ModuleStoreTests`。AGENTS.md 已同步。

### AUDIT-034 远程推送注册只存在于 Stocks 模块
- 编号：AUDIT-034｜严重程度：P2｜模块：App/CloudSync｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Application/StockRefreshCoordinator.swift:579`（全项目唯一的 `registerForRemoteNotifications`）
- 描述：CloudKit 静默推送依赖远程通知注册，但注册放在 Stocks 刷新协调器中。
- 预期：App 启动即注册，与模块裁剪无关。／实际：裁掉 Stocks 的构建，以及 macOS 上（该文件路径为 iOS），都不注册，CloudKit 变更只能靠前台拉取。
- 触发/复现：`MYTOOLS_FEATURE_STOCKS` 关闭构建（未测试）。
- 证据：grep 结果。／根因：职责放错位置。／影响范围：同步及时性。
- 修复方案：移到 App 启动或 CloudSync 层，iOS/macOS 各自注册。／修复风险：低。
- 回归测试方案：裁剪构建下检查注册调用（可用依赖注入的 application 代理）。
- 关联问题/依赖：AUDIT-035。
- 处理记录（2026-10-14，阶段 3）：远程推送注册移到 App 层 `ToolBoxAppDelegate`，不再依赖 Stocks 模块是否编译。

### AUDIT-035 macOS Release entitlements 疑似不完整
- 编号：AUDIT-035｜严重程度：P2｜模块：工程配置｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`MyToolsMacRelease.entitlements`
- 描述：缺 `com.apple.security.files.user-selected.read-write`、`com.apple.security.personal-information.location`；推送使用 `aps-environment`，macOS 应为 `com.apple.developer.aps-environment`。
- 预期：macOS 上备份导入导出、定位、推送可用。／实际：未运行 macOS target，无法确认。
- 触发/复现：macOS 版执行导出备份、地图定位。
- 证据：文件内容。／根因：沿用 iOS 配置。／影响范围：macOS 用户。
- 修复方案：补齐沙盒权限并修正键名，用真机验证。／修复风险：低（涉及签名配置，需所有者确认）。
- 回归测试方案：macOS 手测导入导出、定位、CloudKit 推送。
- 关联问题/依赖：AUDIT-034、AUDIT-085。
- 处理记录（2026-10-15）：`MyToolsMacRelease.entitlements` 补 `com.apple.security.files.user-selected.read-write`、`com.apple.security.personal-information.location`，`aps-environment` 改为 macOS 键 `com.apple.developer.aps-environment`；`plutil -lint` 通过，macOS 构建通过。未在签名的 Release 真机上验证文件导入、定位与推送，需真机确认。

### AUDIT-036 Partnership 补录早期流出只校验该日期前的余额
- 编号：AUDIT-036｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:206,234,481-485`
- 描述：`withdraw` 与买入以 `through: date` 计算余额，忽略该日期之后已有的取出与亏损重投。
- 预期：README:206 个人取出不超过当前可用现金，任何时点余额 ≥ 0。／实际：B 在 T2 取出 1500 后补录 T1 买入 10500，校验通过，总可用资金最终 −1500。
- 触发/复现：按上述步骤（未编写测试）。
- 证据：代码。／根因：只校验插入点。／影响范围：补录历史流水。
- 修复方案：插入后重放全部流水，所有时点余额 ≥ 0 才接受。／修复风险：低。
- 回归测试方案：上述场景断言抛错。
- 关联问题/依赖：AUDIT-009。

### AUDIT-037 Partnership 撤销只删最后一条记录
- 编号：AUDIT-037｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:173-176,187-190,404,411`
- 描述：撤销实现为“删掉最后一条记录（或同 operationID 的一组）”。重命名不产生记录；新成员加入只删注资、成员保留；按比例注资多条记录无 operationID。
- 预期：撤销恢复到上一次操作前。／实际：重命名后撤销会误删一条交易；其余两种只撤销一部分。
- 触发/复现：重命名账本后点“撤销最近一次修改”。
- 证据：代码。／根因：撤销基于记录而非操作。／影响范围：账本数据被误删（可“取消撤回”恢复，但见 AUDIT-039）。
- 修复方案：撤销改为恢复操作前的整本账快照，或每个操作带 operationID 并覆盖成员变更。／修复风险：中。
- 回归测试方案：三种操作各自撤销后与操作前账本相等。
- 关联问题/依赖：AUDIT-038、AUDIT-039。

### AUDIT-038 Partnership 导入含股息时撤销不是原子的
- 编号：AUDIT-038｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:103-107,359`
- 描述：批量导入的买卖记录带同一 operationID，`recordDividend` 不接收 operationID。股息日期最晚时排在最后，撤销只删股息。
- 预期：README:207 批量导入整体撤销。／实际：买卖记录残留。
- 触发/复现：从股票投资导入含股息的交易后撤销。现有测试 `importIsAtomicAndUndoRevertsTheWholeImport` 只覆盖买入。
- 证据：代码。／根因：参数缺失。／影响范围：导入撤销。
- 修复方案：`recordDividend` 增加 operationID 参数。／修复风险：低。
- 回归测试方案：扩展现有测试加入股息。
- 关联问题/依赖：AUDIT-037。

### AUDIT-039 Partnership 取消撤回抹掉“撤销”审计日志
- 编号：AUDIT-039｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:429,442-446`
- 描述：取消撤回时恢复撤销前快照（其中没有“撤销”日志），再追加“取消撤回”。
- 预期：AGENTS“不可变审计日志”、README:207。／实际：“撤销”记录永久消失。
- 触发/复现：撤销 → 取消撤回 → 查看审计日志。
- 证据：代码。／根因：快照恢复覆盖了 auditLog。／影响范围：审计可追溯性。
- 修复方案：恢复快照时保留当前 auditLog 再追加。／修复风险：低。
- 回归测试方案：断言日志中撤销与取消撤回均存在。
- 关联问题/依赖：AUDIT-037。

### AUDIT-040 Partnership 卖出分成比例未保存
- 编号：AUDIT-040｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Presentation/PartnershipView.swift:456`；`Partnership/Application/PartnershipStore.swift:81,319`；`PartnershipEditorViews.swift:420`
- 描述：每笔卖出可单独填比例，但记录不保存；流水显示 `book.adjustmentRate`；导入默认 5%，忽略账本比例。
- 预期：流水显示实际使用的比例。／实际：填 10% 显示 5%。
- 触发/复现：卖出时修改比例后查看流水。
- 证据：代码。／根因：字段未冻结。／影响范围：展示与审计。
- 修复方案：`PartnershipRecord` 增加 Optional 的 adjustmentRate；导入默认取账本比例。／修复风险：低（Optional 兼容旧数据）。
- 回归测试方案：卖出 10% 后读回记录比例。
- 关联问题/依赖：无。

### AUDIT-041 单价超过两位小数的股票交易无法导入 Partnership
- 编号：AUDIT-041｜严重程度：P2｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:476`；`App/Composition/AppStore.swift:35`；`Stocks/Presentation/StockTransactionEditorView.swift:36`
- 描述：`validAmount(price)` 要求最多两位小数；股票模块单价保留 4 位，由总额反推的单价常有更多位。导入为原子操作。
- 预期：可以导入。／实际：整批失败。
- 触发/复现：股票交易单价 12.345 后导入合伙账本。
- 证据：代码。／根因：价格与金额共用精度校验。／影响范围：从股票投资导入。
- 修复方案：单价不限两位，只要求现金金额精确到分。／修复风险：低。
- 回归测试方案：4 位小数单价导入成功。
- 关联问题/依赖：无。

### AUDIT-042 Bills 重复导入覆盖用户补充的分类、标签、备注
- 编号：AUDIT-042｜严重程度：P2｜模块：Bills｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Bills/Application/BillsStore.swift:73-77`
- 描述：匹配到已有记录后 `records[index] = stored`，只保留 id 与 createdAt。微信适配器标签恒为 `[]`，分类只有 other/transfer/refund。
- 预期：重复导入只更新平台字段。／实际：用户改过的分类、标签、备注被覆盖。
- 触发/复现：导入 → 改分类加标签 → 再导入同一份账单。
- 证据：代码。／根因：整条替换。／影响范围：微信/支付宝导入用户。
- 修复方案：只覆盖金额、状态、平台原值等平台字段。／修复风险：低。
- 回归测试方案：上述步骤断言分类、标签保留。
- 关联问题/依赖：AUDIT-010。
- 处理记录（2026-10-15）：重复导入平台账单时 `BillsStore.merged(_:into:)` 只刷新平台字段：保留用户的分类与非空备注，标签取并集，id 与 createdAt 不变。`BillsTests.platformReimportOnlyRefreshesPlatformFields`。

### AUDIT-043 支付宝“交易关闭”映射为取消，可能重复冲减
- 编号：AUDIT-043｜严重程度：P2｜模块：Bills｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`Bills/Infrastructure/BillImportAdapters.swift:346-358`；`Bills/Domain/BillAnalytics.swift:191`
- 描述：“关闭/取消/失败”→ cancelled；含“退款”字样→ refund。若全额退款后原支出行显示“交易关闭”，原支出被排除，退款行仍从净支出扣减。
- 预期：净支出不重复冲减。／实际：可能偏小甚至为负（取决于真实账单格式）。
- 触发/复现：需真实样本（`MYTOOLS_ALIPAY_BILL_SAMPLE`），未验证。
- 证据：映射代码。／根因：状态语义未结合退款行判断。／影响范围：账单分析。
- 修复方案：按订单号配对“关闭 + 退款”，或映射为 refunded。／修复风险：中。
- 回归测试方案：构造配对样本断言净支出为 0。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`AlipayBillImportAdapter` 导入后执行 `pairingClosedExpensesWithRefunds`：“交易关闭”的支出如有金额不超过原额、交易号相同或以原交易号为前缀的退款，改记为已退款并关联退款记录，不再重复冲减。`BillsTests.alipayClosedExpenseWithRefundIsNotSubtractedTwice`。配对规则基于样例结构推断，需用真实支付宝导出样本复核。

### AUDIT-044 Bills 分析页一次 body 重算数十次
- 编号：AUDIT-044｜严重程度：P2｜模块：Bills｜验证状态：静态确认（耗时未实测）｜处理状态：已修复
- 文件位置：`Bills/Presentation/BillAnalysisView.swift:31-45,56-62`
- 描述：`snapshot` 为计算属性，一次 body 读取 26 次；`previousSnapshot` 9 次；`currency` 每次对全部记录建 Set。
- 预期：每次渲染只算一次。／实际：全量过滤聚合排序重复执行。
- 触发/复现：记录数较多时打开分析页（未实测）。
- 证据：读取次数统计。／根因：与 AGENTS 记录的 2026-09-22 股票看门狗崩溃同类。／影响范围：大数据量下卡顿甚至看门狗终止。
- 修复方案：body 内局部常量或 `@State` 缓存。／修复风险：低。
- 回归测试方案：性能测试或 Instruments 对比。
- 关联问题/依赖：AUDIT-075。
- 处理记录（2026-10-15，阶段 4）：`BillAnalysisView` 新增私有 `BillAnalysisCache`，按 refreshID、区间、周期、币种缓存本期与上期 snapshot 及可选币种列表，一次 body 只计算一次；记录变化经 `onReceive(store.$records)` 刷新 refreshID 失效。Bills 默认不编译，本次临时以 `MYTOOLS_ENABLE_BILLS` 构建验证并运行 `BillsTests`（16 项通过；其中 `vaultBackupAndCloudRespectBillsModuleBoundary` 的断言已按 AUDIT-006 “整体替换”裁决更新）。耗时未实测。

### AUDIT-045 4 个可选币种永远取不到现汇价
- 编号：AUDIT-045｜严重程度：P2｜模块：CurrencyExchange｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`CurrencyExchange/Presentation/CurrencyExchangeView.swift:366-376`；`Core/Currency/CurrencyCode.swift:84-90`；`Core/Currency/ForeignExchangeRateService.swift:59,61`
- 描述：ILS 名称与中行页面不一致（“以色列新谢克尔”对“以色列谢克尔”）；UGX 中行无此币种；CZK、PLN 只有现钞价，现汇买入为空而正则要求数字。总损耗只要一条缺价就返回 nil。`ExchangeRateStore.apply` 整体覆盖，漏抓的币种连旧值也丢。
- 预期：其余记录照常显示损耗。／实际：总损耗一直“待同步”。
- 触发/复现：任意一条记录使用上述币种。中行页面是否带 `data-currency` 属性未验证。
- 证据：代码与当日抓取的页面文本。／根因：币种列表与数据源不匹配。／影响范围：换汇概览。
- 修复方案：从可选列表移除或标注；总额显示“已知合计 + 缺价笔数”；合并快照保留旧值。／修复风险：低。
- 回归测试方案：ILS 记录无牌价时总额部分显示；中行 HTML fixture 解析测试。
- 关联问题/依赖：README 币种列表已按代码修正为 24 种。
- 处理记录（2026-10-14，阶段 3）：ILS 改用中行页面名称，UGX 不再请求中行牌价；只有现钞价的币种回退到现钞价；拉取结果与旧快照合并，漏抓币种保留旧值；总额改为“已知合计 + 缺价笔数”；`ExchangeRateRepositoryTests`。

### AUDIT-046 体彩模块默认隐藏时自动刷新仍联网
- 编号：AUDIT-046｜严重程度：P2｜模块：SportsLottery｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`SportsLottery/Application/SportsLotteryRefreshCoordinator.swift:25-41,63-71`；`App/Navigation/RootView.swift:58-61,88-89`；`Config/Shared.xcconfig:30`
- 描述：RootView 无条件调用 `SportsLotteryRefreshCoordinator.shared.update(scenePhase:)`；协调器不检查可见性，没有 `ModuleLifecycleParticipant`；未保存偏好时默认 6 个联赛。
- 预期：AGENTS:27 首页隐藏即停止后台刷新。／实际：从未打开体彩的用户每次进前台与每个时段都发起完整抓取（每场比赛 2 个补全请求）。
- 触发/复现：默认配置启动 App，抓包可见（未实测网络）。
- 证据：代码。／根因：未接入模块生命周期。／影响范围：流量、电量、隐私（对第三方接口暴露使用）。
- 修复方案：参照 `StockRefreshCoordinator.updateModuleVisibility` 接入可见性。／修复风险：低。
- 回归测试方案：可见性 false 时 HTTP 桩收到 0 次请求。
- 关联问题/依赖：AUDIT-033。
- 处理记录（2026-10-14，阶段 3）：按裁决（报告 4.2 #31）以代码为准：README 已改为比分“暂无数据”、玩法结果“暂无”，并注明首页隐藏不停止前台定时刷新。刷新逻辑本身暂不调整，SportsLottery 仍未编译。
- 处理记录（2026-10-15）：AGENTS.md 首页隐藏一条注明体彩隐藏不停止前台定时刷新的现有例外；代码未改（模块未编译）。
- 处理记录（2026-10-15）：`SportsLotteryRefreshCoordinator.updateModuleVisibility(_:)`：首页隐藏体彩时停止前台定时检查并取消 BGTask，`refreshIfDue` 与后台调度都受 `isModuleVisible` 守卫；`AppStore.moduleVisibilityChanged` 与 App 启动时同步可见性。AGENTS.md 与 README 的“例外”描述已改回。`SportsLotteryTests.hiddenModuleStopsAutomaticRefresh`。

### AUDIT-047 FoodMap 城市名未归一导致刷新失败和重复导入
- 编号：AUDIT-047｜严重程度：P2｜模块：FoodMap｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`FoodMap/Domain/DianpingImport.swift:88-102`；`FoodMap/Presentation/DianpingImportView.swift:754,761-763`；`FoodMap/Domain/ChinaAdministrativeDivision.swift:214-222`
- 描述：导入时 `infer` 返回标准名“北京市”，合集页候选为“北京”，比较不做别名归一。
- 预期：同一店铺匹配成功。／实际：无 shopURL 的记录永远刷新不到；重复导入合集产生重复记录。测试夹具 `FoodMapTests.swift:216,238` 直接写“北京”，掩盖了问题。
- 触发/复现：先用 infer 生成 existing，候选 city 为“北京”，断言 matchesExisting（未编写）。
- 证据：代码。／根因：两侧未统一归一化。／影响范围：大众点评导入与批量刷新。
- 修复方案：比较前统一走 cityAlias 或都经过 infer。／修复风险：低。
- 回归测试方案：上述用例。
- 关联问题/依赖：无。

### AUDIT-048 FoodMap 浏览器 sheet 关闭后 webView 为 nil
- 编号：AUDIT-048｜严重程度：P2｜模块：FoodMap｜验证状态：静态确认（前提：sheet 关闭后 WKWebView 被释放）｜处理状态：不予处理
- 文件位置：`FoodMap/Presentation/DianpingImportView.swift:17,31-38,53,560,594,602,730`
- 描述：同一 model 被后台 1×1 视图与 sheet 两个 representable 共享，`weak var webView` 被 sheet 的视图替换，sheet 关闭后变 nil，后台视图不会重新 attach。两个 WebView 的 delegate 都是同一个 model。
- 预期：关闭 sheet 后仍可解析单店链接。／实际：报“登录页面尚未准备好”。
- 触发/复现：打开“登录并加载链接”→ 关闭 → 粘贴单店链接点“解析”。
- 证据：代码。／根因：共享 model 持有弱引用。／影响范围：导入流程。
- 修复方案：model 强持有唯一 WKWebView，两个 representable 复用。／修复风险：中（WebView 生命周期）。
- 回归测试方案：手测上述流程。
- 关联问题/依赖：AUDIT-049。

### AUDIT-049 FoodMap 非 http 导航强制跳转登录页
- 编号：AUDIT-049｜严重程度：P2｜模块：FoodMap｜验证状态：静态确认（是否触发取决于页面）｜处理状态：不予处理
- 文件位置：`FoodMap/Presentation/DianpingImportView.swift:337-343`
- 描述：`dianping://`、`imeituan://` 或 iframe 中的自定义 scheme 被 cancel 后调用 `openWebLogin()`。
- 预期：只取消导航。／实际：批量刷新中断或解析到登录页，记为“未找到”。
- 触发/复现：依赖页面实际行为，未验证。
- 证据：代码。／根因：过度处理。／影响范围：批量刷新成功率。
- 修复方案：只 cancel；仅主框架登录拦截时跳转。／修复风险：低。
- 回归测试方案：手测。
- 关联问题/依赖：AUDIT-048。

### AUDIT-050 备份/恢复时附件内存峰值高
- 编号：AUDIT-050｜严重程度：P2｜模块：备份｜验证状态：静态确认｜处理状态：待确认
- 文件位置：`Core/Backup/VaultBackup.swift:100-138`
- 描述：附件整体读入内存，经 base64 → AES-GCM → base64 多次放大。
- 预期：附件较多时备份不被系统终止。／实际：峰值约为附件总量的数倍（未实测）。
- 触发/复现：附件总量数百 MB 时导出备份。
- 证据：代码。／根因：单一 JSON 信封格式。／影响范围：附件多的用户。
- 修复方案：流式分块加密或附件单独打包。／修复风险：高（备份格式变更需兼容）。
- 回归测试方案：大附件内存测试。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：未改实现，给出建议：备份格式已升级为 2.0（见 AUDIT-086），内存峰值的根治需要把附件从 JSON 载荷中拆出——方案 A：附件按 1 MB 分块逐块 AES-GCM 加密，写入与 JSON 并列的流式容器；方案 B：备份导出为目录包（`payload.json` + 逐个加密的附件文件）。两者都需要备份格式 3.0 与新旧兼容读取，改动面大，待所有者决定是否投入。

### AUDIT-051 删除股票后旧图表缓存被写回磁盘
- 编号：AUDIT-051｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Application/StockStore.swift:367-372`；`StockChartService.swift:351-363,418-432`；`StockRefreshCoordinator.swift:407`
- 描述：删除时用无序 Task 调 `clearCache(for:)`，不递增 generation；在途子任务、`refreshClosingData` 捕获的旧列表、`refreshAfterFinalSession` 第二周期仍可提交并写盘。
- 预期：实现指南“删除后旧任务不得写回”。／实际：重新添加同代码时看到旧数据。
- 触发/复现：Provider 挂起期间删除股票，再放行（未编写）。
- 证据：代码。／根因：无按 key 的删除状态。／影响范围：图表缓存。
- 修复方案：按 key 墓碑或 generation，提交前校验股票存在。／修复风险：低。
- 回归测试方案：上述步骤断言 `diskStore.load` 为 nil。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`StockChartService` 按 `StockChartStoreKey` 维护删除代数，`clearCache(for:)` 时递增，在途请求写盘前比较，删除后不再写回；`refreshAfterFinalSession` 每轮先校验；`StockRefreshCoordinator.refreshClosingData` 写回前确认股票仍存在且未存档。`StockChartServiceTests.removingStockDiscardsInFlightChartWrite`。

### AUDIT-052 不同市场的合并请求被放大为全市场强刷
- 编号：AUDIT-052｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Application/StockStore.swift:63-72,80-88`
- 描述：合并时市场不同置 nil，任一 stockIDs 为 nil 整体置 nil，forceRefresh 取 OR。
- 预期：按市场分桶合并。／实际：港股手动刷新 + 美股自动刷新 → 全部股票强刷。
- 触发/复现：两次不同市场请求排队，统计 Provider 调用次数（未编写）。
- 证据：代码。／根因：合并粒度过粗。／影响范围：网络与接口限流。
- 修复方案：按市场分桶，ID 取并集。／修复风险：低。
- 回归测试方案：上述计数测试。
- 关联问题/依赖：AUDIT-053。
- 处理记录（2026-10-15）：报价与分时刷新队列改为按“市场 + 股票 ID”分桶的数组：被已有请求覆盖且强度不高的请求直接吸收，范围完全相同的合并强度，其余各自排队，不再放大为全市场强刷。`AppStoreFacadeTests.queuedSingleStockRefreshIsNotWidenedByOtherMarket`。

### AUDIT-053 队列执行者被取消时丢弃其他调用方的请求
- 编号：AUDIT-053｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Application/StockStore.swift:550-556,745`
- 描述：defer 中 `Task.isCancelled` 时把 pending 置 nil，所有等待者按“已完成”返回。前台轮询在进入后台/inactive 时被取消，正好触发。
- 预期：指南“调用方会等待队列完成”。／实际：其他调用方的刷新被丢弃。
- 触发/复现：轮询执行期间切后台，同时有手动刷新排队（未编写）。
- 证据：代码。／根因：取消语义作用于整个队列。／影响范围：刷新可靠性。
- 修复方案：只取消自身份额，其余交给新执行者。／修复风险：中。
- 回归测试方案：取消执行者后断言排队请求仍被执行。
- 关联问题/依赖：AUDIT-052。
- 处理记录（2026-10-15）：队列执行者被取消时，把在途请求与待处理请求合并后交给一个等待者接管（continuation 返回 Bool 表示是否接管），其余等待者正常返回；报价与分时两条队列同样处理。`AppStoreFacadeTests.cancelledQuoteDrainHandsQueuedRequestToWaiter`。

### AUDIT-054 报价时间戳缺失时伪造为当前时间
- 编号：AUDIT-054｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：Tencent Provider :186；Sina :128,162,184；Yahoo :72-74；`EastmoneyStockQuoteProvider.swift:85`；择优 `StockQuoteService.swift:125-144`；`StockQuoteRefreshReducer.swift:64-68`
- 描述：解析不到时间戳时用 `Date()`；择优“时间戳新者胜”，Reducer 拒绝早于 lastQuoteAt 的报价。
- 预期：真实时间较新的报价胜出。／实际：伪造时间挤掉真实报价，收盘覆盖检查误判完成。
- 触发/复现：东方财富与腾讯同时返回（未编写）。
- 证据：代码。／根因：缺失值被填充。／影响范围：报价准确性。
- 修复方案：时间戳缺失传 nil，择优降权。／修复风险：低。
- 回归测试方案：上述双源择优测试。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`StockQuote.updatedAt` 改为可选，各数据源缺时间戳时传 nil（东方财富接口不返回成交时间）；`preferredQuote` 中有时间戳的报价优先；Reducer 遇到 nil 只更新价格、不推进 `lastQuoteAt`。`StockQuoteServiceTests.quoteWithTimestampWinsOverQuoteWithoutTimestamp`、`StockQuoteRefreshReducerTests.undatedQuoteUpdatesPriceButKeepsQuoteTime`。

### AUDIT-055 图表共享请求 key 不含 forceRefresh
- 编号：AUDIT-055｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Application/StockChartService.swift:173-190,241-244`
- 描述／预期／实际：强刷加入已有非强刷请求后，可能只拿到缓存，或因 60 秒窗口得到 noData；预期强刷总能触发网络请求。
- 触发/复现：非强刷请求在途时发起强刷（未编写）。
- 证据：代码。／根因：key 设计。／影响范围：手动刷新体验。
- 修复方案：key 纳入 forceRefresh，或强刷升级在途请求。／修复风险：低。
- 回归测试方案：并发两种请求断言强刷命中网络。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：共享请求 key 改为 `FlightKey(cache:forceRefresh:)`，强制刷新不再加入非强制的在途请求。`StockChartServiceTests.forcedRefreshDoesNotJoinNonForcedFlight`。

### AUDIT-056 停牌股票收盘补刷无上限
- 编号：AUDIT-056｜严重程度：P3｜模块：Stocks/行情｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`Stocks/Application/StockRefreshCoordinator.swift:336-341,393-398,450,461-468`
- 描述：冷却在尝试前打上，无重试上限；:450 未排除已存档股票（:337 排除了）。
- 预期：有限次重试。／实际：永远无法完成的股票每 5 分钟强刷一次。
- 触发/复现：持有停牌股票（未验证）。
- 证据：代码。／根因：无上限。／影响范围：网络。
- 修复方案：加次数上限，并排除存档股票。／修复风险：低。
- 回归测试方案：桩始终返回不完整数据，断言重试次数有限。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：收盘补刷按“市场 + 场次结束时间”计数，每场最多 12 次（`maxClosingRefreshAttempts`）；报价补刷排除存档股票。

### AUDIT-057 分钟数据每次提交整份重编码写盘
- 编号：AUDIT-057｜严重程度：P3｜模块：Stocks/行情｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Infrastructure/Charts/StockChartDiskStore.swift:321`；Tencent 图表 :154-161；Eastmoney 图表 :144-151；`StockQuoteProvider.swift:845-856`
- 描述：每次分钟提交都重编码包括全部日线与指标的整份 store；解析时每个点新建 DateFormatter。
- 预期／实际：增量写入、格式化器复用；现为全量重写与重复创建（耗时未实测）。
- 触发/复现：交易时段持续运行。
- 证据：代码。／根因：存储粒度粗。／影响范围：CPU、磁盘写入、电量。
- 修复方案：分钟数据单独文件；静态缓存 formatter。／修复风险：中（缓存格式变更）。
- 回归测试方案：现有迁移与损坏保护测试须继续通过。
- 关联问题/依赖：无。
- 处理记录（2026-10-15，阶段 4）：未拆分分钟文件（避免缓存格式变更）：`StockChartPersistedStore.differsOnlyInMinuteData` 识别“只有分钟序列、5 日派生、分钟指标与分钟档元数据变化”，此类写入与“内容未变”一样在 5 分钟内合并，日线修正、迁移与失败重试仍立即写入，进程被杀最多丢失 5 分钟分钟缓存。行情与图表解析改用 `StockDateParser`（按格式 + 时区缓存 DateFormatter，Tencent/Eastmoney/Nasdaq 图表与 `StockQuoteProviderSupport` 共用）。`StockChartDiskStoreTests.minuteOnlyChangesAreCoalescedButDailyChangesWriteImmediately`、`StockChartProviderParsingTests.cachedDateParserKeepsFormatAndTimeZoneSeparate`。

### AUDIT-058 成本标签去重以柱序号为单位
- 编号：AUDIT-058｜严重程度：P3｜模块：Stocks/图表｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Presentation/PortfolioChartCanvas.swift:353-370`
- 描述：最小间距 110 与文字宽度估算以柱序号计，与屏幕宽度无关；末尾标签不检查与前一个的间距。
- 预期：标签不重叠。／实际：随数据量变化，末尾两个可能重叠。
- 触发/复现：不同时间范围查看组合走势。
- 证据：代码。／根因：坐标系混用。／影响范围：展示。
- 修复方案：用 ChartProxy 换算屏幕坐标。／修复风险：低。
- 回归测试方案：为 `nonOverlapping` 加单元测试。
- 关联问题/依赖：无。
- 处理记录（2026-10-14，阶段 3）：成本标签改为按屏幕点去重：用图表实际宽度和文字宽度计算间距，末尾（当前成本）必定保留；裁决（报告 4.2 #25）后成本线重新设计为分时/5 日台阶并标注，日K 及以上统一连续折线、不标注，不再在周K 以上混用台阶；`StockPortfolioEditorTests.costLabelsAreThinnedInScreenSpaceAndKeepTheLastLabel`。README 已同步。

### AUDIT-059 周 K 的周起始日不一致
- 编号：AUDIT-059｜严重程度：P3｜模块：Stocks/图表｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`StockChartSeriesProcessor.swift:581`（周一）；`PortfolioChartCanvas.swift:630`；`StockChartPresentation.swift:1619,1989`（系统日历）
- 描述／预期／实际：三处应一致；后两处随地区设置变化，周边界的点或交易标记被归到相邻周 K。
- 触发/复现：地区设为周日起始（如美国）后查看周 K 交易标记。
- 证据：代码。／根因：日历未统一。／影响范围：周 K 展示。
- 修复方案：统一使用处理器的周一日历。／修复风险：低。
- 回归测试方案：参数化 firstWeekday 测试。
- 关联问题/依赖：AUDIT-016。
- 处理记录（2026-10-15）：`StockChartPresentation.calendar(for:)` 与组合图周 K 聚合统一使用 `StockChartSeriesProcessor.marketCalendar`（周一起始、ISO 首周规则）。

### AUDIT-060 组合 K 线高低为包络；休市日也补“今天”
- 编号：AUDIT-060｜严重程度：P3｜模块：Stocks/图表｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/PortfolioValueHistory.swift:173-177,233-235`
- 描述：组合最高/最低为各股之和（上下包络）；实时价补点不判断交易日，只替换收盘，可能落在高低区间外。
- 预期：README:90 汇总开高低收。／实际：高低偏离真实值；周末出现补点。
- 触发/复现：周末打开组合日 K。
- 证据：代码。／根因：近似算法。／影响范围：展示。
- 修复方案：文档注明包络，或用分钟数据计算；补点前判断交易日并同步调整高低。／修复风险：低。
- 回归测试方案：周末 now 断言不补点。
- 关联问题/依赖：AUDIT-013。
- 处理记录（2026-10-14，阶段 3）：所有者要求补充说明后再裁决（报告 4.2 #26）。说明见报告 4.2 #26 的处理列；代码暂未修改。
- 处理记录（2026-10-15）：所有者裁决“能画真实 K 线就画，不能就包络近似”。日K历史没有分钟数据（分钟缓存只覆盖最近约 5 个交易日），无法逐分钟汇总出真实高低，因此采用包络近似：README 注明开收为真实组合价值、高低为各股高低按持仓数量相加的包络。补点问题已修：`buildSeries` 新增 `now` 参数，只在该市场交易日用实时价补今天；今天已有日线时把高低扩到包含实时价、收盘改为实时价。新增 `StockPortfolioEditorTests.liveDailyBarSkipsNonTradingDayAndKeepsCloseWithinRange`。

### AUDIT-061 Finance 归档规则偏差
- 编号：AUDIT-061｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Domain/FinancialInstitution.swift:194-203`
- 描述：abnormal 状态子账户被视为不活跃；非银行机构 `allAccounts` 只含 bankAccounts，券商与支付机构永不归档。
- 预期：README 归档规则（全部账户与卡片关闭才归档，适用于所有机构）。／实际：如上；`ModuleStoreTests.financeArchiveFollowsAccountAndCardClosure` 失败。
- 触发/复现：r1.xcresult；券商账户全部关闭后仍显示在活跃列表。
- 证据：代码与测试。／根因：schema 3 后未覆盖新 kind。／影响范围：首页分组。
- 修复方案：按 kind 汇总账户，明确 abnormal 的归档语义（需产品确认）。／修复风险：低。
- 回归测试方案：改写现有测试并覆盖各 kind。
- 关联问题/依赖：AUDIT-012。
- 处理记录（2026-10-14，阶段 3）：所有者要求补充说明后再裁决（报告 4.2 #19），文档与代码的差异继续记录，代码暂未修改。
- 处理记录（2026-10-15）：所有者裁决以代码为准，代码未改，文档按代码修正：README 金融部分改为机构类型单选、银行分组内“银行/借记卡/信用卡/子账户”总览、停用银行展开、银行归档以卡片为准（无卡片时需机构状态异常或销户，异常子账户不算在用）、券商与支付不归档、银行账户下可挂子账户、银行卡关联账户无编辑入口；FINANCE_MODEL 补充关联与归档规则。`ModuleStoreTests.financeArchiveFollowsAccountAndCardClosure` 移除 `withKnownIssue`，改为代码口径并补机构状态销户时归档的断言。

### AUDIT-062 Finance validate 漏校验
- 编号：AUDIT-062｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Domain/FinancialInstitution.swift:233-249`
- 描述：不检查 fundingProfileIDs 是否属于 routeIDs；不检查附件引用及附件 ID 唯一性；schemaVersion 严格相等，旧版本也报“来自更新版本”。
- 预期：`FINANCE_MODEL.md:23` 校验“附件引用完整”。／实际：未校验；错误提示误导。
- 触发/复现：构造悬挂 fundingProfileID 的机构保存成功（未编写）。
- 证据：代码。／根因：校验不完整。／影响范围：数据完整性。
- 修复方案：补齐校验；版本比较改为 `>`。／修复风险：低。
- 回归测试方案：各类非法引用断言抛错。
- 关联问题/依赖：AUDIT-005。
- 处理记录（2026-10-14，阶段 3）：validate 增加：券商账户引用的入金资料必须存在、附件 ID 不重复；schemaVersion 改为“不高于当前版本”（旧版本已在解码时迁移）；`ModuleStoreTests`。FINANCE_MODEL.md 已列出实际校验项。

### AUDIT-063 未知开户日期在编辑时被改成今天
- 编号：AUDIT-063｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/BankAccountViews.swift:547`
- 描述／预期／实际：`openedAt` 为 nil 时被强制设为 `Date()`；预期保持未知。打开编辑并保存即写入错误日期。
- 触发/复现：编辑无开户日期的账户后保存。
- 证据：代码。／根因：DatePicker 绑定需要非可选值。／影响范围：账户资料准确性。
- 修复方案：增加“未知”开关。／修复风险：低。
- 回归测试方案：草稿往返保留 nil。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：按所有者要求，未知开户日期的默认值为 `FinancialInstitution.defaultOpeningDate`（1970-01-01，北京时间 12:00）：账户编辑草稿、日期行与可选开户日期行均不再落为今天。

### AUDIT-064 子账户编辑入口点击无效
- 编号：AUDIT-064｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/FinancialArchiveViews.swift:832-846`
- 描述／预期／实际：查找目标账户只在顶层 accounts 中进行，子账户查不到，点击无反应。
- 触发/复现：在机构详情点子账户的编辑。
- 证据：代码。／根因：未递归查找。／影响范围：子账户编辑。
- 修复方案：查找包含 subaccounts。／修复风险：低。
- 回归测试方案：查找函数单测。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`upsertAccount` 先在各父账户的子账户中按 ID 就地替换；`FinanceAccountInfoView` 编辑入口改用 `institution.allAccounts`，子账户入口可打开。

### AUDIT-065 支付与其他机构没有删除入口
- 编号：AUDIT-065｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/FinanceHomeView.swift:60-86`；`PaymentInstitutionDetailView`
- 描述／预期／实际：银行（:125）与券商有删除入口；支付与其他机构没有，用户无法删除。
- 触发/复现：进入支付机构详情查找删除。
- 证据：代码。／根因：入口遗漏。／影响范围：数据管理。
- 修复方案：补齐删除入口与确认。／修复风险：低。
- 回归测试方案：手测。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：支付机构详情页与其他机构详情页增加“删除支付机构档案 / 删除金融档案”入口，确认后删除并返回。

### AUDIT-066 Finance 敏感字段处理不一致
- 编号：AUDIT-066｜严重程度：P3｜模块：Finance｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Finance/Presentation/BankCardEditorView.swift:104,378`（CVV 明文）；`BankAccountViews.swift:836`（登录密码明文）；`FinancialArchiveViews.swift:488`（券商账号全文）；`:245`（机构编辑无生物识别）
- 描述／预期／实际：卡片详情有遮罩，但编辑页与部分详情直接显示明文；验证要求不一致。
- 触发/复现：打开上述页面。
- 证据：代码。／根因：缺统一的敏感字段组件。／影响范围：金融隐私。
- 修复方案：统一遮罩组件与验证门槛。／修复风险：低。
- 回归测试方案：手测或快照测试。
- 关联问题/依赖：AUDIT-007。
- 处理记录（2026-10-15）：券商与支付账户详情页的账户号默认掩码，验证身份后才显示全文，离开前台时恢复掩码；四类机构与账户的编辑按钮先验证身份；`FieldEditorRow` 增加 `isSecure`，CVV 与敏感登录字段改用 `SecureField`。

### AUDIT-067 住院日记录被计入就诊次数
- 编号：AUDIT-067｜严重程度：P3｜模块：Health｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Health/Presentation/MedicalRecordsPresentation.swift:135`
- 描述／预期／实际：只排除购药记录；住院 5 天预期计 1 次，实际计 6 次。
- 触发/复现：录入一次多日住院后看年度统计。
- 证据：`guard !record.isPharmacyPurchase else { continue }`。／根因：漏排除 `isInpatientDailyRecord`。／影响范围：统计。
- 修复方案：同时排除住院日记录。／修复风险：低。
- 回归测试方案：断言就诊次数为 1。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`MedicalRecordsPresentation` 的就诊次数跳过购药与住院日记录，住院只计一次。`MedicalRecordsPresentationTests.inpatientDailyRecordsCountAsOneVisit`。

### AUDIT-068 删除仍被引用的医疗机构后会恢复
- 编号：AUDIT-068｜严重程度：P3｜模块：Health｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Health/Application/HealthRecordSynchronizer.swift:118`
- 描述／预期／实际：同步时找不到机构资料就 append 一条新的；用户删除仍被引用的机构，重启后又出现。
- 触发/复现：删除被记录引用的机构后重启。
- 证据：代码。／根因：缺删除标记。／影响范围：机构库管理。
- 修复方案：删除前提示引用，或记录删除标记。／修复风险：低。
- 回归测试方案：删除后重新同步断言不出现。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`HealthStore.referencingRecordCount(for:)` 统计仍引用该机构的记录；医疗机构滑动删除改为确认弹窗，仍被引用时只提示“请先修改或删除这些记录”，不再删除后又被恢复。

### AUDIT-069 锁定状态下的列表级信息泄露
- 编号：AUDIT-069｜严重程度：P3｜模块：Documents、Secrets｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Documents/Presentation/DocumentsView.swift:117,131,349`；`Documents/Application/DocumentsStore.swift:402`；`Secrets/Presentation/SecretVaultView.swift:151`
- 描述：锁定时可按证件号/持有人搜索命中；列表按真实姓名排序；列表显示到期日而详情遮罩；到期通知正文含持有人姓名（锁屏可见）；保密资料列表显示全部标签而详情遮罩。
- 预期：锁定状态与详情页遮罩口径一致。／实际：如上。
- 触发/复现：锁定状态浏览列表与搜索。
- 证据：代码。／根因：遮罩只在详情页实现。／影响范围：隐私。
- 修复方案：锁定时搜索只匹配非敏感字段；通知正文去除姓名。／修复风险：低。
- 回归测试方案：锁定时搜索证件号断言无结果。
- 关联问题/依赖：AUDIT-007。
- 处理记录（2026-10-15）：锁定时：证照搜索只匹配标题、类型、标签、字段名与非敏感字段值（`CredentialDocument.matches(_:includesProtected:)`），按类型排序，行内到期日显示掩码；到期通知正文只含类型与到期日，不含持有人姓名；保密资料搜索不匹配标签，标签筛选只在解锁后显示，离开前台时清空所选标签。

### AUDIT-070 证照闰日期限与提醒窗口
- 编号：AUDIT-070｜严重程度：P3｜模块：Documents｜验证状态：静态确认（提醒窗口）／疑似风险（闰日）｜处理状态：已修复
- 文件位置：`Documents/Domain/CredentialDocument.swift:364`；`Documents/Application/DocumentsStore.swift:398`
- 描述：2 月 29 日签发加 N 年后落在 2 月 28 日，护照为 2 月 27 日（无测试）；已进入提前提醒窗口时一条提醒都不发。
- 预期：按证件规则计算；进入窗口后仍发送剩余提醒。／实际：如上。
- 触发/复现：签发日 2024-02-29；或到期前 20 天新增证件。
- 证据：代码。／根因：日期运算与调度条件。／影响范围：到期提醒。
- 修复方案：补闰日规则；窗口内立即安排下一次提醒。／修复风险：低。
- 回归测试方案：闰日参数化测试；窗口内调度测试。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：`expirationDate` 的“周年前一天”规则在周年日落到不同日号（2-29 签发）时取周年日本身，即 2 月最后一天；`DocumentsStore.reminderFireDate` 在提醒时刻已过但证照未到期时改为次日 9:00（不晚于到期时刻）立即提醒。`DocumentsTests.leapDayIssueEndsOnLastDayOfFebruary`、`reminderInsideWindowFiresAtNextMorningUntilExpiry`。

### AUDIT-071 滑动删除无确认且级联删除
- 编号：AUDIT-071｜严重程度：P3｜模块：Health、Documents、Secrets｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Health/Presentation/HealthRecordsView.swift:236`；`Documents/Presentation/DocumentsView.swift:296`；`Secrets/Presentation/SecretVaultView.swift:170`
- 描述／预期／实际：左滑立即删除，原始就诊/证照的关联记录、全部版本与附件一并删除，无法撤销。预期有确认或撤销。
- 触发/复现：左滑删除。
- 证据：代码。／根因：缺确认。／影响范围：误删。
- 修复方案：确认弹窗并说明级联范围。／修复风险：低。
- 回归测试方案：手测。
- 关联问题/依赖：无。
- 处理记录（2026-10-15）：健康记录、证照、保密资料的滑动删除改为确认弹窗，并说明级联范围（子记录、全部版本、附件与到期提醒）。

### AUDIT-072 Partnership 舍入与零头
- 编号：AUDIT-072｜严重程度：P3｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`Partnership/Application/PartnershipStore.swift:311`；`Partnership/Domain/PartnershipLedger.swift:177,560-562`；`PartnershipEditorViews.swift:193`
- 描述：卖出盈利不舍入到分（与 Ledger:177 注释不符）；3 人等额分摊后显示合计 99.99；每人约 0.0033 的零头无法取出；收益池零头使清账按钮一直可用，每次生成 0.00 清账记录。Ledger:560-562 注释“残差归投资人”与实际（归最后一个正权重成员）不符。
- 预期：现金流按分舍入，清账后收益池清零。／实际：如上（内部 12 位精度下守恒已推演确认）。
- 触发/复现：3 人等额出资买入 100.00 后 110 卖出、清账。
- 证据：代码推演。／根因：舍入点不一致。／影响范围：显示与对账。
- 修复方案：卖出收入先 `money()`；清账忽略 |余额| < 0.005。／修复风险：低。
- 回归测试方案：上述场景断言清账后按钮不可用。
- 关联问题/依赖：AUDIT-008。

### AUDIT-073 Partnership 其他 P3 项
- 编号：AUDIT-073｜严重程度：P3｜模块：Partnership｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：Ledger `:424,467`；Store `:116,375,481`；Editor `:324-327,426`
- 描述：(1) 备注为“初始出资”的注资不受日期过滤，用户手写同名备注会改变历史权重；(2) 清账日期可早于产生收益的卖出；(3) 关闭“自定义汇率”后来源记为 `.bankOfChina` 但数值仍是自定义；(4) 导入日志 recordID 指向股票模块的交易 ID。
- 预期／实际：各项见描述。
- 触发/复现：按各项操作。
- 证据：代码。／根因：魔法字符串与校验缺失。／影响范围：账本正确性与审计日志。
- 修复方案：专用标记字段；清账日期不早于最近卖出；关闭时清空自定义值；记录本账本 ID。／修复风险：低。
- 回归测试方案：逐项单测。
- 关联问题/依赖：AUDIT-039。

### AUDIT-074 Bills 导入文件的资源上限
- 编号：AUDIT-074｜严重程度：P3｜模块：Bills｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Bills/Infrastructure/BillSpreadsheetReader.swift:352-355,364-372`；`Bills/Presentation/BillImportView.swift:136`；`Bills/Infrastructure/BillImportAdapters.swift:154,162`
- 描述：列号 `value * 26 + ...` 在 14 个以上字母时 Int 溢出 trap；`<row r="900000000">` 驱动 `rows.append([])` 循环放大内存；`Data(contentsOf:)` 无大小上限；支付宝 CSV 在 canImport 与 decode 各完整解码一次。
- 预期：恶意或损坏文件给出错误。／实际：崩溃或内存耗尽。
- 触发/复现：构造 `<c r="ZZZZZZZZZZZZZZZ1">` 与超大 r 属性（未编写）。
- 证据：代码。／根因：缺上限。／影响范围：用户选择的外部文件。
- 修复方案：列上限 16384、行上限约 1,048,576；文件 >20MB 拒绝；canImport 只读前几 KB。／修复风险：低。
- 回归测试方案：上述两个 fixture。
- 关联问题/依赖：AUDIT-087（deflate 路径无测试）。
- 处理记录（2026-10-15）：导入文件上限 20 MB（选择后先读 `fileSizeKey`，`decode` 再校验）；XLSX 解析遇到列号 ≥ 16384 或行号 > 1048576 即中止并报 `oversizedFile`，`columnIndex` 超限提前返回，不再整数溢出崩溃；支付宝 `canImport` 只解码前 4 KB。`BillsTests.spreadsheetLimitsRejectOverflowingReferences`。

### AUDIT-075 Bills 对比方向与 0 元记录
- 编号：AUDIT-075｜严重程度：P3｜模块：Bills｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Bills/Presentation/BillAnalysisView.swift:456`；`Bills/Application/BillsStore.swift:39`；`Bills/Presentation/BillEditorView.swift:121`；`Bills/Presentation/BillsView.swift:68-83,286-292`
- 描述：`(current - previous) / previous` 在上期为负时方向反（上期 −50、本期 100 显示“减少 300%”）；0 元记录可导入（测试 ali-003）但编辑器要求 >0、`upsert` 直接 return；列表每行 onAppear 重复过滤两次。
- 预期／实际：见描述。
- 触发/复现：退款多于支出的周期；编辑 0 元导入记录。
- 证据：代码。／根因：边界条件。／影响范围：分析与编辑。
- 修复方案：除以 abs 或显示“无可比基数”；放宽为 ≥ 0；过滤结果下传。／修复风险：低。
- 回归测试方案：逐项单测。
- 关联问题/依赖：AUDIT-044。
- 处理记录（2026-10-15）：对比文字按上期绝对值计算比例（`BillAnalysisView.comparisonText`），上期为负时方向正确；手工记录与编辑器允许 0 元。`BillsTests.zeroAmountRecordsCanBeSavedAndComparisonsHandleNegativeBase`。列表分页在 body 中只计算一次。

### AUDIT-076 换汇跨时区分组与筛选不一致
- 编号：AUDIT-076｜严重程度：P3｜模块：CurrencyExchange｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`CurrencyExchange/Domain/CurrencyExchange.swift:54-56`；`CurrencyExchange/Presentation/CurrencyExchangeView.swift:411-416,518`
- 描述／预期／实际：存储用本地中午，分组用 Asia/Shanghai，行内日期用本地时区。UTC-4 以西时 10-31 记录被分到“11月”，12-31 记录算到下一年。
- 触发/复现：时区设为 America/New_York。
- 证据：代码。／根因：日历不统一。／影响范围：海外使用。
- 修复方案：统一一个 Calendar。／修复风险：低。
- 回归测试方案：固定时区断言分组标题。
- 关联问题/依赖：AUDIT-016。
- 处理记录（2026-10-15）：换汇记录的存储（中午归一）、月份分组、年份筛选与标题统一使用 `CurrencyExchangeRecord.calendar`。`ExchangeRateRepositoryTests.monthGroupingUsesStorageCalendar`（多时区参数化）。

### AUDIT-077 换汇模型无缺键兼容
- 编号：AUDIT-077｜严重程度：P3｜模块：CurrencyExchange｜验证状态：静态确认（现网是否存在旧数据未知）｜处理状态：已修复
- 文件位置：`CurrencyExchange/Domain/CurrencyExchange.swift:20-51`；`Core/Persistence/VaultData.swift:376-385`；`Core/CloudSync/CloudSyncModels.swift:595`
- 描述：ff82476 删除了自定义 `init(from:)` 与旧枚举值 `oneSoldToBought`。缺 `fee`/`quoteConvention` 键或含旧枚举的数据会使 Vault 中整个模块被隔离，CloudKit 单条解码抛错；`exchangedAt` 解码后不归一到中午。仓库没有换汇模型测试，与 AGENTS:86-92 检查清单冲突。
- 预期：旧数据可读。／实际：模块不可用（原始数据保留）。
- 触发/复现：MVP 1.3 时期数据（未验证）。
- 证据：git 历史与代码。／根因：去掉了兼容解码。／影响范围：老用户。
- 修复方案：恢复 `decodeIfPresent` 默认值并映射旧枚举，加 fixture。／修复风险：低。
- 回归测试方案：旧 JSON fixture 解码。
- 关联问题/依赖：AUDIT-083 同类。
- 处理记录（2026-10-15，阶段 4）：`CurrencyExchangeRecord` 恢复自定义解码：缺键取默认值，`exchangedAt` 归一到中午，旧口径 `oneSoldToBought` 换算为 `hundredSoldToBought`（报价 ×100），未知口径抛出解码错误；`BankOfChinaRateParsingTests.legacyExchangeRecordsDecodeWithDefaultsAndConvertedConvention`。

### AUDIT-078 体彩补全失败覆盖缓存；单联赛失败中断全部
- 编号：AUDIT-078｜严重程度：P3｜模块：SportsLottery｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`SportsLottery/Infrastructure/SportsLotteryService.swift:130-146,269-273,284`
- 描述：`getMatchHeadV1` 失败时日期回退为只有日期；`getFixedBonusV1` 失败时 outcomes 清空，整条替换缓存；`for` 循环中任一联赛抛错即整体退出，排在其后的联赛一直刷不到。
- 预期：按字段合并、失败隔离。／实际：已得到的数据被降级覆盖。
- 触发/复现：桩让 head/bonus 抛错（未编写）。
- 证据：代码。／根因：整条替换、错误未隔离。／影响范围：赛果展示。
- 修复方案：缺失字段保留旧值，outcomes 按 code 并集；每联赛单独 catch。／修复风险：低。
- 回归测试方案：两次刷新桩测试。
- 关联问题/依赖：AUDIT-079。
- 处理记录（2026-10-14，阶段 3）：报告 4.2 #10 中体彩部分已按代码修正 README（单场缺失显示“暂无数据”、获取失败弹窗）；缓存覆盖与联赛中断问题未处理，SportsLottery 仍未编译。
- 处理记录（2026-10-15）：每个赛事单独 do/catch，失败只记日志并继续，最后抛出第一个错误；单场补全失败时保留上次已得到的开赛时间、队名与玩法结果，玩法结果按代码取并集。`SportsLotteryTests.failedEnrichmentKeepsCachedFieldsAndOutcomes`、`oneLeagueFailureDoesNotBlockLaterLeagues`。

### AUDIT-079 体彩赛果单行 null 整页解码失败
- 编号：AUDIT-079｜严重程度：P3｜模块：SportsLottery｜验证状态：疑似风险｜处理状态：已修复
- 文件位置：`SportsLottery/Infrastructure/SportsLotteryService.swift:505-508,517-526,549-552`
- 描述／预期／实际：DTO 字符串字段全部非可选，任一行字段为 null 整页抛错，用户看到“无法识别的数据”。接口实际是否返回 null 未验证。
- 触发/复现：fixture 一行 `"matchNumStr":null`。
- 证据：代码。／根因：严格解码。／影响范围：赛果加载。
- 修复方案：字段可选，逐行容错。／修复风险：低。
- 回归测试方案：上述 fixture。
- 关联问题/依赖：AUDIT-078。
- 处理记录（2026-10-15）：赛果 DTO 的非关键字段改为可选，列表元素经 `LossyDecoded` 逐行容错，单行缺字段只跳过该行。`SportsLotteryTests.malformedResultRowsAreSkippedIndividually`。

### AUDIT-080 FoodMap 批量刷新基于旧快照写回
- 编号：AUDIT-080｜严重程度：P3｜模块：FoodMap｜验证状态：疑似风险｜处理状态：不予处理
- 文件位置：`FoodMap/Presentation/DianpingImportView.swift:957,1037-1041`；`FoodMap/Application/FoodMapStore.swift:89-93`
- 描述／预期／实际：`apply` 把候选合并进几十秒前的快照后整条 upsert；期间 CloudKit 改过的备注、状态被覆盖，新增照片不在旧快照中而被 `attachmentStore.delete` 删除。
- 触发/复现：批量刷新期间另一设备修改同一记录（未验证）。
- 证据：代码。／根因：未取最新版本。／影响范围：数据与照片丢失。
- 修复方案：apply 时取 `store.places` 中最新版本再合并。／修复风险：低。
- 回归测试方案：刷新中途替换 store 数据，断言新照片仍在。
- 关联问题/依赖：AUDIT-017。

### AUDIT-081 FoodMap 地图选点回填的区县被清空
- 编号：AUDIT-081｜严重程度：P3｜模块：FoodMap｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`FoodMap/Presentation/FoodPlaceEditorView.swift:88-90,264-267,399`
- 描述／预期／实际：apply 同时设省市区，省份 onChange 触发 `provinceDidChange` 清空区县；README:145 写选点自动回填行政区。
- 触发/复现：新建记录或跨省选点。
- 证据：代码。／根因：程序赋值与用户操作未区分。／影响范围：编辑体验。
- 修复方案：标志位区分程序性赋值。／修复风险：低。
- 回归测试方案：手测或 ViewModel 测试。
- 关联问题/依赖：无。

### AUDIT-082 FoodMap 星级误判与封面类型
- 编号：AUDIT-082｜严重程度：P3｜模块：FoodMap｜验证状态：静态确认｜处理状态：不予处理
- 文件位置：`FoodMap/Domain/DianpingImport.swift:132,163,230-235`；`FoodMap/Presentation/DianpingImportView.swift:213-221,800-812`
- 描述：全文第一个 0–5 数字被当作星级（“3号仓烧烤”→3）；封面固定声明 `.jpeg`，HTML 也会被存为照片，10MB 限制在完整下载后才判断；页面坐标取 `__InitialState__` 中第一个 lat/lng，且正则丢负号（疑似）。
- 预期／实际：见描述。
- 触发/复现：`parseWebItems` 首行为“3号仓烧烤”。
- 证据：代码。／根因：解析过宽。／影响范围：导入数据质量。
- 修复方案：限定匹配范围；CGImageSource 嗅探类型。／修复风险：低。
- 回归测试方案：解析单测。
- 关联问题/依赖：无。

### AUDIT-083 FoodMap 旧状态 notTried 无迁移
- 编号：AUDIT-083｜严重程度：P3｜模块：FoodMap｜验证状态：静态确认（影响范围小）｜处理状态：不予处理
- 文件位置：`FoodMap/Domain/FoodPlace.swift:194`；`Core/Persistence/VaultData.swift:408-420`
- 描述／预期／实际：`notTried` 在 da1c47a 引入、b933133 删除；含该值的数据解码抛错，foodMap 整个模块被隔离（原始数据保留）。
- 触发/复现：08-11～08-13 期间的数据或备份。
- 证据：git 历史。／根因：枚举删除无迁移。／影响范围：少量早期数据。
- 修复方案：未知状态映射为 `.wantToTry`。／修复风险：低。
- 回归测试方案：旧 JSON fixture。
- 关联问题/依赖：AUDIT-077。

### AUDIT-084 存储统计与设置页性能
- 编号：AUDIT-084｜严重程度：P3｜模块：Core/Storage、App/Settings｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/Storage/StorageUsageService.swift:85,141,185`；`App/Settings/StorageSettingsView.swift:286-305`
- 描述：只统计 `MyTools-Diagnostics.log`，却把整个 Diagnostics 目录从“其他”中排除，系统日志抄本与 CallStacks 两头都没算；路径自行拼接未用 DiagnosticPaths（AGENTS:53）。设置页每次 body 多次全量重算 `referencedAttachmentStoredFileNames`，`scanRedundantData` 在主线程执行。
- 预期／实际：见描述。
- 触发/复现：打开存储设置页。
- 证据：代码。／根因：统计口径与路径未统一。／影响范围：存储显示、页面卡顿。
- 修复方案：按目录统计；使用 DiagnosticPaths；结果缓存并后台计算。／修复风险：低。
- 回归测试方案：临时目录中构造文件断言统计值。
- 关联问题/依赖：无。
- 处理记录（2026-10-14，阶段 3）：诊断统计改为按 `DiagnosticPaths.directoryURL` 整个目录计入（系统日志抄本、CallStacks 不再漏算），AGENTS.md 已同步；`AppStoreFacadeTests`。设置页重复计算与主线程扫描的性能项留待阶段 4。
- 处理记录（2026-10-15，阶段 4）：设置页不再在 body 中反复重建附件引用集合：孤立附件列表改为 `@State`，`scan()` 只取一次 `referencedAttachmentStoredFileNames`，清理前按最新引用重新过滤。`scanRedundantData`/`scanLegacyData` 每次扫描仍在主线程执行一次（读取 MainActor Store 的内存数据，不涉及磁盘），未移到后台。

### AUDIT-085 pbxproj 写死 DEVELOPMENT_TEAM
- 编号：AUDIT-085｜严重程度：P3｜模块：工程配置｜验证状态：静态确认｜处理状态：待确认
- 文件位置：`MyTools.xcodeproj/project.pbxproj:1816,1885`（值已遮蔽：6Y8D******）
- 描述／预期／实际：README:262 写 Team ID 由 Xcode Cloud 或本机签名提供；pbxproj 写死后 `Signing.local` 的覆盖失效。
- 触发/复现：其他开发者本机构建。
- 证据：文件内容。／根因：Xcode 自动写入。／影响范围：协作与 CI。
- 修复方案：移除 target 级设置，改由 xcconfig 提供。／修复风险：低（需所有者确认签名流程）。
- 回归测试方案：用 Signing.local 构建验证。
- 关联问题/依赖：AUDIT-035。
- 处理记录（2026-10-14，阶段 3）：按裁决（报告 4.2 #15）维持现状并记录，pbxproj 中的 DEVELOPMENT_TEAM（6Y8D******）未改动。
- 处理记录（2026-10-15）：README 签名说明按代码修正为 pbxproj target 级仍写有 `DEVELOPMENT_TEAM`（6Y8D******），优先级高于 xcconfig，其他开发者需在 Xcode 中改成自己的 Team；代码维持现状。

### AUDIT-086 CloudSync/备份的其他稳健性问题
- 编号：AUDIT-086｜严重程度：P3｜模块：CloudSync、备份、App/Navigation｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Core/CloudSync/CloudSyncStateStore.swift:147-160`；`Core/Backup/VaultBackup.swift`；`App/Navigation/RootView.swift:98`；`App/Composition/AppStoreBackupProcessor.swift:116-158`
- 描述：(1) 同步状态读不出时回落为空文档，已删数据会复活并全量重传；(2) PBKDF2 21 万轮（低于 OWASP 现行建议的 60 万）且轮数未写入信封，无法平滑升级；(3) 进入后台 flush 未用 beginBackgroundTask，README 写“进入后台等待保存完成”；(4) LWW 使用 reconcile 时间而非编辑时间；(5) 每个同步事件全量重写状态文件；(6) 主库信封无 AAD；(7) 导出时未排除被排除模块的标签与模板。
- 预期／实际：见描述。
- 触发/复现：静态分析。
- 证据：代码。／根因：稳健性细节缺失。／影响范围：同步与备份。
- 修复方案：逐项处理；(2) 需版本化信封。／修复风险：(2)(6) 中，涉及格式兼容。
- 回归测试方案：逐项单测。
- 关联问题/依赖：AUDIT-002。
- 处理记录（2026-10-14，阶段 3）：(3) 已修复：进入后台的保存包在 `beginBackgroundTask` 中（`RootView.swift` 的 `BackgroundSaveTask`）。其余 (1)(2)(4)–(7) 未处理。
- 处理记录（2026-10-15）：(1) 同步状态文件存在但读不出时 `CloudSyncStateStore.load()` 抛错，同步暂停并提示，不再回落为空文档；(2)(6) 备份格式 2.0：PBKDF2 60 万轮并把轮数写入信封，信封头作为 AAD，仍可导入 1.0 旧备份；主库信封 2.1 带 AAD，仍可读取 2.0 并在下次保存时升级；(4) LWW 改用记录自身的编辑时间（不晚于当前时刻，且不早于上次时间）；(5) 状态文件写入 2 秒内合并，停止同步时立即写盘；(7) 导出时一并排除被排除模块的标签与模板。`CloudSyncMergerTests`、`SecureStoreEncryptionTests`、`AppStoreBackupProcessorTests` 新增对应用例。

### AUDIT-087 关键路径缺少测试
- 编号：AUDIT-087｜严重程度：P3｜模块：测试工程｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`MyToolsTests/`
- 描述：无测试：DecimalTextParser、换汇口径/损耗/解码/中行 HTML 解析、XLSX deflate 路径（真实样本测试在环境变量缺失时直接 return 显示为通过，`BillsTests.swift:396-399`）、美股周六元旦/港股周六假日、`buildSeries`、`nonOverlapping`、Partnership P1-P3 场景、FoodMap BrowserModel/`refreshAll`/`importCandidate`、体彩可见性与失败隔离、Stocks 删除后写回与合并放大。
- 预期：高风险逻辑有回归保护。／实际：缺失。
- 触发/复现：—。／证据：测试目录检索。／根因：测试滞后。／影响范围：回归风险。
- 修复方案：将审计复现测试（AuditReproTests 9 条）迁入真实工程，随问题修复转为正向断言；按上述清单补测。／修复风险：低。
- 回归测试方案：—。
- 关联问题/依赖：AUDIT-001、AUDIT-012。
- 处理记录（2026-10-15）：已补测：DecimalTextParser 溢出、中行 HTML 解析与换汇分组、XLSX deflate 路径（`BillsTests.deflatedXLSXDecodesLikeStoredXLSX`）、美股/港股周六假日、`buildSeries`、`nonOverlapping`、体彩可见性与失败隔离、Stocks 删除后写回与合并放大。Partnership、FoodMap 已删除，不再需要。真实账单样本测试仍依赖环境变量，缺失时跳过。

### AUDIT-088 死代码、重复实现与 View 层业务逻辑
- 编号：AUDIT-088｜严重程度：P4｜模块：多模块｜验证状态：静态确认｜处理状态：已修复
- 文件位置：见描述
- 描述：
  - `Core/Currency/ExchangeRateStore` 的 `history` 全项目无读取方，每次刷新仍向 UserDefaults 写最多 2000 个点。
  - `Stocks/Domain/Stock.swift:162-174` `executionInstant` 的 `market` 参数未使用（见 AUDIT-091）。
  - FoodMap：`importCandidate`（`DianpingImportView.swift:751-815`）与 `refreshAll`（`:946-1033`）写在 View 中且无测试；候选到 FoodPlace 的映射与 `FoodPlaceSourceRefreshMerge` 重复；“大众点评”字符串硬编码 3 处；`extractDianpingURL` 是 `firstDianpingURL` 的弱化副本。
  - Health：费用聚合在 Editor 与 Detail 各写一遍；Documents 与 Secrets 各有一套几乎相同的模板编辑器与匹配逻辑（AUDIT-018 需同时修两处）。
- 预期／实际：单一实现。／重复实现，修一处漏一处。
- 触发/复现：—。／证据：代码检索。／根因：迭代累积。／影响范围：可维护性。
- 修复方案：随相关问题修复时顺带收敛，不单独重构。／修复风险：低。
- 回归测试方案：现有测试。
- 关联问题/依赖：AUDIT-018、AUDIT-047、AUDIT-091。
- 处理记录（2026-10-14，阶段 3）：券商部分已修复（报告 4.2 #20）：移除 `FinancialAccount.brokerage` 与 `BrokerageAccountFieldsEditor`，旧数据经私有 `LegacyBrokerageAccount` 解码迁移为 `BrokerageAccount`，新建机构按类型进入专属编辑页；`ModuleStoreTests`。其余死代码与重复实现留待阶段 4。
- 处理记录（2026-10-15，阶段 4）：`ExchangeRateStore.history` 及其 UserDefaults 写入已删除（`ExchangeRateProviding.loadHistory` 一并移除），旧键 `boc-currency-rates-history-v1` 在读取与清理缓存时删除；`ExchangeRateRepositoryTests.unusedRateHistoryIsNoLongerWrittenAndLegacyCopyIsRemoved`。Health 费用汇总收敛为 `Sequence<MedicalRecord>.costSummary`，编辑页、详情页与列表分组共用。`executionInstant` 的 `market` 参数已在阶段 2 移除；FoodMap 部分随模块删除失效。Documents 与 Secrets 的模板编辑器字段类型不同，按修复方案“不单独重构”保留，状态维持修复中。
- 处理记录（2026-10-15）：`FinanceInstitutionsView`（无调用方）与只剩注释的 `FinancialProviderViews.swift` 已删除，pbxproj 同步。Documents 与 Secrets 的模板编辑器仍按“不单独重构”保留，状态维持修复中。
- 处理记录（2026-10-15，所有者要求收敛）：Documents 与 Secrets 的模板编辑器与匹配逻辑已统一到 `Core/UI/FieldTemplateEditor.swift`：`FieldTemplateEditorView`（编辑界面与保存清理）、`FieldTemplateMatching`（同名同类型匹配、显隐同步、空白模板判断）与协议 `TemplateEditableField`/`TemplateFieldInputKind`；两模块只保留字段一致性实现（布局签名：证照为实际换行、保密为字段 kind），原 `CredentialFieldTemplateEditorView` 与 `SecretFieldTemplateEditorView` 删除。界面与行为不变；`DocumentsTests.sharedFieldTemplateEditorCleansAndMatchesCredentialFields`。

### AUDIT-089 零散建议项
- 编号：AUDIT-089｜严重程度：P4｜模块：多模块｜验证状态：静态确认（个别为疑似，已标注）｜处理状态：已修复
- 文件位置：见描述
- 描述：
  - IME：保密资料备注用 `TextEditor`（`Secrets/Presentation/SecretVaultView.swift:888`），各改名弹窗用普通 `TextField`，与 AGENTS.md:81 不符。
  - `ProtectedContent` 复制敏感值未设置 `localOnly`/过期时间，进入通用剪贴板。
  - 表达式计算溢出未检查 NaN/Inf。
  - `Core/UI/MarkdownRendering.swift:35`：“$5 和 $10”中美元符号被吞；`m^-2` 只有一个字符上标。
  - FoodMap：`FoodSourceLink.url` 接受任意 scheme；百度导航 `name:` 含 `|` 会破坏参数；刷新 sheet 未设 `interactiveDismissDisabled`；`visiblePlaces` 每次 body 重算多次；当前位置用自定义 Annotation 绘制，大陆可能与 GCJ-02 店铺坐标偏移（疑似，建议 `UserAnnotation()`）。
  - Health：空状态文案写“验证身份”但无验证（`HealthRecordsView.swift:76`）；医院名称每变一次都覆盖分类（`MedicalRecordEditorView.swift:850`）。
  - Stocks：全亏时 XIRR 原因提示误导；`StockConvertedPortfolioSummary` 已清仓股票缺汇率即整体 nil（`StockPortfolioAnalytics.swift:665-670`，与 `:739-740` 不一致）；`StockStore.swift:381` 校验失败日志写“未找到持仓”；`upsertStock` 可能回滚编辑期间刷新的报价（疑似，`StockEditorView.swift:329`）；`StockHomeRows.swift:36` 非隔离上下文访问 UIDevice（编译警告）。
  - 测试：`strictBackupDecodeStillRejectsBrokenModule…` 断言口径过时；`persistenceCoordinatorRetriesTemporaryKeychainFailure` 疑似时序抖动。
- 预期／实际：见各项。
- 触发/复现：静态分析。／证据：代码。／根因：细节。／影响范围：小。
- 修复方案：逐项小改。／修复风险：低。
- 回归测试方案：逐项单测或手测。
- 关联问题/依赖：AUDIT-012。
- 处理记录（2026-10-14，阶段 3）：诊断挂载：Bills 各页面已补 `.diagnosticScreen`（Bills 未编译，未经构建验证）。IME 一项按裁决（报告 4.2 #13）维持现状并记录。其余建议项未处理。
- 处理记录（2026-10-15）：AGENTS.md 的 IME 规则注明现有例外（保密资料备注 `TextEditor`、改名弹窗 `TextField`），维持现状。
- 处理记录（2026-10-15）：剪贴板改为仅本机、300 秒过期（macOS 另标记 ConcealedType）；表达式计算拒绝 NaN/溢出（`AuditReproTests.auditDecimalExpressionRejectsOverflow`）；Markdown 不再吞价格美元符号，多字符上标正确（`MedicalRecordEditingTests.markdownRendererKeepsPriceDollarsAndMultiCharacterExponents`）；`StockHomeRows` 与 `AppMemoryMonitor` 的并发警告已消除；Health 空状态文案改为“点右上角“+”记录…”；已清仓股票缺汇率只影响已实现与累计收益，持仓市值与今日盈亏照常（`StockConvertedPortfolioSummaryTests.clearedPositionWithoutRateKeepsHeldMarketValue`）；`StockStore` 失败日志改为“未找到持仓或校验未通过”。未改：IME（裁决维持现状）；医院名称覆盖分类只在命中已有机构档案时发生，属预期；全亏 XIRR 提示与 `upsertStock` 回滚报价为疑似项，未复现，保留观察；测试两项：`strictBackupDecode…` 现断言严格解码拒绝、隔离解码逐组保留，与当前口径一致；`persistenceCoordinatorRetriesTemporaryKeychainFailure` 在本轮各次全量运行中均通过，未见抖动，未改。

### AUDIT-090 文档与代码不一致（需求冲突类）
- 编号：AUDIT-090｜严重程度：P4｜模块：文档｜验证状态：静态确认｜处理状态：已修复
- 文件位置：README.md、AGENTS.md、FINANCE_MODEL.md、Stocks GUIDE 等，逐条见 `PROJECT_AUDIT_REPORT.md` 第 4 节
- 描述：涉及产品需求的不一致不由审计改写文档，只登记。按“代码为准、需求不改”规则，本次仅修正了 5 处纯事实性错误（链接、目录树、币种列表、空行），其余全部列入报告。
- 预期：文档与实现一致，或代码按需求修正。／实际：需所有者逐条裁决“改代码还是改文档”。
- 触发/复现：—。／证据：逐条对照。／根因：文档与实现迭代不同步。／影响范围：维护者与用户预期。
- 修复方案：所有者逐条裁决后处理。／修复风险：低。
- 回归测试方案：—。
- 关联问题/依赖：AUDIT-006、AUDIT-021、AUDIT-026、AUDIT-002 等。
- 处理记录（2026-10-14，阶段 3）：报告 4.2 的 34 条需求冲突已逐条裁决，裁决与处理结果见报告 4.2；README、AGENTS、FINANCE_MODEL、STOCKS_IMPLEMENTATION_GUIDE 已按裁决同步。

### AUDIT-091 美股成交时间在北京跨日后被提前 24 小时
- 编号：AUDIT-091｜严重程度：P1｜模块：Stocks/账本｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/Stock.swift:162-174`（`executionInstant`）、`:153-155,178-179`（注释）；`Stocks/Presentation/StockTransactionEditorView.swift:82,221`；`Stocks/Presentation/StockEditorView.swift:313`
- 描述：`executionInstant` 用 `beijingCalendar.dateComponents([.year,.month,.day], from: tradingDate)` 取交易日（美股的美东营业日），再拼上北京时间时分；`market` 参数未使用。美股盘中下午到盘后的成交在北京已是次日凌晨，但日期仍取美东营业日。
- 预期：ET 10-13 15:30 的成交存为 2026-10-13T19:30Z。
- 实际：用户按界面提示（“按北京时间记录”）输入交易日 10-13、时间 03:30，存为北京 10-13 03:30 = ET 10-12 15:30，提前整整 24 小时。
- 触发/复现：美股交易日 + 北京时间 00:00 之后的成交时间。复现测试思路：`executionInstant(tradingDate: 美股 10-13 营业日, time: 北京 03:30, market: .us)`，断言等于 `2026-10-13T19:30:00Z`。
- 证据：代码与 UI 文案；注释写“按市场时区解释”，与实现不符。
- 根因：营业日（市场时区）与时钟时间（北京时区）混在一个日历中组装，未处理跨日。
- 影响范围：美股下午及盘后的每一笔有成交时间的交易：交易标记、市值与成本台阶、日内生效判断、导出的“成交时间（市场当地）”均错位。
- 修复方案：按市场时区解释营业日，北京时间早于该市场开盘对应时刻时日期 +1；或改为让用户直接录入市场当地时间。需补数据迁移评估（已存数据无法区分）。
- 修复风险：中（涉及已存数据语义，需所有者确认口径）。
- 回归测试方案：美股夏令时/冬令时、港股、A 股各一组跨日与不跨日用例。
- 关联问题/依赖：AUDIT-016、AUDIT-092、AUDIT-093；README:87 口径冲突。
- 处理记录（2026-10-14，阶段 2）：统一口径：本地填写的日期与时间一律为北京时间。`executionInstant(tradingDate:beijingTime:)` 经 `StockMarketClock.instant` 组装“北京日期 + 北京时刻”，市场交易日由 `StockMarketClock.marketBusinessDayStart` 从北京时间换算；美股北京 10-14 03:30 = ET 10-13 15:30。日期与时间选择器固定按北京时区显示，界面提示美股夜间成交需填北京日期并填写成交时间。数据迁移评估：已存 `executedAt` 本来就是“北京日期 + 北京时刻”的绝对时刻，语义不变，无需迁移；已存 `tradedAt` 为录入设备的本地中午，东八区设备上即北京中午，偏移不超过 ±12 小时的设备上仍落在同一北京日期，无需迁移。按旧提示把美东交易日当日期、北京凌晨时刻录入的历史美股记录会被解释为早一天，已存数据无法区分，需用户自行核对。`AuditReproTests.auditExecutionTimeIsBeijingWallClock` 覆盖夏令时、冬令时、港股与 A 股。

### AUDIT-092 美股无成交时间的交易在冬令时被映射到前一交易日
- 编号：AUDIT-092｜严重程度：P2｜模块：Stocks/账本、组合走势｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/PortfolioValueHistory.swift:24-27,381`；`Stocks/Presentation/StockChartPresentation.swift:1615,1640`
- 描述／预期／实际：交易日以“北京中午”承载，`executedAt` 为空时用 `tradedAt` 与按市场日历分组的 K 线点比较。冬令时北京 12:00 = ET 前一日 23:00，交易被归到前一个美股交易日的点上。
- 触发/复现：美股、冬令时、未填成交时间的交易；看组合日线与交易标记。
- 证据：代码。／根因：营业日承载值与市场日历不一致。
- 影响范围：美股交易标记位置、当日持股与成本口径。
- 修复方案：营业日比较统一用市场日历的 y/m/d 组件，不比较瞬时。／修复风险：中。
- 回归测试方案：冬令时美股交易日的点归属断言。
- 关联问题/依赖：AUDIT-015、AUDIT-016、AUDIT-091。
- 处理记录（2026-10-14，阶段 2）：只填日期的交易按所填北京日期对应的同日期市场交易日归属 K 线（比较市场时区的日起点，不再比较北京中午瞬时），交易标记、分钟回放与组合日线一致；`AuditReproTests.auditDateOnlyWinterUSTradeUsesSameDatedBar`。

### AUDIT-093 日内生效子集可出现负股数
- 编号：AUDIT-093｜严重程度：P2｜模块：Stocks/账本｜验证状态：静态确认｜处理状态：已修复
- 文件位置：`Stocks/Domain/Stock.swift:351-353` 对比 `:419-429`；`:578` 对比 `:585-591`
- 描述：`hasValidTransactionOrder` 按“日期 + dayOrder”排序后校验股数不为负；`transactionIsEffective` 按 `executedAt` 判断是否已生效。同一天里“卖出（有较早的成交时间）”排在“买入（无成交时间或较晚）”之后时，排序校验通过，但在两者之间的时刻只有卖出生效，持股为负。
- 预期：任意时刻生效子集的持股 ≥ 0。／实际：可为负，成本、收益计算异常。
- 触发/复现：同日先录买入（10:30）、后录卖出（09:45）且 dayOrder 买在前；在 10:00 计算持仓。
- 证据：代码。／根因：校验顺序与生效判断使用两套时间轴。
- 影响范围：日内看盘与组合摘要。
- 修复方案：校验时按生效顺序（`executedAt` 优先）排序，或要求同日 dayOrder 与成交时间一致。／修复风险：中。
- 回归测试方案：上述场景断言保存被拒绝或任意时刻持股非负。
- 关联问题/依赖：AUDIT-091。
- 处理记录（2026-10-14，阶段 2）：`hasValidTransactionOrder` 在“日 + dayOrder”校验之外，再按生效时刻（同一时刻先买后卖）校验持股非负；`AuditReproTests.auditSameDaySellBeforeBuyExecutionIsRejected`。

### AUDIT-094 分红日历、外币入金重复计入与数量截断
- 编号：AUDIT-094｜严重程度：P3｜模块：Stocks/账本｜验证状态：静态确认（第 2 项当前无 UI，未触发）｜处理状态：已修复
- 文件位置：`Stocks/Domain/StockCashLedger.swift:86-101,114-115,276-282`；`Stocks/Domain/Stock.swift:595-597`；`Stocks/Presentation/StockTransactionEditorView.swift:36,208`；`Stocks/Presentation/StockEditorView.swift:267`
- 描述：
  1. 分红生效日：现金账本用市场日历，收益回放用设备日历，同一笔分红在两处生效日可能不同。
  2. 旧的关联外币入金在现金账本里被计两次（USD 1000 变 2000，CNY 对应 −7010）；现金账本目前无 UI 入口。
  3. 由总额反推单价或股数时截断到 4 位小数，与用户输入总额不一致。
- 预期／实际：见描述。
- 触发/复现：1 设备时区非北京；2 含旧格式关联入金的数据；3 总额 1000、股数 3。
- 证据：代码。／根因：日历与精度口径不统一。／影响范围：小。
- 修复方案：统一市场日历；去重关联入金；保留更多小数或改为保存总额。／修复风险：低。
- 回归测试方案：逐项单测。
- 关联问题/依赖：AUDIT-016。
- 处理记录（2026-10-15）：(2) 关联换汇的外币入金在现金账本中按卖出币种计入，不再重复；(3) 由总额反推单价或股数时保留 10 位小数。第 1 项已在阶段 2 修复。

