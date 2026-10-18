# 统一金融机构模型

金融档案只持久化 `FinancialInstitution`，它是金融模块唯一的聚合根。银行、券商、支付机构和后续扩展类型通过 `FinancialInstitutionKind` 区分，类型专属资料位于对应 payload 中。银行、券商和支付机构是同一金融机构模型的三个实例：共享机构身份、联系方式、登录、文件和附件，账户与资料按类型各自建模，互不复用字段。

## 聚合边界

- `FinancialInstitution` 保存机构身份、联系方式、登录信息、文件和机构类型；银行、券商、支付机构账户集合不共享业务类型。
- 银行资料位于 `BankInstitutionDetails`：境内／境外地区、开户网点、开户日期、地址、汇款信息、账户、银行卡和收款资料。
- 券商资料位于 `BrokerageInstitutionDetails`：IBKR 平台资料、现金／保证金账户、基准币种、开户实体、持有形式和入金资料。股票持仓、交易、分红和资金流水仍属于 Stocks。
- 支付资料位于 `PaymentInstitutionDetails`：Wise 资料、多个币种账户，每个币种账户支持多套收款资料（`PaymentAccount.receivingProfiles`）。收款字段按币种模板创建后仍可自由增删。
- 券商账户使用 `BrokerageAccount`；支付机构账户使用 `PaymentAccount`。两者不再复用银行的 `FinancialAccount`，也不共享银行子账户或银行卡字段。`FinancialAccount` 只用于银行和其他机构，已不含券商字段；旧数据中的 `FinancialAccount.brokerage` 在解码时经私有的 `LegacyBrokerageAccount` 迁移为 `BrokerageAccount`，不再写回旧形状。
- 新建机构时先选类型，再进入该类型专属的编辑页（券商用券商编辑页、支付机构用支付编辑页、银行和其他用通用金融编辑页），不再在通用编辑页里提供券商账户字段。
- `FinancialAccount.subaccounts` 表示银行账户下的社保、公积金、个人养老金等子账户；子账户不再单独成为机构。
- `BankCard` 挂在银行机构内，主卡和附加卡号保留各自 ID、卡号、网络、币种和状态；一卡两号不合并成一个字符串。银行卡与账户的关联记录在 `linkedFinancialAccountIDs`，账户详情据此显示关联卡片；编辑页暂无设置关联的入口，删除账户时自动解除关联。
- 机构类型单选；首页只对银行区分在用与停用（卡片全部销户且无正常子账户；无卡片时还需机构状态为异常或销户），券商和支付机构不归档，规则见 `FinancialInstitution.isInactiveFinanceArchive(cards:)`。

## 数据与同步

券商机构编辑页通过独立的 `BrokerageAccountEditorView` 新建和修改账户，完成子编辑后加入机构草稿；取消不新增空记录。账户和入金资料可在机构编辑页滑动删除，再保存机构。删除账户解除入金、登录及文件的关联，保留独立入金资料；删除入金资料清除账户及文件对该资料的引用。账户详情可直接编辑，保存以打开编辑页时的机构快照校验冲突，错误保留草稿并提示。银行、券商和支付机构统一从金融账户首页左滑删除，经过确认后删除整个档案；券商和支付机构详情只保留编辑入口。添加菜单只提供银行、券商和支付机构，旧“其他”档案继续可读。

Vault、加密备份和 CloudKit 只使用 `financialInstitutions`。旧的 `accounts`、`cards`、`financialProviders` 顶层载荷会被拒绝，不再作为运行时兼容输入。银行卡和金融文件随所属机构原子保存、导出和同步。

备份导入按 `includedModules` 做模块级覆盖：包含的模块即使是空快照也会清空本地同模块；未包含的模块保持不变。金融档案可以通过 `AppStore.makeBackupDocument(password:includedModules:)` 单独导出。

金融机构保存前验证：结构版本不高于当前版本（旧版本已在解码时迁移，可以通过；更新的版本拒绝）、类型 payload 与机构类型一致、实体 ID 唯一、账户／子账户／收款资料关联有效、券商账户引用的入金资料都存在、文件引用的账户和收款资料都存在、附件 ID 不重复、银行卡关联账户有效且替换关系无环。编辑使用打开时快照，冲突时拒绝覆盖。

## 外部资料模板

IBKR 入金资料和 Wise 币种收款资料只提供字段模板，不自动填写用户的账号、Routing、IBAN、SWIFT 或 Reference。Wise 每个币种账户可新增、编辑和删除多套收款资料；IBKR 入金资料与券商账户资料分开保存。

Wise 字段模板覆盖 USD、EUR、GBP、AUD、NZD、AED、CAD、CHF、CNY、CZK、DKK、HKD、HUF、ILS、JPY、NOK、PHP、PLN、SEK、SGD、UGX、ZAR。AED 截图显示的国际收款字段为姓名、IBAN、SWIFT/BIC、银行名称和地址；未提供本地账户字段的币种共享这一 SWIFT-only 模板。USD、EUR、GBP、AUD、CAD、HKD、HUF、NZD、PHP、SGD 使用截图中对应的本地字段模板。模板依据 Wise Help Centre 的 Account details 说明：https://wise.com/help/articles/2978083/how-do-i-get-account-details。Wise 页面按地区和账户资格显示可用字段，因此模板是可编辑的字段族，不承诺每个用户都能获得全部字段。

## 旧银行备份离线转换

入口：`scripts/finance/convert-bank-backup.sh`。仅读取旧银行备份，通过当前金融领域模型转换、校验和重新加密到独立新文件；不修改原备份，不在运行时引入旧模型解码。使用说明见 `scripts/finance/README.md`。


支付账户多套收款资料使用 FinancialInstitution schema v4；Vault 文档与 CloudKit 外层版本不变，机构 JSON 继续通过既有备份、同步白名单传输。旧 `receivingProfile` 缺失安全默认为空数组，存在则迁为单元素数组；新 `receivingProfiles` 优先（明确空数组保持空），损坏数组拒绝解码，不回退成空资料。写回仍带首套旧字段，schema v4 让旧版客户端拒绝校验该机构，避免覆盖其余资料。迁移保留资料 ID、字段和账户关联，机构级旧资料按账户迁入，悬挂引用由校验阻断。写盘继续复用 SecureStore 的临时文件回读、校验、恢复快照与原子替换流程。

开户网点调起地图保留“有效坐标直接标注，缺坐标才按名称搜索”的规则；坐标来自用户在 MapKit 搜索结果中的选择，可避免同名网点重新匹配。坐标的准确性取决于选点和坐标系，名称搜索的准确性取决于名称／地址完整度与目标地图 POI 数据。地图专属 POI ID 才能明确关联该平台的网点详情，当前未保存这些跨平台标识。参考 Google Maps URLs 文档：https://developers.google.com/maps/documentation/urls/get-started 。
