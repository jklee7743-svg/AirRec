// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Run with bash Tests/Policy/run.sh.

import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("FAILED: \(message)")
    }
}

let firstID = UUID()
let secondID = UUID()
func call(_ id: UUID = firstID, connected: Bool = true, ended: Bool = false,
          held: Bool = false) -> AirRecordCallState {
    AirRecordCallState(id: id, hasConnected: connected, hasEnded: ended, isOnHold: held)
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [], enabled: true, now: 0) == .noCall, "no call")
    check(policy.decision(calls: [call(connected: false)], enabled: true, now: 0) == .connecting,
          "ringing must not start")
    check(!policy.reserveStart(for: firstID, calls: [call(connected: false)]),
          "cannot reserve an unconnected call")
    check(policy.decision(calls: [call()], enabled: true, now: 1) == .inspect(firstID),
          "connected callback starts readiness inspection")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "duplicate callback remains bounded readiness inspection")
    check(policy.reserveStart(for: firstID, calls: [call()]), "first tap reservation")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no second reservation")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .handled(firstID),
          "ambiguous or successful tap is never retried")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "resume cannot grant a second start tap")
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [call(held: true)], enabled: true, now: 0) == .held,
          "held call")
    check(policy.decision(calls: [call(), call(secondID, connected: false)], enabled: true, now: 0)
          == .multipleCalls, "call waiting blocks start too")
    check(policy.decision(calls: [call(), call(secondID, held: true)], enabled: true, now: 1)
          == .multipleCalls, "held second call still counts")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "single remaining connected call can be inspected")
    check(!policy.reserveStart(for: firstID, calls: [call(), call(secondID)]),
          "revalidate active count immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(held: true)]),
          "revalidate hold immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(ended: true)]),
          "revalidate ended immediately before tap")
    check(!policy.reserveStart(for: secondID, calls: [call()]), "must match UUID")
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [call()], enabled: false, now: 0) == .paused, "pause")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no inspection while paused")
    _ = policy.decision(calls: [call()], enabled: true, now: 1)
    _ = policy.decision(calls: [call()], enabled: false, now: 1.1)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "pause revokes a pending tap")
    _ = policy.decision(calls: [call()], enabled: true, now: 1.2)
    policy.markAlreadyRecording(firstID)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "manual recording is respected")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .handled(firstID),
          "manual recording stays handled after resume")
    check(policy.decision(calls: [call(ended: true)], enabled: true, now: 3) == .noCall,
          "ended call removed")
    check(policy.completedCalls.isEmpty, "ended UUID pruned")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .inspect(firstID),
          "reused UUID after ended session is new")
    check(policy.reserveStart(for: firstID, calls: [call()]), "new session can reserve")
    _ = policy.decision(calls: [], enabled: false, now: 5)
    check(policy.reservedStarts.isEmpty, "cleanup runs while paused too")
}

do {
    var policy = AirRecordPolicy(retryWindow: 2, maximumInspections: 10)
    check(policy.decision(calls: [call()], enabled: true, now: 0) == .inspect(firstID), "window starts")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .expired(firstID), "deadline bound")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "deadline is not reset by another callback")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 5) == .handled(firstID),
          "expired call remains handled until new call")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired never reserves")
}

do {
    var policy = AirRecordPolicy(retryWindow: 100, maximumInspections: 2)
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    _ = policy.decision(calls: [call()], enabled: true, now: 0.1)
    check(policy.decision(calls: [call()], enabled: true, now: 0.2) == .expired(firstID),
          "inspection count bound")
}

do {
    check(AirRecordCallUI.recognizes(buttonLabels: ["더 보기", "소리 끔", "스피커", "키패드"]),
          "captured iOS 27 Korean call controls work without a recognized end label")
    check(AirRecordCallUI.recognizes(buttonLabels: ["more options", " MUTE ", "Audio", "Keypad"]),
          "English controls use the same normalized semantic families")
    check(AirRecordCallUI.recognizes(buttonLabels: ["통화 종료", "소리 끔"]),
          "the existing end-call plus control route still works")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["더 보기", "키패드"]),
          "a generic More menu and keypad alone are not a call screen")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "Mute", "음소거", "Keypad"]),
          "multiple mute aliases cannot replace the missing audio family")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "More Options", "Mute", "Speaker", "Keypad"]),
          "an ambiguous More target cannot verify the fallback screen")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["Mute", "Speaker", "Keypad"]),
          "the fallback requires the actual More menu too")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["Hang Up"]),
          "an end-call label alone is insufficient")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "one", "two", "three"]),
          "unknown buttons cannot replace known call controls")
}

do {
    var policy = AirRecordPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) == 27.5,
          "a late More request receives eight seconds for menu readiness and confirmation")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 21) == nil,
          "the same menu cannot repeatedly extend its deadline")
    check(policy.decision(calls: [call()], enabled: true, now: 22) == .inspect(firstID),
          "record inspection survives the old twenty-second boundary")
    check(policy.reserveStart(for: firstID, calls: [call()]), "start can be reserved in menu phase")
    policy.resume()
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 23) == nil,
          "rearm cannot reopen the window of a submitted recording start")
    check(policy.decision(calls: [call()], enabled: true, now: 23) == .handled(firstID),
          "rearm never submits a second recording start")
}

