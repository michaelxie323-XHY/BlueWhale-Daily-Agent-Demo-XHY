import Foundation

struct WorkItem: Codable, Identifiable {
    var id: String
    var title: String
    var minutes: Int
    var notes: String? = nil
    var url: String? = nil
    var fixedStart: Date? = nil
    var windows: [TimeSlot]? = nil
    var location: String? = nil
    var reminderMinutes: [Int]? = nil
    var travelMinutes: Int? = nil
}
struct TaskPlan: Codable {
    var items: [WorkItem]
    var start: Date
    var deadline: Date
}
struct TimeSlot: Codable { var start: Date; var end: Date; var label: String? = nil }
struct ScheduledItem { var item: WorkItem; var slot: TimeSlot }
enum Planner {
    private static func describe(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .abbreviated, time: .shortened)) 至 \(end.formatted(date: .abbreviated, time: .shortened))"
    }
    static func schedule(_ plan: TaskPlan, busy: [TimeSlot]) throws -> [ScheduledItem] {
        guard plan.start < plan.deadline, !plan.items.isEmpty, plan.items.count <= 20,
              Set(plan.items.map(\.id)).count == plan.items.count else { throw PlanError.invalid }
        var occupied = busy
        var result: [ScheduledItem] = []
        for item in plan.items {
            guard (1...480).contains(item.minutes), !item.title.trimmingCharacters(in: .whitespaces).isEmpty,
                  (0...240).contains(item.travelMinutes ?? 0),
                  (item.reminderMinutes ?? []).count <= 2,
                  (item.reminderMinutes ?? []).allSatisfy({ (0...10080).contains($0) }) else { throw PlanError.invalid }
            for window in item.windows ?? [] {
                guard window.start < window.end, window.start >= plan.start, window.end <= plan.deadline else { throw PlanError.invalid }
            }
        }
        func append(_ item: WorkItem, _ start: Date) {
            let travel = item.travelMinutes ?? 0
            let end = start.addingTimeInterval(Double(item.minutes * 60))
            if travel > 0 {
                let travelStart = start.addingTimeInterval(-Double(travel * 60))
                let travelItem = WorkItem(id: item.id + "-travel", title: "出发预留 · " + item.title, minutes: travel,
                    notes: "按你指定的路程时长预留；未查询实时交通。", location: item.location)
                result.append(ScheduledItem(item: travelItem, slot: TimeSlot(start: travelStart, end: start)))
                occupied.append(TimeSlot(start: travelStart, end: start, label: "本次任务：出发预留 · " + item.title))
            }
            result.append(ScheduledItem(item: item, slot: TimeSlot(start: start, end: end)))
            occupied.append(TimeSlot(start: start, end: end, label: "本次任务：" + item.title))
        }
        // Fixed meetings and their travel blocks take precedence over flexible work.
        for item in plan.items where item.fixedStart != nil {
            let fixed = item.fixedStart!
            let end = fixed.addingTimeInterval(Double(item.minutes * 60))
            let travelStart = fixed.addingTimeInterval(-Double((item.travelMinutes ?? 0) * 60))
            let windows = item.windows ?? [TimeSlot(start: plan.start, end: plan.deadline)]
            guard windows.contains(where: { fixed >= $0.start && end <= $0.end }), travelStart >= plan.start else {
                throw PlanError.outsideWindow("「\(item.title)」会议：\(describe(fixed, end))；含出发预留从 \(travelStart.formatted(date: .abbreviated, time: .shortened)) 开始。允许时段：" + windows.map { describe($0.start, $0.end) }.joined(separator: "；"))
            }
            if let block = occupied.first(where: { $0.start < end && $0.end > travelStart }) {
                throw PlanError.fixedConflict("「\(item.title)」需要 \(describe(travelStart, end))（含出发预留），与「\(block.label ?? "已有日程")」\(describe(block.start, block.end)) 重叠。")
            }
            append(item, fixed)
        }
        let flexible = plan.items.enumerated().filter { $0.element.fixedStart == nil }.sorted {
            let a = $0.element.windows?.map(\.start).min() ?? plan.start
            let b = $1.element.windows?.map(\.start).min() ?? plan.start
            return a == b ? $0.offset < $1.offset : a < b
        }
        var nextStart = plan.start
        for (_, item) in flexible {
            let duration = Double(item.minutes * 60)
            let travel = Double((item.travelMinutes ?? 0) * 60)
            let windows = (item.windows ?? [TimeSlot(start: plan.start, end: plan.deadline)]).sorted { $0.start < $1.start }
            var selected: Date?
            for window in windows {
                var cursor = max(window.start, nextStart)
                for block in occupied.sorted(by: { $0.start < $1.start }) {
                    if block.end <= cursor { continue }
                    if cursor.addingTimeInterval(travel + duration) <= block.start { break }
                    cursor = max(cursor, block.end)
                }
                if cursor.addingTimeInterval(travel + duration) <= window.end {
                    selected = cursor.addingTimeInterval(travel); break
                }
            }
            guard let start = selected else { throw PlanError.noSpace }
            append(item, start)
            nextStart = start.addingTimeInterval(Double(item.minutes * 60))
        }
        return result.sorted { $0.slot.start < $1.slot.start }
    }
}
enum PlanError: LocalizedError {
    case invalid, noSpace
    case fixedConflict(String), outsideWindow(String)
    var errorDescription: String? {
        switch self {
        case .invalid: return "任务格式无效，请检查时长与日期。"
        case .noSpace: return "截止时间前没有足够空档，未创建任何日程。"
        case .fixedConflict(let detail): return "时间冲突：" + detail + " 本次未创建任何日程。"
        case .outsideWindow(let detail): return "计划时间范围不一致：" + detail + " 本次未写入，请调整时间范围后重试。"
        }
    }
}

