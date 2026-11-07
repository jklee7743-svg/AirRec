// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import Combine
import Foundation

/// Receipts record that each action was invoked, not its result or caller name.
@MainActor
final class AirRecordShortcutPresence: ObservableObject {
    static let shared = AirRecordShortcutPresence()
    static let targetName = "AirRec(발신)"

    @Published private(set) var lastActionRunAt: Date?
    @Published private(set) var lastEndActionRunAt: Date?
    @Published private(set) var lastIncomingActionRunAt: Date?

    private let defaults: UserDefaults
    private static let actionKey = "AirRecord.shortcuts.outgoing.lastActionRunAt"
    private static let endActionKey = "AirRecord.shortcuts.callEnd.lastActionRunAt"
    private static let incomingActionKey = "AirRecord.shortcuts.incoming.lastActionRunAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastActionRunAt = defaults.object(forKey: Self.actionKey) as? Date
        lastEndActionRunAt = defaults.object(forKey: Self.endActionKey) as? Date
        lastIncomingActionRunAt = defaults.object(forKey: Self.incomingActionKey) as? Date
    }

    func recordIncomingActionRun() {
        let now = Date()
        lastIncomingActionRunAt = now
        defaults.set(now, forKey: Self.incomingActionKey)
    }

    func recordActionRun() {
        let now = Date()
        lastActionRunAt = now
        defaults.set(now, forKey: Self.actionKey)
    }

    func recordEndActionRun() {
        let now = Date()
        lastEndActionRunAt = now
        defaults.set(now, forKey: Self.endActionKey)
    }

}
#endif