do {
    var policy = AirRecordPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call(held: true)], now: 1) == nil,
          "held calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: firstID, calls: [call(), call(secondID)], now: 1) == nil,
          "multiple calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: secondID, calls: [call()], now: 1) == nil,
          "menu phase must match the active call")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) != nil,
          "only a valid call enters the menu phase")
    check(policy.decision(calls: [call()], enabled: true, now: 28) == .expired(firstID),
          "menu phase is still bounded")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired menu never starts recording")
    check(policy.decision(calls: [], enabled: true, now: 29) == .noCall,
          "ended calls clear their menu reservations")
    check(policy.decision(calls: [call()], enabled: true, now: 30) == .inspect(firstID),
          "a genuinely new session may reuse an ended UUID")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 30) != nil,
          "the new session can reserve its own menu phase")
}

do {
    var lease = AirRecordKeepAliveLease()
    let current = UUID(), old = UUID()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    check(!lease.isValid(now: 10, hostTraced: true), "attach reports without a heartbeat never maintain runtime")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    check(lease.isValid(now: 16, hostTraced: true), "a fresh, traced two-process session maintains runtime")
    check(!lease.isValid(now: 16.01, hostTraced: true), "stale helper heartbeat revokes runtime")
    check(!lease.isValid(now: 11, hostTraced: false), "persistent JIT state cannot replace live host tracing")
    lease.receivedHeartbeat(old, hostAttached: false, helperTraced: false, now: 11)
    check(lease.isValid(now: 11, hostTraced: true), "an old session cannot revoke a newer lease")
    lease.receivedHeartbeat(current, hostAttached: false, helperTraced: true, now: 12)
    check(!lease.isValid(now: 12, hostTraced: true), "negative peer evidence revokes immediately")
    lease.invalidate()
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 13)
    check(!lease.isValid(now: 13, hostTraced: true), "late heartbeat after Stop cannot restore a lease")
    lease.begin(old)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(old, hostAttached: true, helperTraced: true, now: 20)
    check(!lease.isValid(now: 20, hostTraced: true), "old debugger completions cannot complete a new session")
}

do {
    let current = UUID()
    var lease = AirRecordKeepAliveLease()
    check(lease.issue(now: 10, hostTraced: true) == .missingEvidence,
          "an unconfigured lease reports missing evidence")
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    check(lease.issue(now: 17, hostTraced: true) == .staleHeartbeat,
          "a delayed heartbeat is distinguished from a detached host")
    check(lease.issue(now: 17, hostTraced: false) == .hostUntraced,
          "actual host trace loss is not treated as only a delayed heartbeat")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: false, now: 17)
    check(lease.issue(now: 17, hostTraced: true) == .helperUntraced,
          "negative helper trace evidence is diagnosed immediately")
    check(lease.issue(now: .nan, hostTraced: true) == .invalidTime,
          "non-finite diagnostic time fails closed")
}

do {
    let current = UUID()
    var lease = AirRecordKeepAliveLease()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 10)
    check(lease.heartbeat == 10 && lease.issue(now: 17, hostTraced: true) == .staleHeartbeat,
          "a queued old heartbeat cannot become fresh at receive time")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 18)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: .infinity)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: .nan, sampledAt: 17)
    check(lease.heartbeat == 10, "future and non-finite samples cannot refresh evidence")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 16)
    check(lease.heartbeatAge(now: 18) == 2,
          "freshness measures sampling age instead of callback age")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 18, sampledAt: 15.5)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 16.9, sampledAt: 16.5)
    check(lease.heartbeat == 16, "backwards sampling or receive clocks cannot replace newer evidence")
    check(lease.issue(now: 16.5, hostTraced: true) == .invalidTime,
          "a backwards current clock is reported separately")
}

do {
    let current = UUID(), old = UUID()
    var lease = AirRecordKeepAliveLease()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    guard let ping = lease.beginRecheck(current, now: 20) else { fatalError("expected recheck") }
    check(lease.pendingDeadline == 28 && lease.sentAt == 20,
          "a recheck has a fixed eight-second deadline")
    check(lease.beginRecheck(current, now: 21) == nil && lease.pendingDeadline == 28,
          "repeated health ticks cannot extend an outstanding challenge")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 21, sampledAt: 21)
    check(lease.issue(now: 21, hostTraced: true) == .challengePending
          && !lease.isValid(now: 21, hostTraced: true),
          "even a positive ordinary heartbeat cannot satisfy the pending challenge")
    check(!lease.acceptPong(old, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "an old session cannot answer the current challenge")
    check(!lease.acceptPong(current, pingID: ping + 1, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a mismatched challenge identifier is rejected")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 19.9, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a sample predating the ping cannot prove a fresh peer response")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 23, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a pong with a future sample is rejected")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: false, now: 22),
          "a fresh pong cannot replace actual host tracing")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: false, hostTraced: true, now: 22),
          "a fresh pong cannot replace actual helper tracing")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: false,
                           helperTraced: true, hostTraced: true, now: 22),
          "a helper without a host debugger connection cannot restore runtime")
    check(lease.pendingID == ping && lease.pendingDeadline == 28,
          "rejected responses neither clear nor extend the challenge")
    check(lease.acceptPong(current, pingID: ping, sampledAt: 22.5, hostAttached: true,
                          helperTraced: true, hostTraced: true, now: 23),
          "a fresh matching pong restores the current two-process session")
    check(lease.isValid(now: 23, hostTraced: true) && lease.pendingID == nil
          && lease.pendingDeadline == nil && lease.sentAt == nil,
          "successful recovery clears the challenge and leaves valid fresh evidence")
    guard let next = lease.beginRecheck(current, now: 30) else { fatalError("expected next recheck") }
    check(next != ping, "each challenge in one session uses a new identifier")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 30, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 30),
          "a delayed old pong cannot satisfy a newer challenge")
    check(!lease.recheckExpired(now: 37.99) && lease.recheckExpired(now: 38),
          "the recovery deadline expires at its original bound")
    check(!lease.acceptPong(current, pingID: next, sampledAt: 38, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 38),
          "an expired challenge cannot revive the session")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 39, sampledAt: 39)
    check(!lease.isValid(now: 39, hostTraced: true) && lease.pendingDeadline == 38,
          "ordinary heartbeat after timeout still cannot revive or extend recovery")
    lease.invalidate()
    check(!lease.acceptPong(current, pingID: next, sampledAt: 39, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 39),
          "late pong after Stop cannot restore a lease")
    check(lease.pendingID == nil && lease.pendingDeadline == nil && !lease.recheckExpired(now: 40),
          "Stop removes all pending recovery state")
}

