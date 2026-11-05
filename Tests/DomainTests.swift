import Foundation

@main
struct DomainTests {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }
    static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "+09:00")!
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func revision(_ title: String = "薬", hour: Int = 20, weekdays: Set<Int> = Set(1...7), starts: String = "2026-11-01T00:00:00") -> ScheduleRevision {
        ScheduleRevision(reminder: Reminder(title: title, hour: hour, minute: 0, weekdays: weekdays), now: date(starts), calendar: calendar)
    }
    static func main() throws {
        expect(Reminder.repeatText(Set(2...6)) == "平日", "weekday label")
        expect(Reminder.repeatText([1, 7]) == "週末", "weekend label")
        expect(Reminder.repeatText(Set(1...7)) == "毎日", "daily label")
        expect(Reminder.repeatText([1, 3, 5]) == "火・木・日", "individual weekday ordering")
        expect(Reminder.repeatText([]) == "繰り返しなし", "one-shot label")

        let daily = revision()
        expect(daily.dates(through: date("2026-11-01T19:59:59"), calendar: calendar).isEmpty, "future occurrence excluded")
        expect(daily.dates(through: date("2026-11-01T20:00:00"), calendar: calendar) == [date("2026-11-01T20:00:00")], "due instant included")
        expect(revision(starts: "2026-11-01T20:00:01").dates(through: date("2026-11-02T20:00:00"), calendar: calendar) == [date("2026-11-02T20:00:00")], "no retroactive occurrence on creation")
        let weekdays = revision(weekdays: Set(2...6)).dates(through: date("2026-11-08T23:59:59"), calendar: calendar)
        expect(weekdays.count == 5 && weekdays.first == date("2026-11-02T20:00:00") && weekdays.last == date("2026-11-06T20:00:00"), "weekly recurrence skips weekend")

        let oneShotToday = revision(weekdays: [], starts: "2026-11-01T10:00:00")
        expect(oneShotToday.dates(through: date("2026-12-01T00:00:00"), calendar: calendar) == [date("2026-11-01T20:00:00")], "one-shot fires once, today when future")
        let oneShotTomorrow = revision(weekdays: [], starts: "2026-11-01T21:00:00")
        expect(oneShotTomorrow.dates(through: date("2026-12-01T00:00:00"), calendar: calendar) == [date("2026-11-02T20:00:00")], "one-shot moves to next date after passed time")

        var db = ReminderDatabase()
        db.revisions = [daily, revision("運動", hour: 21)]
        let now = date("2026-11-02T20:30:00")
        db.materialize(through: now)
        expect(db.occurrences.count == 3, "counts occurrences, not calendar days, and excludes today's future time")
        let original = db
        db.materialize(through: now)
        expect(db == original, "materialization idempotent")
        db.occurrences[0].completedAt = now
        let stats = db.statistics(month: now, now: now, calendar: calendar)
        expect(stats.scheduled == 3 && stats.completed == 1 && stats.percentage == 33, "completion denominator includes every scheduled instance")
        expect(db.pending.count == 2, "completing one instance retains other pending instances")
        expect(db.pending.map(\.scheduledAt) == db.pending.map(\.scheduledAt).sorted(), "pending oldest first")

        var paused = daily
        paused.endsAt = date("2026-11-03T20:00:00")
        var resumed = revision(starts: "2026-11-05T12:00:00")
        resumed.reminderID = daily.reminderID
        var disabledDB = ReminderDatabase()
        disabledDB.revisions = [paused, resumed]
        disabledDB.materialize(through: date("2026-11-05T22:00:00"))
        expect(disabledDB.occurrences.map(\.scheduledAt) == [date("2026-11-01T20:00:00"), date("2026-11-02T20:00:00"), date("2026-11-05T20:00:00")], "disabled interval excluded and closing boundary exclusive")

        var editedOld = daily
        editedOld.endsAt = date("2026-11-02T20:30:00")
        var editedNew = revision("新しい名前", hour: 21, starts: "2026-11-02T20:30:00")
        editedNew.reminderID = editedOld.reminderID
        var editedDB = ReminderDatabase()
        editedDB.revisions = [editedOld, editedNew]
        editedDB.materialize(through: date("2026-11-02T22:00:00"))
        expect(editedDB.occurrences.count == 3, "editing preserves old scheduled instances")
        expect(editedDB.occurrences[0].title == "薬" && editedDB.occurrences.last?.title == "新しい名前", "history keeps original titles")
        editedDB.revisions[1].endsAt = date("2026-11-03T00:00:00")
        editedDB.reminders = [] // UI deletion cannot erase independently stored revisions/history.
        editedDB.materialize(through: date("2026-11-10T00:00:00"))
        expect(editedDB.occurrences.count == 3, "deleting reminder preserves history, ends future schedule")

        var late = ReminderDatabase()
        var october = revision(starts: "2026-10-31T00:00:00")
        october.endsAt = date("2026-11-01T00:00:00")
        late.revisions = [october]
        late.materialize(through: date("2026-11-02T00:00:00"))
        late.occurrences[0].completedAt = date("2026-11-02T00:00:00")
        let octoberStats = late.statistics(month: date("2026-10-01T00:00:00"), now: date("2026-11-03T00:00:00"), calendar: calendar)
        let novemberStats = late.statistics(month: date("2026-11-01T00:00:00"), now: date("2026-11-03T00:00:00"), calendar: calendar)
        expect(octoberStats.completed == 1 && octoberStats.percentage == 100, "late completion attributed to scheduled month")
        expect(novemberStats.completed == 0 && novemberStats.lifetimeCompleted == 1 && novemberStats.percentage == nil, "zero due month has no false percentage and keeps lifetime total")

        late.theme = .yellow
        late.occurrences[0].retryAlarmID = UUID()
        late.occurrences[0].retryAt = date("2026-11-02T00:03:00")
        let restored = try JSONDecoder().decode(ReminderDatabase.self, from: JSONEncoder().encode(late))
        expect(restored == late, "persistence roundtrip preserves history, theme, and retry state")
        let completedID = late.occurrences[0].id
        let retryID = late.occurrences[0].retryAlarmID!
        late.markIncomplete(id: completedID, now: date("2026-11-03T00:00:00"))
        let revised = late.statistics(month: date("2026-10-01T00:00:00"), now: date("2026-11-03T00:00:00"), calendar: calendar)
        expect(revised.scheduled == 1 && revised.completed == 0 && revised.lifetimeCompleted == 0 && revised.percentage == 0, "undo completion changes counts and rate, not scheduled denominator")
        expect(late.pending.isEmpty && !late.occurrences[0].needsAttention, "historical incomplete must not show completion prompt or restart notifications")
        expect(late.occurrences[0].retryAt == nil && late.occurrences[0].retryAlarmID == nil && late.cancellations.contains(retryID), "historical correction clears retries and queues cancellation")
        late.materialize(through: date("2026-11-04T00:00:00"))
        let corrected = try JSONDecoder().decode(ReminderDatabase.self, from: JSONEncoder().encode(late))
        expect(corrected.pending.isEmpty && corrected.occurrences[0].completedAt == nil, "suppression survives restart and materialization")
        var repeating = ReminderDatabase()
        repeating.revisions = [daily]
        repeating.materialize(through: date("2026-11-01T20:00:00"))
        repeating.occurrences[0].completedAt = date("2026-11-01T20:01:00")
        repeating.markIncomplete(id: repeating.occurrences[0].id, now: date("2026-11-01T21:00:00"))
        repeating.materialize(through: date("2026-11-02T20:00:00"))
        expect(repeating.revisions == [daily] && repeating.pending.map(\.scheduledAt) == [date("2026-11-02T20:00:00")], "correction suppresses only the old occurrence and preserves the next recurring reminder")
        late.occurrences[0].completedAt = date("2026-11-04T00:00:00")
        let completedAgain = late.statistics(month: date("2026-10-01T00:00:00"), now: date("2026-11-04T00:00:00"), calendar: calendar)
        expect(completedAgain.completed == 1 && completedAgain.lifetimeCompleted == 1 && completedAgain.percentage == 100, "completion can be restored without double counting")
        let legacyData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var legacy = legacyData
        legacy["occurrences"] = (legacyData["occurrences"] as! [[String: Any]]).map { item in
            var value = item
            value.removeValue(forKey: "notificationsSuppressed")
            return value
        }
        let legacyRestored = try JSONDecoder().decode(ReminderDatabase.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(legacyRestored.pending.count == original.pending.count, "legacy data without suppression keeps existing pending behavior")
        var future = ReminderDatabase()
        future.occurrences = [Occurrence(revision: oneShotToday, date: date("2026-11-01T20:00:00"))]
        future.occurrences[0].completedAt = date("2026-11-01T18:00:00")
        let beforeFutureUndo = future
        future.markIncomplete(id: future.occurrences[0].id, now: date("2026-11-01T19:00:00"))
        expect(future == beforeFutureUndo, "future history changes are not supported by the past-only correction")
        var deletedHistory = repeating
        let removedID = deletedHistory.occurrences[0].id
        let removedRetry = UUID()
        deletedHistory.occurrences[0].retryAlarmID = removedRetry
        deletedHistory.deleteOccurrence(id: removedID, now: date("2026-11-02T21:00:00"))
        deletedHistory.materialize(through: date("2026-11-02T21:00:00"))
        expect(deletedHistory.occurrences.count == 1 && !deletedHistory.occurrences.contains(where: { $0.id == removedID }), "deleted history does not reappear during materialization")
        expect(deletedHistory.cancellations.contains(removedRetry) && deletedHistory.revisions == repeating.revisions, "history deletion cancels retries and preserves recurring schedule")
        let deletionStats = deletedHistory.statistics(month: now, now: date("2026-11-02T21:00:00"), calendar: calendar)
        expect(deletionStats.scheduled == 1 && deletionStats.completed == 0, "deleted history is excluded from statistics")
        var deletedRestored = try JSONDecoder().decode(ReminderDatabase.self, from: JSONEncoder().encode(deletedHistory))
        deletedRestored.materialize(through: date("2026-11-03T21:00:00"))
        expect(deletedRestored.occurrences.count == 2 && !deletedRestored.occurrences.contains(where: { $0.id == removedID }), "deletion survives restart without suppressing future occurrences")
        print("PASS: scheduling, statistics, history corrections and deletion, notification suppression, recurrence preservation, legacy decoding, JSON roundtrip")
    }
}
