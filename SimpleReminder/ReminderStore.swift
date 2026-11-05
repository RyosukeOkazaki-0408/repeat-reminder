import Foundation
import SwiftUI
import AlarmKit
import AppIntents
import Observation

extension ReminderTheme {
    var color: Color {
        switch self {
        case .pink: Color(red: 0.91, green: 0.43, blue: 0.61)
        case .blue: Color(red: 0.21, green: 0.58, blue: 0.96)
        case .green: Color(red: 0.22, green: 0.65, blue: 0.48)
        case .yellow: Color(red: 0.77, green: 0.58, blue: 0.14)
        }
    }
    var pastel: Color { color.opacity(0.16) }
}

struct ReminderAlarmMetadata: AlarmMetadata {}

struct StopReminderIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "リマインダーのアラームを停止"
    static var openAppWhenRun = false
    @Parameter(title: "アラームID") var alarmID: String
    @Parameter(title: "予定ID") var revisionID: String
    @Parameter(title: "実行回ID") var occurrenceID: String
    init() {}
    init(alarmID: UUID, revisionID: UUID, occurrenceID: String = "") {
        self.alarmID = alarmID.uuidString; self.revisionID = revisionID.uuidString; self.occurrenceID = occurrenceID
    }
    @MainActor func perform() async throws -> some IntentResult {
        try await ReminderStore.shared.stopped(alarmID: alarmID, revisionID: revisionID, occurrenceID: occurrenceID)
        return .result()
    }
}

