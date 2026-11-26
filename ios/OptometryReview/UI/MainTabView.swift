import SwiftUI
import SwiftData
import Observation

/// App-wide navigation state: selected tab and the mock exam being taken (presented over all tabs).
@Observable
final class AppRouter {
    var tab: Int = DebugLaunch.initialTab
    var activeExam: MockExam?
    /// Five-subject full mock being taken (presented over all tabs).
    var activeFullMock: FullMock?
    /// Bumped per tab when its already selected tab item is tapped again: that tab pops to its root.
    var rootRequests: [Int: Int] = [:]

    /// Tab bar selection: tapping the active tab pops it to its root.
    func select(_ newTab: Int) {
        if newTab == tab { popToRoot(newTab) }
        tab = newTab
    }

    func popToRoot(_ t: Int) {
        rootRequests[t, default: 0] += 1
    }

    func rootRequest(_ t: Int) -> Int { rootRequests[t] ?? 0 }

    /// 單元 tab at its root (the unit overview).
    func openUnitOverview() {
        popToRoot(Tab.units)
        tab = Tab.units
    }

    enum Tab {
        static let today = 0
        static let units = 1
        static let mistakes = 2
        static let exam = 3
        static let stats = 4
    }
}

struct MainTabView: View {
    @State private var router = AppRouter()
    @Environment(\.questionBank) private var bank
    @State private var debugPractice: SessionRequest?
    @State private var debugAI: AIPracticeRequest?
    @State private var debugGallery: GalleryRequest?
    @State private var debugHandout: HandoutRoute?
    @AppStorage(WhatsNewSheet.shownKey) private var whatsNewShown = false
    @AppStorage(OnboardingFlow.whatsNewZeroThreeTwoKey) private var whatsNewZeroThreeTwoShown = false
    @State private var showWhatsNew = false
    @State private var whatsNewIncludesZeroThreeTwo = false

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.select($0) })) {
            TodayView()
                .tabItem { Label("今日", systemImage: "calendar") }
                .tag(AppRouter.Tab.today)
            UnitsTabView()
                .tabItem { Label("單元", systemImage: "books.vertical") }
                .tag(AppRouter.Tab.units)
            MistakesView()
                .tabItem { Label("錯題本", systemImage: "book.closed") }
                .tag(AppRouter.Tab.mistakes)
            ExamSetupView()
                .tabItem { Label("模擬考", systemImage: "timer") }
                .tag(AppRouter.Tab.exam)
            StatsView()
                .tabItem { Label("成績", systemImage: "chart.bar") }
                .tag(AppRouter.Tab.stats)
        }
        .environment(router)
        .fullScreenCover(item: $router.activeExam) { exam in
            ExamFlowView(exam: exam)
                .environment(router)
        }
        .fullScreenCover(item: $router.activeFullMock) { full in
            FullMockFlowView(full: full)
                .environment(router)
        }
        .fullScreenCover(item: $debugPractice) { req in
            ReviewSessionView(request: req)
        }
        .fullScreenCover(item: $debugAI) { AIPracticeView(request: $0) }
        .fullScreenCover(item: $debugGallery) { DebugFigureGallery(cases: $0.cases) }
        .fullScreenCover(item: $debugHandout) { route in
            NavigationStack { HandoutView(route: route, backLabel: "返回").interactivePopEnabled() }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheet(includesZeroThreeTwo: whatsNewIncludesZeroThreeTwo) {
                whatsNewShown = true
                whatsNewZeroThreeTwoShown = true
                showWhatsNew = false
            }
        }
        .onAppear {
            if !whatsNewShown, router.activeExam == nil {
                whatsNewIncludesZeroThreeTwo = OnboardingFlow.includesZeroThreeTwo(zeroThreeTwoShown: whatsNewZeroThreeTwoShown)
                showWhatsNew = true
            }
            #if DEBUG
            if let ids = DebugLaunch.openAIQueue(bank: bank), debugAI == nil { debugAI = AIPracticeRequest(ids: ids) }
            if let route = DebugLaunch.openHandoutRoute(bank: bank), debugHandout == nil { debugHandout = route }
            if let cases = DebugLaunch.figureGalleryCases(), debugGallery == nil { debugGallery = GalleryRequest(cases: cases) }
            #endif
            if let queue = DebugLaunch.openQuestionQueue(bank: bank), debugPractice == nil {
                debugPractice = SessionRequest(queue: queue, doneBefore: 0, isDaily: false, isPractice: true)
            }
        }
    }
}

struct GalleryRequest: Identifiable {
    let id = UUID()
    let cases: [Int]
}
