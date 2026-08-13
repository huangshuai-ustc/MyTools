#if MYTOOLS_FEATURE_SECRETS
import Foundation
import Testing
@testable import MyTools

struct SecretsTests {
    @Test func applePasswordCSVMapsLoginFieldsAndQuotedNotes() throws {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\n\"Example\",https://example.com,user,secret,\"line one\nline two\",otpauth://totp/example"
        let preview = try ApplePasswordImporter.decode(data: Data(csv.utf8), fileName: "passwords.csv")
        #expect(preview.items.count == 1)
        let item = try #require(preview.items.first)
        #expect(item.category == .login)
        #expect(item.purpose == .personal)
        #expect(item.fields.first(where: { $0.label == "URL" })?.value == "https://example.com")
        #expect(item.fields.first(where: { $0.label == "用户名" })?.value == "user")
        #expect(item.fields.first(where: { $0.label == "密码" })?.value == "secret")
        #expect(item.fields.first(where: { $0.label == "OTPAuth" })?.value == "otpauth://totp/example")
        #expect(item.note == "line one\nline two")
    }

    @Test func oldSecretItemDefaultsPurposeToPersonal() throws {
        let data = Data("{\"title\":\"Legacy\",\"category\":\"login\",\"fields\":[]}".utf8)
        let item = try JSONDecoder().decode(SecretItem.self, from: data)
        #expect(item.purpose == .personal)
    }

    @Test func loginTemplatePlacesURLLast() {
        #expect(SecretCategory.login.defaultFields.map(\.label) == ["用户名", "密码", "URL"])
        #expect(SecretCategory.login.defaultFields.map(\.inputType) == [.text, .text, .url])
    }

    @Test func legacyDateAndURLKindsMapToInputTypes() throws {
        let data = Data("{\"label\":\"日期\",\"value\":\"2026-08-13\",\"kind\":\"date\"}".utf8)
        let dateField = try JSONDecoder().decode(SecretField.self, from: data)
        #expect(dateField.inputType == .date)

        let urlData = Data("{\"label\":\"URL\",\"kind\":\"url\"}".utf8)
        let urlField = try JSONDecoder().decode(SecretField.self, from: urlData)
        #expect(urlField.inputType == .url)
    }

    @Test @MainActor func secretStoreCompletesMissingTemplatesAndCreatesFreshFields() {
        let custom = SecretFieldTemplate(
            category: .login,
            fields: [
                SecretField(label: "密码", kind: .password),
                SecretField(label: "用户名", kind: .username),
                SecretField(label: "URL", kind: .url)
            ]
        )
        let store = SecretStore(
            fieldTemplates: [custom],
            attachmentStore: AttachmentStore()
        )

        #expect(store.fieldTemplates.count == SecretCategory.allCases.count)
        #expect(store.fieldTemplate(for: .login).fields.map(\.label) == ["密码", "用户名", "URL"])

        let fields = store.makeFields(for: .login)
        #expect(fields.map(\.value) == ["", "", ""])
        #expect(Set(fields.map(\.id)).count == fields.count)
    }

    @Test @MainActor func vaultDataLegacyDecodeCompletesTemplatesInSecretStore() throws {
        let data = Data("{\"currencyRateAlerts\":[],\"stockPriceAlerts\":[]}".utf8)
        let vault = try JSONDecoder().decode(VaultData.self, from: data)
        #expect(vault.secretFieldTemplates.isEmpty)

        let store = SecretStore(
            fieldTemplates: vault.secretFieldTemplates,
            attachmentStore: AttachmentStore()
        )
        #expect(store.fieldTemplates.count == SecretCategory.allCases.count)
    }
}
#endif
