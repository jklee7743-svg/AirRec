// Copyright 2026 CallTap contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import CallKit
import Darwin
import Foundation
import UIKit

/// Reads the existing lock state; this never unlocks, synthesizes input, or
/// starts XCTest. A registration/read failure is treated as locked.
private final class AirRecordLockState: @unchecked Sendable {
    private let token: Int32

    init() {
        var value: Int32 = -1
        let result = notify_register_check("com.apple.springboard.lockstate", &value)
        token = result == 0 ? value : -1
    }

    var isUnlocked: Bool {
        guard token >= 0 else { return false }
        var state = UInt64.max
        return notify_get_state(token, &state) == 0 && state == 0
    }

    deinit {
        if token >= 0 { _ = notify_cancel(token) }
    }
}

/// The worker's synchronous callbacks access only this locked state. CallKit
/// snapshots are updated on the main actor; UIKit is never read on the worker.
private final class AirRecordAutomationGate: @unchecked Sendable {
    struct Inspection {
        let generation: UInt64
        let callID: UUID
        let mayOpenMore: Bool
    }

    private let lock = NSLock()
    private let lockState = AirRecordLockState()
    private var enabled = false
    private var generation: UInt64 = 0
    private var calls: [AirRecordCallState] = []
    private var policy = AirRecordPolicy()
    private var moreReservations: Set<UUID> = []
    private var deadlines: [UUID: TimeInterval] = [:]
    private var allowLocked = false
    private var retryWindow: TimeInterval = 20

    /// Options apply to readiness windows opened afterwards. Reservations and
    /// handled calls are kept, so a change can never grant a second start tap.
    func configure(allowLocked: Bool, retryWindow: TimeInterval, maximumInspections: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.allowLocked = allowLocked
        self.retryWindow = retryWindow
        policy.configure(retryWindow: retryWindow, maximumInspections: maximumInspections)
    }

    func update(_ calls: [AirRecordCallState]) {
        lock.lock()
        defer { lock.unlock() }
        self.calls = calls
        let active = Set(calls.filter { !$0.hasEnded }.map(\.id))
        moreReservations.formIntersection(active)
        deadlines = deadlines.filter { active.contains($0.key) }
    }

    func start(preservingWindows: Bool = false) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        enabled = true
        if !preservingWindows {
            policy.resume()
            deadlines.removeAll()
        }
        return generation
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
        generation &+= 1
    }

    func decision() -> (AirRecordPolicy.Decision, Inspection?) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let decision = policy.decision(calls: calls, enabled: enabled, now: now)
        guard case .inspect(let id) = decision else { return (decision, nil) }
        if deadlines[id] == nil { deadlines[id] = now + retryWindow }
        return (decision, Inspection(generation: generation, callID: id,
                                     mayOpenMore: !moreReservations.contains(id)))
    }

    private func permitsLocked(_ inspection: Inspection) -> Bool {
        let active = calls.filter { !$0.hasEnded }
        return enabled && generation == inspection.generation
            && active.count == 1 && active[0].id == inspection.callID
            && active[0].hasConnected && !active[0].isOnHold
            && deadlines[inspection.callID].map { ProcessInfo.processInfo.systemUptime <= $0 } == true
            && (allowLocked || lockState.isUnlocked)
    }

    func permits(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return permitsLocked(inspection)
    }

    func reserveMore(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection), !moreReservations.contains(inspection.callID) else { return false }
        guard let deadline = policy.reserveMenuWindow(for: inspection.callID, calls: calls,
                                                       now: ProcessInfo.processInfo.systemUptime) else { return false }
        deadlines[inspection.callID] = deadline
        // Reservation remains spent even if the subsequent request is ambiguous.
        moreReservations.insert(inspection.callID)
        return true
    }

    func reserveStart(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permitsLocked(inspection) else { return false }
        return policy.reserveStart(for: inspection.callID, calls: calls)
    }

    func isCurrent(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && generation == inspection.generation
    }

    func startWasReserved(_ inspection: Inspection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.reservedStarts.contains(inspection.callID)
    }

    func markAlreadyRecording(_ inspection: Inspection) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, generation == inspection.generation else { return }
        policy.markAlreadyRecording(inspection.callID)
    }
}

