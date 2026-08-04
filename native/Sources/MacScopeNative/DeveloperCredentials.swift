import Foundation
import Security

enum DeveloperCredentialStore {
  private static let service = "com.shenmuoso.macscope.developer-login"
  private static let account = "password"

  static func password() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(password: String) throws {
    let data = Data(password.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    } else if status != errSecSuccess {
      throw keychainError(status)
    }
  }

  static func clear() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
    return NSError(
      domain: NSOSStatusErrorDomain,
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
