// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Observes the arrival of a new incoming call only. Calls that were already
/// active when the wait began and outgoing calls never finish it. A separate
/// instance belongs to each wait, and it never answers or records a call.
struct AirRecordIncomingWaitPolicy {
    struct Call: Equatable {
        let id: UUID
        let isOutgoing: Bool
        let hasEnded: Bool
    }

    enum Result: Equatable {
        case incoming, cancelled, timedOut, invalidClock

        var detectedIncoming: Bool { self == .incoming }
    }

    enum Decision: Equatable { case waiting, finished(Result) }

    static let defaultTimeout: TimeInterval = 60 * 60
    static let maximumTimeout: TimeInterval = 180 * 60

    let startedAt: TimeInterval
    let deadline: TimeInterval
    private let preexisting: Set<UUID>
    private var lastObservedAt: TimeInterval
    private var terminal: Result?

    static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(maximumTimeout, max(1, value)) : defaultTimeout
    }

    init(startedAt: TimeInterval, timeout: TimeInterval, initialCalls: [Call]) {
        self.startedAt = startedAt
        deadline = startedAt + Self.boundedTimeout(timeout)
        lastObservedAt = startedAt
        preexisting = Set(initialCalls.filter { !$0.hasEnded }.map(\.id))
    }

    /// The candidate is the only active call, it is incoming, and it began
    /// after this wait. Ringing is enough: the Shortcut must switch cellular
    /// data off before the call connects and the monitor starts inspecting.
    func hasCandidate(in calls: [Call]) -> Bool {
        let active = calls.filter { !$0.hasEnded }
        guard active.count == 1, let call = active.first else { return false }
        return !call.isOutgoing && !preexisting.contains(call.id)
    }

    /// `cellularCalls` is the number of active calls CoreTelephony reports, or
    /// nil when that legacy source cannot answer. With `requireCellular`, a
    /// CallKit-only (internet) call keeps the wait running; an unknown answer
    /// does not block detection.
    mutating func decision(now: TimeInterval, calls: [Call], requireCellular: Bool,
                           cellularCalls: Int?, cancelled: Bool = false) -> Decision {
        if let terminal { return .finished(terminal) }
        if cancelled { return finish(.cancelled) }
        guard now.isFinite, startedAt.isFinite, lastObservedAt.isFinite, deadline.isFinite,
              startedAt >= 0, now >= lastObservedAt else { return finish(.invalidClock) }
        lastObservedAt = now
        // A delayed callback must not convert an expired wait into success.
        guard now < deadline else { return finish(.timedOut) }
        // Call waiting or a conference is never a single recordable call.
        guard hasCandidate(in: calls) else { return .waiting }
        if requireCellular, let cellularCalls, cellularCalls <= 0 { return .waiting }
        return finish(.incoming)
    }

    private mutating func finish(_ result: Result) -> Decision {
        terminal = result
        return .finished(result)
    }
}
