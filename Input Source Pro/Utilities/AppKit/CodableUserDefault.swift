import Cocoa
import Combine

@propertyWrapper
final class CodableUserDefault<T: Codable>: NSObject {
    var wrappedValue: T? {
        get {
            guard let data = userDefaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        set {
            do {
                let data = try JSONEncoder().encode(newValue)

                userDefaults.setValue(data, forKey: key)
            } catch {
                print("Unable to Encode (\(error))")
            }
        }
    }

    private let key: String
    private let userDefaults: UserDefaults
    private var observerContext = 0
    private let subject: CurrentValueSubject<T?, Never>

    init(wrappedValue defaultValue: T, _ key: String, userDefaults: UserDefaults = .standard) {
        self.key = key
        self.userDefaults = userDefaults
        subject = CurrentValueSubject(defaultValue)

        super.init()

        do {
            try userDefaults.register(defaults: [key: JSONEncoder().encode(defaultValue)])
            // This fulfills requirement 4. Some implementations use NSUserDefaultsDidChangeNotification
            // but that is sent every time any value is updated in UserDefaults.
            userDefaults.addObserver(self, forKeyPath: key, options: .new, context: &observerContext)
        } catch {
            print("Unable to register (\(error))")
        }

        subject.value = wrappedValue
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if context == &observerContext {
            subject.value = wrappedValue
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    deinit {
        userDefaults.removeObserver(self, forKeyPath: key, context: &observerContext)
    }
}
