import Foundation
import Security

private enum GoogleCredentialsStore {
    private static let service = "com.cyberofficeindustries.smoothtalker.google-credentials"
    private static let account = "service-account-json"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            return nil
        }

        guard let data = item as? Data,
              let credentials = String(data: data, encoding: .utf8) else {
            return nil
        }

        return credentials
    }

    @discardableResult
    static func save(_ credentials: String) -> Bool {
        guard let data = credentials.data(using: .utf8) else {
            return false
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return false
        }

        return true
    }

    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return false
        }

        return true
    }
}

class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let credentials = "credentials"
        static let inputText = "inputText"
        static let voiceName = "voiceName"
        static let language = "language"
        static let speakingSpeed = "speakingSpeed"
        static let hotkey = "hotkey"
        static let secondLaunch = "secondLaunch"
        static let hasPremiumVoices = "hasPremiumVoices"
    }
    
    var credentials: String {
        get {
            if let credentials = GoogleCredentialsStore.load() {
                return credentials
            }

            guard let legacyCredentials = defaults.string(forKey: Keys.credentials),
                  !legacyCredentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ""
            }

            do {
                _ = try GoogleServiceAccountCredentials.validate(legacyCredentials)
            } catch {
                return legacyCredentials
            }

            if GoogleCredentialsStore.save(legacyCredentials) {
                defaults.removeObject(forKey: Keys.credentials)
            }

            return legacyCredentials
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedValue.isEmpty else {
                GoogleCredentialsStore.clear()
                defaults.removeObject(forKey: Keys.credentials)
                return
            }

            if GoogleCredentialsStore.save(trimmedValue) {
                defaults.removeObject(forKey: Keys.credentials)
            }
        }
    }
    
    var inputText: String {
        get { defaults.string(forKey: Keys.inputText) ?? "Have a nice day!" }
        set { defaults.set(newValue, forKey: Keys.inputText) }
    }
    
    var voiceName: String {
        get { defaults.string(forKey: Keys.voiceName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceName) }
    }
    
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }
    
    var speakingSpeed: Double {
        get { defaults.double(forKey: Keys.speakingSpeed) }
        set { defaults.set(newValue, forKey: Keys.speakingSpeed) }
    }

    var hotkey: String {
        get { defaults.string(forKey: Keys.hotkey) ?? "option + `" }
        set { defaults.set(newValue, forKey: Keys.hotkey) }
    }
    
    var secondLaunch: Bool {
        get { defaults.bool(forKey: Keys.secondLaunch) }
        set { defaults.set(newValue, forKey: Keys.secondLaunch) }
    }
    
    var hasPremiumVoices: Bool {
        get { defaults.bool(forKey: Keys.hasPremiumVoices) }
        set { defaults.set(newValue, forKey: Keys.hasPremiumVoices) }
    }
    
    private init() {
        // Set default values for the doubles
        if defaults.object(forKey: Keys.speakingSpeed) == nil {
            defaults.set(1.0, forKey: Keys.speakingSpeed)
        }
    }
} 