do {
    let nonce = String(repeating: "a", count: 64)
    let hello = AirRecordKeepAliveMessage(type: "hello", session: firstID.uuidString, nonce: nonce, helperPID: 42)
    let data = try AirRecordKeepAliveWire.encode(hello)
    var buffer = Data()
    let incomplete = try AirRecordKeepAliveWire.append(Data(data.prefix(7)), to: &buffer)
    check(incomplete.isEmpty,
          "a split IPC frame waits for the remaining bytes")
    let messages = try AirRecordKeepAliveWire.append(Data(data.dropFirst(7)) + data, to: &buffer)
    check(messages.count == 2 && messages.allSatisfy { $0.helperPID == 42 } && buffer.isEmpty,
          "fragmented and coalesced IPC frames preserve message boundaries")
    check(AirRecordKeepAliveWire.matchesNonce(nonce, nonce), "matching session nonce is accepted")
    check(!AirRecordKeepAliveWire.matchesNonce(nonce, String(repeating: "b", count: 64)), "wrong nonce is rejected")
    do {
        _ = try AirRecordKeepAliveWire.append(Data(repeating: 65, count: AirRecordKeepAliveWire.maximumFrameBytes + 2), to: &buffer)
        check(false, "oversized IPC data must be rejected")
    } catch { }
    do {
        var invalid = Data()
        _ = try AirRecordKeepAliveWire.append(Data("\n".utf8), to: &invalid)
        check(false, "empty IPC frame must be rejected")
    } catch { }
}

do {
    var location = AirRecordLocationSessionPolicy()
    check(location.session == nil && !location.isReady,
          "location standby begins without an execution session")
    let current = location.begin()
    check(location.matches(current) && !location.isReady && location.lastSampledAt == nil,
          "starting or waiting for permission does not claim location readiness")
    check(!location.receivedSample(for: current, now: 1_000, sampledAt: 939.9)
          && !location.isReady,
          "a delayed cached fix cannot establish readiness at callback time")
    check(location.receivedSample(for: current, now: 1_000, sampledAt: 940)
          && location.isReady,
          "a first sample within sixty seconds establishes this manager's readiness")
    check(location.matches(current) && location.isReady,
          "an already running location session can be reused without beginning a new generation")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let current = location.begin()
    for sample in [TimeInterval.nan, .infinity, -.infinity, -1, 1_001] {
        check(!location.receivedSample(for: current, now: 1_000, sampledAt: sample),
              "invalid or future location sampling times cannot establish readiness")
    }
    for received in [TimeInterval.nan, .infinity, -.infinity, -1] {
        check(!location.receivedSample(for: current, now: received, sampledAt: 999),
              "invalid callback times cannot establish readiness")
    }
    check(!location.isReady && location.lastSampledAt == nil,
          "rejected initial callbacks leave the session unready")
    check(location.receivedSample(for: current, now: 1_000, sampledAt: 999),
          "valid data can arrive after permission and invalid cached callbacks")
    check(!location.receivedSample(for: current, now: 1_001, sampledAt: 998),
          "out-of-order location data cannot replace a newer accepted sample")
    check(!location.receivedSample(for: current, now: 999.5, sampledAt: 999.5),
          "a backwards callback clock does not replace current session evidence")
    check(location.lastSampledAt == 999 && location.isReady,
          "rejected later samples preserve valid execution evidence")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let old = location.begin()
    check(location.receivedSample(for: old, now: 1_000, sampledAt: 1_000),
          "the initial manager establishes readiness")
    let current = location.begin()
    check(current != old && !location.isReady,
          "a replacement manager requires a new generation and a new fresh sample")
    check(!location.receivedSample(for: old, now: 1_001, sampledAt: 1_001)
          && !location.isReady,
          "a queued callback from the previous manager cannot ready the replacement")
    check(!location.pause(for: old) && location.matches(current),
          "an old manager's pause callback cannot stop the replacement")
    check(location.receivedSample(for: current, now: 1_002, sampledAt: 1_002),
          "the replacement manager can independently establish readiness")
    check(location.pause(for: current) && !location.isReady && location.session == nil,
          "a current pause revokes execution and invalidates its generation")
    check(!location.receivedSample(for: current, now: 1_003, sampledAt: 1_003),
          "a callback arriving after pause cannot silently resume execution")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let stopped = location.begin()
    location.stop()
    check(!location.matches(stopped) && !location.isReady,
          "Stop revokes a pending permission or sampling session")
    check(!location.receivedSample(for: stopped, now: 1_000, sampledAt: 1_000),
          "late authorization-following data cannot restart a stopped session")
    let current = location.begin()
    check(current != stopped && !location.isReady,
          "an explicit later start waits for its own sample")
    check(location.receivedSample(for: current, now: 1_001, sampledAt: 1_001),
          "the explicit new start can become ready")
    location.stop()
    check(location.session == nil && !location.isReady && location.lastSampledAt == nil,
          "Stop clears the current execution evidence")
}

