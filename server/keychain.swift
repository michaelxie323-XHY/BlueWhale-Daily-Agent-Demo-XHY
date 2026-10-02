import Foundation
import Security
// JSON input travels over stdin, never process arguments. Output is captured by launcher.
let input = FileHandle.standardInput.readDataToEndOfFile()
do {
    let values = try JSONSerialization.jsonObject(with: input) as? [String: String] ?? [:]
    guard let account = values["account"], ["openai", "amap"].contains(account) else { exit(2) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ai.whale.companion.gateway", kSecAttrAccount as String: account]
    let operation = values["operation"] ?? "read"
    var status: OSStatus
    if operation == "save", let key = values["key"], !key.isEmpty {
        let data = Data(key.utf8)
        status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
    } else if operation == "delete" {
        status = SecItemDelete(query as CFDictionary)
    } else if operation == "read" {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            FileHandle.standardOutput.write(data)
        }
    } else { exit(2) }
    if status == errSecItemNotFound { exit(3) }
    if status != errSecSuccess { fputs("Keychain operation failed (\(status))\n", stderr); exit(1) }
} catch { exit(2) }