@MainActor
final class AirRecordMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = AirRecordMonitor()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var activationError: String? = nil
    @Published private(set) var status = "AirRec 비활성화됨"
    @Published private(set) var recentEvents: [String] = []
    /// Experimental: also inspect a call while the device reports locked.
    @Published private(set) var allowsLockedAttempts: Bool
    /// Experimental: 60-second readiness window instead of 20 seconds.
    @Published private(set) var extendsPreparationWindow: Bool

    var diagnosticSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return (["AirRec \(version)", "AirRec 활성화 설정: \(isEnabled ? "켜짐" : "꺼짐")",
                 "감시 상태: \(isRunning ? "실행 중" : "대기/중지")",
                 "활성화 오류: \(activationError ?? "없음")",
                 "백그라운드 AirRec 설정: \(standby.isEnabled ? "켜짐" : "꺼짐")",
                 "백그라운드 상태: \(standby.status)",
                 standby.authorizationText,
                 "위치 표시: \(standby.indicatorStatusText)",
                 "백그라운드 앱 새로 고침: \(standby.backgroundRefreshStatusText)",
                 "저전력 모드: \(standby.lowPowerModeEnabled ? "켜짐" : "꺼짐")",
                 "잠금 상태 시도: \(allowsLockedAttempts ? "켜짐" : "꺼짐")",
                 "녹음 준비 시간: \(extendsPreparationWindow ? 60 : 20)초",
                 "마지막 실행 점검: \(lastStandbyCheck.map { $0.formatted(date: .omitted, time: .standard) } ?? "없음")"] + recentEvents).joined(separator: "\n")
    }

    private let observer = CXCallObserver()
    private let gate = AirRecordAutomationGate()
    private let standby = AirRecordLocationKeepAlive.shared
    private let standbyAlert = AirRecordStandbyAlert.shared
    private var timer: Timer?
    private var standbyTimer: Timer?
    private var lastStandbyCheck: Date?
    private var workerIsRunning = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var preparationID = UUID()
    private var shortcutPreparation: Task<Bool, Never>?
    private var shortcutPreparationID: UUID?
    private var nativeGeneration: UInt64?
    private var recordingResults: [UUID: AirRecordRecordingWaitPolicy.NativeResult] = [:]
    private var recordingWait: Task<String, Never>?
    private var recordingWaitID: UUID?
    private var recordingWaitResume: Task<Bool, Never>?
    private var recordingWaitShortcutID: UUID?
    private var recordingWaitOwnedGeneration: UUID?
    private var recordingWaitPreparationResult: Bool?
    private let defaults: UserDefaults
    private static let enabledKey = "CallTap.RawAX.autoStartEnabled"
    private static let lockedAttemptsKey = "AirRec.incoming.allowLockedAttempts"
    private static let extendedWindowKey = "AirRec.incoming.extendedPreparationWindow"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        allowsLockedAttempts = defaults.bool(forKey: Self.lockedAttemptsKey)
        extendsPreparationWindow = defaults.bool(forKey: Self.extendedWindowKey)
        super.init()
        applyAutomationOptions()
        standby.onStopped = { [weak self] message in
            guard let self, self.isRunning || self.isPreparing else { return }
            if self.isPreparing {
                // startIfEnabled returns this failure to its original caller.
                // Keep the token so that caller can check its own cancellation
                // before disabling; delegate callbacks run in a separate task.
                self.setStatus(message)
                return
            }
            self.pause(message: message + " · 활성화 설정 유지")
        }
        standby.onEvent = { [weak self] message in self?.recordEvent(message) }
        if isEnabled { status = "AirRec 연결 확인 후 재개" }
    }

    func start() async {
        activationError = nil
        if shortcutPreparation != nil || isPreparing {
            pause(message: "AirRec 연결 재시도")
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        await prepare()
    }

    func resumeIfEnabled() async {
        standby.refreshEnvironment()
        guard UIApplication.shared.applicationState == .active else { return }
        standbyAlert.disarm()
        guard isEnabled else { return }
        noteStandbyProgress()
        await prepare()
    }

    func appDidEnterBackground() {
        guard isRunning, standby.isEnabled, standby.isRunning else { return }
        standbyAlert.arm()
    }

    func setLocationStandbyEnabled(_ enabled: Bool) async {
        if !enabled { standbyAlert.disarm() }
        // Revoke any in-flight input before changing execution support. The
        // call policy retains all recording reservations across this restart.
        pause(message: activationError ?? "백그라운드 AirRec 설정 변경")
        standby.setEnabled(enabled)
        guard !Task.isCancelled else { return }
        let request = preparationID
        // Ask on this explicit toggle before checking the main switch, pairing,
        // or VPN. Permission-only preparation never turns the main switch on.
        let plan = standby.requestBackgroundAuthorizationIfNeeded(monitoringEnabled: isEnabled)
        if plan.requiresPermissionDecision && isEnabled {
            setStatus(standby.status)
            let ready = await standby.waitForBackgroundAuthorizationDecision {
                self.preparationID == request && self.isEnabled && self.standby.isEnabled
            }
            // Off/Stop, another activation, or cancellation supersedes this
            // caller; its late permission result must not start a new engine.
            guard preparationID == request, isEnabled, standby.isEnabled, !Task.isCancelled else { return }
            if ready { await prepare() }
            else { failActivation(request: request, message: standby.status) }
        } else if plan.shouldPrepareMonitoring {
            await prepare()
        } else if isEnabled && enabled {
            failActivation(request: request, message: standby.status)
        }
    }

    /// A user-configured Shortcut may rearm this process without switching
    /// away from Phone. It does not turn a saved OFF preference back on.
    func resumeFromShortcut(recordingWaitOwner: UUID? = nil) async -> Bool {
        guard isEnabled, !Task.isCancelled else {
            if !isEnabled { setStatus(activationError ?? "홈에서 AirRec을 먼저 활성화해 주세요.") }
            return false
        }
        let request: UUID
        let preparation: Task<Bool, Never>
        if let existing = shortcutPreparation, let id = shortcutPreparationID {
            request = id
            preparation = existing
        } else {
            request = UUID()
            let task = Task { @MainActor in
                guard self.isEnabled, !Task.isCancelled else { return false }
                // Refresh even a running lease: it may be about to expire.
                // The same gate/policy retains all prior one-shot reservations.
                self.pause(message: "단축어로 AirRec 연결 재시도",
                           preservingShortcutPreparation: true, preservingLocation: true)
                self.bindRecordingWaitPreparation(shortcut: request)
                await self.prepare(retryTunnelFor: 8, shortcutOwner: request)
                return self.isEnabled && self.isRunning && !Task.isCancelled
            }
            shortcutPreparationID = request
            shortcutPreparation = task
            preparation = task
        }
        if let owner = recordingWaitOwner, recordingWaitID == owner {
            recordingWaitShortcutID = request
            recordingWaitOwnedGeneration = preparationID
        }
        let ready = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.shortcutPreparationID == request else { return }
                self.pause(message: "단축어 연결 준비 취소 · 활성화 설정 유지")
            }
        }
        if Task.isCancelled, shortcutPreparationID == request {
            pause(message: "단축어 연결 준비 취소 · 활성화 설정 유지")
        }
        if shortcutPreparationID == request {
            shortcutPreparation = nil
            shortcutPreparationID = nil
        }
        return ready && isEnabled && isRunning && !Task.isCancelled
    }

    /// Optional Shortcut step between the user's cellular-data OFF and ON
    /// actions. Conventional failures are text results so the next step runs.
    /// This method observes the existing engine; it never presses a button.
    func waitForRecordingFromShortcut(timeout: TimeInterval = 45) async -> String {
        let request: UUID
        let shared: Task<String, Never>
        if let existing = recordingWait, let id = recordingWaitID {
            request = id
            shared = existing
        } else {
            guard isEnabled else { return "AirRec이 꺼져 있습니다. 다음 동작에서 셀룰러 데이터를 복구하세요." }
            guard !Task.isCancelled else { return "녹음 대기를 취소했습니다. 셀룰러 데이터 상태를 확인하세요." }
            request = UUID()
            let startedAt = ProcessInfo.processInfo.systemUptime
            let initialGeneration = preparationID
            recordingWaitID = request
            recordingWaitOwnedGeneration = initialGeneration
            recordingWaitShortcutID = nil
            recordingWaitPreparationResult = nil
            let task = Task { @MainActor in
                await self.runRecordingWait(request: request, startedAt: startedAt,
                                            timeout: timeout, initialGeneration: initialGeneration)
            }
            recordingWait = task
            shared = task
        }
        let result = await withTaskCancellationHandler {
            await shared.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRecordingWait(request: request) }
        }
        if Task.isCancelled { cancelRecordingWait(request: request) }
        if recordingWaitID == request {
            recordingWait = nil
            recordingWaitID = nil
            recordingWaitResume = nil
            recordingWaitShortcutID = nil
            recordingWaitOwnedGeneration = nil
            recordingWaitPreparationResult = nil
        }
        return result
    }

    private func runRecordingWait(request: UUID, startedAt: TimeInterval,
                                  timeout: TimeInterval, initialGeneration: UUID) async -> String {
        var policy = AirRecordRecordingWaitPolicy(startedAt: startedAt, timeout: timeout,
                                                 initialGeneration: initialGeneration)
        let resume = Task { @MainActor in
            guard self.recordingWaitID == request, self.preparationID == initialGeneration,
                  self.isEnabled, !Task.isCancelled else { return false }
            let ready = await self.resumeFromShortcut(recordingWaitOwner: request)
            if self.recordingWaitID == request { self.recordingWaitPreparationResult = ready }
            return ready
        }
        recordingWaitResume = resume
        while recordingWaitID == request {
            let calls = currentCalls()
            updateCalls()
            let result = policy.callID.flatMap { recordingResults[$0] }
            let decision = policy.decision(
                now: ProcessInfo.processInfo.systemUptime, calls: calls, enabled: isEnabled,
                currentGeneration: preparationID,
                ownedGeneration: recordingWaitOwnedGeneration ?? initialGeneration,
                preparationResult: recordingWaitPreparationResult, nativeResult: result,
                currentNativeGeneration: nativeGeneration, nativeWorkInFlight: workerIsRunning,
                cancelled: Task.isCancelled)
            if case .finished(let outcome) = decision {
                return finishRecordingWait(outcome, request: request)
            }
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return finishRecordingWait(.cancelled, request: request) }
        }
        resume.cancel()
        return "녹음 대기가 다른 요청으로 바뀌었습니다. 셀룰러 데이터 상태를 확인하세요."
    }

    private func bindRecordingWaitPreparation(shortcut request: UUID) {
        guard recordingWaitID != nil, recordingWaitShortcutID == request,
              shortcutPreparationID == request else { return }
        recordingWaitOwnedGeneration = preparationID
    }

    private func pauseRecordingWaitGeneration(request: UUID, message: String) {
        guard recordingWaitID == request, let owned = recordingWaitOwnedGeneration,
              owned == preparationID else { return }
        // pause invalidates the gate synchronously before the Shortcut returns
        // and the user's next action restores cellular data.
        pause(message: message, preservingLocation: true)
    }

    private func cancelRecordingWait(request: UUID) {
        guard recordingWaitID == request else { return }
        recordingWait?.cancel()
        pauseRecordingWaitGeneration(request: request,
                                     message: "단축어 녹음 대기 취소 · 활성화 설정 유지")
        recordingWaitResume?.cancel()
    }

    private func finishRecordingWait(_ outcome: AirRecordRecordingWaitPolicy.Result, request: UUID) -> String {
        switch outcome {
        case .native:
            break
        case .stopped, .superseded:
            break // A new generation belongs to a different user action.
        default:
            pauseRecordingWaitGeneration(request: request,
                                         message: "단축어 녹음 대기 종료 · 활성화 설정 유지")
        }
        recordingWaitResume?.cancel()
        let message: String
        switch outcome {
        case .native(let result, let reused):
            if reused {
                switch result {
                case .confirmed, .alreadyRecording:
                    message = "이 통화의 녹음 시작 처리는 이미 끝났습니다. 실제 타이머를 확인하세요."
                case .submittedUnconfirmed:
                    message = "이 통화의 녹음 요청은 이미 전달됐지만 실제 시작은 미확인입니다. 타이머를 확인하세요."
                case .failedAfterReservation:
                    message = "이 통화의 이전 시작 요청 결과를 확인하지 못했습니다. 다시 누르지 않았습니다."
                }
            } else {
                switch result {
                case .confirmed: message = "기본 전화 화면의 녹음 중 표식을 확인했습니다."
                case .alreadyRecording: message = "기본 전화 화면이 이미 녹음 중임을 확인했습니다."
                case .submittedUnconfirmed: message = "녹음 요청은 전달됐지만 실제 시작은 미확인입니다. 타이머를 확인하세요."
                case .failedAfterReservation: message = "녹음 시작 요청의 결과를 확인하지 못했습니다. 다시 누르지 않았습니다."
                }
            }
        case .stopped: message = "AirRec이 중지되어 녹음 대기를 끝냈습니다."
        case .superseded: message = "새 준비 요청이 시작되어 이전 녹음 대기를 끝냈습니다."
        case .cancelled: message = "녹음 대기를 취소했습니다."
        case .timedOut: message = "녹음 대기 시간이 끝났습니다. 현재 감시의 추가 입력을 중지했습니다."
        case .invalidClock: message = "대기 시간을 확인할 수 없어 현재 감시의 추가 입력을 중지했습니다."
        case .callEnded: message = "대상 통화가 종료되어 녹음 대기를 끝냈습니다."
        case .callChanged: message = "대상 통화가 바뀌어 녹음 대기를 끝냈습니다."
        case .multipleCalls: message = "활성 통화가 여럿이어서 녹음 대기를 끝냈습니다."
        case .preparationFailed: message = "AirRec 연결 준비가 완료되지 않아 녹음 대기를 끝냈습니다."
        }
        recordEvent("단축어 대기: " + message)
        return message + " 다음 동작에서 셀룰러 데이터를 복구하고 상태를 확인하세요."
    }

    private func prepare(retryTunnelFor: TimeInterval = 8, shortcutOwner: UUID? = nil) async {
        guard isEnabled, !isRunning, !isPreparing else { return }
        activationError = nil
        isPreparing = true
        let request = UUID()
        preparationID = request
        if let shortcutOwner { bindRecordingWaitPreparation(shortcut: shortcutOwner) }
        defer {
            // A canceled foreground task must release preparation and location
            // support, without allowing an old task to stop a newer request.
            if preparationID == request && isPreparing && Task.isCancelled {
                pause(message: "AirRec 연결 준비 취소 · 활성화 설정 유지")
            }
        }
        setStatus("페어링 파일과 LocalDevVPN 연결 확인")
        guard PairingFileStore.exists else {
            failActivation(request: request, message: "설정 탭에서 AirRec 초기 설정을 완료해 주세요.")
            return
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, retryTunnelFor)
        var probe: LocalDevVPN.TunnelProbe
        repeat {
            guard preparationID == request, isPreparing, isEnabled, !Task.isCancelled else { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let timeout = retryTunnelFor > 0 ? min(1.5, max(0.1, remaining)) : 1.5
            probe = await LocalDevVPN.probeTunnel(timeout: timeout)
            guard preparationID == request, isPreparing else { return }
            if probe == .reachable || probe == .localNetworkDenied { break }
            if retryTunnelFor <= 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { break }
        } while true
        guard preparationID == request, isPreparing else { return }
        guard isEnabled, !Task.isCancelled else { isPreparing = false; return }
        switch probe {
        case .reachable: break
        case .localNetworkDenied:
            failActivation(request: request, message: "설정에서 AirRec의 로컬 네트워크 접근을 허용하세요.")
            return
        case .unreachable:
            failActivation(request: request, message: "LocalDevVPN을 연결한 뒤 다시 시작하세요.")
            return
        }

        if standby.isEnabled {
            setStatus("백그라운드 AirRec 준비 중")
            let ready = await standby.startIfEnabled()
            guard preparationID == request, isPreparing, isEnabled, !Task.isCancelled else { return }
            guard ready, standby.isRunning else {
                failActivation(request: request, message: standby.status)
                return
            }
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AirRec AX") { [weak self] in
            // UIKit invokes expiration on the main actor. End its assertion
            // synchronously, and never let an old expiration pause a new run.
            guard let self, self.preparationID == request else { return }
            self.endBackgroundLease()
            if self.standby.isEnabled && self.standby.isRunning {
                self.recordEvent("백그라운드 AirRec 대기 유지")
                return
            }
            self.pause(message: "iOS가 감시 일시 중단 · 앱을 열면 재개")
            if UIApplication.shared.applicationState == .active {
                Task { await self.resumeIfEnabled() }
            }
        }
        guard backgroundTask != .invalid || (standby.isEnabled && standby.isRunning) else {
            failActivation(request: request, message: "백그라운드 실행 불가 · 잠시 후 다시 활성화해 주세요.")
            return
        }

        observer.setDelegate(self, queue: .main)
        updateCalls()
        nativeGeneration = gate.start()
        isPreparing = false
        isRunning = true
        activationError = nil
        startStandbyChecks()
        if UIApplication.shared.applicationState == .background { appDidEnterBackground() }
        setStatus(waitingStatus)
        evaluate()
    }

    func setAllowsLockedAttempts(_ enabled: Bool) {
        guard enabled != allowsLockedAttempts else { return }
        allowsLockedAttempts = enabled
        defaults.set(enabled, forKey: Self.lockedAttemptsKey)
        applyAutomationOptions()
        recordEvent(enabled ? "잠금 상태 통화 녹음 시도 켜짐" : "잠금 상태 통화 녹음 시도 꺼짐")
    }

    func setExtendsPreparationWindow(_ enabled: Bool) {
        guard enabled != extendsPreparationWindow else { return }
        extendsPreparationWindow = enabled
        defaults.set(enabled, forKey: Self.extendedWindowKey)
        applyAutomationOptions()
        recordEvent("녹음 준비 시간 \(enabled ? 60 : 20)초")
    }

    private func applyAutomationOptions() {
        // 0.8-second polling: 24 inspections cover 20 s, 80 cover 60 s.
        gate.configure(allowLocked: allowsLockedAttempts,
                       retryWindow: extendsPreparationWindow ? 60 : 20,
                       maximumInspections: extendsPreparationWindow ? 80 : 24)
    }

    /// Lets Shortcut observers add a fixed, non-sensitive line to the activity log.
    func noteShortcutEvent(_ value: String) {
        recordEvent(value)
    }

    func stop() {
        standbyAlert.disarm()
        activationError = nil
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        pause(message: "AirRec 비활성화됨")
    }

    private func failActivation(request: UUID, message: String) {
        guard AirRecordActivationFailurePolicy.shouldDisable(
            request: request, currentRequest: preparationID,
            isEnabled: isEnabled, cancelled: Task.isCancelled) else { return }
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        activationError = message
        // Invalidate input and preparation before cancelling their tasks. A
        // late Shortcut cancellation cannot match or stop a later activation.
        pause(message: message)
    }

    private func pause(message: String, preservingShortcutPreparation: Bool = false,
                       preservingLocation: Bool = false) {
        if !preservingShortcutPreparation {
            // Revoke the ID before cancellation: an old cancellation handler
            // must never match and pause a later manual or foreground run.
            let previous = shortcutPreparation
            shortcutPreparation = nil
            shortcutPreparationID = nil
            previous?.cancel()
        }
        preparationID = UUID()
        gate.stop() // Invalidates worker callbacks before touching UI/task state.
        nativeGeneration = nil
        isRunning = false
        isPreparing = false
        timer?.invalidate()
        timer = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        observer.setDelegate(nil, queue: nil)
        endBackgroundLease()
        if !preservingLocation { standby.stop() }
        setStatus(message)
        // Never join a blocking network worker on the main actor. Its callbacks
        // now refuse input, and the client's bounded operation closes normally.
    }

    private func endBackgroundLease() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private var waitingStatus: String {
        (standby.isEnabled && standby.isRunning) ? "통화 대기 · 백그라운드 AirRec 사용 중"
            : "통화 대기 · iOS 기본 허용 시간 적용"
    }

    private func startStandbyChecks() {
        standbyTimer?.invalidate()
        standbyTimer = nil
        guard standby.isEnabled, standby.isRunning else { return }
        lastStandbyCheck = Date()
        // Check progress and refresh the optional alert while iOS runs AirRec.
        let check = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.noteStandbyProgress() }
        }
        standbyTimer = check
        RunLoop.main.add(check, forMode: .common)
    }

    private func noteStandbyProgress() {
        guard isRunning, standby.isEnabled else { return }
        let now = Date()
        if let lastStandbyCheck, now.timeIntervalSince(lastStandbyCheck) > 75 {
            recordEvent("감시 점검 공백 \(Int(now.timeIntervalSince(lastStandbyCheck)))초 · 당시 상태 미확인")
        }
        lastStandbyCheck = now
        if !standby.isRunning {
            pause(message: "백그라운드 AirRec 중단 · 활성화 설정 유지")
        } else if UIApplication.shared.applicationState == .background {
            standbyAlert.refresh()
        }
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.evaluate() }
    }

    private func currentCalls() -> [AirRecordCallState] {
        observer.calls.map {
            AirRecordCallState(id: $0.uuid, hasConnected: $0.hasConnected,
                             hasEnded: $0.hasEnded, isOnHold: $0.isOnHold)
        }
    }

    private func updateCalls() {
        let calls = currentCalls()
        gate.update(calls)
        let active = Set(calls.filter { !$0.hasEnded }.map(\.id))
        recordingResults = recordingResults.filter { active.contains($0.key) }
    }

    private func evaluate() {
        guard isRunning else { return }
        if standby.isEnabled && !standby.isRunning {
            pause(message: standby.status + " · 활성화 설정 유지")
            return
        }
        updateCalls()
        guard !workerIsRunning else { return }
        let (decision, inspection) = gate.decision()
        if case .inspect = decision {
            setInspectionPolling(true)
        } else {
            setInspectionPolling(false)
        }
        switch decision {
        case .inspect:
            guard let inspection else { return }
            guard gate.permits(inspection) else {
                setStatus("잠금 해제 및 기본 통화 화면 열기 필요")
                return
            }
            inspect(inspection)
        case .expired:
            setStatus("녹음 준비 시간 초과 · 이번 통화 재시도 없음")
        case .multipleCalls:
            setStatus("활성 통화가 여러 건 · 자동 녹음 건너뜀")
        case .held:
            setStatus("보류 중인 통화 · 자동 녹음 대기")
        case .connecting:
            setStatus("통화 연결 대기")
        case .noCall:
            setStatus(waitingStatus)
        default: break
        }
    }

    private func setInspectionPolling(_ enabled: Bool) {
        guard enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func inspect(_ inspection: AirRecordAutomationGate.Inspection) {
        workerIsRunning = true
        let gate = self.gate
        let pairingPath = PairingFileStore.storedURL.path
        // At most one worker exists, including across stop/start. A dedicated
        // thread avoids the small Swift concurrency worker stack used by FFI.
        let thread = Thread { [weak self] in
            let result: Result<AirRecordAXOutcome, Error>
            do {
                result = .success(try AirRecordAXClient.inspectAndAct(
                    pairingPath: pairingPath, mayOpenMore: inspection.mayOpenMore,
                    shouldContinue: { gate.permits(inspection) },
                    reserveMore: { gate.reserveMore(inspection) },
                    reserveStart: { gate.reserveStart(inspection) }))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self?.didInspect(result, inspection: inspection)
            }
        }
        thread.name = "airrecord.ax.inspect"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func didInspect(_ result: Result<AirRecordAXOutcome, Error>,
                            inspection: AirRecordAutomationGate.Inspection) {
        workerIsRunning = false
        guard gate.isCurrent(inspection), isRunning else {
            if isRunning { evaluate() }
            return
        }
        switch result {
        case .success(.waiting(let detail)):
            setStatus(detail)
        case .success(.openedMore):
            setStatus("더 보기 열림 · 녹음 버튼 확인")
        case .success(.startSubmitted):
            recordingResults[inspection.callID] = .init(outcome: .submittedUnconfirmed, generation: inspection.generation)
            setStatus("녹음 요청 전달 · 시작 미확인 · 재시도 없음")
        case .success(.alreadyRecording):
            recordingResults[inspection.callID] = .init(outcome: .alreadyRecording, generation: inspection.generation)
            gate.markAlreadyRecording(inspection)
            setStatus("이미 녹음 중 · 자동 시작 건너뜀")
        case .success(.recordingConfirmed):
            recordingResults[inspection.callID] = .init(outcome: .confirmed, generation: inspection.generation)
            gate.markAlreadyRecording(inspection)
            setStatus("통화 녹음 시작 확인")
        case .failure(let error):
            // Never emit native exception text: it can contain private UI text.
            if gate.startWasReserved(inspection) {
                recordingResults[inspection.callID] = .init(outcome: .failedAfterReservation, generation: inspection.generation)
                setStatus("녹음 요청 결과 미확인 · 재시도 없음")
            } else {
                setStatus("통화 화면 확인 실패 · 재시도 예정")
            }
            if let detail = AirRecordAXClient.diagnostic(for: error) {
                recordEvent("접근성 검사: \(detail)")
            }
        }
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
        recordEvent(value)
    }

    private func recordEvent(_ value: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        recentEvents.append("[\(time)] \(value)")
        if recentEvents.count > 12 { recentEvents.removeFirst(recentEvents.count - 12) }
        airRecordLog("AirRec: \(value)")
    }
}
#endif