do {
    var indicator = AirRecordLocationIndicatorPolicy()
    check(indicator.showsBackgroundLocationIndicator,
          "the default preference never suppresses the location indicator")
    for authorization in AirRecordLocationIndicatorPolicy.Authorization.allCases {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "Always authorization alone cannot opt the user into minimization")
    }
    indicator.setMinimizationEnabled(true)
    for authorization in AirRecordLocationIndicatorPolicy.Authorization.allCases where authorization != .always {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "a saved minimization preference cannot hide without actual Always authorization")
    }
    indicator.updateAuthorization(.always)
    check(!indicator.showsBackgroundLocationIndicator,
          "explicit preference plus actual Always permission requests minimization")
    indicator.updateAuthorization(.whenInUse)
    check(indicator.showsBackgroundLocationIndicator && indicator.minimizationEnabled,
          "revoking Always immediately restores the indicator without clearing the preference")
    indicator.updateAuthorization(.always)
    check(!indicator.showsBackgroundLocationIndicator,
          "a later actual Always grant can apply the retained preference")
    indicator.setMinimizationEnabled(false)
    check(indicator.showsBackgroundLocationIndicator,
          "opting out immediately restores the indicator even while Always is granted")
    indicator.setMinimizationEnabled(true)
    for authorization in [AirRecordLocationIndicatorPolicy.Authorization.denied, .restricted, .unknown, .notDetermined] {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "denied, restricted, unknown, and undecided transitions fail back to a visible indicator request")
    }
}

do {
    typealias Permission = AirRecordBackgroundPermissionPolicy
    func preflight(_ trigger: Permission.Trigger = .enabledByUser,
                   monitoring: Bool = false,
                   authorization: Permission.Authorization = .notDetermined,
                   pending: Bool = false, foreground: Bool = true,
                   liveContainer: Bool = false, purpose: Bool = true) -> Permission.Plan {
        Permission.plan(trigger: trigger, monitoringEnabled: monitoring,
                        authorization: authorization, requestPending: pending,
                        isForeground: foreground, isLiveContainer: liveContainer,
                        hasUsageDescription: purpose)
    }
    let independent = preflight()
    check(independent.action == .requestWhenInUse && !independent.shouldPrepareMonitoring,
          "explicit background-on requests basic permission while the main feature remains OFF; connection prerequisites are not inputs")
    let enabled = preflight(monitoring: true)
    check(enabled.action == .requestWhenInUse && !enabled.shouldPrepareMonitoring && enabled.requiresPermissionDecision,
          "main ON still requests basic permission first and waits rather than preparing through an inactive permission sheet")
    check(preflight(pending: true).action == .waitForDecision,
          "repeating background-on while a request is pending cannot issue a second prompt")
    check(preflight(monitoring: true, pending: true).requiresPermissionDecision,
          "a still-enabled explicit activation waits for an existing permission decision")
    for trigger in [Permission.Trigger.disabledByUser, .passive] {
        check(preflight(trigger, monitoring: true).action == .none,
              "background-off and passive preflight never add a permission request")
    }
    check(preflight(.disabledByUser, monitoring: true).shouldPrepareMonitoring,
          "background-off retains the enabled main feature's finite-runtime fallback")
    check(!preflight(.disabledByUser).shouldPrepareMonitoring,
          "background-off never turns a saved OFF main feature on")
    let permitted = preflight(monitoring: true, authorization: .authorized)
    check(permitted.action == .none && permitted.shouldPrepareMonitoring,
          "already-granted permission follows normal main-enabled preparation without a new prompt")
    check(!preflight(authorization: .authorized).shouldPrepareMonitoring,
          "permission already granted still cannot turn a saved OFF main feature on")
    for authorization in [Permission.Authorization.denied, .restricted, .unknown] {
        let blocked = preflight(monitoring: true, authorization: authorization)
        check(blocked.action == .showSettings && !blocked.shouldPrepareMonitoring && !blocked.requiresPermissionDecision,
              "denied, restricted, and unknown authorization offer Settings without fake prompts or execution")
    }
    check(preflight(foreground: false).action == .requireForeground,
          "a new permission request requires an active foreground user action")
    check(preflight(liveContainer: true).action == .unsupportedEnvironment,
          "LiveContainer cannot issue the independent-app permission request")
    check(preflight(purpose: false).action == .missingUsageDescription,
          "a package missing its privacy explanation cannot request permission")
}

