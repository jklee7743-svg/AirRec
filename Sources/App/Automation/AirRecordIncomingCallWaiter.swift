// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import CallKit
import Foundation

private final class AirRecordIncomingWaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Reads CoreTelephony's legacy call list through the Objective-C runtime so a
/// deprecated declaration is never linked directly. A missing class or
/// selector answers nil ("unknown"); it never throws or stops the wait.
@MainActor
final class AirRecordCellularCallProbe {
    private let retained: NSObject?

    init() {
        retained = Self.makeCenter()
    }

    private static func makeCenter() -> NSObject? {
        guard let type = NSClassFromString("CTCallCenter") as? NSObject.Type else { return nil }
        return type.init()
    }

    /// Active cellular calls, or nil when CoreTelephony cannot answer.
    func activeCellularCalls() -> Int? {
        let first = retained.flatMap { Self.count(in: $0) }
        if let first, first > 0 { return first }
        // A fresh center avoids relying only on a long-lived cached list.
        let second = Self.makeCenter().flatMap { Self.count(in: $0) }
        if first == nil && second == nil { return nil }
        return max(first ?? 0, second ?? 0)
    }

    private static func count(in center: NSObject) -> Int? {
        guard center.responds(to: NSSelectorFromString("currentCalls")) else { return nil }
        guard let calls = center.value(forKey: "currentCalls") as? NSSet else { return 0 }
        var active = 0
        for case let call as NSObject in calls {
            guard call.responds(to: NSSelectorFromString("callState")) else {
                active += 1
                continue
            }
            if (call.value(forKey: "callState") as? String) != "CTCallStateDisconnected" {
                active += 1
            }
        }
        return active
    }
}

/// Observes CallKit only. It never answers, ends, or records a call and never
/// changes network settings, location sessions, or the monitor's preference.
@MainActor
enum AirRecordIncomingCallWaiter {
    static func wait(timeout: TimeInterval, requireCellular: Bool,
                     onProgress: @escaping @MainActor @Sendable (TimeInterval) -> Void) async -> Bool {
        let cancellation = AirRecordIncomingWaitCancellation()
        let request = Request(timeout: timeout, requireCellular: requireCellular,
                              cancellation: cancellation, onProgress: onProgress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation, cancelled: Task.isCancelled)
            }
        } onCancel: {
            // Mark before hopping to MainActor so an already queued call event
            // does not win solely because cancellation cleanup was queued later.
            cancellation.cancel()
            Task { @MainActor in request.cancel() }
        }
    }

    @MainActor
    private final class Request: NSObject, CXCallObserverDelegate {
        private let observer: CXCallObserver
        private let probe = AirRecordCellularCallProbe()
        private let requireCellular: Bool
        private let cancellation: AirRecordIncomingWaitCancellation
        private let onProgress: @MainActor @Sendable (TimeInterval) -> Void
        private var policy: AirRecordIncomingWaitPolicy
        private var continuation: CheckedContinuation<Bool, Never>?
        private var pollingTask: Task<Void, Never>?
        private var started = false
        private var skippedCalls: Set<UUID> = []

        init(timeout: TimeInterval, requireCellular: Bool,
             cancellation: AirRecordIncomingWaitCancellation,
             onProgress: @escaping @MainActor @Sendable (TimeInterval) -> Void) {
            let observer = CXCallObserver()
            self.observer = observer
            self.requireCellular = requireCellular
            self.cancellation = cancellation
            self.onProgress = onProgress
            // Calls already present (for example, the call a previous loop
            // iteration is still waiting on) never count as a new arrival.
            policy = AirRecordIncomingWaitPolicy(startedAt: ProcessInfo.processInfo.systemUptime,
                                                 timeout: timeout,
                                                 initialCalls: Request.snapshot(observer))
            super.init()
        }

        private static func snapshot(_ observer: CXCallObserver) -> [AirRecordIncomingWaitPolicy.Call] {
            observer.calls.map {
                AirRecordIncomingWaitPolicy.Call(id: $0.uuid, isOutgoing: $0.isOutgoing,
                                                 hasEnded: $0.hasEnded)
            }
        }

        func start(_ continuation: CheckedContinuation<Bool, Never>, cancelled: Bool) {
            guard !started else {
                continuation.resume(returning: false)
                return
            }
            started = true
            self.continuation = continuation
            if cancelled || cancellation.isCancelled {
                evaluate(cancelled: true)
                return
            }
            observer.setDelegate(self, queue: .main)
            evaluate()
            guard self.continuation != nil else { return }
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let remaining = self?.remainingBudget else { return }
                    guard remaining > 0 else {
                        self?.evaluate()
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64((min(1, remaining) * 1_000_000_000).rounded(.up)))
                    } catch { return }
                    self?.evaluate()
                }
            }
        }

        private var remainingBudget: TimeInterval? {
            guard continuation != nil else { return nil }
            return max(0, policy.deadline - ProcessInfo.processInfo.systemUptime)
        }

        func cancel() {
            cancellation.cancel()
            if started { evaluate(cancelled: true) }
        }

        nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
            // Re-read on the actor rather than carrying a possibly stale call.
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        private func evaluate(cancelled: Bool = false) {
            guard let continuation else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let calls = Request.snapshot(observer)
            // Ask CoreTelephony only while a new incoming call is present.
            let candidate = policy.hasCandidate(in: calls)
            let cellular: Int? = (requireCellular && candidate) ? probe.activeCellularCalls() : nil
            let decision = policy.decision(now: now, calls: calls, requireCellular: requireCellular,
                                           cellularCalls: cellular,
                                           cancelled: cancelled || cancellation.isCancelled)
            switch decision {
            case .waiting:
                if candidate, requireCellular, let cellular, cellular <= 0,
                   let id = calls.first(where: { !$0.hasEnded })?.id, !skippedCalls.contains(id) {
                    skippedCalls.insert(id)
                    AirRecordMonitor.shared.noteShortcutEvent("수신 대기: 일반 전화로 확인되지 않아 데이터 전환을 건너뜀")
                }
                onProgress(max(0, now - policy.startedAt))
            case .finished(let result):
                self.continuation = nil
                observer.setDelegate(nil, queue: nil)
                pollingTask?.cancel()
                pollingTask = nil
                let detected = result.detectedIncoming && !cancellation.isCancelled
                if detected {
                    let source = cellular.map { "일반 전화 \($0)건 확인" } ?? (requireCellular ? "일반 전화 여부 확인 불가" : "일반 전화 확인 안 함")
                    AirRecordMonitor.shared.noteShortcutEvent("수신 대기: 새 수신 전화 감지 (\(source))")
                }
                continuation.resume(returning: detected)
            }
        }
    }
}
#endif
