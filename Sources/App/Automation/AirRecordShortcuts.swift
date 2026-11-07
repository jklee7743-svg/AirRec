// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import AppIntents
import Foundation

/// Bridges the system's synchronous cancellation callback to this invocation's
/// observer task, including cancellation before that task is installed.
private final class AirRecordIntentTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ task: Task<Bool, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = task
        lock.unlock()
        pending?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

/// A CallKit observation only; the shortcut chooses what to do with the Bool.
struct WaitForAirRecordOutgoingCallIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource = "발신"
    static var description: IntentDescription = "발신 시작을 기본 20초 기다립니다. 대기 시간은 1~180초로 설정할 수 있습니다. 단일 발신을 감지하면 즉시 예, 시간이 지나면 아니요를 반환합니다. 25초를 넘는 대기에는 iOS 진행 표시가 나타날 수 있으며, FaceTime 등 CallKit 발신도 감지할 수 있습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(초)", default: 20, controlStyle: .field, inclusiveRange: (1, 180))
    var waitSeconds: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        AirRecordShortcutPresence.shared.recordActionRun()
        airRecordLog("Outgoing wait intent: started")
        let seconds = AirRecordOutgoingWaitPolicy.boundedTimeout(TimeInterval(waitSeconds))
        let outgoing: Bool
        if seconds <= 25 {
            outgoing = await AirRecordOutgoingCallWaiter.wait(timeout: seconds)
        } else {
            outgoing = await waitForOutgoingInBackground(seconds: seconds)
        }
        let detected = outgoing && !Task.isCancelled
        airRecordLog("Outgoing wait intent: result=\(detected)")
        return .result(value: detected)
    }

    @MainActor
    private func waitForOutgoingInBackground(seconds: TimeInterval) async -> Bool {
        let displayProgress = progress
        displayProgress.totalUnitCount = Int64(seconds)
        displayProgress.completedUnitCount = 0
        displayProgress.localizedDescription = "발신 대기"
        displayProgress.localizedAdditionalDescription = "발신하면 다음 동작을 실행합니다."
        do {
            let detected = try await runBackgroundWait {
                await AirRecordOutgoingCallWaiter.wait(timeout: seconds) { elapsed in
                    displayProgress.completedUnitCount = Int64(elapsed)
                    displayProgress.localizedAdditionalDescription = "경과 \(Int(elapsed))초 · 최대 \(Int(seconds))초 대기"
                }
            }
            displayProgress.localizedDescription = detected ? "발신 확인됨" : "발신 대기 종료"
            if detected { displayProgress.completedUnitCount = displayProgress.totalUnitCount }
            return detected
        } catch {
            displayProgress.localizedDescription = "발신 대기 중단됨"
            airRecordLog("Outgoing wait intent: interrupted")
            return false
        }
    }
}

/// Observes completion; never hangs up or changes cellular data itself.
struct WaitForAirRecordCallEndIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource = "발신종료"
    static var description: IntentDescription = "발신 자동화에서 사용합니다. 진행 중인 모든 활성 통화가 끝날 때까지 기다립니다. 이미 통화가 없으면 즉시 참, 시간 초과·중단이면 거짓을 반환합니다. 기본 60분, 최대 180분이며 대기 중 시스템 진행 표시가 나타납니다. 다음에 셀룰러 데이터 켜기를 연결하세요. 통화를 직접 끊지는 않습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(분)", default: 60)
    var waitMinutes: Int

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        AirRecordShortcutPresence.shared.recordEndActionRun()
        let seconds = AirRecordCallEndWaitPolicy.boundedTimeout(TimeInterval(waitMinutes) * 60)
        let displayProgress = progress
        displayProgress.totalUnitCount = Int64(seconds.rounded(.up))
        displayProgress.completedUnitCount = 0
        displayProgress.localizedDescription = "발신종료 대기"
        displayProgress.localizedAdditionalDescription = "모든 통화가 끝나면 다음 동작을 실행합니다."
        airRecordLog("Call end wait intent: started")
        do {
            let confirmed = try await runBackgroundWait {
                await AirRecordCallEndWaiter.wait(timeout: seconds) { elapsed in
                    // Progress measures elapsed observation time, not the
                    // unknown duration or completion percentage of a call.
                    displayProgress.completedUnitCount = min(
                        displayProgress.totalUnitCount, Int64(max(0, elapsed).rounded(.down)))
                    displayProgress.localizedAdditionalDescription = "경과 \(Int(elapsed))초 · 최대 \(Int(seconds / 60))분 대기"
                }
            }
            displayProgress.localizedDescription = confirmed ? "발신종료 확인됨" : "발신종료 대기 중단됨"
            if confirmed { displayProgress.completedUnitCount = displayProgress.totalUnitCount }
            airRecordLog("Call end wait intent: result=\(confirmed)")
            return .result(value: confirmed)
        } catch {
            displayProgress.localizedDescription = "발신종료 대기 중단됨"
            airRecordLog("Call end wait intent: interrupted")
            return .result(value: false)
        }
    }
}

