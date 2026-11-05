import SwiftUI
import AlarmKit
import UIKit

@main struct SimpleReminderApp: App {
    var body: some Scene { WindowGroup { RootView().environment(\.locale, Locale(identifier: "ja_JP")) } }
}

struct RootView: View {
    @State private var store = ReminderStore.shared
    @Environment(\.scenePhase) private var phase
    @State private var draft: Reminder?
    @State private var showingTheme = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        Group {
            if store.authorization == .authorized {
                reminderContent
            } else {
                ContentUnavailableView {
                    Label("アラームの許可が必要です", systemImage: "bell.badge")
                } description: {
                    Text("リマインダーを使うには、アラームを許可してください。")
                } actions: {
                    if store.authorization == .notDetermined {
                        Button("アラームを許可") { Task { await store.requestAlarmAccess() } }
                            .disabled(store.busy)
                    } else {
                        Button("設定を開く") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            }
        }
        .tint(store.theme.color)
        .alert("確認", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task {
            await store.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if phase == .active { store.refresh() }
            }
        }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await store.recover() } } }
        .onChange(of: store.pending?.id, initial: true) { _, id in
            if id != nil { showingTheme = false }
        }
    }
    private func updateAppIcon(for theme: ReminderTheme) {
        let iconName: String? = switch theme {
        case .pink: nil
        case .blue: "AppIcon-Blue"
        case .green: "AppIcon-Green"
        case .yellow: "AppIcon-Yellow"
        }
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != iconName else { return }
        Task {
            do { try await application.setAlternateIconName(iconName) }
            catch { store.errorMessage = "ホーム画面のアイコンを変更できませんでした。同じテーマを選び直すと再試行できます。" }
        }
    }

    private var reminderContent: some View {
        ZStack {
            Group {
                if let draft {
                    ReminderEditor(reminder: draft, store: store) { self.draft = nil }
                } else {
                    TabView {
                        ReminderList(store: store, edit: { draft = $0 })
                            .tabItem { Label("リマインダー", systemImage: "bell.fill") }
                        StatisticsView(store: store, showingTheme: $showingTheme)
                            .tabItem { Label("履歴", systemImage: "chart.bar.fill") }
                    }
                }
            }
            .blur(radius: store.pending == nil ? 0 : 9)
            .allowsHitTesting(store.pending == nil)
            .accessibilityHidden(store.pending != nil)
            if showingTheme && store.pending == nil {
                Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { showingTheme = false }
                VStack(spacing: 18) {
                    HStack { Text("カラーテーマ").font(.headline); Spacer(); Button("閉じる") { showingTheme = false } }
                    ForEach(ReminderTheme.allCases) { theme in
                        Button {
                            store.setTheme(theme)
                            showingTheme = false
                            if store.theme == theme { updateAppIcon(for: theme) }
                        } label: {
                            HStack {
                                Circle().fill(theme.color).frame(width: 26, height: 26)
                                Text(theme.title).foregroundStyle(.primary)
                                Spacer()
                                if theme == store.theme { Image(systemName: "checkmark") }
                            }.padding(12).background(theme.pastel, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28)).padding(28)
            }
            if let occurrence = store.pending {
                Color.black.opacity(0.20).ignoresSafeArea().accessibilityHidden(true)
                VStack(spacing: 20) {
                    Image(systemName: "bell.badge.waveform.fill").font(.system(size: 48)).foregroundStyle(store.theme.color)
                    Text(occurrence.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(occurrence.timeText).font(.title3).foregroundStyle(.secondary)
                    Button { Task { await store.complete(occurrence) } } label: {
                        Text("完了").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(store.busy)
                }
                .padding(28).frame(maxWidth: 340)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.8)))
                .shadow(color: .black.opacity(0.10), radius: 30, y: 10).padding(24)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
            }
        }
    }
}

