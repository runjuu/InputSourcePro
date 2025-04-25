import AppKit
import ApplicationServices

extension AXValue {
    private func get<T>(_ type: AXValueType, initial: T) -> T? {
        var result = initial
        return AXValueGetValue(self, type, &result) ? result : nil
    }

    var asPoint: CGPoint? { return get(.cgPoint, initial: .zero) }
    var asSize: CGSize? { return get(.cgSize, initial: .zero) }
    var asRect: CGRect? { return get(.cgRect, initial: .zero) }
    var asRange: CFRange? { return get(.cfRange, initial: CFRange()) }
    var asError: AXError? { return get(.axError, initial: .success) }

    private static func create<T>(_ type: AXValueType, _ value: T) -> AXValue {
        var value = value
        return AXValueCreate(type, &value)!
    }

    static func point(_ v: CGPoint) -> AXValue { return create(.cgPoint, v) }
    static func size(_ v: CGSize) -> AXValue { return create(.cgSize, v) }
    static func rect(_ v: CGRect) -> AXValue { return create(.cgRect, v) }
    static func range(_ v: CFRange) -> AXValue { return create(.cfRange, v) }
    static func error(_ v: AXError) -> AXValue { return create(.axError, v) }
}