do {
    typealias Wait = AirRecordRecordingWaitPolicy
    let generation = UUID(), laterGeneration = UUID()
    let call = AirRecordCallState(id: firstID, hasConnected: true, hasEnded: false, isOnHold: false)
    let other = AirRecordCallState(id: secondID, hasConnected: true, hasEnded: false, isOnHold: false)
    func observe(_ policy: inout Wait, now: TimeInterval = 101,
                 calls: [AirRecordCallState] = [], enabled: Bool = true,
                 current: UUID, owned: UUID, prepared: Bool? = true,
                 result: Wait.NativeResult? = nil, nativeGeneration: UInt64? = 7,
                 inFlight: Bool = false, cancelled: Bool = false) -> Wait.Decision {
        policy.decision(now: now, calls: calls, enabled: enabled,
                        currentGeneration: current, ownedGeneration: owned,
                        preparationResult: prepared, nativeResult: result,
                        currentNativeGeneration: nativeGeneration,
                        nativeWorkInFlight: inFlight, cancelled: cancelled)
    }
    check(Wait.boundedTimeout(0) == 1 && Wait.boundedTimeout(-10) == 1
          && Wait.boundedTimeout(90) == 60 && Wait.boundedTimeout(45) == 45,
          "recording waits clamp finite requests to one through sixty seconds")
    check(Wait.boundedTimeout(.nan) == 45 && Wait.boundedTimeout(.infinity) == 45,
          "invalid timeout requests use a finite forty-five-second default")

    var preparation = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&preparation, now: 120, current: generation, owned: generation, prepared: nil) == .waiting,
          "preparation consumes the same bounded wait rather than starting a second timer")
    check(observe(&preparation, now: 145, current: generation, owned: generation, prepared: nil) == .finished(.timedOut),
          "the original deadline expires even if preparation has not returned")
    check(observe(&preparation, now: 146, calls: [call], current: generation, owned: generation,
                  result: .init(outcome: .confirmed, generation: 7)) == .finished(.timedOut),
          "a late native result cannot change a finished timeout")

    var success = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&success, calls: [call], current: generation, owned: generation, prepared: nil) == .waiting
          && success.callID == firstID,
          "one active call is fixed while preparation is still pending")
    let confirmed = Wait.NativeResult(outcome: .confirmed, generation: 7)
    check(observe(&success, now: 102, calls: [call], current: generation, owned: generation,
                  result: confirmed, inFlight: true) == .waiting,
          "even completion evidence cannot return while native work is still in flight")
    check(observe(&success, now: 103, calls: [call], current: generation, owned: generation,
                  result: confirmed) == .finished(.native(.confirmed, reused: false)),
          "native-confirmed recording completes only after the worker returned")

    for outcome in [Wait.NativeOutcome.alreadyRecording, .submittedUnconfirmed, .failedAfterReservation] {
        var resultWait = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
        let result = Wait.NativeResult(outcome: outcome, generation: 6)
        check(observe(&resultWait, calls: [call], current: generation, owned: generation,
                      result: result) == .finished(.native(outcome, reused: true)),
              "same-call returned results are reusable and distinguished from current-generation proof")
    }

    var ended = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    _ = observe(&ended, calls: [call], current: generation, owned: generation)
    check(observe(&ended, now: 102, current: generation, owned: generation) == .finished(.callEnded),
          "ending the fixed call ends the wait rather than following a future call")
    var changed = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    _ = observe(&changed, calls: [call], current: generation, owned: generation)
    check(observe(&changed, now: 102, calls: [other], current: generation, owned: generation) == .finished(.callChanged),
          "a different active call cannot satisfy the previous call's wait")
    var multiple = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&multiple, calls: [call, other], current: generation, owned: generation) == .finished(.multipleCalls),
          "multiple calls fail the single-call observation requirement")

    var ownedPreparation = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    _ = observe(&ownedPreparation, current: generation, owned: generation, prepared: nil)
    check(observe(&ownedPreparation, now: 102, calls: [call], current: laterGeneration,
                  owned: laterGeneration) == .waiting,
          "the explicit owner's pause-to-prepare transition is accepted before readiness")
    check(observe(&ownedPreparation, now: 103, calls: [call], current: generation,
                  owned: generation, result: confirmed) == .finished(.superseded),
          "a new preparation cannot replace a wait's generation once readiness was established")
    var foreignPreparation = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&foreignPreparation, current: laterGeneration, owned: generation, prepared: nil) == .finished(.superseded),
          "a foreign generation invalidates the wait even during preparation")

    var stopped = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&stopped, enabled: false, current: generation, owned: generation) == .finished(.stopped),
          "a saved OFF main feature cannot be revived by completion evidence")
    var cancelled = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&cancelled, current: generation, owned: generation, cancelled: true) == .finished(.cancelled),
          "cancellation is a conventional terminal result")
    var failed = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    check(observe(&failed, current: generation, owned: generation, prepared: false) == .finished(.preparationFailed),
          "preparation failure returns without waiting for a call or a second deadline")
    var clock = Wait(startedAt: 100, timeout: 45, initialGeneration: generation)
    _ = observe(&clock, now: 110, current: generation, owned: generation, prepared: nil)
    check(observe(&clock, now: 109, current: generation, owned: generation, prepared: nil) == .finished(.invalidClock),
          "a backwards monotonic clock cannot extend or complete a recording wait")
}

