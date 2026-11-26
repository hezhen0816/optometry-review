import SwiftUI
import SwiftData

/// 單元 tab: subject → unit overview with 歷屆 and AI 題 counts. Unit pages hold the handout, 考點 and both practice kinds.
struct UnitsTabView: View {
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router
    @AppStorage(YearFilterStore.key(.units)) private var unitYearsRaw = ""
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @State private var path = NavigationPath()
    @State private var showYears = false
    @State private var customRequest: CustomPracticeRequest?
    @State private var aiPractice: AIPracticeRequest?

    private var unitYears: YearSelection { YearFilterStore.decode(unitYearsRaw) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("單元").headingFont(32)
                        Spacer(minLength: 0)
                        YearFilterButton(active: unitYears.mode != .all) { showYears = true }
                            .padding(.top, 8)
                    }
                    if let label = unitYears.label {
                        YearRangeChip(label: label) { YearFilterStore.set(.all, for: .units) }
                            .padding(.top, -4)
                    }
                    UnitOverviewList(years: unitYears, onOpen: { path.append(UnitRoute(unitID: $0.id)) },
                                     onPracticeSubject: { customRequest = .shortcut(subject: $0, kind: .all) },
                                     onPracticeAI: { ids in if !ids.isEmpty { aiPractice = AIPracticeRequest(ids: ids) } })
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .readableScrollWidth()
            .foregroundStyle(Palette.ink)
            .background(Palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .trackScreen("units")
            .firstVisitTip(key: SettingsKey.tipUnitsShown, title: "每個科目一行三個數字",
                           message: "依序是歷屆題數、AI 題數和你的錯題數。點科目展開單元，點單元進去讀重點講義，再練歷屆題或 AI 題；只有計算題的考點有 AI 題。")
            .interactivePopEnabled()
            .navigationDestination(for: UnitRoute.self) { route in
                UnitDetailView(unitID: route.unitID, backTitle: "單元")
            }
            .navigationDestination(for: QuestionDetailRoute.self) { route in
                QuestionDetailView(route: route)
            }
            .customPractice($customRequest)
            .fullScreenCover(item: $aiPractice) { AIPracticeView(request: $0) }
            .sheet(isPresented: $showYears) {
                YearFilterSheet(initial: unitYears,
                                count: { sel in bank.reviewPool(includeSpecial: includeSpecial).filter { sel.contains($0.year) }.count },
                                note: "歷屆題數、正確率、錯題只算範圍內的題目；AI 題不受年份影響。") { sel in
                    YearFilterStore.set(sel, for: .units)
                }
            }
        }
        .onChange(of: router.rootRequest(AppRouter.Tab.units)) { path = NavigationPath() }
    }
}
