import SwiftUI
import EventKit
import BackgroundTasks

@main struct WhaleApp: App {
    @StateObject private var model = AgentModel()
    var body: some Scene { WindowGroup { HomeView(model: model) } }
}
struct Receipt: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var message: String
}
struct SavedEvent: Codable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarID: String
    var calendarTitle: String? = nil
    var location: String? = nil
    var alarmOffsets: [Double]? = nil
    var notes: String? = nil
    var url: String? = nil
}
struct ScheduleChange: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var before: [SavedEvent]
    var after: [SavedEvent]
}
struct AgendaEntry: Identifiable {
    let run: TaskRun
    let event: SavedEvent
    var id: String { run.id + "|" + event.id }
}
struct TaskRun: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var instruction: String
    var fingerprint: String
    var status = "等待执行"
    var events: [SavedEvent] = []
    var finishedInBackground: Bool? = nil
    var undoneIDs: [String]? = nil
    var failureReason: String? = nil
    var changes: [ScheduleChange]? = nil
}
struct UndoCandidate {
    let originalID: String
    let current: SavedEvent
    let changed: Bool
}
struct UndoReview {
    var candidates: [UndoCandidate] = []
    var unresolved: [String] = []
    var message = ""
}
@MainActor private final class ExecutionContext {
    let startedAt = Date()
    var phase = "启动"
    var expired = false
    var finished = false
    var worker: Task<Void, Never>?
}
@MainActor final class AgentModel: ObservableObject {
    @Published private(set) var previousInput = UserDefaults.standard.string(forKey: "taskDraft") ?? ""
    @Published var instruction = "" {
        didSet {
            // Emptying the editor should not destroy the recoverable last nonempty input.
            if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                previousInput = instruction
                UserDefaults.standard.set(instruction, forKey: "taskDraft")
            }
        }
    }
    func restoreInput() { instruction = previousInput }
    func clearInput() { instruction = "" }
    @Published var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
    @Published var running = false
    @Published var records: [Receipt] = []
    @Published var runs: [TaskRun] = []
    @Published var notice: String?
    @Published var showModificationTasks = false
    @Published var undoReviews: [String: UndoReview] = [:]
    @Published var availableCalendars: [EKCalendar] = []
    @Published private var calendarOverrides: [String: Bool] = UserDefaults.standard.dictionary(forKey: "calendarConflictOverrides") as? [String: Bool] ?? [:]
    func includesCalendar(_ calendar: EKCalendar) -> Bool {
        calendarOverrides[calendar.calendarIdentifier] ?? CalendarConflictPolicy.defaultIncluded(title: calendar.title, readOnly: !calendar.allowsContentModifications)
    }
    func setCalendar(_ calendar: EKCalendar, included: Bool) {
        calendarOverrides[calendar.calendarIdentifier] = included
        UserDefaults.standard.set(calendarOverrides, forKey: "calendarConflictOverrides")
    }
    func refreshCalendars() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        availableCalendars = store.calendars(for: .event).sorted { $0.title < $1.title }
    }
    private var activeRunID: String?
    private let runArchive = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tasks.json")
    private let store = EKEventStore()
    private var worker: Task<Void, Never>?
    private var registeredID: String?
    private let archive = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("receipts.json")
    init() {
        if let data = try? Data(contentsOf: archive), let saved = try? JSONDecoder().decode([Receipt].self, from: data) { records = saved }
        if let data = try? Data(contentsOf: runArchive), let saved = try? JSONDecoder().decode([TaskRun].self, from: data) {
            runs = saved
            for i in runs.indices where ["等待执行", "正在规划", "正在写入"].contains(runs[i].status) { runs[i].status = "中断，请检查日历" }
        }
    }
    private func saveRuns() throws { try JSONEncoder().encode(runs).write(to: runArchive, options: .atomic) }
    private func updateRun(_ body: (inout TaskRun) -> Void) throws {
        guard let id = activeRunID, let i = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[i]); try saveRuns()
    }
    private func taskCalendar() throws -> EKCalendar {
        let title = "日常事务"
        let key = "dailyTasksCalendarID"
        if let id = UserDefaults.standard.string(forKey: key),
           let existing = store.calendar(withIdentifier: id), existing.allowsContentModifications {
            return existing
        }
        let matches = store.calendars(for: .event).filter { $0.title == title && $0.allowsContentModifications }
        let defaultSource = store.defaultCalendarForNewEvents?.source
        if let existing = matches.first(where: { $0.source.sourceIdentifier == defaultSource?.sourceIdentifier }) ?? matches.first {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: key)
            return existing
        }
        // Create in the default account when possible; never fall back to its unrelated calendar.
        var sources: [EKSource] = []
        if let preferred = defaultSource, [.local, .calDAV].contains(preferred.sourceType) { sources.append(preferred) }
        for source in store.sources where [.local, .calDAV].contains(source.sourceType) {
            if !sources.contains(where: { $0.sourceIdentifier == source.sourceIdentifier }) { sources.append(source) }
        }
        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.source = source
            calendar.cgColor = UIColor.systemTeal.cgColor
            do {
                try store.saveCalendar(calendar, commit: true)
                UserDefaults.standard.set(calendar.calendarIdentifier, forKey: key)
                log("已创建日历：日常事务（\(source.title)）")
                return calendar
            } catch { continue }
        }
        throw NSError(domain: "鲸伴", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法创建「日常事务」日历。请先在系统日历中手动新建一个可写的同名日历，再重试。"])
    }
    private func extraFieldsMatch(_ event: EKEvent, _ saved: SavedEvent) -> Bool {
        let alarms = event.alarms ?? []
        return event.location == saved.location && alarms.allSatisfy { $0.absoluteDate == nil && $0.structuredLocation == nil }
            && alarms.map(\.relativeOffset).sorted() == (saved.alarmOffsets ?? []).sorted()
    }
    private func snapshot(_ event: EKEvent) -> SavedEvent {
        SavedEvent(id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate,
                   end: event.endDate, calendarID: event.calendar.calendarIdentifier,
                   calendarTitle: event.calendar.title, location: event.location,
                   alarmOffsets: (event.alarms ?? []).map(\.relativeOffset), notes: event.notes,
                   url: event.url?.absoluteString)
    }
    private func unchanged(_ event: EKEvent, _ saved: SavedEvent) -> Bool {
        event.title == saved.title && event.startDate == saved.start && event.endDate == saved.end
        && event.calendar.calendarIdentifier == saved.calendarID && event.notes == saved.notes
        && event.url?.absoluteString == saved.url && extraFieldsMatch(event, saved)
    }
    func prepareUndo(_ run: TaskRun) async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            guard try await store.requestFullAccessToEvents() else {
                throw NSError(domain: "鲸伴", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法读取日历，请检查日历权限。"])
            }
            store.refreshSourcesIfNecessary()
            var review = UndoReview()
            // Search each year separately: EventKit predicates have a bounded date range.
            let anchor = run.events.map(\.start).min() ?? run.date
            var pool: [EKEvent] = []
            for year in -1...2 {
                let start = Calendar.current.date(byAdding: .year, value: year, to: anchor)!
                let end = Calendar.current.date(byAdding: .year, value: 1, to: start)!
                pool += store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                    .filter { UndoIdentity.belongs(notes: $0.notes, runID: run.id) }
            }
            var used = Set<String>()
            for saved in run.events where !(run.undoneIDs ?? []).contains(saved.id) {
                let itemMarker = saved.notes?.components(separatedBy: "\n").first { $0.hasPrefix("鲸伴日程 · ") }
                let found: EKEvent?
                if let direct = store.event(withIdentifier: saved.id), UndoIdentity.belongs(notes: direct.notes, runID: run.id) {
                    found = direct
                } else {
                    let matches = pool.filter { event in
                        if let itemMarker { return (event.notes ?? "").components(separatedBy: "\n").contains(itemMarker) }
                        return event.title == saved.title && event.notes == saved.notes && event.url?.absoluteString == saved.url
                    }
                    let unique = Dictionary(grouping: matches, by: { $0.eventIdentifier ?? "" })
                    found = unique.count == 1 ? unique.values.first?.first : nil
                }
                guard let event = found, let id = event.eventIdentifier, !id.isEmpty,
                      !event.hasRecurrenceRules, event.calendar.allowsContentModifications,
                      used.insert(id).inserted else {
                    review.unresolved.append(saved.title)
                    continue
                }
                review.candidates.append(UndoCandidate(originalID: saved.id, current: snapshot(event), changed: !unchanged(event, saved)))
            }
            review.message = "已找到 \(review.candidates.count) 条，其中 \(review.candidates.filter(\.changed).count) 条已变更。未定位 \(review.unresolved.count) 条。"
            undoReviews[run.id] = review
        } catch {
            undoReviews[run.id] = UndoReview(message: "核对失败：" + error.localizedDescription)
        }
    }
    func acknowledgeMissing(_ run: TaskRun) {
        guard !running, let review = undoReviews[run.id], review.candidates.isEmpty,
              !review.unresolved.isEmpty, let i = runs.firstIndex(where: { $0.id == run.id }) else { return }
        let previous = runs[i]
        runs[i].undoneIDs = runs[i].events.map(\.id)
        runs[i].status = "已撤销"
        do {
            try saveRuns()
            undoReviews.removeValue(forKey: run.id)
            log("用户确认未定位的 \(review.unresolved.count) 条日程已手动删除；已结束撤销记录。未额外删除日历数据。")
        } catch {
            runs[i] = previous
            undoReviews[run.id]?.message = "保存确认失败：" + error.localizedDescription
        }
    }
    func undo(_ run: TaskRun) async {
        guard !running, let review = undoReviews[run.id], !review.candidates.isEmpty else { return }
        running = true
        defer { running = false }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw PlanError.invalid }
            // Recheck the exact preview before staging deletions, including any moved dates.
            var events: [EKEvent] = []
            for candidate in review.candidates {
                guard let event = store.event(withIdentifier: candidate.current.id),
                      !event.hasRecurrenceRules, event.calendar.allowsContentModifications,
                      unchanged(event, candidate.current) else {
                    undoReviews[run.id] = UndoReview(message: "日历在确认期间发生变化，请重新核对后撤销。")
                    return
                }
                events.append(event)
            }
            for event in events { try store.remove(event, span: .thisEvent, commit: false) }
            try store.commit()
            guard let i = runs.firstIndex(where: { $0.id == run.id }) else { return }
            runs[i].undoneIDs = Array(Set((runs[i].undoneIDs ?? []) + review.candidates.map(\.originalID)))
            runs[i].status = review.unresolved.isEmpty ? "已撤销" : "部分撤销，待核对"
            try saveRuns()
            undoReviews[run.id] = UndoReview(unresolved: review.unresolved,
                message: "已删除 \(events.count) 条。" + (review.unresolved.isEmpty ? "撤销完成。" : "其余未定位条目未处理，可重新核对。"))
            log("已撤销本次创建的 \(events.count) 条日程；未定位 \(review.unresolved.count) 条。")
        } catch {
            store.reset()
            undoReviews[run.id] = UndoReview(message: "撤销未能确认完成，请重新核对：" + error.localizedDescription)
        }
    }
    func log(_ message: String) {
        records.insert(Receipt(message: message), at: 0)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: archive, options: .atomic) }
    }
    func retry(_ run: TaskRun) async {
        guard let latest = runs.first(where: { $0.id == run.id }),
              latest.status == "失败（未写入）", latest.events.isEmpty else { return }
        guard Calendar.current.isDateInToday(latest.date) else {
            notice = "这是之前日期的任务。为避免「明天」「下周」含义变化，请点「载入编辑」核对日期后再提交。"
            return
        }
        await start(probe: latest.instruction == "后台执行验证", textOverride: latest.instruction)
    }
    func start(probe: Bool, textOverride: String? = nil) async {
        let instruction = textOverride ?? self.instruction
        guard !running else { return }
        if !probe && TaskIntentGuard.isModification(instruction) {
            showModificationTasks = true
            notice = "这看起来是在修改已有日程，本次不会新建。请在任务记录中找到原活动，点「修改日程时间」，选择新时间并确认。同名活动需要你选择，避免改错。"
            return
        }
        guard probe || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "请先输入要安排的任务。"
            return
        }
        let normalized = instruction.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        let fingerprint = TimeZone.current.identifier + "|" + String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + "|" + normalized
        if !probe, runs.contains(where: { $0.fingerprint == fingerprint && $0.status != "已撤销" && $0.status != "失败（未写入）" }) {
            notice = "今天已提交过相同内容，请查看任务卡片。需要重新安排时，先撤销原任务。"; return
        }
        running = true
        do {
            guard try await store.requestFullAccessToEvents() else { throw NSError(domain: "鲸伴", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要日历权限才能检查冲突和写入日程。"] ) }
            refreshCalendars()
            if !probe && endpoint.isEmpty { throw NSError(domain: "鲸伴", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先填写 Mac 服务地址；或先运行后台验证。"] ) }
            UserDefaults.standard.set(endpoint, forKey: "endpoint")
            let identifier = "ai.whale.companion.job." + UUID().uuidString
            let text = instruction
            let run = TaskRun(instruction: probe ? "后台执行验证" : text, fingerprint: probe ? UUID().uuidString : fingerprint)
            runs.insert(run, at: 0); activeRunID = run.id
            try saveRuns()
            let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in self?.execute(continued, runID: run.id, probe: probe, instruction: text) }
            }
            guard accepted else { throw NSError(domain: "鲸伴", code: 3, userInfo: [NSLocalizedDescriptionKey: "后台任务注册失败。"] ) }
            registeredID = identifier
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "鲸伴正在安排事务", subtitle: "可以继续使用其他 App")
            request.strategy = .fail
            try BGTaskScheduler.shared.submit(request)
            log("任务已提交，等待系统启动。")
        } catch { try? updateRun { $0.status = "失败（未写入）"; $0.failureReason = error.localizedDescription }; running = false; log(error.localizedDescription); cleanup() }
    }
    private func cleanup() {
        registeredID = nil
        activeRunID = nil
    }
    private func execute(_ background: BGContinuedProcessingTask, runID: String, probe: Bool, instruction: String) {
        guard activeRunID == runID, worker == nil else {
            background.setTaskCompleted(success: false)
            return
        }
        let context = ExecutionContext()
        background.progress.totalUnitCount = 4
        background.expirationHandler = {
            Task { @MainActor in
                guard !context.finished else { return }
                context.expired = true
                context.worker?.cancel()
            }
        }
        worker = Task { @MainActor in
            defer {
                context.finished = true
                context.worker = nil
                background.expirationHandler = nil
                running = false; worker = nil; cleanup()
            }
            do {
                log(probe ? "后台验证已开始：等待 12 秒，请切去其他 App。" : "正在理解任务。")
                try updateRun { $0.status = "正在规划" }
                let plan: TaskPlan
                context.phase = probe ? "后台验证等待" : "等待 Mac 模型服务"
                if probe {
                    try await Task.sleep(for: .seconds(12))
                    let start = Date().addingTimeInterval(3600)
                    plan = TaskPlan(items: [WorkItem(id: "probe", title: "鲸伴后台验证", minutes: 5)], start: start, deadline: start.addingTimeInterval(86400))
                } else {
                    guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/plan") else { throw URLError(.badURL) }
                    var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 85
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["instruction": instruction, "now": ISO8601DateFormatter().string(from: Date()), "timezone": TimeZone.current.identifier])
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "鲸伴", code: 4, userInfo: [NSLocalizedDescriptionKey: "模型服务失败，请查看 Mac 服务日志。"] ) }
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    plan = try decoder.decode(TaskPlan.self, from: data)
                }
                try Task.checkCancellation()
                background.progress.completedUnitCount = 1
                context.phase = "检查日历与排程"
                log("模型规划已返回，开始检查日历。")
                store.refreshSourcesIfNecessary()
                let predicate = store.predicateForEvents(withStart: plan.start, end: plan.deadline, calendars: nil)
                refreshCalendars()
                let excluded = availableCalendars.filter { !includesCalendar($0) }.map(\.title)
                if !excluded.isEmpty { log("以下日历不参与冲突检查：" + excluded.joined(separator: "、")) }
                let busy = store.events(matching: predicate).filter { $0.availability != .free && includesCalendar($0.calendar) }.map { TimeSlot(start: $0.startDate, end: $0.endDate, label: ($0.title ?? "无标题") + " · " + $0.calendar.title + ($0.isAllDay ? "（全天）" : "")) }
                let scheduled = try Planner.schedule(plan, busy: busy)
                let calendar = try taskCalendar()
                log("目标日历：\(calendar.title)")
                background.progress.completedUnitCount = 2
                log("已复查日历，准备创建 \(scheduled.count) 项。")
                guard let runID = activeRunID else { throw PlanError.invalid }
                try updateRun { $0.status = "正在写入" }
                context.phase = "写入日历"
                var created: [EKEvent] = []
                do {
                    for entry in scheduled {
                        try Task.checkCancellation()
                        let event = EKEvent(eventStore: store)
                        event.title = entry.item.title; event.startDate = entry.slot.start; event.endDate = entry.slot.end
                        event.calendar = calendar
                        event.location = entry.item.location
                        event.alarms = Array(Set(entry.item.reminderMinutes ?? [])).sorted().map { EKAlarm(relativeOffset: -Double($0 * 60)) }
                        let note = entry.item.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        event.notes = (note.isEmpty ? "" : note + "\n\n") + "鲸伴任务 · " + runID + "\n鲸伴日程 · " + UUID().uuidString
                        if let link = entry.item.url, !link.isEmpty {
                            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw PlanError.invalid }
                            event.url = url
                        }
                        try store.save(event, span: .thisEvent, commit: false)
                        created.append(event)
                    }
                    try store.commit()
                } catch { store.reset(); throw error }
                try updateRun { run in
                    run.events = created.map { SavedEvent(id: $0.eventIdentifier ?? "", title: $0.title ?? "日程", start: $0.startDate, end: $0.endDate, calendarID: $0.calendar.calendarIdentifier, calendarTitle: $0.calendar.title, location: $0.location, alarmOffsets: ($0.alarms ?? []).map(\.relativeOffset), notes: $0.notes, url: $0.url?.absoluteString) }
                }
                background.progress.completedUnitCount = 3
                context.phase = "回读验证"
                let verified = created.filter { event in
                    guard let id = event.eventIdentifier, let saved = store.event(withIdentifier: id) else { return false }
                    return saved.title == event.title && saved.startDate == event.startDate && saved.endDate == event.endDate && saved.notes == event.notes && saved.url == event.url && saved.location == event.location && (saved.alarms ?? []).map(\.relativeOffset).sorted() == (event.alarms ?? []).map(\.relativeOffset).sorted()
                }
                guard verified.count == created.count else { throw NSError(domain: "鲸伴", code: 6, userInfo: [NSLocalizedDescriptionKey: "可能已写入部分日程，但回读验证未通过，请检查系统日历，勿直接重复运行。"] ) }
                for event in verified { log("已验证：\(event.title ?? "日程") · \(event.startDate.formatted(date: .abbreviated, time: .shortened))") }
                log("完成时 App 状态：\(UIApplication.shared.applicationState == .background ? "后台" : "前台")")
                try updateRun { run in
                    run.status = "已完成"
                    run.finishedInBackground = UIApplication.shared.applicationState == .background
                }
                background.progress.completedUnitCount = 4
                background.setTaskCompleted(success: true)
            } catch {
                try? updateRun { run in run.status = (run.status == "正在写入" || !run.events.isEmpty) ? "结果待核对" : "失败（未写入）" }
                let elapsed = Int(Date().timeIntervalSince(context.startedAt))
                let nsError = error as NSError
                let reason: String
                if context.expired {
                    reason = "iOS 已结束本次后台执行（可能是系统限制或任务被停止）"
                } else if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                    reason = "请求被取消，未收到后台到期通知"
                } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    reason = "等待模型服务超时，请检查 Mac 服务和网络"
                } else {
                    reason = error.localizedDescription
                }
                let needsReview = runs.first(where: { $0.id == runID })?.status == "结果待核对"
                let failure = "\(reason)。阶段：\(context.phase)，耗时 \(elapsed) 秒。\(needsReview ? "可能已写入，请先核对日历，勿重复提交。" : "本次未写入日程。") [\(nsError.domain):\(nsError.code)]"
                try? updateRun { $0.failureReason = failure }
                log(failure)
                background.setTaskCompleted(success: false)
            }
        }
        context.worker = worker
    }
}
struct MoveSelection: Identifiable {
    let id = UUID()
    let run: TaskRun
    let eventID: String?
}
struct HomeView: View {
    @ObservedObject var model: AgentModel
    private enum InputField: Hashable { case instruction, endpoint }
    @FocusState private var focusedField: InputField?
    @State private var pendingUndo: TaskRun?
    @State private var expandedRuns: Set<String> = []
    @State private var editCandidate: TaskRun?
    @State private var rescheduleRun: MoveSelection?
    @State private var scrollTarget: String?
    @State private var agendaSearch = ""
    @State private var agendaLimit = 10
    private var agenda: [AgendaEntry] {
        var entries: [AgendaEntry] = []
        for run in model.runs where run.status == "已完成" {
            for event in run.events {
                guard event.end > Date(), !event.title.hasPrefix("出发预留 · "),
                      !(run.undoneIDs ?? []).contains(event.id) else { continue }
                let searchable = event.title + " " + (event.location ?? "")
                guard agendaSearch.isEmpty || searchable.localizedCaseInsensitiveContains(agendaSearch) else { continue }
                entries.append(AgendaEntry(run: run, event: event))
            }
        }
        return entries.sorted { left, right in
            if left.event.start == right.event.start { return left.id < right.id }
            return left.event.start < right.event.start
        }
    }
    @State private var section = "日程助手"
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Picker("功能板块", selection: $section) {
                        ForEach(["日程助手", "出行准备", "任务记录", "设置"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                }
                if section == "出行准备" { TravelPanel(model: model) { section = "日程助手" } }
                if section == "日程助手" {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "water.waves").font(.largeTitle).foregroundStyle(.cyan)
                        Text("安排好日程，专注眼前的事。").font(.title2.bold())
                        Text("把计划交给鲸伴，按你的节奏执行。").foregroundStyle(.secondary)
                    }.padding(.vertical)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.instruction)
                            .frame(minHeight: 120)
                            .focused($focusedField, equals: .instruction)
                            .accessibilityLabel("任务内容")
                        if model.instruction.isEmpty {
                            Text("请输入今日任务，或告诉我某一天的安排…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    HStack {
                        if model.instruction.isEmpty && !model.previousInput.isEmpty {
                            Button("恢复上次输入") { model.restoreInput(); focusedField = .instruction }
                        }
                        if !model.instruction.isEmpty {
                            Button("一键清空") { model.clearInput(); focusedField = .instruction }
                        }
                    }.buttonStyle(.borderless)
                    Button("安排这些事情") { focusedField = nil; Task { await model.start(probe: false) } }.disabled(model.running || model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("交代任务") } footer: { Text("新日程写入「日常事务」日历，首次执行时自动创建。开始即授权创建所描述的日程。已有日程不会被修改。支持日历提前提醒；实际提醒由系统日历及通知设置控制。路程时长用独立出发预留日程记录。") }
                Section {
                    TextField("搜索活动名称或地点", text: $agendaSearch)
                        .onChange(of: agendaSearch) { agendaLimit = 10 }
                    if agenda.isEmpty { Text("暂无符合条件的待进行活动").foregroundStyle(.secondary) }
                    ForEach(Array(agenda.prefix(agendaLimit))) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.event.title).font(.headline)
                            Text(entry.event.start.formatted() + " — " + entry.event.end.formatted(date: .omitted, time: .shortened)).font(.subheadline)
                            if let location = entry.event.location, !location.isEmpty { Label(location, systemImage: "mappin").font(.caption) }
                            if let travel = entry.run.events.first(where: { $0.title == "出发预留 · " + entry.event.title && $0.end == entry.event.start }) {
                                Text("出发预留：" + travel.start.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("修改时间") { rescheduleRun = MoveSelection(run: entry.run, eventID: entry.event.id) }
                                Button("查看原任务") { expandedRuns.insert(entry.run.id); section = "任务记录"; scrollTarget = entry.run.id }
                            }.buttonStyle(.borderless).disabled(model.running)
                        }.padding(.vertical, 4)
                    }
                    if agenda.count > agendaLimit { Button("显示更多（还有 \(agenda.count - agendaLimit) 项）") { agendaLimit += 10 } }
                } header: { Text("已安排 · 按时间排序") }
                footer: { Text("显示鲸伴记录中尚未结束的活动，关联出发预留合并展示。系统日历中的手动更改不会自动同步到此列表；修改前会再次核对。") }
                }
                if section == "任务记录" {
                Section("我的任务") {
                    if model.runs.isEmpty { Text("新任务的结果会按次保存在这里").foregroundStyle(.secondary) }
                    ForEach(model.runs) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup(isExpanded: Binding(get: { expandedRuns.contains(run.id) }, set: { expanded in
                                if expanded { expandedRuns.insert(run.id) } else { expandedRuns.remove(run.id); if pendingUndo?.id == run.id { pendingUndo = nil } }
                            })) {
                            Text(run.instruction).font(.subheadline).textSelection(.enabled)
                            if let reason = run.failureReason {
                                Text("失败原因：" + reason).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
                            } else if run.status == "失败（未写入）" {
                                Text("这条旧记录没有保存独立失败原因，请查看下方对应时间的执行回执。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if run.status == "失败（未写入）" && run.events.isEmpty {
                                    Button("一键重试") { focusedField = nil; Task { await model.retry(run) } }
                                }
                                Button("载入编辑") {
                                    if model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.instruction == run.instruction {
                                        model.instruction = run.instruction; section = "日程助手"; focusedField = .instruction
                                    } else { editCandidate = run }
                                }
                            }.buttonStyle(.borderless).disabled(model.running)
                            ForEach(run.events) { event in
                                VStack(alignment: .leading) {
                                    Text(event.title).font(.subheadline.bold())
                                    if let location = event.location, !location.isEmpty { Label(location, systemImage: "mappin").font(.caption) }
                                    if let alarms = event.alarmOffsets, !alarms.isEmpty {
                                        Label(alarms.sorted().map { $0 == 0 ? "开始时提醒" : "提前\(Int(-$0 / 60))分钟" }.joined(separator: "、"), systemImage: "bell").font(.caption)
                                    }
                                    if let calendar = event.calendarTitle { Label(calendar, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
                                    if let notes = event.notes?.components(separatedBy: "\n\n鲸伴任务 · ").first, !notes.hasPrefix("鲸伴任务 · "), !notes.isEmpty {
                                        Text(notes).font(.caption).textSelection(.enabled)
                                    }
                                    if let raw = event.url { Text(verbatim: raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let changes = run.changes, !changes.isEmpty {
                                DisclosureGroup("改期历史（\(changes.count)次）") {
                                    ForEach(changes.reversed()) { change in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(change.date.formatted()).font(.caption).foregroundStyle(.secondary)
                                            ForEach(Array(change.before.enumerated()), id: \.offset) { offset, before in
                                                if offset < change.after.count {
                                                    Text(before.title).font(.caption.bold())
                                                    Text(before.start.formatted() + " → " + change.after[offset].start.formatted()).font(.caption)
                                                }
                                            }
                                        }.padding(.vertical, 4)
                                    }
                                }
                            }
                            Text(run.date.formatted()).font(.caption2).foregroundStyle(.secondary)
                            if run.status == "已完成" {
                                Button("修改日程时间") { rescheduleRun = MoveSelection(run: run, eventID: nil) }
                                    .buttonStyle(.borderless).disabled(model.running)
                            }
                            if ["已完成", "部分撤销，待核对", "结果待核对"].contains(run.status) {
                                if pendingUndo?.id == run.id {
                                    if let review = model.undoReviews[run.id] {
                                        Text(review.message).font(.subheadline)
                                        ForEach(review.candidates, id: \.originalID) { candidate in
                                            Text("\(candidate.changed ? "已变更 · " : "")\(candidate.current.title)：\(candidate.current.start.formatted())")
                                                .font(.caption)
                                        }
                                        if !review.unresolved.isEmpty {
                                            Text("未定位：" + review.unresolved.joined(separator: "、") + "。可能已手动删除、未同步或移动到检索范围外；不会阻止其他条目的撤销。检索范围为原任务最早日期前一年至后三年。")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if review.candidates.isEmpty && !review.unresolved.isEmpty {
                                            Button("我确认未定位的条目已手动删除，结束撤销") {
                                                model.acknowledgeMissing(run); pendingUndo = nil
                                            }.buttonStyle(.bordered).disabled(model.running)
                                        }
                                        if !review.candidates.isEmpty {
                                            Button("确认删除以上 \(review.candidates.count) 条（含已变更项）", role: .destructive) {
                                                Task { await model.undo(run) }
                                            }.buttonStyle(.bordered).disabled(model.running)
                                        }
                                    }
                                    HStack {
                                        Button("重新核对") { Task { await model.prepareUndo(run) } }
                                        Button("收起", role: .cancel) { pendingUndo = nil }
                                    }.buttonStyle(.borderless).disabled(model.running)
                                } else {
                                    Button("撤销本次创建", role: .destructive) {
                                        focusedField = nil; pendingUndo = run
                                        Task { await model.prepareUndo(run) }
                                    }.buttonStyle(.borderless).disabled(model.running)
                                }
                            }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(run.status).font(.headline)
                                        if let background = run.finishedInBackground {
                                            Text(background ? "后台完成" : "前台完成").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(run.instruction).font(.subheadline).lineLimit(1)
                                    Text(run.date.formatted()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 6).id(run.id)
                    }
                }
                }
                if section == "设置" {
                Section("真机验证") {
                    Button("运行后台验证（创建一条 5 分钟日程）") { focusedField = nil; Task { await model.start(probe: true) } }.disabled(model.running)
                    Text("开始后切到其他 App。12 秒后尝试写入一条测试日程，并记录完成时是否处于后台。系统可能显示任务进度。").font(.caption).foregroundStyle(.secondary)
                    if model.running { ProgressView("任务执行中…") }
                }
                Section {
                    DisclosureGroup("参与冲突检查的日历") {
                        if model.availableCalendars.isEmpty { Text("授权日历后显示列表").foregroundStyle(.secondary) }
                        ForEach(model.availableCalendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: Binding(get: { model.includesCalendar(calendar) }, set: { model.setCalendar(calendar, included: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                    Text(calendar.source.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(model.running)
                        }
                        Button("刷新日历列表") { model.refreshCalendars() }.disabled(model.running)
                    }
                } footer: { Text("关闭的日历仍保留在系统日历中，但不会阻挡排程。按名称识别的只读节假日日历默认关闭，其他日历默认开启；可手动调整。") }
                Section("Mac 模型服务") {
                    TextField("http://你的 Mac 局域网地址:8765", text: $model.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .endpoint)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                Section("密钥管理") {
                    Text("在 Mac 的 configure.command 中保存、更换或删除密钥。密钥保存在 Mac 钥匙串，手机不保存服务商 Key。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                if section == "任务记录" {
                Section("执行回执") {
                    if model.records.isEmpty { Text("真实执行结果会显示在这里").foregroundStyle(.secondary) }
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.message)
                            Text(record.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                }
            }
            .sheet(item: $rescheduleRun) { selection in RescheduleView(model: model, run: selection.run, initialEventID: selection.eventID) }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                await Task.yield()
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .alert("提示", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("知道了", role: .cancel) { model.notice = nil }
            } message: { Text(model.notice ?? "") }
            .alert("替换当前草稿？", isPresented: Binding(get: { editCandidate != nil }, set: { if !$0 { editCandidate = nil } })) {
                Button("载入并替换") {
                    if let run = editCandidate { model.instruction = run.instruction; section = "日程助手"; focusedField = .instruction }
                    editCandidate = nil
                }
                Button("保留草稿", role: .cancel) { editCandidate = nil }
            } message: { Text("输入框已有内容。载入历史任务会替换当前草稿，但不会修改日历。") }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { model.refreshCalendars() }
            .onChange(of: model.showModificationTasks) {
                if model.showModificationTasks { section = "任务记录"; model.showModificationTasks = false }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.cyan)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(section).font(.headline).foregroundStyle(.blue)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                        .overlay(Capsule().stroke(Color.blue.opacity(0.22), lineWidth: 1))
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .accessibilityLabel("完成输入并收起键盘")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if focusedField != nil {
                        Button("完成") { focusedField = nil }
                    }
                }
            }
        }
    }
}
}

private struct TravelPlace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let location: String
    let citycode: String
    let address: String
}
private struct TravelRoute: Codable, Identifiable {
    let id: String
    let minutes: Int
    let steps: [String]
}
private struct PlacesResponse: Decodable { let places: [TravelPlace] }
private struct RoutesResponse: Decodable {
    let routes: [TravelRoute]
    let queriedAt: String
    let source: String
    let notice: String
    let emptyReason: String?
    let mode: String?
}
private struct TravelServiceError: Decodable { let error: String }

struct TravelPanel: View {
    @ObservedObject var model: AgentModel
    var onDraft: () -> Void
    @AppStorage("travelCity") private var city = ""
    @AppStorage("travelOriginText") private var originText = ""
    @State private var destinationText = ""
    @State private var origin: TravelPlace?
    @State private var destination: TravelPlace?
    @State private var candidates: [TravelPlace] = []
    @State private var choosingOrigin = true
    @State private var mode = "transit"
    @State private var routes: RoutesResponse?
    @State private var querying = false
    @State private var message = ""
    @State private var arrival = Date().addingTimeInterval(86400)
    @State private var duration = 60
    @State private var buffer = 15
    @State private var draft: String?
    @FocusState private var editing: Bool

    private func request<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        let base = model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            throw NSError(domain: "鲸伴", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先在设置中填写 Mac 服务地址。"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let explanation = (try? JSONDecoder().decode(TravelServiceError.self, from: data).error) ?? "查询失败，请确认 Mac 服务已更新并重新启动。"
            throw NSError(domain: "鲸伴", code: 2, userInfo: [NSLocalizedDescriptionKey: explanation])
        }
        return try JSONDecoder().decode(type, from: data)
    }
    private func search(originSide: Bool) async {
        guard !querying else { return }
        querying = true; editing = false; message = ""; candidates = []; choosingOrigin = originSide
        defer { querying = false }
        do {
            let response = try await request("/travel/places", body: ["city": city, "query": originSide ? originText : destinationText], as: PlacesResponse.self)
            candidates = response.places
            message = candidates.isEmpty ? "没有找到地点，请补充城市和更准确的名称。" : "请选择准确的\(originSide ? "起点" : "终点")。"
        } catch { message = error.localizedDescription }
    }
    private func queryRoutes() async {
        guard !querying, let origin, let destination else { return }
        querying = true; editing = false; routes = nil; message = ""
        defer { querying = false }
        do {
            routes = try await request("/travel/route", body: [
                "mode": mode,
                "origin": ["location": origin.location, "citycode": origin.citycode],
                "destination": ["location": destination.location, "citycode": destination.citycode]], as: RoutesResponse.self)
            if routes?.routes.isEmpty == true { message = routes?.emptyReason ?? "接口未返回路线，请调整地点或切换出行方式。" }
        } catch { message = error.localizedDescription }
    }
    private func highlights(_ route: TravelRoute) -> [String] {
        if mode == "transit" {
            let lines = route.steps.filter { $0.contains("：") && $0.contains(" → ") }
            if !lines.isEmpty { return lines }
        }
        return [mode == "driving" ? "驾车前往目的地" : "步行前往目的地"]
    }
    private var mapURL: URL? {
        guard let origin, let destination else { return nil }
        var parts = URLComponents(string: "https://uri.amap.com/navigation")!
        parts.queryItems = [
            URLQueryItem(name: "from", value: origin.location + "," + origin.name.replacingOccurrences(of: ",", with: " ")),
            URLQueryItem(name: "to", value: destination.location + "," + destination.name.replacingOccurrences(of: ",", with: " ")),
            URLQueryItem(name: "mode", value: mode == "driving" ? "car" : mode == "walking" ? "walk" : "bus"),
            URLQueryItem(name: "src", value: "WhaleCompanion"),
            URLQueryItem(name: "callnative", value: "1")]
        return parts.url
    }
    private func makeDraft(_ route: TravelRoute) {
        guard let origin, let destination, let routes else { return }
        guard arrival > Date(), route.minutes + buffer <= 240 else {
            message = "请选未来时间；当前日程助手支持最多 240 分钟的路程加缓冲。"; return
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let start = formatter.string(from: arrival)
        draft = "\(start)在\(destination.name)参加活动，时长\(duration)分钟。路程\(route.minutes + buffer)分钟（含提前到达\(buffer)分钟），提前\(route.minutes + buffer)分钟提醒。\n备注：从\(origin.name)（\(origin.address)）出发，目的地\(destination.address)。出行方式\(mode == "driving" ? "驾车" : mode == "walking" ? "步行" : "公交/地铁")，高德地图查询于\(routes.queriedAt)，预计路程\(route.minutes)分钟，另留\(buffer)分钟提前到达。路线：\(highlights(route).joined(separator: "；"))。出发前需重新核对班次。\n路线链接：\(mapURL?.absoluteString ?? "")"
    }
    var body: some View {
        Section {
            Text("先选准确地点，再查询公交、驾车或步行方案。查询会将城市、地点或坐标发送给高德地图。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("城市，例如上海", text: $city).focused($editing)
                .onChange(of: city) { origin = nil; destination = nil; candidates = []; routes = nil }
            TextField("出发地点", text: $originText).focused($editing)
                .onChange(of: originText) { origin = nil; candidates = []; routes = nil }
            Button("搜索起点") { Task { await search(originSide: true) } }.buttonStyle(.borderless)
            if let origin { Label(origin.name + " · " + origin.address, systemImage: "mappin.circle.fill").font(.caption) }
            TextField("目的地点", text: $destinationText).focused($editing)
                .onChange(of: destinationText) { destination = nil; candidates = []; routes = nil }
            Button("搜索终点") { Task { await search(originSide: false) } }.buttonStyle(.borderless)
            if let destination { Label(destination.name + " · " + destination.address, systemImage: "flag.fill").font(.caption) }
        } header: { Text("地点确认") }
        .disabled(querying)
        if !candidates.isEmpty {
            Section(choosingOrigin ? "选择起点" : "选择终点") {
                ForEach(candidates) { place in
                    Button {
                        if choosingOrigin { origin = place } else { destination = place }
                        routes = nil; candidates = []; message = "地点已选择。"
                    } label: {
                        VStack(alignment: .leading) { Text(place.name); Text(place.address).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.borderless)
                }
            }
        }
        Section("路线查询") {
            Picker("出行方式", selection: $mode) {
                Text("公交 / 地铁").tag("transit")
                Text("驾车").tag("driving")
                Text("步行").tag("walking")
            }.pickerStyle(.segmented).disabled(querying)
                .onChange(of: mode) { routes = nil; message = "" }
            Button("查询路线方案") { Task { await queryRoutes() } }
                .buttonStyle(.borderless).disabled(querying || origin == nil || destination == nil)
            if querying { ProgressView("正在查询…") }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("首版使用当前查询的路线耗时；查询期间请留在 App。尚未配置高德 Key 时，请在 Mac 运行 configure.command。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let routes, !routes.routes.isEmpty {
            Section("到达与活动安排") {
                DatePicker("活动开始时间", selection: $arrival, in: Date()...)
                Stepper("提前到达 \(buffer) 分钟", value: $buffer, in: 0...60, step: 5)
                Stepper("活动时长 \(duration) 分钟", value: $duration, in: 15...240, step: 15)
                Text(routes.source + " · 查询时间 " + routes.queriedAt).font(.caption)
                Text(routes.notice).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(routes.routes) { route in
                Section("方案 \((Int(route.id) ?? 0) + 1) · 约 \(route.minutes) 分钟") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(origin?.name ?? "起点", systemImage: "circle.fill").foregroundStyle(.teal)
                        ForEach(Array(highlights(route).enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: mode == "transit" ? "tram.fill" : mode == "driving" ? "car.fill" : "figure.walk")
                                    .foregroundStyle(.secondary)
                                Text(step).font(.subheadline)
                            }.padding(.leading, 8)
                        }
                        Label(destination?.name ?? "终点", systemImage: "flag.fill").foregroundStyle(.teal)
                    }.padding(.vertical, 6)
                    Text("路线示意，非地理地图；步行接驳及转弯细节见下方详情或高德。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = mapURL {
                        Link(destination: url) { Label("在高德查看路线", systemImage: "map") }
                            .buttonStyle(.borderless)
                        Text("按相同起终点与出行方式重新查询，可能与此方案不同。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("查看完整路线指引（\(route.steps.count)条）") {
                        Text(route.steps.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }
                    Text("建议出发：" + arrival.addingTimeInterval(-Double((route.minutes + buffer) * 60)).formatted()).font(.subheadline.bold())
                    Button("载入日程草稿") { makeDraft(route) }.buttonStyle(.borderless).disabled(model.running)
                }
            }
        }
        Section {
            Text("这里只查询和生成草稿；切到日程助手提交后，才会创建活动及出发预留日程。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("载入出行日程草稿？", isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            Button("载入") {
                if let draft { model.instruction = draft }
                draft = nil; onDraft()
            }
            Button("取消", role: .cancel) { draft = nil }
        } message: { Text("将替换日程助手中的当前草稿。你可以修改活动名称、时间和路线备注，再提交。") }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if editing { Button("完成") { editing = false } }
            }
        }
    }
}

struct MovePreview {
    let runID: String
    let events: [SavedEvent]
    let delta: TimeInterval
    let conflicts: [String]
    let suggestions: [Date]
}
extension AgentModel {
    private func moveError(_ message: String) -> NSError {
        NSError(domain: "鲸伴", code: 30, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func moveBusy(start: Date, end: Date, excluding ids: Set<String>) -> [TimeSlot] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !ids.contains($0.eventIdentifier ?? "") && $0.availability != .free && includesCalendar($0.calendar) }
            .map { TimeSlot(start: $0.startDate, end: $0.endDate, label: ($0.title ?? "日程") + " · " + $0.calendar.title) }
    }
    func previewMove(runID: String, eventID: String, to newStart: Date) async throws -> MovePreview {
        guard !running else { throw moveError("请等待当前任务完成。") }
        running = true; defer { running = false }
        guard try await store.requestFullAccessToEvents(),
              let run = runs.first(where: { $0.id == runID && $0.status == "已完成" }),
              let selected = run.events.first(where: { $0.id == eventID }) else { throw moveError("任务或日历权限不可用。") }
        store.refreshSourcesIfNecessary()
        // Legacy events have no group ID; require exact generated title and adjacent time.
        let travel = run.events.filter { $0.title == "出发预留 · " + selected.title && $0.end == selected.start }
        guard travel.count <= 1 else { throw moveError("存在多个出发预留，请先核对日历。") }
        let group = travel + [selected]
        for saved in group {
            guard let event = store.event(withIdentifier: saved.id), !event.hasRecurrenceRules,
                  event.calendar.allowsContentModifications,
                  UndoIdentity.belongs(notes: event.notes, runID: runID), unchanged(event, saved) else {
                throw moveError("日程已在系统日历中更改或删除。为保留外部改动，本次未修改；请先核对原日程。")
            }
        }
        let delta = newStart.timeIntervalSince(selected.start)
        let earliest = group.map(\.start).min()!.addingTimeInterval(delta)
        let latest = selected.end.addingTimeInterval(delta)
        guard earliest > Date() else { throw moveError("活动及出发预留必须在未来。") }
        let horizon = Calendar.current.date(byAdding: .day, value: 8, to: newStart)!
        let busy = moveBusy(start: Calendar.current.startOfDay(for: earliest), end: horizon, excluding: Set(group.map(\.id)))
        let collisions = ReschedulePolicy.conflicts(start: earliest, end: latest, busy: busy)
        return MovePreview(runID: runID, events: group, delta: delta,
            conflicts: collisions.map { "\($0.label ?? "已有日程")：\($0.start.formatted()) — \($0.end.formatted())" },
            suggestions: collisions.isEmpty ? [] : ReschedulePolicy.suggestions(desired: newStart,
                lead: newStart.timeIntervalSince(earliest), duration: selected.end.timeIntervalSince(selected.start), busy: busy, now: Date()))
    }
    func commitMove(_ preview: MovePreview) throws {
        guard !running, preview.conflicts.isEmpty else { throw moveError("请先解决冲突并重新预览。") }
        running = true; defer { running = false }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let index = runs.firstIndex(where: { $0.id == preview.runID && $0.status == "已完成" }) else { throw moveError("任务状态变化，请重新打开改期。") }
        var current: [EKEvent] = []
        for saved in preview.events {
            guard let event = store.event(withIdentifier: saved.id), !event.hasRecurrenceRules,
                  event.calendar.allowsContentModifications, unchanged(event, saved) else { throw moveError("预览后日历有变化，请重新预览。") }
            current.append(event)
        }
        let start = preview.events.map(\.start).min()!.addingTimeInterval(preview.delta)
        let end = preview.events.map(\.end).max()!.addingTimeInterval(preview.delta)
        guard start > Date() else { throw moveError("目标时间已过去，请重新预览。") }
        let busy = moveBusy(start: start, end: end, excluding: Set(preview.events.map(\.id)))
        guard ReschedulePolicy.conflicts(start: start, end: end, busy: busy).isEmpty else { throw moveError("确认前出现了新冲突，请重新预览。") }
        do {
            for event in current {
                event.startDate = event.startDate.addingTimeInterval(preview.delta)
                event.endDate = event.endDate.addingTimeInterval(preview.delta)
                try store.save(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch { store.reset(); throw error }
        for (offset, event) in current.enumerated() {
            if let position = runs[index].events.firstIndex(where: { $0.id == preview.events[offset].id }) {
                runs[index].events[position] = snapshot(event)
            }
        }
        do {
            try saveRuns()
            for event in current {
                guard let saved = store.event(withIdentifier: event.eventIdentifier), unchanged(saved, snapshot(event)) else {
                    throw moveError("日历已提交，但回读未确认，请核对结果。")
                }
            }
        } catch {
            runs[index].status = "结果待核对"; try? saveRuns()
            throw moveError("改期可能已写入，请先核对日历，勿重复操作。")
        }
        runs[index].changes = (runs[index].changes ?? []) + [ScheduleChange(before: preview.events, after: current.map { snapshot($0) })]
        do { try saveRuns() } catch {
            log("改期成功，但历史记录保存失败。")
            throw moveError("日历已改期，但历史保存失败，请勿重复改期。")
        }
        undoReviews.removeValue(forKey: preview.runID)
        log("已改期并验证 \(current.count) 条日程，保留备注、链接和相对提醒；关联出发预留同步移动。")
    }
}
struct RescheduleView: View {
    @ObservedObject var model: AgentModel
    let run: TaskRun
    var initialEventID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var eventID = ""
    @State private var date = Date().addingTimeInterval(86400)
    @State private var preview: MovePreview?
    @State private var message = ""
    @State private var finished = false
    var choices: [SavedEvent] { run.events.filter { !$0.title.hasPrefix("出发预留 · ") } }
    var body: some View {
        NavigationStack {
            Form {
                Section("选择要改期的活动") {
                    if let initialEventID, let selected = choices.first(where: { $0.id == initialEventID }) {
                        Text(selected.title).font(.headline)
                        Text("当前时间：" + selected.start.formatted()).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Picker("活动", selection: $eventID) {
                            ForEach(choices) { event in Text(event.title + " · " + event.start.formatted()).tag(event.id) }
                        }.onChange(of: eventID) { preview = nil; message = "" }
                    }
                    DatePicker("新的开始时间", selection: $date, in: Date()...)
                        .onChange(of: date) { preview = nil; message = "" }
                    Text("时长、备注、链接和相对提醒保留。关联出发预留一起移动，其余活动不变。已有路线不会重新查询，出发前需核对班次与路况。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("检查冲突并预览") {
                        Task {
                            preview = nil; message = ""
                            do { preview = try await model.previewMove(runID: run.id, eventID: eventID, to: date) }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(model.running || eventID.isEmpty || finished)
                }.disabled(finished)
                if let preview {
                    Section("变更预览") {
                        ForEach(preview.events) { event in
                            VStack(alignment: .leading) {
                                Text(event.title).bold()
                                Text("原：" + event.start.formatted() + " — " + event.end.formatted())
                                Text("新：" + event.start.addingTimeInterval(preview.delta).formatted() + " — " + event.end.addingTimeInterval(preview.delta).formatted())
                            }.font(.caption)
                        }
                        if preview.conflicts.isEmpty {
                            Button("确认改期") {
                                do { try model.commitMove(preview); finished = true; message = "改期成功，已回读验证。" }
                                catch { message = error.localizedDescription; self.preview = nil }
                            }.disabled(model.running || finished)
                        } else {
                            Text("存在冲突，尚未修改任何日程。").foregroundStyle(.orange)
                            ForEach(preview.conflicts, id: \.self) { Text($0).font(.caption) }
                            Text("可选空档（未来七天 09:00–18:00，每半小时检查，包含出发预留）：").font(.caption)
                            if preview.suggestions.isEmpty { Text("未找到合适空档，请手动选择其他时间。") }
                            ForEach(preview.suggestions, id: \.self) { suggestion in
                                Button(suggestion.formatted()) { date = suggestion }
                            }
                            Text("选择候选后，请重新预览确认。") .font(.caption)
                        }
                    }
                }
                if !message.isEmpty { Section { Text(message) } }
            }
            .navigationTitle("修改日程")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { if eventID.isEmpty { eventID = choices.first(where: { $0.id == initialEventID })?.id ?? choices.first?.id ?? "" } }
        }
    }
}
