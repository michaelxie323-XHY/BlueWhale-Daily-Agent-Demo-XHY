import Foundation
let base = Date(timeIntervalSince1970: 0)
func at(_ minute: Int) -> Date { base.addingTimeInterval(Double(minute * 60)) }
let plan = TaskPlan(items: [WorkItem(id:"a",title:"A",minutes:30),WorkItem(id:"b",title:"B",minutes:20)],start:at(0),deadline:at(180))
let schedule = try Planner.schedule(plan,busy:[TimeSlot(start:at(20),end:at(40)),TimeSlot(start:at(35),end:at(60)),TimeSlot(start:at(90),end:at(100))])
assert(schedule[0].slot.start == at(60))
assert(schedule[1].slot.start == at(100))
var short=plan; short.deadline=at(40)
do { _ = try Planner.schedule(short,busy:[TimeSlot(start:at(0),end:at(20))]); fatalError("must reject") } catch PlanError.noSpace {}
var invalid=plan; invalid.items[0].minutes = -1
do { _ = try Planner.schedule(invalid,busy:[]); fatalError("must reject") } catch PlanError.invalid {}
print("PASS: overlapping conflicts, boundary, insufficient time, invalid duration")

let meeting = TaskPlan(items: [WorkItem(id:"meeting",title:"会议",minutes:30,notes:"准备作品集",url:"https://example.com",fixedStart:at(60))],start:at(0),deadline:at(180))
let meetingResult = try Planner.schedule(meeting,busy:[])
assert(meetingResult[0].slot.start == at(60))
do { _ = try Planner.schedule(meeting,busy:[TimeSlot(start:at(70),end:at(80))]); fatalError("fixed meeting must not move") } catch PlanError.fixedConflict(_) {}
let legacy = Data("{\"id\":\"old\",\"title\":\"旧任务\",\"minutes\":30}".utf8)
let oldItem = try JSONDecoder().decode(WorkItem.self,from:legacy)
assert(oldItem.notes == nil)
print("PASS: fixed meeting, conflict refusal, old task decoding")

let mixed = TaskPlan(items: [WorkItem(id:"flex",title:"准备",minutes:90), WorkItem(id:"fixed",title:"开会",minutes:30,fixedStart:at(60))], start:at(0), deadline:at(240))
let mixedResult = try Planner.schedule(mixed,busy:[])
assert(mixedResult.first(where: {$0.item.id == "fixed"})!.slot.start == at(60))
assert(mixedResult.first(where: {$0.item.id == "flex"})!.slot.start == at(90))
print("PASS: flexible tasks reserve fixed meetings regardless of input order")

let week = TaskPlan(items: [
    WorkItem(id:"tue",title:"周二任务",minutes:60,windows:[TimeSlot(start:at(1440),end:at(1560))]),
    WorkItem(id:"mon",title:"周一任务",minutes:30,windows:[TimeSlot(start:at(0),end:at(120))])
],start:at(0),deadline:at(3000))
let weekResult = try Planner.schedule(week,busy:[])
assert(weekResult[0].item.id == "mon" && weekResult[1].slot.start == at(1440))
do { _ = try Planner.schedule(week,busy:[TimeSlot(start:at(1440),end:at(1560))]); fatalError("must not leak into next day") } catch PlanError.noSpace {}
let multipleWindows = TaskPlan(items:[WorkItem(id:"x",title:"择日工作",minutes:60,windows:[TimeSlot(start:at(0),end:at(60)),TimeSlot(start:at(1440),end:at(1500))])],start:at(0),deadline:at(1500))
let nextDay = try Planner.schedule(multipleWindows,busy:[TimeSlot(start:at(0),end:at(60))])
assert(nextDay[0].slot.start == at(1440))
let commute = TaskPlan(items:[WorkItem(id:"c",title:"会议",minutes:30,fixedStart:at(60),windows:[TimeSlot(start:at(60),end:at(90))],reminderMinutes:[10,30],travelMinutes:20)],start:at(0),deadline:at(120))
let commuteResult = try Planner.schedule(commute,busy:[])
assert(commuteResult.count == 2 && commuteResult[0].slot.start == at(40) && commuteResult[1].slot.start == at(60))
do { _ = try Planner.schedule(commute,busy:[TimeSlot(start:at(45),end:at(50))]); fatalError("travel must block conflicts") } catch PlanError.fixedConflict(_) {}
var badAlarm = commute; badAlarm.items[0].reminderMinutes = [-1]
do { _ = try Planner.schedule(badAlarm,busy:[]); fatalError("negative alarm") } catch PlanError.invalid {}
print("PASS: per-day windows, no day leakage, alternative dates, travel blocks/conflicts, reminder bounds")