struct ReminderList: View {
    let store: ReminderStore
    var edit: (Reminder) -> Void
    var body: some View {
        NavigationStack {
            List {
                if store.authorization == .denied {
                    Text("アラームが許可されていません。iPhoneの設定から許可してください。")
                        .font(.subheadline).foregroundStyle(.red).listRowBackground(Color.white.opacity(0.8))
                }
                if store.reminders.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell").font(.system(size: 38)).foregroundStyle(store.theme.color)
                        Text("リマインダーがありません").font(.headline)
                        Text("右上の＋から予定を追加できます").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 50).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(store.reminders) { reminder in
                    HStack(spacing: 14) {
                        Button { edit(reminder) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "bell").font(.title2)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(reminder.title).font(.headline).foregroundStyle(.primary)
                                    Text("\(reminder.repeatText) \(reminder.timeText)").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(reminder.title)、\(reminder.repeatText)、\(reminder.timeText)、編集")
                        Toggle("有効", isOn: Binding(get: { reminder.enabled }, set: { enabled in Task { await store.setEnabled(reminder, enabled) } }))
                            .labelsHidden().disabled(store.busy).accessibilityLabel("\(reminder.title)を有効にする")
                    }.padding(.vertical, 12)
                    .listRowBackground(Color.white.opacity(0.78)).listRowSeparator(.hidden)
                    .moveDisabled(store.busy || store.fatalLoadError)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("削除", role: .destructive) {
                            Task { await store.delete(reminder) }
                        }.disabled(store.busy)
                    }
                }
                .onMove { source, destination in
                    store.moveReminders(from: source, to: destination)
                }
            }
            .scrollContentBackground(.hidden).background { themedBackdrop(store.theme) }
            .navigationTitle("リマインダー")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { edit(Reminder(title: "", hour: 20, minute: 0, weekdays: [])) } label: { Image(systemName: "plus").font(.title2) }.accessibilityLabel("リマインダーを追加").disabled(store.busy || store.fatalLoadError)
            } }
        }
    }
}

struct ReminderEditor: View {
    @State var reminder: Reminder
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    let original: Reminder
    let store: ReminderStore
    var close: () -> Void

