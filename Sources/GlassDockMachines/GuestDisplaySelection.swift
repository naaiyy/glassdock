import Foundation

/// A firmware framebuffer and an accelerated adapter can expose separate SPICE
/// channels. Prefer the live GPU rather than the inactive firmware primary.
public enum GuestDisplaySelection {
    public struct Candidate {
        public let accelerated: Bool
        public let primary: Bool
        public let width: Double
        public let height: Double
        public init(accelerated: Bool, primary: Bool, width: Double, height: Double) {
            self.accelerated = accelerated
            self.primary = primary
            self.width = width
            self.height = height
        }
    }
    public static func preferredIndex(in candidates: [Candidate]) -> Int? {
        candidates.indices.filter { candidates[$0].width > 0 && candidates[$0].height > 0 }.max {
            let lhs = candidates[$0]
            let rhs = candidates[$1]
            return (lhs.accelerated ? 2 : lhs.primary ? 1 : 0) < (rhs.accelerated ? 2 : rhs.primary ? 1 : 0)
        }
    }
}
