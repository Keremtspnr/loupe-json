import Darwin
import Synchronization

/// Cooperative cancellation flag shared between the UI and a worker.
public final class CancelToken: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

public struct CancelledError: Error {}

/// Time-based gate so long loops report progress at most every `interval`.
struct Throttle {
    private var last: UInt64
    private let interval: UInt64

    init(milliseconds: UInt64 = 100) {
        interval = milliseconds * 1_000_000
        last = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    mutating func due() -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- last >= interval else { return false }
        last = now
        return true
    }
}
