#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h}"
build_dir=$(mktemp -d /tmp/mytools-bank-converter.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
cd "$project_root"
swiftc -module-cache-path "$build_dir/modules" -D MYTOOLS_FEATURE_FINANCE \
 MyTools/Core/Attachments/FileAttachment.swift \
 MyTools/Core/Currency/CurrencyCode.swift \
 MyTools/Core/Formatting/AccountNumberFormatter.swift \
 MyTools/Features/Finance/Domain/BankCard.swift \
 MyTools/Features/Finance/Domain/FinancialArchive.swift \
 MyTools/Features/Finance/Domain/FinancialFoundation.swift \
 MyTools/Features/Finance/Domain/FinancialInstitution.swift \
 scripts/finance/convert-bank-backup.swift -o "$build_dir/convert"
"$build_dir/convert" "$@"
