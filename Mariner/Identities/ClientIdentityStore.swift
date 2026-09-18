// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import Security

/// A client certificate identity available for `6x` challenges.
struct StoredClientIdentity: Identifiable, Equatable {
    /// Keychain label (`mariner.identity.<uuid>`); stable across launches.
    let id: String
    /// Human-readable name: certificate common name, or a short id prefix.
    let displayName: String
}

/// Errors from importing or reading client certificate identities.
enum IdentityError: LocalizedError, Equatable {
    case wrongPassword
    case noIdentityInFile
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "The password was incorrect."
        case .noIdentityInFile: return "No certificate identity was found in that file."
        case .keychainError(let detail): return "Keychain error: \(detail)"
        }
    }
}

/// Imports PKCS#12 client identities and persists them in the Keychain
/// (kSecClassIdentity) so they survive relaunches and can be bound to hosts.
///
/// Uses the data-protection Keychain (no per-item ACLs), so reads and writes
/// never trigger "wants to access your keychain" prompts.
@Observable @MainActor
final class ClientIdentityStore {
    private(set) var identities: [StoredClientIdentity] = []

    static let labelPrefix = "mariner.identity."

    init() {
        refresh()
    }

    /// Re-reads the Keychain. Call after import/delete.
    func refresh() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess else {
            identities = []
            return
        }
        let attributes: [[String: Any]]
        if let array = items as? [[String: Any]] {
            attributes = array
        } else if let single = items as? [String: Any] {
            attributes = [single]
        } else {
            identities = []
            return
        }
        identities = attributes.compactMap { attrs in
            guard let label = attrs[kSecAttrLabel as String] as? String,
                label.hasPrefix(Self.labelPrefix)
            else { return nil }
            return StoredClientIdentity(id: label, displayName: Self.commonName(forLabel: label) ?? label)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Imports the first identity from PKCS#12 `data` and stores it in the Keychain.
    @discardableResult
    func importIdentity(pkcs12Data data: Data, password: String) throws -> StoredClientIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]] else {
            if status == errSecAuthFailed {
                throw IdentityError.wrongPassword
            }
            throw IdentityError.keychainError("Import failed (OSStatus \(status)).")
        }
        guard let secIdentity = items.first?[kSecImportItemIdentity as String] else {
            throw IdentityError.noIdentityInFile
        }
        let label = Self.labelPrefix + UUID().uuidString
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: secIdentity,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw IdentityError.keychainError("Could not store identity (OSStatus \(addStatus)).")
        }
        refresh()
        return identities.first { $0.id == label } ?? StoredClientIdentity(id: label, displayName: label)
    }

    /// The `SecIdentity` for a stored id, or nil if it was removed.
    func secIdentity(for id: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: id,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecIdentity)
    }

    func delete(_ identity: StoredClientIdentity) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: identity.id,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        refresh()
    }

    private static func commonName(forLabel label: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let identity = item as! SecIdentity?
        else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
            let certificate
        else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }
}