do {
    typealias Wait = AirRecordOutgoingWaitPolicy
    let outgoing = Wait.Call(isOutgoing: true, hasEnded: false, isOnHold: false)
    let incoming = Wait.Call(isOutgoing: false, hasEnded: false, isOnHold: false)
    let ended = Wait.Call(isOutgoing: true, hasEnded: true, isOnHold: false)
    let held = Wait.Call(isOutgoing: true, hasEnded: false, isOnHold: true)

    check(Wait.boundedTimeout(0) == 1 && Wait.boundedTimeout(-10) == 1
          && Wait.boundedTimeout(1000) == 180 && Wait.boundedTimeout(20) == 20
          && Wait.boundedTimeout(60) == 60 && Wait.boundedTimeout(180) == 180,
          "outgoing waits keep the requested seconds within one through one hundred eighty")
    check(Wait.boundedTimeout(.nan) == 20 && Wait.boundedTimeout(.infinity) == 20,
          "outgoing waits use a finite twenty-second default for invalid timeouts")
    var existing = Wait(startedAt: 100, timeout: 20)
    check(existing.decision(now: 100, calls: [outgoing]) == .finished(.outgoing),
          "an existing single outgoing call immediately satisfies a new wait without requiring connection")
    check(existing.decision(now: 101, calls: [], cancelled: true) == .finished(.outgoing),
          "a completed request is immutable when late cancellation or callbacks arrive")

    var longWait = Wait(startedAt: 100, timeout: 180)
    check(longWait.decision(now: 126, calls: []) == .waiting,
          "a configured long outgoing wait survives the previous 25-second cap")
    check(longWait.decision(now: 279, calls: [outgoing]) == .finished(.outgoing),
          "outgoing evidence can complete a three-minute wait early")
    var longDeadline = Wait(startedAt: 100, timeout: 1000)
    check(longDeadline.decision(now: 280, calls: [outgoing]) == .finished(.timedOut),
          "outgoing evidence at the three-minute cap is already too late")

    var direction = Wait(startedAt: 100, timeout: 20)
    check(direction.decision(now: 100, calls: []) == .waiting,
          "absence of a call waits for an event")
    check(direction.decision(now: 101, calls: [incoming]) == .waiting,
          "an incoming call never counts as an outgoing call")
    check(direction.decision(now: 102, calls: [ended, incoming]) == .waiting,
          "a stale ended outgoing call alongside an incoming call cannot satisfy the wait")
    check(direction.decision(now: 103, calls: [ended]) == .waiting,
          "an ended outgoing call alone cannot satisfy the wait")
    check(direction.decision(now: 104, calls: [ended, outgoing]) == .finished(.outgoing),
          "ended calls do not make a genuinely single active outgoing call ambiguous")

    var multiple = Wait(startedAt: 100, timeout: 20)
    check(multiple.decision(now: 101, calls: [outgoing, incoming]) == .finished(.multipleCalls),
          "call waiting or multiple active calls fail conservatively")
    check(multiple.decision(now: 102, calls: [outgoing]) == .finished(.multipleCalls),
          "a late single-call snapshot cannot revive a completed ambiguous request")
    var onHold = Wait(startedAt: 100, timeout: 20)
    check(onHold.decision(now: 101, calls: [held]) == .finished(.held),
          "a held outgoing call fails rather than reporting a new usable outgoing call")

    var before = Wait(startedAt: 100, timeout: 20)
    check(before.decision(now: 119.999, calls: [outgoing]) == .finished(.outgoing),
          "an outgoing observation before the monotonic deadline may succeed")
    var boundary = Wait(startedAt: 100, timeout: 20)
    check(boundary.decision(now: 120, calls: [outgoing]) == .finished(.timedOut),
          "an outgoing observation exactly at the deadline is already too late")
    check(boundary.decision(now: 121, calls: [outgoing]) == .finished(.timedOut),
          "a delayed delegate event cannot change a timeout into success")
    var delayed = Wait(startedAt: 100, timeout: 20)
    check(delayed.decision(now: 130, calls: [outgoing]) == .finished(.timedOut),
          "suspension or a delayed timer never extends the original wait deadline")

    var cancelled = Wait(startedAt: 100, timeout: 20)
    check(cancelled.decision(now: 101, calls: [outgoing], cancelled: true) == .finished(.cancelled),
          "observed cancellation takes precedence over simultaneous outgoing evidence")
    var independent = Wait(startedAt: 101, timeout: 20)
    check(independent.decision(now: 102, calls: [outgoing]) == .finished(.outgoing),
          "a separate request remains independent of another request's cancellation")
    check(cancelled.decision(now: 103, calls: [outgoing]) == .finished(.cancelled),
          "an old request's late event stays terminal while a newer request succeeds")

    var clock = Wait(startedAt: 100, timeout: 20)
    _ = clock.decision(now: 105, calls: [])
    check(clock.decision(now: 104, calls: [outgoing]) == .finished(.invalidClock),
          "backwards monotonic time cannot yield outgoing success")
    var invalid = Wait(startedAt: .nan, timeout: 20)
    check(invalid.decision(now: 100, calls: [outgoing]) == .finished(.invalidClock),
          "an invalid initial clock cannot create an unbounded or successful wait")
    for result in [Wait.Result.multipleCalls, .held, .cancelled, .timedOut, .invalidClock] {
        check(!result.detectedOutgoing, "only the outgoing terminal result maps to true")
    }
    check(Wait.Result.outgoing.detectedOutgoing, "outgoing evidence maps to true")
}

