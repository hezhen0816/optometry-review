import SwiftUI

private struct UsageLayoutKey: EnvironmentKey {
    static let defaultValue = "single"
}

private struct UsageEntryKey: EnvironmentKey {
    static let defaultValue = "unknown"
}

extension EnvironmentValues {
    var usageLayout: String {
        get { self[UsageLayoutKey.self] }
        set { self[UsageLayoutKey.self] = newValue }
    }
    var usageEntry: String {
        get { self[UsageEntryKey.self] }
        set { self[UsageEntryKey.self] = newValue }
    }
}

private struct UsageScreen: ViewModifier {
    let name: String
    let page: Int?
    let answerSource: String?
    let entry: String?
    let navigation: UsageNavigation?
    @Environment(\.scenePhase) private var phase
    @Environment(\.usageEntry) private var parentEntry
    @Environment(\.usageLayout) private var parentLayout
    @State private var clock = UsageForegroundClock()
    @State private var visible = false
    @State private var contextID = UUID()
    @State private var enteredFrom = "unknown"
    @State private var layout = "single"

    func body(content: Content) -> some View {
        content
            .environment(\.usageEntry, name)
            .environment(\.usageLayout, layout)
            .background {
                GeometryReader { geo in
                    Color.clear.onAppear { updateLayout(geo.size) }
                        .onChange(of: geo.size) { _, size in updateLayout(size) }
                }
            }
            .onAppear {
                visible = true
                enteredFrom = entry ?? (parentEntry == "unknown" ? answerSource ?? "tab" : parentEntry)
                if phase == .active { clock.resume(at: .now) }
                if let answerSource { UsageLog.shared.enterAnswerContext(contextID, source: answerSource) }
            }
            .onDisappear {
                end()
                visible = false
                // The view's own disappearance handler commits any pending answer first.
                let id = contextID
                DispatchQueue.main.async { if !visible { UsageLog.shared.leaveAnswerContext(id) } }
            }
            .onChange(of: parentLayout) { _, _ in if name == "ai" { updateLayout(.zero) } }
            .onChange(of: phase) { _, phase in
                if phase == .background { end() }
                else if phase == .inactive { clock.pause(at: .now) }
                else if phase == .active, visible { clock.resume(at: .now) }
            }
    }

    private func updateLayout(_ size: CGSize) {
        let next: String
        if name == "ai" { next = parentLayout }
        else if name == "handout", size.width >= Layout.threeColumnWidth { next = "three-column" }
        else if ["review", "question", "questionDetail", "ai", "handoutAsk", "aiQuestion"].contains(name),
                Layout.isWideAnswerLayout(size) { next = "two-column" }
        else { next = "single" }
        if next != layout, visible {
            end()
            if phase == .active { clock.resume(at: .now) }
        }
        layout = next
    }

    private func end() {
        let seconds = clock.take(at: .now)
        guard seconds > 0 else { return }
        var fields: [String: Any] = ["name": name, "seconds": seconds, "entry": enteredFrom, "layout": layout]
        if let page { fields["page"] = page }
        if let navigation { fields.merge(navigation.fields) { _, new in new } }
        UsageLog.shared.log("screen", fields)
    }
}

extension View {
    /// `page` (1-based) is for multi-page screens such as the tour; each page is its own view instance.
    func trackScreen(_ name: String, page: Int? = nil, answerSource: String? = nil,
                     entry: String? = nil, navigation: UsageNavigation? = nil) -> some View {
        modifier(UsageScreen(name: name, page: page, answerSource: answerSource, entry: entry, navigation: navigation))
    }
}