    init(reminder: Reminder, store: ReminderStore, close: @escaping () -> Void) {
        _reminder = State(initialValue: reminder)
        original = reminder
        self.store = store
        self.close = close
    }
    private var date: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: Date()) ?? Date() },
                set: { reminder.hour = Calendar.current.component(.hour, from: $0); reminder.minute = Calendar.current.component(.minute, from: $0) })
    }
    var body: some View {
        let isExisting = store.reminders.contains { $0.id == original.id }
        NavigationStack {
            Form {
                TextField("リマインダー名", text: $reminder.title).font(.headline).accessibilityIdentifier("reminder.title").focused($nameFocused)
                Section {
                    DatePicker(selection: date, displayedComponents: .hourAndMinute) { Label("通知時刻", systemImage: "clock") }
                }
                Section {
                    Picker("再通知の間隔", selection: Binding(get: { reminder.retryMinutes ?? 3 }, set: { reminder.retryMinutes = $0 })) {
                        ForEach([1, 3, 5, 10, 15, 30], id: \.self) { minutes in
                            Text("\(minutes)分").tag(minutes)
                        }
                    }
                }
                Section {
                    HStack { Label("繰り返し", systemImage: "calendar"); Spacer(); Text(reminder.repeatText).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        ForEach([1, 2, 3, 4, 5, 6, 7], id: \.self) { day in
                            let selected = reminder.weekdays.contains(day)
                            Button {
                                if selected { reminder.weekdays.remove(day) } else { reminder.weekdays.insert(day) }
                            } label: {
                                Text(["日", "月", "火", "水", "木", "金", "土"][day - 1]).fontWeight(.semibold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(selected ? store.theme.color : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                                    .foregroundStyle(selected ? .white : .primary)
                            }.buttonStyle(.plain).accessibilityLabel("\(["日", "月", "火", "水", "木", "金", "土"][day - 1])曜日")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                if isExisting {
                    Section {
                        Button("削除する", role: .destructive) {
                            confirmDelete = true
                        }
                        .disabled(store.busy)
                    }
                }
            }.scrollContentBackground(.hidden).background { themedBackdrop(store.theme) }
            .navigationTitle(isExisting ? "リマインダーの編集" : "リマインダーの追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("戻る") {
                    if reminder == original { close() } else { confirmDiscard = true }
                }.disabled(store.busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        reminder.title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { if await store.save(reminder) { close() } }
                    }.disabled(reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                }
            }
        }
        .onChange(of: store.pending?.id) { _, id in
            if id != nil {
                nameFocused = false
                confirmDiscard = false
                confirmDelete = false
            }
        }
        .background {
            Color.clear
                .alert("変更を破棄しますか？", isPresented: $confirmDiscard) {
                    Button("破棄する", role: .destructive, action: close)
                    Button("破棄しない", role: .cancel) { confirmDiscard = false }
                }
                .tint(.blue)
        }
        .background {
            Color.clear
                .alert("本当に削除しますか？", isPresented: $confirmDelete) {
                    Button("はい", role: .destructive) {
                        Task { if await store.delete(original) { close() } }
                    }
                    Button("いいえ", role: .cancel) {}
                }
                .tint(.blue)
        }
    }
}

struct StatisticsView: View {
    let store: ReminderStore
    @Binding var showingTheme: Bool
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var selectedDay: HistoryDay?
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 1; return c }
    private var currentMonth: Date { calendar.dateInterval(of: .month, for: Date())?.start ?? Date() }
    private var stats: MonthlyStatistics { store.database.statistics(month: month, now: Date(), calendar: calendar) }
    private var cells: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<1
        let offset = calendar.component(.weekday, from: month) - 1
        return Array(repeating: nil, count: offset) + range.map { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 14) {
                        HStack {
                            Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前の月")
                            Spacer()
                            Text(month.formatted(.dateTime.year().month(.wide))).font(.headline)
                            Spacer()
                            Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("次の月").disabled(month >= currentMonth)
                        }
                        Divider()
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                            ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                                if let date {
                                    Button { selectedDay = HistoryDay(date: date) } label: { dayCell(date) }
                                        .buttonStyle(.plain)
                                } else { Color.clear.frame(height: 36) }
                            }
                        }
                    }.padding(18).card()
                    HStack { Text("月の完了率").font(.headline); Spacer(); Text(stats.percentage.map { "\($0)%" } ?? "—").font(.title2.bold()) }.padding(18).card()
                    HStack(spacing: 12) {
                        countCard("月の完了数", stats.completed)
                        countCard("全期間の完了数", stats.lifetimeCompleted)
                    }
                }.padding(20)
            }.background { themedBackdrop(store.theme) }
            .navigationTitle("履歴")
            .sheet(item: $selectedDay) { day in
                ReminderHistoryView(date: day.date, store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: store.pending?.id, initial: true) { _, id in
                if id != nil { selectedDay = nil }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingTheme = true } label: { Image(systemName: "paintpalette").font(.title2) }.accessibilityLabel("カラーテーマ") } }
        }
    }
    private func dayCell(_ date: Date) -> some View {
        let now = Date()
        let due = store.database.occurrences.filter {
            calendar.isDate($0.scheduledAt, inSameDayAs: date) && $0.scheduledAt <= now
        }
        let futureCount: Int
        if calendar.isDate(date, inSameDayAs: now),
           let day = calendar.dateInterval(of: .day, for: date) {
            let endOfDay = day.end.addingTimeInterval(-1)
            futureCount = store.database.revisions.lazy.filter { revision in
                revision.endsAt == nil && revision.dates(through: endOfDay, startingAt: now)
                    .contains(where: { $0 > now && $0 < day.end })
            }.count
        } else {
            futureCount = 0
        }
        let complete = futureCount == 0 && !due.isEmpty && due.allSatisfy { $0.completedAt != nil }
        return VStack(spacing: 3) {
            Text("\(calendar.component(.day, from: date))").font(.caption2).foregroundStyle(.secondary)
            ZStack {
                Circle().fill(complete ? store.theme.color : Color.gray.opacity(0.17)).frame(width: 25, height: 25)
                if complete { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
            }
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(calendar.isDate(date, inSameDayAs: now) ? store.theme.color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(date.formatted(.dateTime.month().day()))、\(due.filter { $0.completedAt != nil }.count)件完了、\(due.count + futureCount)件予定")
    }
    private func countCard(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text("\(count)件").font(.title.bold()) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).card()
    }
    private func move(_ offset: Int) { if let value = calendar.date(byAdding: .month, value: offset, to: month), value <= currentMonth { month = value } }
}
private struct HistoryDay: Identifiable {
    let date: Date
    var id: Date { date }
}

private struct ReminderHistoryView: View {
    let date: Date
    let store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var historyToDelete: Occurrence?
    private var occurrences: [Occurrence] {
        let calendar = Calendar(identifier: .gregorian)
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var database = store.database
        database.materialize(through: day.end.addingTimeInterval(-1))
        return database.occurrences.filter { $0.scheduledAt >= day.start && $0.scheduledAt < day.end }
    }
    var body: some View {
        NavigationStack {
            List {
                if occurrences.isEmpty {
                    Text("この日の予定はありません").foregroundStyle(.secondary)
                }
                ForEach(occurrences) { occurrence in
                    let showsDate = occurrence.completedAt.map {
                        !Calendar.current.isDate($0, inSameDayAs: occurrence.scheduledAt)
                    } ?? false
                    HStack(spacing: 14) {
                        Image(systemName: occurrence.completedAt == nil ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(occurrence.completedAt == nil ? Color.secondary : store.theme.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(occurrence.title).font(.headline)
                            Text("予定: \(historyTime(occurrence.scheduledAt, showsDate: showsDate))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let completedAt = occurrence.completedAt {
                                Text("完了: \(historyTime(completedAt, showsDate: showsDate))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else if occurrence.scheduledAt <= Date() {
                                Text("未完了")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if occurrence.completedAt != nil {
                                Button("未完了に戻す", systemImage: "arrow.uturn.backward") {
                                    Task { await store.markIncomplete(occurrence) }
                                }
                            } else {
                                Button("完了にする", systemImage: "checkmark") {
                                    Task { await store.complete(occurrence) }
                                }.disabled(occurrence.scheduledAt > Date())
                            }
                            if occurrence.scheduledAt <= Date() {
                                Divider()
                                Button("削除する", systemImage: "trash", role: .destructive) {
                                    historyToDelete = occurrence
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(occurrence.title)の履歴を変更")
                        .disabled(store.busy || store.fatalLoadError)
                    }.padding(.vertical, 6)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if occurrence.scheduledAt <= Date() {
                            Button("削除", role: .destructive) {
                                Task { await store.deleteHistory(occurrence) }
                            }.disabled(store.busy || store.fatalLoadError)
                        }
                    }
                }
            }
            .navigationTitle(date.formatted(.dateTime.month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .alert("本当に削除しますか？", isPresented: Binding(get: { historyToDelete != nil }, set: { if !$0 { historyToDelete = nil } }), presenting: historyToDelete) { occurrence in
            Button("はい", role: .destructive) {
                historyToDelete = nil
                Task { await store.deleteHistory(occurrence) }
            }
            Button("いいえ", role: .cancel) { historyToDelete = nil }
        }
        .alert("確認", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .tint(store.theme.color)
    }
    private func historyTime(_ date: Date, showsDate: Bool) -> String {
        if showsDate { return date.formatted(.dateTime.month().day().hour().minute()) }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
private func themedBackdrop(_ theme: ReminderTheme) -> some View {
    LinearGradient(colors: [Color(.systemBackground), theme.pastel], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
}
private extension View {
    func card() -> some View { background(Color(.secondarySystemGroupedBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 18)).shadow(color: .black.opacity(0.035), radius: 5, y: 3) }
}
