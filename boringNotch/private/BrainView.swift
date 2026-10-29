//
//  BrainView.swift
//  boringNotch
//
//  Zac's notch tab: Claude status, top Brain nudge, next event, quick capture.
//  Reads ~/Notes and screen-intelligence's status.json directly (app sandbox is off).
//

import AppKit
import SwiftUI

let brainIndigo = Color(red: 0x3a / 255, green: 0x35 / 255, blue: 0xff / 255)

struct ClaudeStatus: Decodable {
    let state: String
    let task: String?
    let step: String?
    let n: Int?
    let of: Int?
    let updated: Double?

    // ponytail: 30-min staleness cutoff, so a crashed task doesn't pin the island forever
    var isLive: Bool {
        guard state == "running" || state == "waiting", let updated else { return false }
        return Date().timeIntervalSince1970 - updated < 30 * 60
    }

    var color: Color {
        switch state {
        case "running": return brainIndigo
        case "waiting": return .orange
        case "stopped": return .red
        default: return Color(red: 0.42, green: 0.16, blue: 0.85)  // done: deep purple
        }
    }
}

struct Nudge {
    let id: String
    let title: String
    let due: Date?
}

@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()

    @Published var claude: ClaudeStatus?
    @Published var nudge: Nudge?
    @Published var nextEvent: EventModel?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var statusURL: URL { home.appendingPathComponent("Projects/screen-intelligence/runtime/status.json") }
    private var nudgesURL: URL { home.appendingPathComponent("Notes/nudges.md") }
    private var inboxURL: URL { home.appendingPathComponent("Notes/inbox.md") }
    private let calendar = CalendarService()
    private var timer: Timer?
    private var tick = 0

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        refresh()
        // ponytail: 2s polling; switch to DispatchSource file watching if it ever shows up in Activity Monitor
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in BrainStore.shared.refresh() }
        }
    }

    func refresh() {
        if let data = try? Data(contentsOf: statusURL) {
            claude = try? JSONDecoder().decode(ClaudeStatus.self, from: data)
        }
        // nudges and calendar change slowly: every 30s
        if tick % 15 == 0 {
            nudge = Self.topNudge(in: (try? String(contentsOf: nudgesURL, encoding: .utf8)) ?? "")
            Task { await loadNextEvent() }
        }
        tick += 1
    }

    /// Most overdue open nudge (earliest due first, undated last), skipping ones snoozed past today.
    static func topNudge(in markdown: String) -> Nudge? {
        let today = Calendar.current.startOfDay(for: Date())
        var open: [Nudge] = []
        for block in markdown.components(separatedBy: "\n## ").dropFirst() {
            let lines = block.components(separatedBy: "\n")
            func field(_ name: String) -> String {
                lines.first { $0.hasPrefix("- \(name):") }
                    .map { String($0.dropFirst(name.count + 3)).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            guard field("status") == "open" else { continue }
            if let snooze = day.date(from: field("snooze_until")), snooze > today { continue }
            let head = lines[0].components(separatedBy: " · ")
            open.append(Nudge(id: head[0], title: head.dropFirst().joined(separator: " · "), due: day.date(from: field("due"))))
        }
        return open.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    private func loadNextEvent() async {
        let now = Date()
        let events = await calendar.events(from: now, to: now.addingTimeInterval(7 * 86400), calendars: [])
        nextEvent = events
            .filter { e in
                guard case .event = e.type else { return false }
                return !e.isAllDay && e.end > now
            }
            .min { $0.start < $1.start }
    }

    func capture() {
        let alert = NSAlert()
        alert.messageText = "Capture to Brain"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "A note, idea or todo"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "- \(stamp.string(from: Date())) · note · \(text)\n"
        var inbox = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? "# Inbox\n"
        if !inbox.hasSuffix("\n") { inbox += "\n" }
        try? (inbox + line).write(to: inboxURL, atomically: true, encoding: .utf8)
    }

    func openBrain() {
        NSWorkspace.shared.open(home.appendingPathComponent("Applications/Brain.app"))
    }
}

// MARK: - Open notch tab

struct BrainView: View {
    @ObservedObject var store = BrainStore.shared

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                card(icon: "sparkle", tint: store.claude?.color ?? .gray, label: claudeLabel, detail: claudeDetail) {}
                card(icon: "flag.fill", tint: .orange,
                     label: store.nudge?.title ?? "No open nudges",
                     detail: store.nudge.map { nudgeDue($0) } ?? "You're clear") { store.openBrain() }
            }
            GridRow {
                card(icon: "calendar", tint: .blue,
                     label: store.nextEvent?.title ?? "Nothing in the next week",
                     detail: store.nextEvent.map { eventWhen($0) } ?? "Allow calendar access in Settings if this is wrong") {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                }
                card(icon: "square.and.pencil", tint: brainIndigo, label: "Quick capture", detail: "Goes to your Brain inbox") {
                    store.capture()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
    }

    private var claudeLabel: String {
        guard let c = store.claude, c.isLive else { return "Claude is idle" }
        return c.task ?? "Claude"
    }

    private var claudeDetail: String {
        guard let c = store.claude else { return "No task yet" }
        guard c.isLive else { return "Last task \(c.state)" }
        if let n = c.n, let of = c.of { return "Step \(n) of \(of) · \(c.state)" }
        return c.state.capitalized
    }

    private func nudgeDue(_ n: Nudge) -> String {
        guard let due = n.due else { return n.id }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: due).day ?? 0
        switch days {
        case ..<0: return "\(n.id) · \(-days)d overdue"
        case 0: return "\(n.id) · due today"
        case 1: return "\(n.id) · due tomorrow"
        default: return "\(n.id) · due in \(days)d"
        }
    }

    private func eventWhen(_ e: EventModel) -> String {
        if e.start <= Date() { return "Now · ends " + e.end.formatted(date: .omitted, time: .shortened) }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return rel.localizedString(for: e.start, relativeTo: Date()) + " · " + e.start.formatted(date: .omitted, time: .shortened)
    }

    private func card(icon: String, tint: Color, label: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.gray).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Closed notch live activity

/// Shown around the closed notch while a Claude task is live: sparkle on the left, step count on the right.
struct ClaudeLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var store = BrainStore.shared

    var body: some View {
        let side = max(0, vm.effectiveClosedNotchHeight - 12)
        HStack {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(store.claude?.color ?? brainIndigo)
                .frame(width: side, height: side)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width - 20)
            Text(store.claude.flatMap { c in c.n.flatMap { n in c.of.map { "\(n)/\($0)" } } } ?? "•")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(store.claude?.color ?? brainIndigo)
                .frame(width: side, height: side)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
