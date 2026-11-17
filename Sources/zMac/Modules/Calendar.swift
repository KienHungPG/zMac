import AppKit
import EventKit
import Observation
import SwiftUI

// Lịch trên notch: dải 7 ngày quanh hôm nay, chấm ngày có sự kiện, sự kiện sắp tới kèm nút vào họp.
// Đọc từ app Lịch qua EventKit (mọi tài khoản đã thêm vào Lịch: iCloud, Google, Exchange), chỉ đọc, không gửi đi đâu.
// Không timer: chỉ đọc khi notch mở và đang thấy cột lịch; lịch đổi (EKEventStoreChanged) hay qua ngày mới
// (NSCalendarDayChanged) lúc notch đóng thì chỉ đánh dấu, lần mở sau mới đọc lại.

// MARK: - Hàm thuần (có test)

/// Link họp trong sự kiện (URL, địa điểm, ghi chú).
enum MeetingLink {
    struct Found: Equatable {
        var url: String
        var service: String
    }

    private static let patterns: [(service: String, regex: String)] = [
        ("Meet", #"https://meet\.google\.com/[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}"#),
        ("Zoom", #"https://(?:[a-z0-9-]+\.)?zoom\.us/(?:j|my|w|s)/[A-Za-z0-9?=&._/-]+"#),
        ("Teams", #"https://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[A-Za-z0-9%._~:/?#\[\]@!$&'()*+,;=-]+"#),
        ("Webex", #"https://[a-z0-9-]+\.webex\.com/[A-Za-z0-9%._~/?=&-]+"#),
    ]

    static func find(in texts: [String?]) -> Found? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for p in patterns {
                guard let re = try? Regex(p.regex), let m = text.firstMatch(of: re) else { continue }
                return Found(url: String(text[m.range]), service: p.service)
            }
        }
        return nil
    }
}

enum CalendarWeek {
    /// 7 ngày, hôm nay ở giữa (lùi 3 ngày), `offset` tuần trước / sau.
    static func days(around today: Date, offset: Int, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: today)
        guard let first = calendar.date(byAdding: .day, value: offset * 7 - 3, to: start) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

// MARK: - Module

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var color: Color
    var meeting: MeetingLink.Found?
}

@MainActor @Observable
final class CalendarModule: ZModule {
    static let id = "calendar"
    static var name: String { L("Lịch", "Calendar") }
    static let replaces = "Itsycal"
    static let symbol = "calendar"
    static var summary: String {
        L("Tuần này và sự kiện sắp tới ngay trong notch, bấm một lần là vào họp Meet, Zoom, Teams. Đọc từ app Lịch, không gửi đi đâu.",
          "This week and your next event right in the notch, one click to join Meet, Zoom or Teams. Read from the Calendar app, never sent anywhere.")
    }

    enum Access { case notAsked, granted, denied }

    private(set) var access: Access = .notAsked
    /// Tuần đang xem so với tuần quanh hôm nay.
    private(set) var weekOffset = 0
    private(set) var selected = Calendar.current.startOfDay(for: Date())
    private(set) var days: [Date] = []
    private(set) var busyDays: Set<Date> = []
    private(set) var events: [CalendarEvent] = []

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var stale = true
    #if DEBUG
    @ObservationIgnored fileprivate var previewing = false
    #endif

    init() {}

    func start() {
        access = Self.currentAccess()
        if access == .granted { store = EKEventStore() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.weekOffset = 0
                self.selected = Calendar.current.startOfDay(for: Date())
                self.changed()
            }
        })
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        store = nil
        events = []
        busyDays = []
        days = []
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    // MARK: Đọc

    /// Cột lịch hiện ra (notch mở) / ẩn đi.
    func setVisible(_ on: Bool) {
        visible = on
        if on && stale { reload() }
    }

    private func changed() {
        stale = true
        if visible { reload() }
    }

    func reload() {
        #if DEBUG
        if previewing { return }
        #endif
        stale = false
        let cal = Calendar.current
        days = CalendarWeek.days(around: Date(), offset: weekOffset, calendar: cal)
        guard access == .granted, let store, let first = days.first, let last = days.last,
              let end = cal.date(byAdding: .day, value: 1, to: last) else {
            busyDays = []
            events = []
            return
        }
        let all = store.events(matching: store.predicateForEvents(withStart: first, end: end, calendars: nil))
            .filter { !Self.declined($0) }
        var busy = Set<Date>()
        for e in all {
            var d = cal.startOfDay(for: e.startDate)
            // Sự kiện kéo dài nhiều ngày: chấm mọi ngày nó đi qua (endDate là mốc kết thúc, không tính).
            while d < e.endDate && d < end {
                busy.insert(d)
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        busyDays = busy
        events = Self.agenda(all, day: selected, calendar: cal)
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// Sự kiện của ngày đang chọn. Hôm nay thì bỏ sự kiện đã xong. Sự kiện có giờ trước, cả ngày sau.
    private static func agenda(_ all: [EKEvent], day: Date, calendar cal: Calendar) -> [CalendarEvent] {
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: day) else { return [] }
        let now = Date()
        let isToday = cal.isDateInToday(day)
        return all
            .filter { $0.startDate < dayEnd && $0.endDate > day && (!isToday || $0.endDate > now) }
            .sorted { ($0.isAllDay ? 1 : 0, $0.startDate) < ($1.isAllDay ? 1 : 0, $1.startDate) }
            .map { e in
                CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? L("Không tên", "Untitled"),
                              start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                              color: e.calendar.map { Color(nsColor: $0.color) } ?? ZTheme.blue.light,
                              meeting: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]))
            }
    }

