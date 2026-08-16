import Foundation
@testable import ApfelRunCore

/// Deterministic RandomBytesProviding for PKCE/state assertions.
/// Each call to `randomBytes` consumes the next scripted draw; when the
/// script is exhausted it repeats the last one. Records how many draws
/// were made so tests can assert "independent draw" semantics.
final class FixedRandom: RandomBytesProviding, @unchecked Sendable {
    // Test-only fixture: mutated from a single test thread.
    private(set) var draws: [[UInt8]]
    private(set) var callCount = 0

    init(draws: [[UInt8]]) {
        self.draws = draws
    }

    convenience init(bytes: [UInt8]) {
        self.init(draws: [bytes])
    }

    func randomBytes(_ count: Int) -> [UInt8] {
        let index = min(callCount, draws.count - 1)
        callCount += 1
        let draw = draws[index]
        precondition(draw.count == count, "scripted draw has \(draw.count) bytes, caller wants \(count)")
        return draw
    }
}

/// Deterministic clock for expiry math.
struct FixedClock: AuthClock {
    var now: Date
    init(now: Date = Date(timeIntervalSince1970: 1_755_000_000)) {
        self.now = now
    }
}
