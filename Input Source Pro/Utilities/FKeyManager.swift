import IOKit
import IOKit.hid
import Foundation

enum FKeyMode: String, CaseIterable, Identifiable {
    case mediaKeys
    case functionKeys

    var id: String { rawValue }

    var ioKitValue: Int {
        switch self {
        case .mediaKeys:
            return 0
        case .functionKeys:
            return 1
        }
    }

    var isFunctionKeysEnabled: Bool {
        self == .functionKeys
    }

    init(isFunctionKeysEnabled: Bool) {
        self = isFunctionKeysEnabled ? .functionKeys : .mediaKeys
    }

    init?(ioKitValue: Int) {
        switch ioKitValue {
        case 0:
            self = .mediaKeys
        case 1:
            self = .functionKeys
        default:
            return nil
        }
    }

    static func defaultIsFunctionKeysEnabled() -> Bool {
        switch FKeyManager.getCurrentFKeyMode() {
        case let .success(mode):
            return mode.isFunctionKeysEnabled
        case .failure:
            return false
        }
    }
}

enum FKeyManager {
    typealias FKeyManagerResult = Result<FKeyMode, Error>

    enum FKeyManagerError: LocalizedError {
        case cannotCreateMasterPort
        case cannotOpenService
        case cannotSetParameter
        case cannotGetParameter

        case otherError

        var errorDescription: String? {
            switch self {
            case .cannotCreateMasterPort:
                return "Master port creation failed (E1)"
            case .cannotOpenService:
                return "Service opening failed (E2)"
            case .cannotSetParameter:
                return "Parameter set not possible (E3)"
            case .cannotGetParameter:
                return "Parameter read not possible (E4)"
            default:
                return "Unknown error (E99)"
            }
        }
    }

    static func setCurrentFKeyMode(_ mode: FKeyMode) throws {
        let connect = try FKeyManager.getServiceConnect()
        defer { IOServiceClose(connect) }
        let value = mode.ioKitValue as CFNumber

        guard IOHIDSetCFTypeParameter(connect, kIOHIDFKeyModeKey as CFString, value) == KERN_SUCCESS else {
            throw FKeyManagerError.cannotSetParameter
        }
    }

    static func getCurrentFKeyMode() -> FKeyManagerResult {
        FKeyManagerResult {
            let registry = try self.getIORegistry()
            defer { IOObjectRelease(registry) }

            let entry = IORegistryEntryCreateCFProperty(
                registry,
                "HIDParameters" as CFString,
                kCFAllocatorDefault,
                0
            )
            .autorelease()

            guard let dict = entry.takeUnretainedValue() as? NSDictionary,
                  let mode = dict.value(forKey: "HIDFKeyMode") as? Int,
                  let currentMode = FKeyMode(ioKitValue: mode)
            else {
                throw FKeyManagerError.cannotGetParameter
            }

            return currentMode
        }
    }

    private static func getIORegistry() throws -> io_registry_entry_t {
        var masterPort: mach_port_t = .zero
        guard IOMasterPort(bootstrap_port, &masterPort) == KERN_SUCCESS else {
            throw FKeyManagerError.cannotCreateMasterPort
        }

        return IORegistryEntryFromPath(masterPort, "IOService:/IOResources/IOHIDSystem")
    }

    private static func getIOHandle() throws -> io_service_t {
        try self.getIORegistry() as io_service_t
    }

    private static func getServiceConnect() throws -> io_connect_t {
        var service: io_connect_t = .zero
        let handle = try self.getIOHandle()
        defer { IOObjectRelease(handle) }

        guard IOServiceOpen(handle, mach_task_self_, UInt32(kIOHIDParamConnectType), &service) == KERN_SUCCESS else {
            throw FKeyManagerError.cannotOpenService
        }

        return service
    }
}