// Names are a heuristic only; users can override each calendar in the app.
enum CalendarConflictPolicy {
    static func defaultIncluded(title: String, readOnly: Bool) -> Bool {
        guard readOnly else { return true }
        let name = title.lowercased()
        return !["holidays", "holiday calendar", "节假日", "節假日", "中国节日", "中國節日"].contains(where: { name.contains($0) })
    }
}

// Ownership markers must match complete lines, never a title or a substring.
enum UndoIdentity {
    static func belongs(notes: String?, runID: String) -> Bool {
        (notes ?? "").components(separatedBy: "\n").contains("鲸伴任务 · " + runID)
    }
}

// Half-open intervals allow one event to begin exactly when another ends.
enum ReschedulePolicy {
    static func conflicts(start: Date, end: Date, busy: [TimeSlot]) -> [TimeSlot] {
        busy.filter { $0.start < end && $0.end > start }
    }
    static func suggestions(desired: Date, lead: TimeInterval, duration: TimeInterval,
                            busy: [TimeSlot], now: Date, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        let day = calendar.startOfDay(for: desired)
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: day),
                  let open = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date),
                  let close = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date) else { continue }
            var cursor = open
            while cursor.addingTimeInterval(duration) <= close {
                if cursor >= desired && cursor.addingTimeInterval(-lead) > now,
                   cursor.addingTimeInterval(-lead) >= open,
                   conflicts(start: cursor.addingTimeInterval(-lead), end: cursor.addingTimeInterval(duration), busy: busy).isEmpty {
                    result.append(cursor)
                    if result.count == 3 { return result }
                }
                cursor = cursor.addingTimeInterval(1800)
            }
        }
        return result
    }
}

// Conservative routing: modification language must never be silently treated as creation.
enum TaskIntentGuard {
    static func isModification(_ text: String) -> Bool {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        return ["改到", "改成", "改为", "改期", "调整到", "调整为", "挪到", "移到", "推迟", "提前到", "取消会议", "删除日程", "reschedule", "postpone"].contains { compact.contains($0) }
    }
}