/// A CallKit observation only; it never answers, records, or changes data.
struct WaitForAirRecordIncomingCallIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource = "수신"
    static var description: IntentDescription = "새 수신 전화가 울리기 시작할 때까지 기다립니다. 감지하면 예, 시간이 지나거나 중단되면 아니요를 반환합니다. 기본 60분, 최대 180분이며 대기 중 iOS 진행 표시가 나타날 수 있습니다. ‘일반 전화만’을 켜면 보이스톡·FaceTime 같은 인터넷 통화는 감지하지 않습니다. 결과가 예이고 Wi-Fi가 없을 때만 ‘셀룰러 데이터 끄기 → 발신종료 → 셀룰러 데이터 켜기’를 실행하세요. 전화를 받거나 끊지는 않습니다."
    static var supportedModes: IntentModes { [.background] }
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "최대 대기 시간(분)", default: 60)
    var waitMinutes: Int

    @Parameter(title: "일반 전화만", default: true)
    var cellularOnly: Bool

    @MainActor
    func perform() async -> some IntentResult & ReturnsValue<Bool> {
        AirRecordShortcutPresence.shared.recordIncomingActionRun()
        let seconds = AirRecordIncomingWaitPolicy.boundedTimeout(TimeInterval(waitMinutes) * 60)
        let requireCellular = cellularOnly
        let displayProgress = progress
        displayProgress.totalUnitCount = Int64(seconds.rounded(.up))
        displayProgress.completedUnitCount = 0
        displayProgress.localizedDescription = "수신 대기"
        displayProgress.localizedAdditionalDescription = "새 수신 전화가 오면 다음 동작을 실행합니다."
        airRecordLog("Incoming wait intent: started")
        do {
            let detected = try await runBackgroundWait {
                await AirRecordIncomingCallWaiter.wait(timeout: seconds, requireCellular: requireCellular) { elapsed in
                    displayProgress.completedUnitCount = min(
                        displayProgress.totalUnitCount, Int64(max(0, elapsed).rounded(.down)))
                    displayProgress.localizedAdditionalDescription = "경과 \(Int(elapsed / 60))분 · 최대 \(Int(seconds / 60))분 대기"
                }
            }
            displayProgress.localizedDescription = detected ? "수신 확인됨" : "수신 대기 종료"
            if detected { displayProgress.completedUnitCount = displayProgress.totalUnitCount }
            airRecordLog("Incoming wait intent: result=\(detected)")
            return .result(value: detected)
        } catch {
            displayProgress.localizedDescription = "수신 대기 중단됨"
            airRecordLog("Incoming wait intent: interrupted")
            return .result(value: false)
        }
    }
}

private extension LongRunningIntent where Self: CancellableIntent {
    @MainActor
    func runBackgroundWait(_ wait: @escaping @MainActor @Sendable () async -> Bool) async throws -> Bool {
        let cancellation = AirRecordIntentTask()
        defer { cancellation.clear() }
        do {
            let result = try await performBackgroundTask {
                let pending = Task { @MainActor in
                    guard !Task.isCancelled, !cancellation.isCancelled else { return false }
                    return await wait()
                }
                cancellation.install(pending)
                let value = await withTaskCancellationHandler {
                    await pending.value
                } onCancel: {
                    cancellation.cancel()
                }
                cancellation.clear()
                return value && !cancellation.isCancelled && !Task.isCancelled
            } onCancel: { _ in
                cancellation.cancel()
            }
            return result && !cancellation.isCancelled && !Task.isCancelled
        } catch {
            cancellation.cancel()
            throw error
        }
    }
}

struct AirRecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WaitForAirRecordOutgoingCallIntent(),
            phrases: ["\(.applicationName) 발신"],
            shortTitle: "발신",
            systemImageName: "phone.arrow.up.right"
        )
        AppShortcut(
            intent: WaitForAirRecordIncomingCallIntent(),
            phrases: ["\(.applicationName) 수신"],
            shortTitle: "수신",
            systemImageName: "phone.arrow.down.left"
        )
        AppShortcut(
            intent: WaitForAirRecordCallEndIntent(),
            phrases: ["\(.applicationName) 발신종료"],
            shortTitle: "발신종료",
            systemImageName: "phone.down"
        )
    }
}
#endif
