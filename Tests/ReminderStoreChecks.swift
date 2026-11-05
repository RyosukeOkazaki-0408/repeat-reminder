import Foundation

// Run separately from DomainTests, using an iOS Simulator executable.
@main
struct ReminderStoreChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReminderStoreChecks-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "reminders.json")
        let now = Date()
        let scheduledAt = Calendar.current.date(bySetting: .second, value: 0, of: now.addingTimeInterval(-120))!
        let parts = Calendar.current.dateComponents([.hour, .minute], from: scheduledAt)
        let a = Reminder(title: "A", hour: parts.hour!, minute: parts.minute!, weekdays: Set(1...7))
        let b = Reminder(title: "B", hour: 2, minute: 0, weekdays: Set(1...7))
        var removed = Reminder(title: "Deleted", hour: 3, minute: 0, weekdays: [])
        removed.deleted = true
        var db = ReminderDatabase()
        db.reminders = [a, removed, b]
        let revision = ScheduleRevision(reminder: a, now: scheduledAt.addingTimeInterval(-1))
        var occurrence = Occurrence(revision: revision, date: scheduledAt)
        occurrence.completedAt = now
        db.revisions = [revision]
        db.occurrences = [occurrence]
        try JSONEncoder().encode(db).write(to: file)
        let store = ReminderStore(file: file)
        store.moveReminders(from: IndexSet(integer: 0), to: 2)
        let reordered = ReminderStore(file: file)
        precondition(reordered.reminders.map(\.title) == ["B", "A"], "order must persist")
        precondition(reordered.database.reminders.contains(where: { $0.id == removed.id }), "deleted records retained")
        await reordered.markIncomplete(occurrence)
        let reopened = ReminderStore(file: file)
        precondition(reopened.pending == nil && reopened.database.occurrences[0].completedAt == nil, "historical undo stays silent after restart")
        try await reopened.stopped(alarmID: revision.id.uuidString, revisionID: revision.id.uuidString, occurrenceID: "")
        precondition(reopened.database.occurrences[0].retryAlarmID == nil, "stale stop intent must not restart retry")
        await reopened.complete(occurrence)
        precondition(reopened.errorMessage == nil, "completion operation must not report an error")
        let completed = ReminderStore(file: file)
        precondition(completed.database.occurrences[0].completedAt != nil, "recompletion persists")
        await completed.deleteHistory(occurrence)
        precondition(completed.errorMessage == nil, "deletion operation must not report an error: \(completed.errorMessage ?? "")")
        let deleted = ReminderStore(file: file)
        precondition(deleted.database.occurrences.isEmpty && deleted.database.deletedOccurrenceIDs?.contains(occurrence.id) == true, "deletion persists")
        try await deleted.stopped(alarmID: revision.id.uuidString, revisionID: revision.id.uuidString, occurrenceID: "")
        precondition(deleted.database.occurrences.isEmpty, "stale intent must not resurrect deleted history")
        var futureDatabase = ReminderDatabase()
        let futureOccurrence = Occurrence(revision: revision, date: now.addingTimeInterval(3600))
        futureDatabase.occurrences = [futureOccurrence]
        let futureFile = folder.appending(path: "future.json")
        try JSONEncoder().encode(futureDatabase).write(to: futureFile)
        let futureStore = ReminderStore(file: futureFile)
        await futureStore.complete(futureOccurrence)
        precondition(futureStore.database == futureDatabase && ReminderStore(file: futureFile).database == futureDatabase,
                     "completion before scheduled time must not change data")
        print("PASS: real ReminderStore reorder, reopen, complete, delete, restart, stale stop intent")
    }
}
