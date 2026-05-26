import Foundation

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
    }
    
    var credentials: String {
        get { defaults.string(forKey: Keys.credentials) ?? "" }
        set { defaults.set(newValue, forKey: Keys.credentials) }
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
    
    private init() {
        // Set default values for the doubles
        if defaults.object(forKey: Keys.speakingSpeed) == nil {
            defaults.set(1.0, forKey: Keys.speakingSpeed)
        }
    }
} 
