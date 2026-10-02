import Foundation

/// 공개 릴리즈의 X.Y.Z만 비교한다. 사전 릴리즈나 잘못된 태그는 업데이트로 안내하지 않는다(ADR 0044).
public struct ReleaseVersion: Sendable, Equatable, Comparable {
    public let string: String
    private let components: [Int]

    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        string = text
        components = numbers
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum UpdateCheckPolicy {
    public static let interval: TimeInterval = 24 * 60 * 60

    /// 마지막 시도도 저장해 오류나 재실행 때문에 요청이 몰리지 않게 한다. 시계가 뒤로 가면 새 기준으로 확인한다.
    public static func delay(lastAttempt: Date?, now: Date) -> TimeInterval {
        guard let lastAttempt, lastAttempt <= now else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastAttempt))
    }
}