    // MARK: Thao tác

    func select(_ day: Date) {
        selected = day
        reload()
    }

    func shiftWeek(_ by: Int) {
        weekOffset += by
        let cal = Calendar.current
        selected = by == 0 || weekOffset == 0
            ? cal.startOfDay(for: Date())
            : CalendarWeek.days(around: Date(), offset: weekOffset, calendar: cal)[3]
        reload()
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        EKEventStore().requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.access = granted ? .granted : .denied
                    if granted { self.store = EKEventStore() }
                    self.reload()
                }
            }
        }
    }

    func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func join(_ m: MeetingLink.Found) {
        if let url = URL(string: m.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Chữ

    static func monthTitle(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .year], from: d)
        if LangState.shared.isVietnamese { return "Tháng \(c.month ?? 1), \(c.year ?? 2000)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: d)
    }

    static func weekday(_ d: Date) -> String {
        let w = Calendar.current.component(.weekday, from: d)   // 1 = Chủ nhật
        let vi = ["CN", "T2", "T3", "T4", "T5", "T6", "T7"]
        let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return (LangState.shared.isVietnamese ? vi : en)[(w - 1) % 7]
    }

    static func timeRange(_ e: CalendarEvent) -> String {
        if e.allDay { return L("Cả ngày", "All day") }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
    }

    // MARK: Cài đặt

    func settingsView() -> AnyView {
        moduleForm {
            Section {
                LabeledContent(L("Quyền đọc Lịch", "Calendar access")) {
                    switch access {
                    case .granted: Text(L("Đã cho phép", "Allowed")).foregroundStyle(.green)
                    case .denied:
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { self.requestAccess() }
                    case .notAsked:
                        Button(L("Cho phép", "Allow")) { self.requestAccess() }
                    }
                }
                Text(L("Lịch hiện ở cột bên phải khi mở notch. zMac đọc sự kiện từ app Lịch của macOS (mọi tài khoản bạn đã thêm: iCloud, Google, Exchange), chỉ đọc, không ghi, không gửi đi đâu. Link Meet, Zoom, Teams, Webex trong sự kiện thành nút vào họp.",
                       "The calendar shows in the right column when the notch opens. zMac reads events from the macOS Calendar app (every account you added: iCloud, Google, Exchange). It only reads, never writes or sends anything. Meet, Zoom, Teams and Webex links become a join button."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Giao diện (cột phải của notch khi mở)

struct NotchCalendarView: View {
    let cal: CalendarModule

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(CalendarModule.monthTitle(cal.selected))
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                arrow("chevron.left", L("Tuần trước", "Previous week")) { cal.shiftWeek(-1) }
                arrow("chevron.right", L("Tuần sau", "Next week")) { cal.shiftWeek(1) }
            }
            if cal.access == .granted {
                week
                agenda
            } else {
                permission
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { cal.setVisible(true) }
        .onDisappear { cal.setVisible(false) }
    }

    private func arrow(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var week: some View {
        let today = Calendar.current.startOfDay(for: Date())
        return HStack(spacing: 0) {
            ForEach(cal.days, id: \.self) { d in
                let isToday = d == today
                let isSelected = d == cal.selected
                VStack(spacing: 3) {
                    Text(CalendarModule.weekday(d))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isToday ? 0.9 : 0.45))
                    Text("\(Calendar.current.component(.day, from: d))")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(isToday || isSelected ? 1 : 0.8))
                        .frame(width: 25, height: 25)
                        .background {
                            if isToday {
                                Circle().fill(Color(hex: 0xFF453A))
                            } else if isSelected {
                                Circle().fill(.white.opacity(0.16))
                            }
                        }
                    Circle()
                        .fill(.white.opacity(cal.busyDays.contains(d) ? 0.55 : 0))
                        .frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { cal.select(d) }
            }
        }
    }

    @ViewBuilder private var agenda: some View {
        if let e = cal.events.first {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(e.color).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(CalendarModule.timeRange(e))
                        if cal.events.count > 1 {
                            Text(L("+\(cal.events.count - 1) sự kiện", "+\(cal.events.count - 1) more"))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let m = e.meeting {
                    Button { cal.join(m) } label: {
                        Label(m.service, systemImage: "video.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color(hex: 0x2F7BF6)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(m.url)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { cal.openCalendarApp() }
        } else {
            Text(Calendar.current.isDateInToday(cal.selected) ? L("Hôm nay không còn sự kiện nào", "Nothing else today")
                                                                : L("Không có sự kiện", "No events"))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 4)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cal.access == .denied
                 ? L("zMac chưa được đọc Lịch. Bật trong Cài đặt hệ thống → Quyền riêng tư → Lịch.",
                     "zMac can't read your calendar yet. Turn it on in System Settings → Privacy → Calendars.")
                 : L("Xem tuần này và cuộc họp sắp tới ngay tại đây. Chỉ đọc, không gửi đi đâu.",
                     "See this week and your next meeting right here. Read only, never sent anywhere."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button { cal.requestAccess() } label: {
                Text(cal.access == .denied ? L("Mở Cài đặt", "Open Settings") : L("Cho phép đọc Lịch", "Allow Calendar"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

#if DEBUG
extension CalendarModule {
    /// Chỉ cho `--render-ui`: tuần mẫu, không đụng EventKit.
    func previewSample() {
        previewing = true
        access = .granted
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        days = CalendarWeek.days(around: Date(), offset: 0, calendar: cal)
        selected = today
        busyDays = Set([days[2], days[3], days[4]])
        let start = cal.date(bySettingHour: 17, minute: 0, second: 0, of: today) ?? today
        events = [
            CalendarEvent(id: "1", title: "Demo sprint", start: start, end: start.addingTimeInterval(3600), allDay: false,
                          color: ZTheme.green.light,
                          meeting: MeetingLink.Found(url: "https://meet.google.com/abc-defg-hij", service: "Meet")),
            CalendarEvent(id: "2", title: "Gửi thiết kế", start: start.addingTimeInterval(5400),
                          end: start.addingTimeInterval(7200), allDay: false, color: ZTheme.orange.light, meeting: nil),
        ]
    }
}
#endif