var narrow = meeting; narrow.items[0].windows = [TimeSlot(start:at(0),end:at(30))]
do { _ = try Planner.schedule(narrow,busy:[]); fatalError("must identify model window error") } catch PlanError.outsideWindow(let detail) { assert(detail.contains("会议")) }
do { _ = try Planner.schedule(meeting,busy:[TimeSlot(start:at(70),end:at(80),label:"冲突会议")]); fatalError("must identify conflict") } catch PlanError.fixedConflict(let detail) { assert(detail.contains("冲突会议")) }
print("PASS: distinguishes malformed window from named calendar conflict")
let iso = ISO8601DateFormatter()
func date(_ text: String) -> Date { iso.date(from:text)! }
let actual = TaskPlan(items:[
 WorkItem(id:"mon",title:"周会",minutes:30,fixedStart:date("2026-10-05T09:00:00+08:00"),windows:[TimeSlot(start:date("2026-10-05T09:00:00+08:00"),end:date("2026-10-05T09:30:00+08:00"))],reminderMinutes:[10]),
 WorkItem(id:"wed",title:"面试",minutes:60,fixedStart:date("2026-10-07T14:00:00+08:00"),windows:[TimeSlot(start:date("2026-10-07T14:00:00+08:00"),end:date("2026-10-07T15:00:00+08:00"))],location:"公司A",reminderMinutes:[30],travelMinutes:30),
 WorkItem(id:"fri1",title:"整理面试笔记",minutes:45,windows:[TimeSlot(start:date("2026-10-09T09:00:00+08:00"),end:date("2026-10-09T12:00:00+08:00"))]),
 WorkItem(id:"fri2",title:"修改简历",minutes:30,windows:[TimeSlot(start:date("2026-10-09T09:00:00+08:00"),end:date("2026-10-09T12:00:00+08:00"))])
],start:date("2026-10-05T09:00:00+08:00"),deadline:date("2026-10-09T12:00:00+08:00"))
let actualResult = try Planner.schedule(actual,busy:[])
assert(actualResult.count == 5)
assert(actualResult[1].slot.start == date("2026-10-07T13:30:00+08:00"))
assert(actualResult[4].slot.start == date("2026-10-09T09:45:00+08:00"))
print("PASS: reported weekly scenario schedules 5 events without external conflicts")

assert(!CalendarConflictPolicy.defaultIncluded(title:"中国大陆节假日",readOnly:true))
assert(!CalendarConflictPolicy.defaultIncluded(title:"Australian Holidays",readOnly:true))
assert(CalendarConflictPolicy.defaultIncluded(title:"我的全天请假",readOnly:false))
assert(CalendarConflictPolicy.defaultIncluded(title:"Holidays 项目排期",readOnly:false))
assert(CalendarConflictPolicy.defaultIncluded(title:"团队共享日历",readOnly:true))
print("PASS: read-only holiday defaults, personal leave and shared calendar preservation")

assert(UndoIdentity.belongs(notes: "汇报项目\n\n鲸伴任务 · abc\n鲸伴日程 · item", runID: "abc"))
assert(!UndoIdentity.belongs(notes: "鲸伴任务 · abc-other", runID: "abc"))
assert(!UndoIdentity.belongs(notes: "备注引用鲸伴任务 · abc", runID: "abc"))
assert(!UndoIdentity.belongs(notes: nil, runID: "abc"))
print("PASS: undo ownership requires exact task marker, including legacy notes")

let moveBase = Date(timeIntervalSince1970: 1_800_000_000)
let moveBusy = [TimeSlot(start: moveBase, end: moveBase.addingTimeInterval(3600), label: "占用")]
assert(ReschedulePolicy.conflicts(start: moveBase.addingTimeInterval(3600), end: moveBase.addingTimeInterval(7200), busy: moveBusy).isEmpty)
assert(ReschedulePolicy.conflicts(start: moveBase.addingTimeInterval(-900), end: moveBase.addingTimeInterval(900), busy: moveBusy).count == 1)
var moveCalendar = Calendar(identifier: .gregorian)
moveCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
let desiredMove = moveCalendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
let options = ReschedulePolicy.suggestions(desired: desiredMove, lead: 1800, duration: 3600,
    busy: [TimeSlot(start: desiredMove, end: desiredMove.addingTimeInterval(3600))],
    now: desiredMove.addingTimeInterval(-86400), calendar: moveCalendar)
assert(options.count == 3)
assert(options[0] == desiredMove.addingTimeInterval(5400))
print("PASS: reschedule boundaries, travel conflict, candidate slots")
assert(TaskIntentGuard.isModification("四号的产品研讨会改到下午四点半"))
assert(TaskIntentGuard.isModification("把周会推迟一个小时"))
assert(!TaskIntentGuard.isModification("2026年10月4日16:30开30分钟产品讨论会"))
assert(!TaskIntentGuard.isModification("下午2点面试，提前30分钟提醒"))
print("PASS: modification routing versus new events and reminders")
