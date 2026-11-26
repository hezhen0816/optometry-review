import SwiftUI
import SwiftData
import PDFKit

/// Original PDF of one paper with 試題／答案／更正答案 segments, plus practice and mock buttons.
struct PaperView: View {
    let paper: Paper

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false

    @State private var document = PaperDocument.questions.rawValue
    @State private var page = 1
    @State private var pageCount = 1
    @State private var practice: SessionRequest?
    @State private var pendingExam: MockExam?
    @State private var askReplace = false

    private var documents: [PaperDocument] {
        PaperDocument.allCases.filter { $0 != .corrected || bank.pdfURL(paper, .corrected) != nil }
    }

    private var currentURL: URL? {
        bank.pdfURL(paper, PaperDocument(rawValue: document) ?? .questions)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Palette.segmentTrack.ignoresSafeArea(edges: .horizontal)
                if let url = currentURL {
                    PDFKitView(url: url, page: $page, pageCount: $pageCount)
                        .id(url)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.questionmark").font(.system(size: 28))
                        Text("找不到這份 PDF").appFont(15, .bold)
                    }
                    .foregroundStyle(Palette.muted)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: document)
            .overlay(alignment: .bottom) {
                if currentURL != nil {
                    Text("第 \(page) / \(pageCount) 頁 ・ 雙指可縮放")
                        .appFont(12, relativeTo: .caption1)
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.ground.opacity(0.92)))
                        .padding(.bottom, 8)
                }
            }
            bottomBar
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .trackScreen("paper")
        .fullScreenCover(item: $practice) { req in
            ReviewSessionView(request: req)
        }
        .confirmationDialog("有一份模擬考還沒交卷", isPresented: $askReplace, titleVisibility: .visible,
                            presenting: pendingExam) { old in
            Button("繼續那一份（\(old.subject)）") { router.activeExam = old }
            Button("放棄那一份，開始這份", role: .destructive) {
                context.delete(old)
                try? context.save()
                startExam()
            }
            Button("取消", role: .cancel) {}
        } message: { old in
            Text("\(old.title) \(old.subject)，已答 \(old.answeredCount) 題。")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                BackButton(label: "返回模擬考") { dismiss() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(subtitle).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    Text(paper.subject).appFont(16, .bold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let url = currentURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("分享或存檔 PDF")
                }
            }
            SegmentPicker(options: documents.map(\.rawValue), selection: $document, height: 38)
                .padding(.horizontal, 8)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Palette.ground)
    }

    private var subtitle: String {
        let session = PaperCatalog.sessionLabel(for: paper, in: bank.papers)
        let kind = paper.sessionNote != nil ? "" : " \(paper.examKind)"
        let code = paper.paperCode.map { " ・ 代號 \($0)" } ?? ""
        return session + kind + code
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("逐題練習") { startPractice() }
            .buttonStyle(SecondaryButtonStyle(height: 50))
            Button("當模擬考") { requestExam() }
                .buttonStyle(PrimaryButtonStyle(height: 50))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.ground.ignoresSafeArea(edges: .bottom))
    }

    /// The whole paper in question order.
    private func startPractice() {
        practice = SessionRequest(queue: paper.questionIDs, doneBefore: 0, isDaily: false, isPractice: true, isPaper: true)
    }

    private func requestExam() {
        if let old = StudyStore(context: context).unfinishedExam() {
            pendingExam = old
            askReplace = true
        } else {
            startExam()
        }
    }

    private func startExam() {
        let store = StudyStore(context: context)
        if let exam = store.makeExam(subject: paper.subject, mode: .wholePaper, paper: paper, bank: bank,
                                     includeSpecial: includeSpecial) {
            router.activeExam = exam
        }
    }
}

/// PDFKit viewer reporting the current page.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var page: Int
    @Binding var pageCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(Palette.segmentTrack)
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        DispatchQueue.main.async {
            pageCount = view.document?.pageCount ?? 1
            page = 1
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    final class Coordinator: NSObject {
        let parent: PDFKitView
        init(_ parent: PDFKitView) { self.parent = parent }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                                                   name: .PDFViewPageChanged, object: view)
        }

        @objc func changed(_ note: Notification) {
            guard let view = note.object as? PDFView, let doc = view.document, let p = view.currentPage else { return }
            parent.page = doc.index(for: p) + 1
            parent.pageCount = doc.pageCount
        }
    }
}
