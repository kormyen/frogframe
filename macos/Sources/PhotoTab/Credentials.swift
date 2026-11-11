import Foundation
import Security

enum Credentials {
    private static let service = "nz.kor.frogframe.manager"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "bucket"]
    }
    static func load() -> BucketConfiguration? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BucketConfiguration.self, from: data)
    }
    static func save(_ configuration: BucketConfiguration) throws {
        _ = try configuration.validatedURL()
        let data = try JSONEncoder().encode(configuration)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BucketError.message("Cannot save the management token in Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw BucketError.message("Cannot update the management token in Keychain (\(status)).")
        }
    }
}
