import Foundation
import CryptoKit
import CommonCrypto
import Darwin

struct BackupEnvelope: Codable { let format: String; let version: String; let salt: Data; let combined: Data }
enum ConversionError: Error { case invalidEnvelope, unsupportedSource, invalidRelationship, outputExists, keyDerivation }
func key(_ password: String, salt: Data) throws -> SymmetricKey {
    let password = Data(password.utf8)
    var output = Data(count: 32)
    let status = output.withUnsafeMutableBytes { out in password.withUnsafeBytes { pass in salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.bindMemory(to: UInt8.self).baseAddress, password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, out.bindMemory(to: UInt8.self).baseAddress, 32)
    } } }
    guard status == kCCSuccess else { throw ConversionError.keyDerivation }
    return SymmetricKey(data: output)
}
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: jsonData(value)) }
func convert(_ source: [String: Any]) throws -> [String: Any] {
    guard var vault = source["vault"] as? [String: Any], let banks = vault["accounts"] as? [[String: Any]], let cards = vault["cards"] as? [[String: Any]], vault["financialInstitutions"] == nil, vault["financialProviders"] == nil else { throw ConversionError.unsupportedSource }
    let cardValues = try decode([BankCard].self, cards)
    var result: [FinancialInstitution] = []
    for raw in banks {
        guard let text = raw["id"] as? String, let id = UUID(uuidString: text), let regionText = raw["region"] as? String, let region = BankRegion(rawValue: regionText), raw["financialProfile"] == nil else { throw ConversionError.unsupportedSource }
        var institution = FinancialInstitution(kind: .bank)
        institution.id = id
        institution.name = raw["bankName"] as? String ?? ""
        institution.note = raw["note"] as? String ?? ""
        institution.region = region
        institution.status = try decode(AccountStatus.self, raw["status"] ?? "normal")
        institution.isOnlineBank = raw["onlineBank"] as? Bool ?? false
        institution.branchName = raw["branchName"] as? String ?? ""
        if let value = raw["branchLocation"] { institution.branchLocation = try decode(BankBranchLocation.self, value) }
        if let value = raw["openedAt"] { institution.openedAt = try decode(Date.self, value) }
        institution.correspondenceAddressChinese = raw["correspondenceAddressChinese"] as? String ?? ""
        institution.correspondenceAddressEnglish = raw["correspondenceAddressEnglish"] as? String ?? ""
        institution.residentialAddressChinese = raw["residentialAddressChinese"] as? String ?? ""
        institution.residentialAddressEnglish = raw["residentialAddressEnglish"] as? String ?? ""
        institution.swift = raw["swift"] as? String ?? ""
        institution.iban = raw["iban"] as? String ?? ""
        institution.remittanceBankName = raw["remittanceBankName"] as? String ?? ""
        institution.remittanceBankAddress = raw["remittanceBankAddress"] as? String ?? ""
        institution.remittanceInstructions = raw["remittanceInstructions"] as? String ?? ""
        institution.domesticSubaccounts = try decode([DomesticSubaccount].self, raw["domesticSubaccounts"] ?? [])
        institution.foreignSubaccounts = try decode([ForeignSubaccount].self, raw["foreignSubaccounts"] ?? [])
        var fields = try decode([AdditionalLoginField].self, raw["additionalLoginFields"] ?? [])
        for (name, field, sensitive) in [("绑定手机号", "boundPhoneNumber", false), ("登录账号", "loginAccount", false), ("登录密码", "loginPassword", true)] {
            if let value = raw[field] as? String, !value.isEmpty, !fields.contains(where: { $0.name == name && $0.value == value }) {
                fields.append(AdditionalLoginField(name: name, value: value, isSensitive: sensitive))
            }
        }
        institution.additionalLoginFields = fields
        institution.cards = cardValues.filter { $0.accountID == id }
        try institution.validate()
        result.append(institution)
    }
    guard Set(result.map(\.id)).count == banks.count, result.flatMap(\.cards).count == cards.count, Set(cardValues.map(\.id)).count == cards.count else { throw ConversionError.invalidRelationship }
    // Preserve every card field (including unknown keys and embedded PDF bytes).
    var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [[String: Any]]
    for i in encoded.indices {
        var bank = encoded[i]["bank"] as! [String: Any]
        bank["cards"] = cards.filter { ($0["accountID"] as? String)?.uppercased() == result[i].id.uuidString.uppercased() }
        encoded[i]["bank"] = bank
    }
    let verified = try decode([FinancialInstitution].self, encoded)
    for institution in verified { try institution.validate() }
    guard verified == result else { throw ConversionError.invalidRelationship }
    vault.removeValue(forKey: "accounts"); vault.removeValue(forKey: "cards")
    vault["financialInstitutions"] = encoded
    var output = source; output["vault"] = vault
    return output
}

@main struct ConvertBankBackup {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { print("Usage: convert-bank-backup INPUT.mytools OUTPUT.mytools"); exit(1) }
            let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            guard input != output, !FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputExists }
            guard let entered = getpass("Backup password: ") else { exit(1) }
            let password = String(cString: entered)
            let original = try Data(contentsOf: input)
            let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: original)
            guard envelope.format == "mytools-vault", envelope.version == "1.0" else { throw ConversionError.invalidEnvelope }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.combined), using: key(password, salt: envelope.salt))
            let source = try JSONSerialization.jsonObject(with: plaintext) as! [String: Any]
            let converted = try convert(source)
            let payload = try jsonData(converted)
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let derived = try key(password, salt: salt)
            let sealed = try AES.GCM.seal(payload, using: derived)
            let candidate = try JSONEncoder().encode(BackupEnvelope(format: envelope.format, version: envelope.version, salt: salt, combined: sealed.combined!))
            let check = try JSONDecoder().decode(BackupEnvelope.self, from: candidate)
            let reopened = try AES.GCM.open(AES.GCM.SealedBox(combined: check.combined), using: key(password, salt: check.salt))
            guard reopened == payload, try Data(contentsOf: input) == original else { throw ConversionError.invalidRelationship }
            try candidate.write(to: output, options: [.withoutOverwriting])
            let vault = converted["vault"] as! [String: Any]
            let institutions = try decode([FinancialInstitution].self, vault["financialInstitutions"]!)
            print("Verified: \(institutions.count) banks, \(institutions.flatMap(\.cards).count) cards, \(institutions.flatMap(\.allAccounts).count) accounts. Original unchanged.")
        } catch { fputs("Conversion failed: \(error)\n", stderr); exit(2) }
    }
}
