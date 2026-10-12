# 统一金融机构模型

金融档案只持久化 `FinancialInstitution`，它是金融模块唯一的聚合根。银行、券商、支付机构和后续扩展类型通过 `FinancialInstitutionKind` 区分，类型专属资料位于对应 payload 中。

## 聚合边界

- `FinancialInstitution` 保存机构身份、联系方式、登录信息、文件和机构类型；银行、券商、支付机构账户集合不共享业务类型。
- 银行资料位于 `BankInstitutionDetails`：境内／境外地区、开户网点、开户日期、地址、汇款信息、账户、银行卡和收款资料。
- 券商资料位于 `BrokerageInstitutionDetails`：IBKR 平台资料、现金／保证金账户、基准币种、开户实体、持有形式和入金资料。股票持仓、交易、分红和资金流水仍属于 Stocks。
- 支付资料位于 `PaymentInstitutionDetails`：Wise 资料、多个币种账户和每种币种可有多组的收款资料。收款字段按币种模板创建后仍可自由增删。
- 券商账户使用 `BrokerageAccount`；支付机构账户使用 `PaymentAccount`。两者不再复用银行的 `FinancialAccount`，也不共享银行子账户或银行卡字段。
- `FinancialAccount.subaccounts` 表示银行账户下的社保、公积金、个人养老金等子账户；子账户不再单独成为机构。
- `BankCard` 挂在银行机构内，主卡和附加卡号保留各自 ID、卡号、网络、币种和状态；一卡两号不合并成一个字符串。

## 数据与同步

Vault、加密备份和 CloudKit 只使用 `financialInstitutions`。旧的 `accounts`、`cards`、`financialProviders` 顶层载荷会被拒绝，不再作为运行时兼容输入。银行卡和金融文件随所属机构原子保存、导出和同步。

备份导入按 `includedModules` 做模块级覆盖：包含的模块即使是空快照也会清空本地同模块；未包含的模块保持不变。金融档案可以通过 `AppStore.makeBackupDocument(password:includedModules:)` 单独导出。

金融机构保存前验证：类型 payload 与机构类型一致、实体 ID 唯一、账户／子账户／收款资料关联有效、银行卡替换关系无环、附件引用完整。编辑使用打开时快照，冲突时拒绝覆盖。

## 外部资料模板

IBKR 入金资料和 Wise 币种收款资料只提供字段模板，不自动填写用户的账号、Routing、IBAN、SWIFT 或 Reference。Wise 同一币种允许多组收款资料；IBKR 入金资料与券商账户资料分开保存。

Wise 字段模板覆盖 USD、EUR、GBP、AUD、NZD、AED、CAD、CHF、CNY、CZK、DKK、HKD、HUF、ILS、JPY、NOK、PHP、PLN、SEK、SGD、UGX、ZAR。AED 截图显示的国际收款字段为姓名、IBAN、SWIFT/BIC、银行名称和地址；未提供本地账户字段的币种共享这一 SWIFT-only 模板。USD、EUR、GBP、AUD、CAD、HKD、HUF、NZD、PHP、SGD 使用截图中对应的本地字段模板。模板依据 Wise Help Centre 的 Account details 说明：https://wise.com/help/articles/2978083/how-do-i-get-account-details。Wise 页面按地区和账户资格显示可用字段，因此模板是可编辑的字段族，不承诺每个用户都能获得全部字段。

## 旧银行备份离线转换

入口：`scripts/finance/convert-bank-backup.sh`。仅读取旧银行备份，通过当前金融领域模型转换、校验和重新加密到独立新文件；不修改原备份，不在运行时引入旧模型解码。使用说明见 `scripts/finance/README.md`。