do {
    typealias Failure = AirRecordActivationFailurePolicy
    let previous = UUID(), current = UUID(), retry = UUID()
    check(Failure.shouldDisable(request: current, currentRequest: current,
                                isEnabled: true, cancelled: false),
          "a confirmed current preparation failure disables its saved activation")
    check(!Failure.shouldDisable(request: previous, currentRequest: current,
                                 isEnabled: true, cancelled: false),
          "an old preparation failure cannot disable a newer enabled activation")
    check(!Failure.shouldDisable(request: current, currentRequest: current,
                                 isEnabled: true, cancelled: true),
          "cancelling the current preparation retains the saved preference instead of treating it as failure")
    check(!Failure.shouldDisable(request: current, currentRequest: current,
                                 isEnabled: false, cancelled: false),
          "a late result after explicit OFF cannot overwrite the stopped state with an activation error")
    check(!Failure.shouldDisable(request: current, currentRequest: retry,
                                 isEnabled: true, cancelled: false),
          "an automatic failure from before explicit retry cannot disable the new run")
    check(Failure.shouldDisable(request: retry, currentRequest: retry,
                                isEnabled: true, cancelled: false),
          "a new retry owns its own confirmed failure transition")
    check(!Failure.shouldDisable(request: retry, currentRequest: UUID(),
                                 isEnabled: false, cancelled: true),
          "cleanup and cancellation after automatic OFF cannot reapply a finished failure")
}

do {
    typealias Wait = AirRecordCallEndWaitPolicy
    let active = Wait.Call(hasEnded: false)
    let ended = Wait.Call(hasEnded: true)

    check(Wait.defaultTimeout == 3600 && Wait.maximumTimeout == 10800,
          "call-end waits have a one-hour default and three-hour maximum")
    check(Wait.boundedTimeout(0) == 1 && Wait.boundedTimeout(-10) == 1
          && Wait.boundedTimeout(20000) == 10800 && Wait.boundedTimeout(180) == 180,
          "call-end wait timeouts remain positive, finite, and bounded")
    check(Wait.boundedTimeout(.nan) == 3600 && Wait.boundedTimeout(.infinity) == 3600,
          "invalid call-end timeout input falls back to a finite default")

    var betweenSteps = Wait(startedAt: 100, timeout: 3600)
    check(betweenSteps.decision(now: 100, calls: []) == .finished(.noActiveCalls),
          "a call already ended between Shortcuts steps returns true immediately")
    check(betweenSteps.decision(now: 101, calls: [active], cancelled: true) == .finished(.noActiveCalls),
          "a finished call-end policy does not change after a late call or cancellation")
    var endedOnly = Wait(startedAt: 100, timeout: 3600)
    check(endedOnly.decision(now: 100, calls: [ended, ended]) == .finished(.noActiveCalls),
          "stale ended CallKit entries do not keep a call-end wait alive")

    var session = Wait(startedAt: 100, timeout: 3600)
    check(session.decision(now: 100, calls: [active]) == .waiting,
          "an active call blocks completion regardless of connection, direction, or hold state")
    check(session.decision(now: 101, calls: [active, active]) == .waiting,
          "call waiting or multiple active calls keep the call-end request pending")
    check(session.decision(now: 102, calls: [ended, active]) == .waiting,
          "ending one call cannot restore data while a second call remains")
    check(session.decision(now: 103, calls: [active]) == .waiting,
          "a replacement active call blocks completion without relying on stale identifiers")
    check(session.decision(now: 104, calls: [ended]) == .finished(.noActiveCalls),
          "the wait completes only after every observed active call is gone or ended")

    var before = Wait(startedAt: 100, timeout: 180)
    check(before.decision(now: 279.999, calls: []) == .finished(.noActiveCalls),
          "a zero-call observation before the call-end deadline may succeed")
    var boundary = Wait(startedAt: 100, timeout: 180)
    check(boundary.decision(now: 280, calls: []) == .finished(.timedOut),
          "zero calls exactly at the call-end deadline cannot turn a timeout into success")
    check(boundary.decision(now: 281, calls: []) == .finished(.timedOut),
          "a late delegate event leaves a timed-out call-end request terminal")
    var suspended = Wait(startedAt: 100, timeout: 180)
    check(suspended.decision(now: 300, calls: [active]) == .finished(.timedOut),
          "suspension and delayed timers cannot extend the original call-end deadline")

    var cancelled = Wait(startedAt: 100, timeout: 3600)
    check(cancelled.decision(now: 101, calls: [], cancelled: true) == .finished(.cancelled),
          "call-end cancellation takes precedence over an empty simultaneous snapshot")
    var independent = Wait(startedAt: 101, timeout: 3600)
    check(independent.decision(now: 102, calls: []) == .finished(.noActiveCalls),
          "cancelling one call-end wait does not alter another request")
    check(cancelled.decision(now: 103, calls: []) == .finished(.cancelled),
          "a late callback cannot revive the cancelled call-end wait")

    var clock = Wait(startedAt: 100, timeout: 3600)
    _ = clock.decision(now: 105, calls: [active])
    check(clock.decision(now: 104, calls: []) == .finished(.invalidClock),
          "backwards monotonic time cannot produce a false call-end success")
    var invalid = Wait(startedAt: .nan, timeout: 3600)
    check(invalid.decision(now: 100, calls: []) == .finished(.invalidClock),
          "an invalid initial clock cannot complete a call-end wait")
    var negative = Wait(startedAt: -1, timeout: 3600)
    check(negative.decision(now: 100, calls: []) == .finished(.invalidClock),
          "an invalid negative starting clock cannot complete a call-end wait")
    for result in [Wait.Result.cancelled, .timedOut, .invalidClock] {
        check(!result.allCallsEnded, "only verified absence of active calls maps to true")
    }
    check(Wait.Result.noActiveCalls.allCallsEnded, "no active calls maps to true")
}

