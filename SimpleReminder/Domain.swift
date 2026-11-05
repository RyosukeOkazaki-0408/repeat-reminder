import Foundation

enum ReminderTheme: String, Codable, CaseIterable, Identifiable {
    case pink, blue, green, yellow
    var id: String { rawValue }
    var title: String {
        switch self { case .pink: "パステルピンク"; case .blue: "パステルブルー"; case .green: "パステルグリーン"; case .yellow: "パステルイエロー" }
    }
}
struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    var retryMinutes: Int? = nil
    var enabled = true
    var deleted = false
    var timeText: String { String(format: "%02d:%02d", hour, minute) }
    var repeatText: String { Self.repeatText(weekdays) }
    static func repeatText(_ days: Set<Int>) -> String {
        if days.isEmpty { return "繰り返しなし" }
        if days == Set(2...6) { return "平日" }
        if days == [1, 7] { return "週末" }
        if days == Set(1...7) { return "毎日" }
        let labels = [1: "日", 2: "月", 3: "火", 4: "水", 5: "木", 6: "金", 7: "土"]
        return [2, 3, 4, 5, 6, 7, 1].filter { days.contains($0) }.compactMap { labels[$0] }.joined(separator: "・")
    }
}
/// Closing a revision changes future scheduling, while retaining the historical denominator.
struct ScheduleRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var reminderID: UUID
    var title: String
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    var startsAt: Date
    var endsAt: Date?
    var oneShotDate: Date?
    var timeZoneID: String
    init(reminder: Reminder, now: Date, calendar: Calendar = .current) {
        reminderID = reminder.id; title = reminder.title; hour = reminder.hour; minute = reminder.minute
        weekdays = reminder.weekdays; startsAt = now; timeZoneID = calendar.timeZone.identifier
        if weekdays.isEmpty {
            oneShotDate = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }
    }
    func dates(through now: Date, startingAt lowerBound: Date? = nil, calendar supplied: Calendar? = nil) -> [Date] {
        let start = max(startsAt, lowerBound ?? startsAt)
        guard start <= now else { return [] }
        if let date = oneShotDate {
            return date >= start && date <= now && (endsAt == nil || date < endsAt!) ? [date] : []
        }
        var calendar = supplied ?? Calendar(identifier: .gregorian)
        if supplied == nil { calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current }
        let end = min(now, endsAt ?? now)
        guard end >= start else { return [] }
        var day = calendar.startOfDay(for: start)
        var result: [Date] = []
        while day <= end {
            if weekdays.contains(calendar.component(.weekday, from: day)),
               let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
               date >= start, date <= now, endsAt == nil || date < endsAt! { result.append(date) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
}
struct Occurrence: Codable, Identifiable, Equatable {
    var id: String
    var revisionID: UUID
    var reminderID: UUID
    var title: String
    var scheduledAt: Date
    var completedAt: Date?
    var retryAlarmID: UUID?
    var retryAt: Date?
    var notificationsSuppressed: Bool?
    var hour: Int
    var minute: Int
    var timeText: String { String(format: "%02d:%02d", hour, minute) }
    var needsAttention: Bool { completedAt == nil && notificationsSuppressed != true }
    init(revision: ScheduleRevision, date: Date) {
        id = Self.identifier(revisionID: revision.id, date: date)
        revisionID = revision.id; reminderID = revision.reminderID; title = revision.title
        scheduledAt = date; hour = revision.hour; minute = revision.minute
    }
    static func identifier(revisionID: UUID, date: Date) -> String { "\(revisionID.uuidString):\(Int64(date.timeIntervalSince1970))" }
}
struct ReminderDatabase: Codable, Equatable {
    var version = 1
    var reminders: [Reminder] = []
    var revisions: [ScheduleRevision] = []
    var occurrences: [Occurrence] = []
    var theme: ReminderTheme = .pink
    var cancellations: Set<UUID> = []
    var deletedOccurrenceIDs: Set<String>?
    mutating func materialize(through now: Date) {
        var known = Set(occurrences.map(\.id))
        for revision in revisions {
            for date in revision.dates(through: now) {
                let occurrence = Occurrence(revision: revision, date: date)
                if deletedOccurrenceIDs?.contains(occurrence.id) != true && known.insert(occurrence.id).inserted { occurrences.append(occurrence) }
            }
        }
        occurrences.sort { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt }
    }
    var pending: [Occurrence] { occurrences.filter(\.needsAttention) }
    mutating func deleteOccurrence(id: String, now: Date) {
        guard let occurrence = occurrences.first(where: { $0.id == id }), occurrence.scheduledAt <= now else { return }
        if let retry = occurrence.retryAlarmID { cancellations.insert(retry) }
        var deleted = deletedOccurrenceIDs ?? []
        deleted.insert(id)
        deletedOccurrenceIDs = deleted
        occurrences.removeAll { $0.id == id }
    }
    mutating func markIncomplete(id: String, now: Date) {
        guard let index = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[index].completedAt != nil, occurrences[index].scheduledAt <= now else { return }
        if let retry = occurrences[index].retryAlarmID { cancellations.insert(retry) }
        occurrences[index].completedAt = nil
        occurrences[index].notificationsSuppressed = true
        occurrences[index].retryAlarmID = nil
        occurrences[index].retryAt = nil
    }
    func statistics(month: Date, now: Date, calendar: Calendar = .current) -> MonthlyStatistics {
        guard let range = calendar.dateInterval(of: .month, for: month) else { return .init(scheduled: 0, completed: 0, lifetimeCompleted: 0) }
        let due = occurrences.filter { $0.scheduledAt <= now && $0.scheduledAt >= range.start && $0.scheduledAt < range.end }
        return .init(scheduled: due.count, completed: due.filter { $0.completedAt != nil }.count,
                     lifetimeCompleted: occurrences.filter { $0.scheduledAt <= now && $0.completedAt != nil }.count)
    }
}
struct MonthlyStatistics: Equatable {
    var scheduled: Int
    var completed: Int
    var lifetimeCompleted: Int
    var percentage: Int? { scheduled == 0 ? nil : Int((Double(completed) / Double(scheduled) * 100).rounded()) }
}
