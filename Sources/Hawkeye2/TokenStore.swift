import Foundation
import HawkeyeCore
import Security
import Darwin

enum TokenStore {
    case keychain
    case providerKeychain(TaskProviderID)
    case file(URL)

    private static let account = "personal-access-token"

    static let developmentDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hawkeye2/Development", isDirectory: true)

    static var defaultStore: TokenStore {
        #if DEBUG
        .file(developmentDirectory.appendingPathComponent("ticktick-pat.txt"))
        #else
        .keychain
        #endif
    }

    func scoped(to provider: TaskProviderID) -> TokenStore {
        if provider == .ticktick {
            if case .providerKeychain = self { return .keychain }
            return self
        }
        if case .file(let url) = self {
            return .file(url.deletingLastPathComponent().appendingPathComponent("\(provider.rawValue)-pat.txt"))
        }
        return .providerKeychain(provider)
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    func read() throws -> String? {
        if case .file(let url) = self {
            do {
                let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return nil
            }
        }
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return token
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        if case .file(let url) = self {
            let manager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".pat-\(UUID().uuidString)")
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? manager.removeItem(at: temporary) }
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = identity
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func remove() throws {
        if case .file(let url) = self {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return
            }
            return
        }
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var identity: [String: Any] {
        let provider: TaskProviderID
        if case .providerKeychain(let selected) = self { provider = selected }
        else { provider = .ticktick }
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.hawkeye2.mac.\(provider.rawValue)", kSecAttrAccount as String: Self.account]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain returned error \(status) when accessing the app token. Unlock your login Keychain and try again."
    }
}
