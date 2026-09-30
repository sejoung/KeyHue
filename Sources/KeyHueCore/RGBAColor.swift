import Foundation

/// AppKit 비의존 색상 값. UserDefaults에는 `#RRGGBB` 또는 `#RRGGBBAA` 문자열로 저장한다.
public struct RGBAColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else {
            return nil
        }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    public var hexString: String {
        let r = Self.byte(red), g = Self.byte(green), b = Self.byte(blue), a = Self.byte(alpha)
        if a == 0xFF {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}

extension RGBAColor {
    public static let defaultCapsLock = RGBAColor(hex: "#FF3B30")!
    public static let defaultUnknown = RGBAColor(hex: "#8E8E93")!
}