@MainActor @Observable
final class ReminderStore {
    static let shared = ReminderStore()
    private(set) var database = ReminderDatabase()
    private(set) var busy = false
    private(set) var fatalLoadError = false
    var errorMessage: String?
    private(set) var authorization = AlarmManager.shared.authorizationState
    private var observing = false
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "SimpleReminder", directoryHint: .isDirectory).appending(path: "reminders.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                database = try JSONDecoder().decode(ReminderDatabase.self, from: Data(contentsOf: self.file))
                guard database.version == 1 else { throw StoreError.message("保存データの形式に対応していません。") }
            }
        } catch {
            fatalLoadError = true
            errorMessage = "保存データを読み込めませんでした。データは上書きしていません。\n\(error.localizedDescription)"
        }
    }
    var reminders: [Reminder] { database.reminders.filter { !$0.deleted } }
    var pending: Occurrence? { database.pending.first }
    var theme: ReminderTheme { database.theme }

    private func commit(_ value: ReminderDatabase) throws {
        guard !fatalLoadError else { throw StoreError.message("保存データを読み込めないため変更できません。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        database = value
    }
    private func acquire() async throws {
        while busy { try await Task.sleep(for: .milliseconds(25)) }
        busy = true
    }
    private func authorize() async throws {
        authorization = AlarmManager.shared.authorizationState
        if authorization == .notDetermined { authorization = try await AlarmManager.shared.requestAuthorization() }
        guard authorization == .authorized else { throw StoreError.message("アラームが許可されていません。iPhoneの設定でこのアプリのアラームを許可してください。") }
    }
    func requestAlarmAccess() async {
        do {
            try await acquire(); defer { busy = false }
            try await authorize()
        } catch { report(error) }
        if authorization == .authorized { await recover() }
    }
    private func configuration(title: String, schedule: Alarm.Schedule, intent: StopReminderIntent) -> AlarmManager.AlarmConfiguration<ReminderAlarmMetadata> {
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) { alert = .init(title: LocalizedStringResource(stringLiteral: title)) }
        else { alert = .init(title: LocalizedStringResource(stringLiteral: title), stopButton: .init(text: "停止", textColor: .white, systemImageName: "stop.circle")) }
        return .init(schedule: schedule, attributes: .init(presentation: .init(alert: alert), metadata: .init(), tintColor: theme.color), stopIntent: intent, sound: .default)
    }
    private func register(_ revision: ScheduleRevision) async throws {
        let schedule: Alarm.Schedule
        if let date = revision.oneShotDate { schedule = .fixed(date) }
        else {
            let days: [Int: Locale.Weekday] = [1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday, 5: .thursday, 6: .friday, 7: .saturday]
            schedule = .relative(.init(time: .init(hour: revision.hour, minute: revision.minute), repeats: .weekly(revision.weekdays.sorted().compactMap { days[$0] })))
        }
        _ = try await AlarmManager.shared.schedule(id: revision.id, configuration: configuration(title: revision.title, schedule: schedule, intent: .init(alarmID: revision.id, revisionID: revision.id)))
    }
    private func registerRetry(_ occurrence: Occurrence) async throws {
        guard let id = occurrence.retryAlarmID, let date = occurrence.retryAt else { return }
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration(title: occurrence.title, schedule: .fixed(date), intent: .init(alarmID: id, revisionID: occurrence.revisionID, occurrenceID: occurrence.id)))
    }
    func refresh() {
        guard !busy, !fatalLoadError else { return }
        authorization = AlarmManager.shared.authorizationState
        var value = database; value.materialize(through: Date())
        if value != database { do { try commit(value) } catch { report(error) } }
    }
    func start() async {
        guard !observing else { refresh(); return }
        observing = true
        refresh()
        Task { for await state in AlarmManager.shared.authorizationUpdates { self.authorization = state } }
        Task { for await _ in AlarmManager.shared.alarmUpdates { self.refresh() } }
        await recover()
    }
    func recover() async {
        guard !fatalLoadError else { return }
        do {
            try await acquire(); defer { busy = false }
            var value = database; value.materialize(through: Date()); try commit(value)
            cancelQueued()
            guard AlarmManager.shared.authorizationState == .authorized else { return }
            let registered = Set(try AlarmManager.shared.alarms.map(\.id))
            let known = Set(database.revisions.filter { $0.endsAt == nil }.map(\.id))
                .union(database.pending.compactMap(\.retryAlarmID))
            for id in registered.subtracting(known).subtracting(database.cancellations) { try AlarmManager.shared.cancel(id: id) }
            for revision in database.revisions where revision.endsAt == nil && !registered.contains(revision.id) {
                if let date = revision.oneShotDate, date <= Date() { continue }
                try await register(revision)
            }
            for occurrence in database.pending where occurrence.retryAlarmID != nil && !registered.contains(occurrence.retryAlarmID!) {
                guard let date = occurrence.retryAt else { continue }
                var retry = occurrence
                if date <= Date() {
                    retry.retryAt = Date().addingTimeInterval(3)
                    var updated = database
                    if let index = updated.occurrences.firstIndex(where: { $0.id == retry.id }) {
                        updated.occurrences[index] = retry
                        try commit(updated)
                    }
                }
                try await registerRetry(retry)
            }
        } catch { report(error) }
    }
    func save(_ reminder: Reminder) async -> Bool {
        do {
            try await acquire(); defer { busy = false }
            guard !reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.message("リマインダー名を入力してください。") }
            guard (0...23).contains(reminder.hour), (0...59).contains(reminder.minute), reminder.weekdays.isSubset(of: Set(1...7)) else { throw StoreError.message("通知時刻・曜日を確認してください。") }
            if reminder.enabled && !reminder.deleted { try await authorize() }
            let now = Date()
            var value = database; value.materialize(through: now)
            let old = value.revisions.filter { $0.reminderID == reminder.id && $0.endsAt == nil }
            for index in value.revisions.indices where value.revisions[index].reminderID == reminder.id && value.revisions[index].endsAt == nil {
                value.revisions[index].endsAt = now
            }
            if let index = value.reminders.firstIndex(where: { $0.id == reminder.id }) { value.reminders[index] = reminder }
            else { value.reminders.append(reminder) }
            var added: ScheduleRevision?
            if reminder.enabled && !reminder.deleted {
                let revision = ScheduleRevision(reminder: reminder, now: now)
                try await register(revision)
                added = revision; value.revisions.append(revision)
            }
            var cancelled: [ScheduleRevision] = []
            do {
                for revision in old {
                    try cancelIfPresent(revision.id)
                    cancelled.append(revision)
                }
                try commit(value)
            } catch {
                if let added {
                    do { try cancelIfPresent(added.id) }
                    catch {
                        var cleanup = database
                        cleanup.cancellations.insert(added.id)
                        try? commit(cleanup)
                    }
                }
                for revision in cancelled where revision.oneShotDate.map({ $0 > Date() }) ?? true {
                    try? await register(revision)
                }
                throw StoreError.message("変更を保存できませんでした。元の設定で復旧を試みました。\n\(error.localizedDescription)")
            }
            return true
        } catch { report(error); return false }
    }
    func setEnabled(_ reminder: Reminder, _ enabled: Bool) async {
        var value = reminder; value.enabled = enabled; _ = await save(value)
    }
    @discardableResult
    func delete(_ reminder: Reminder) async -> Bool {
        var value = reminder
        value.deleted = true
        value.enabled = false
        return await save(value)
    }
    func setTheme(_ theme: ReminderTheme) {
        guard !busy else { return }
        var value = database; value.theme = theme
        do { try commit(value) } catch { report(error) }
    }
    private func cancelIfPresent(_ id: UUID) throws {
        guard try AlarmManager.shared.alarms.contains(where: { $0.id == id }) else { return }
        do { try AlarmManager.shared.cancel(id: id) }
        catch {
            if (try? AlarmManager.shared.alarms.contains(where: { $0.id == id })) == false { return }
            throw error
        }
    }
    private func cancelQueued() {
        guard !database.cancellations.isEmpty else { return }
        var value = database
        for id in database.cancellations {
            do {
                try cancelIfPresent(id)
                value.cancellations.remove(id)
            } catch {
                continue
            }
        }
        if value != database { try? commit(value) }
    }
    func complete(_ occurrence: Occurrence) async {
        do {
            try await acquire(); defer { busy = false }
            var value = database
            value.materialize(through: Date())
            guard let index = value.occurrences.firstIndex(where: { $0.id == occurrence.id }), value.occurrences[index].completedAt == nil else { return }
            value.occurrences[index].completedAt = Date()
            if let retry = value.occurrences[index].retryAlarmID { value.cancellations.insert(retry) }
            value.occurrences[index].retryAlarmID = nil; value.occurrences[index].retryAt = nil
            if let revision = value.revisions.first(where: { $0.id == occurrence.revisionID }), revision.oneShotDate != nil {
                value.cancellations.insert(revision.id)
                if let ri = value.reminders.firstIndex(where: { $0.id == revision.reminderID }),
                   !value.revisions.contains(where: { $0.reminderID == revision.reminderID && $0.id != revision.id && $0.endsAt == nil }) {
                    value.reminders[ri].enabled = false
                }
                if let vi = value.revisions.firstIndex(where: { $0.id == revision.id }) { value.revisions[vi].endsAt = Date() }
            }
            try commit(value)
            cancelQueued()
            // stop preserves a weekly schedule; cancel would remove its future occurrences.
            if let active = try? AlarmManager.shared.alarms.first(where: { $0.id == occurrence.revisionID && $0.state == .alerting }),
               value.occurrences.filter({ $0.revisionID == occurrence.revisionID }).last?.id == occurrence.id {
                try? AlarmManager.shared.stop(id: active.id)
            }
        } catch { report(StoreError.message("完了できませんでした。もう一度お試しください。\n\(error.localizedDescription)")) }
    }
    func stopped(alarmID: String, revisionID: String, occurrenceID: String) async throws {
        do {
            try await acquire(); defer { busy = false }
            guard let sourceID = UUID(uuidString: alarmID), let revisionUUID = UUID(uuidString: revisionID) else { return }
            guard database.revisions.contains(where: { $0.id == revisionUUID }) else { return }
            var value = database; value.materialize(through: Date())
            let index: Int?
            if occurrenceID.isEmpty {
                index = value.occurrences.lastIndex(where: { $0.revisionID == revisionUUID })
            } else { index = value.occurrences.firstIndex(where: { $0.id == occurrenceID }) }
            guard let index, value.occurrences[index].completedAt == nil else { try commit(value); return }
            if occurrenceID.isEmpty {
                guard value.occurrences[index].retryAlarmID == nil else { return }
            } else {
                guard value.occurrences[index].retryAlarmID == sourceID else { return }
            }
            if let prior = value.occurrences[index].retryAlarmID { value.cancellations.insert(prior) }
            value.occurrences[index].retryAlarmID = UUID()
            let minutes = value.reminders.first(where: { $0.id == value.occurrences[index].reminderID })?.retryMinutes ?? 3
            value.occurrences[index].retryAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
            try commit(value) // Persist intent first, so a terminated process can recover registration.
            try await registerRetry(value.occurrences[index])
            cancelQueued()
        } catch { report(error); throw error }
    }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
}
enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
