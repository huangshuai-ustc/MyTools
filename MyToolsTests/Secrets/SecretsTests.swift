#if MYTOOLS_FEATURE_SECRETS
import Foundation
import Testing
@testable import MyTools

struct SecretsTests {
    @Test func tagInputUsesChineseCommaAndNormalizesLegacySeparators() {
        #expect(AppTagSupport.parse(" 旅行，朋友推荐、旅行, ") == ["旅行", "朋友推荐"])
        #expect(AppTagSupport.joined(["旅行", "朋友推荐"]) == "旅行，朋友推荐")
        #expect(AppTagSupport.normalize(["旅行、朋友推荐", "旅行"]) == ["旅行", "朋友推荐"])
    }

    @Test func tagLibrariesRoundTripThroughVaultData() throws {
        let vault = VaultData(
            medicalRecordTags: ["复诊"],
            foodPlaceTags: ["沪菜"],
            credentialTags: ["旅行"],
            billTags: ["餐饮"],
            secretTags: ["工作"]
        )
        let data = try JSONEncoder().encode(vault)
        let restored = try JSONDecoder().decode(VaultData.self, from: data)

        #expect(restored.medicalRecordTags == ["复诊"])
        #expect(restored.foodPlaceTags == ["沪菜"])
        #expect(restored.credentialTags == ["旅行"])
        #expect(restored.billTags == ["餐饮"])
        #expect(restored.secretTags == ["工作"])
    }

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
        #expect(SecretFieldInputType.allCases == [.text, .url, .date])
    }

    @Test func legacyDateAndURLKindsMapToInputTypes() throws {
        let data = Data("{\"label\":\"日期\",\"value\":\"2026-08-13\",\"kind\":\"date\"}".utf8)
        let dateField = try JSONDecoder().decode(SecretField.self, from: data)
        #expect(dateField.inputType == .date)

        let urlData = Data("{\"label\":\"URL\",\"kind\":\"url\"}".utf8)
        let urlField = try JSONDecoder().decode(SecretField.self, from: urlData)
        #expect(urlField.inputType == .url)
    }

    @Test func legacyFieldsRemainSensitiveAndTemplatesPreserveSensitivity() throws {
        let legacy = try JSONDecoder().decode(SecretField.self, from: Data("{\"label\":\"旧字段\"}".utf8))
        #expect(legacy.isSensitive)

        let visible = SecretField(label: "明文字段", isSensitive: false)
        let copied = SecretFieldTemplate(category: .other, fields: [visible]).makeFields()
        #expect(copied.map(\.isSensitive) == [false])
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

    @Test @MainActor func templateSensitivityUpdatesExistingItems() throws {
        let item = SecretItem(
            category: .login,
            fields: [
                SecretField(label: "用户名", kind: .username),
                SecretField(label: "密码", kind: .password),
                SecretField(label: "URL", kind: .url)
            ]
        )
        let store = SecretStore(
            secretItems: [item],
            attachmentStore: AttachmentStore()
        )
        var template = store.fieldTemplate(for: .login)
        template.fields = template.fields.map { field in
            var updated = field
            if ["密码", "URL"].contains(field.label) {
                updated.isSensitive = false
            }
            return updated
        }

        store.upsertFieldTemplate(template)

        let saved = try #require(store.secretItems.first)
        #expect(saved.fields.first(where: { $0.label == "密码" })?.isSensitive == false)
        #expect(saved.fields.first(where: { $0.label == "URL" })?.isSensitive == false)
        #expect(saved.fields.first(where: { $0.label == "用户名" })?.isSensitive == true)
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
