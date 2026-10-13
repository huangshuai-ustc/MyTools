#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h}"
check_dir=$(mktemp -d /tmp/mytools-brokerage-check.XXXXXX)
cd "$project_root"
swiftc -module-cache-path "$check_dir/modules" -D MYTOOLS_FEATURE_FINANCE \
 MyTools/Core/Attachments/FileAttachment.swift \
 MyTools/Core/Currency/CurrencyCode.swift \
 MyTools/Core/Formatting/AccountNumberFormatter.swift \
 MyTools/Features/Finance/Domain/BankCard.swift \
 MyTools/Features/Finance/Domain/FinancialArchive.swift \
 MyTools/Features/Finance/Domain/FinancialFoundation.swift \
 MyTools/Features/Finance/Domain/FinancialInstitution.swift \
 scripts/finance/check-brokerage.swift -o "$check_dir/check"
"$check_dir/check"
