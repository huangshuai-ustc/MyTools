import Foundation
import CryptoKit
import Testing
@testable import MyTools

struct AdminPasswordHashTests {
    private func legacySHA256Hex(of password: String) -> String {
        SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @Test func saltedHashRoundTrip() {
        let stored = AdminPasswordHash.make(for: "password-123")
        #expect(stored.hasPrefix("pbkdf2-sha256$"))
        #expect(!AdminPasswordHash.isLegacy(stored))
        #expect(AdminPasswordHash.verify("password-123", stored: stored))
        #expect(!AdminPasswordHash.verify("wrong-password", stored: stored))
    }

    @Test func twoHashesOfSamePasswordDifferBySalt() {
        let first = AdminPasswordHash.make(for: "password-123")
        let second = AdminPasswordHash.make(for: "password-123")
        #expect(first != second)
        #expect(AdminPasswordHash.verify("password-123", stored: first))
        #expect(AdminPasswordHash.verify("password-123", stored: second))
    }

    @Test func legacyUnsaltedHashStillVerifiesAndIsRecognized() {
        let legacy = legacySHA256Hex(of: "password-123")
        #expect(AdminPasswordHash.isLegacy(legacy))
        #expect(AdminPasswordHash.verify("password-123", stored: legacy))
        #expect(!AdminPasswordHash.verify("wrong-password", stored: legacy))
    }

    @Test func malformedStoredValuesRejectEveryPassword() {
        let malformed = [
            "pbkdf2-sha256$210000$not-base64$",
            "pbkdf2-sha256$1$",
            "",
            "short",
        ]
        for stored in malformed {
            #expect(!AdminPasswordHash.verify("password-123", stored: stored))
        }
    }

    @Test @MainActor
    func authManagerMigratesLegacyHashAfterSuccessfulUnlock() {
        let defaults = UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
        defaults.set(legacySHA256Hex(of: "admin-pass-123"), forKey: "admin-password-hash")
        let auth = AuthManager(defaults: defaults)

        #expect(auth.hasPassword)
        #expect(!auth.unlock(with: "wrong-password"))
        #expect(!auth.isAdmin)

        #expect(auth.unlock(with: "admin-pass-123"))
        #expect(auth.isAdmin)
        let migrated = defaults.string(forKey: "admin-password-hash")
        #expect(migrated?.hasPrefix("pbkdf2-sha256$") == true)
        #expect(AdminPasswordHash.isLegacy(migrated ?? "") == false)

        auth.lock()
        #expect(auth.unlock(with: "admin-pass-123"))
        #expect(defaults.string(forKey: "admin-password-hash") == migrated)
    }
}