do {
    var policy = AirRecordPolicy()
    policy.configure(retryWindow: 60, maximumInspections: 80)
    check(policy.retryWindow == 60 && policy.maximumInspections == 80, "configured window is stored")
    check(policy.decision(calls: [call()], enabled: true, now: 0) == .inspect(firstID),
          "extended window opens on connection")
    check(policy.decision(calls: [call()], enabled: true, now: 45) == .inspect(firstID),
          "extended window still inspects after twenty seconds")
    check(policy.decision(calls: [call()], enabled: true, now: 61) == .expired(firstID),
          "extended window still has a deadline")
    policy.configure(retryWindow: .nan, maximumInspections: 0)
    check(policy.retryWindow == 60 && policy.maximumInspections == 1,
          "invalid configuration keeps a finite window and at least one inspection")
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [call()], enabled: true, now: 0) == .inspect(firstID), "default window opens")
    policy.configure(retryWindow: 60, maximumInspections: 80)
    check(policy.decision(calls: [call()], enabled: true, now: 21) == .expired(firstID),
          "a window opened before reconfiguration keeps its original deadline")
    check(policy.reserveStart(for: firstID, calls: [call()]) == false,
          "reconfiguration never reopens an expired call")
}

do {
    typealias Wait = AirRecordIncomingWaitPolicy
    func incoming(_ id: UUID, outgoing: Bool = false, ended: Bool = false) -> Wait.Call {
        Wait.Call(id: id, isOutgoing: outgoing, hasEnded: ended)
    }
    check(Wait.boundedTimeout(0) == 1 && Wait.boundedTimeout(3600) == 3600
          && Wait.boundedTimeout(100_000) == 10_800 && Wait.boundedTimeout(.nan) == 3600,
          "incoming waits are bounded to one second through three hours")

    var fresh = Wait(startedAt: 10, timeout: 60, initialCalls: [])
    check(fresh.decision(now: 10, calls: [], requireCellular: false, cellularCalls: nil) == .waiting,
          "no call keeps waiting")
    check(fresh.decision(now: 11, calls: [incoming(firstID, outgoing: true)],
                         requireCellular: false, cellularCalls: nil) == .waiting,
          "an outgoing call never satisfies an incoming wait")
    check(fresh.decision(now: 12, calls: [incoming(secondID)], requireCellular: false,
                         cellularCalls: nil) == .finished(.incoming),
          "a new ringing incoming call finishes the wait before connection")
    check(fresh.decision(now: 13, calls: [], requireCellular: false, cellularCalls: nil,
                         cancelled: true) == .finished(.incoming),
          "a finished incoming wait is immutable")

    var existing = Wait(startedAt: 0, timeout: 60, initialCalls: [incoming(firstID)])
    check(existing.decision(now: 1, calls: [incoming(firstID)], requireCellular: false,
                            cellularCalls: 1) == .waiting,
          "a call already active when the wait began is not a new arrival")
    check(existing.decision(now: 2, calls: [incoming(firstID, ended: true), incoming(secondID)],
                            requireCellular: false, cellularCalls: 1) == .finished(.incoming),
          "a later incoming call after the old one ended is detected")

    var waiting = Wait(startedAt: 0, timeout: 60, initialCalls: [])
    check(waiting.decision(now: 1, calls: [incoming(firstID, outgoing: true), incoming(secondID)],
                           requireCellular: false, cellularCalls: 2) == .waiting,
          "call waiting during another call is never a single recordable call")

    var cellular = Wait(startedAt: 0, timeout: 60, initialCalls: [])
    check(cellular.decision(now: 1, calls: [incoming(firstID)], requireCellular: true,
                            cellularCalls: 0) == .waiting,
          "a CallKit-only internet call keeps waiting when cellular calls are required")
    check(cellular.decision(now: 2, calls: [incoming(firstID)], requireCellular: true,
                            cellularCalls: 1) == .finished(.incoming),
          "CoreTelephony evidence finishes a cellular-only wait")
    var unknown = Wait(startedAt: 0, timeout: 60, initialCalls: [])
    check(unknown.decision(now: 1, calls: [incoming(firstID)], requireCellular: true,
                           cellularCalls: nil) == .finished(.incoming),
          "an unavailable CoreTelephony answer does not block detection")

    var late = Wait(startedAt: 0, timeout: 5, initialCalls: [])
    check(late.decision(now: 5, calls: [incoming(firstID)], requireCellular: false,
                        cellularCalls: nil) == .finished(.timedOut),
          "evidence at the deadline is too late")
    var cancelled = Wait(startedAt: 0, timeout: 60, initialCalls: [])
    check(cancelled.decision(now: 1, calls: [incoming(firstID)], requireCellular: false,
                             cellularCalls: nil, cancelled: true) == .finished(.cancelled),
          "cancellation wins over a simultaneous call")
    var backwards = Wait(startedAt: 10, timeout: 60, initialCalls: [])
    check(backwards.decision(now: 9, calls: [], requireCellular: false,
                             cellularCalls: nil) == .finished(.invalidClock),
          "a backwards clock ends the incoming wait")
    check(Wait.Result.incoming.detectedIncoming && !Wait.Result.timedOut.detectedIncoming,
          "only incoming maps to true")
}

print("AirRecordPolicy: call safety, lease recovery, bounded IPC, permissions, waits, call-end waits, incoming waits, configurable windows and activation failure ownership passed")
