import SwiftUI
import UIKit

// Shared building blocks for every question screen (review, practice, exam, exam review).

/// Display-only layout for stems; the stored stem (search, AI payload) is unchanged.
enum StemLayout {
    static let markers: Set<Character> = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

    /// Puts each numbered statement (①②③…) of a combination question on its own line.
    /// Applies only when the stem lists at least two statements starting with ①, and the markers are not
    /// blanks or back-references (see `isStatementList`).
    static func display(_ stem: String) -> String {
        guard isStatementList(stem) else { return stem }
        var out = ""
        for ch in stem {
            if markers.contains(ch) {
                while out.last == " " || out.last == "\u{3000}" { out.removeLast() }
                if let last = out.last, last != "\n" { out.append("\n") }
            }
            out.append(ch)
        }
        return out
    }

    /// True for statement lists (「①…②…③… 下列何者正確」). False for fill-in-the-blank stems whose markers are
    /// blanks or back-references: the stem asks to fill in (填入), a marker is directly followed by 、 or by
    /// another marker (「①、②、③」, 「①②③各為何」), or the sequence restarts (① appears again).
    static func isStatementList(_ stem: String) -> Bool {
        let found = stem.filter { markers.contains($0) }
        guard found.count >= 2, found.first == "①" else { return false }
        if stem.contains("填入") || found.filter({ $0 == "①" }).count > 1 { return false }
        let chars = Array(stem)
        for i in chars.indices where markers.contains(chars[i]) && i + 1 < chars.count {
            if chars[i + 1] == "、" || markers.contains(chars[i + 1]) { return false }
        }
        return true
    }

    /// One earlier question quoted before a 「承上題」 question, with its official answer.
    struct Premise: Equatable {
        let text: String
        let answer: String
    }

    /// A 「承上題」 stem split into the quoted earlier question(s) and the question actually asked.
    struct Split: Equatable {
        let premises: [Premise]
        let question: String
    }

    static let premiseTag = "【前題】"
    static let answerOpen = "（前題答案："

    /// Splits stems shaped 「【前題】…（前題答案：…）\n…\n承上題，…」: every line but the last is a premise
    /// ending with its answer; the last line is the question. Nil (render the stem as is) for any other shape.
    static func splitPremise(_ stem: String) -> Split? {
        guard stem.hasPrefix(premiseTag) else { return nil }
        let lines = stem.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let question = lines.last, !question.isEmpty, !question.hasPrefix(premiseTag)
        else { return nil }
        var premises: [Premise] = []
        for line in lines.dropLast() {
            guard line.hasPrefix(premiseTag), line.hasSuffix("）"),
                  let open = line.range(of: answerOpen, options: .backwards) else { return nil }
            let text = String(line[line.index(line.startIndex, offsetBy: premiseTag.count)..<open.lowerBound])
            let answer = String(line[open.upperBound..<line.index(before: line.endIndex)])
            let cleaned = text.replacingOccurrences(of: "[ \u{3000}]{2,}", with: " ", options: .regularExpression)
                .replacingOccurrences(of: " ，", with: "，")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !answer.isEmpty else { return nil }
            premises.append(Premise(text: cleaned, answer: answer.trimmingCharacters(in: .whitespaces)))
        }
        return Split(premises: premises, question: question)
    }
}

/// The quoted earlier question(s) of a 「承上題」 stem: a small gray box labelled 「前題」.
struct PremiseBox: View {
    let premises: [StemLayout.Premise]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("前題").appFont(12, .bold, relativeTo: .caption1).foregroundStyle(Palette.muted)
            ForEach(Array(premises.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.text)
                        .lineSpacing(4)
                    Text("前題答案：\(p.answer)").bold()
                }
                .appFont(fontSize, relativeTo: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.inset))
        .accessibilityElement(children: .combine)
    }
}

/// Stem text, figure crops (tap to zoom) and the missing-figure notice.
struct QuestionStem: View {
    let question: Question
    var fontSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let split = StemLayout.splitPremise(question.stem)
            if let split {
                PremiseBox(premises: split.premises, fontSize: fontSize - 3)
            }
            Text(StemLayout.display(split?.question ?? question.stem))
                .appFont(fontSize)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !question.figures.isEmpty {
                FigureStack(paths: question.figures, optionsInside: question.optionsAsImage)
            } else if question.needsFigureNotice {
                Label("本題有附圖，圖稍後補上", systemImage: "photo")
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.noticeInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.notice))
            }
        }
    }
}

enum FigureCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ path: String) -> UIImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

/// Figure crops on a white card (the crops are scanned on white). Tapping opens the zoomable viewer.
struct FigureStack: View {
    let paths: [String]
    var optionsInside = false
    @State private var viewerIndex: Int?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                if let img = FigureCache.image(path) {
                    Button { viewerIndex = i } label: { card(img) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(optionsInside ? "試卷附圖（含選項 A 到 D）" : "試卷附圖")
                        .accessibilityHint("點兩下放大")
                }
            }
        }
        .fullScreenCover(item: Binding(get: { viewerIndex.map(IndexBox.init) }, set: { viewerIndex = $0?.value })) { box in
            FigureViewer(paths: paths, start: box.value)
        }
    }

    private func card(_ img: UIImage) -> some View {
        // Crops are rendered at about 2× of their printed size; small crops are not blown up past that.
        let naturalWidth = img.size.width * img.scale / 2
        return VStack(spacing: 0) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(img.size, contentMode: .fit)
                .frame(maxWidth: naturalWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: "plus.magnifyingglass")
                Text("點一下放大")
            }
            .appFont(12, .bold, relativeTo: .caption1)
            .foregroundStyle(Palette.heroFill)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct IndexBox: Identifiable {
    let value: Int
    var id: Int { value }
}

/// Full-screen figure viewer with pinch and double-tap zoom.
struct FigureViewer: View {
    let paths: [String]
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                    ZoomableImage(image: FigureCache.image(path))
                        .ignoresSafeArea(edges: .bottom)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: paths.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.onWhiteInk)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.onWhiteChip))
                }
                .accessibilityLabel("關閉附圖")
                Spacer()
                Text("雙指縮放・點兩下放大")
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.onWhiteMuted)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onAppear { page = start }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .white
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        scroll.addSubview(iv)
        context.coordinator.imageView = iv
        context.coordinator.scrollView = scroll
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        DispatchQueue.main.async { context.coordinator.layout() }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var laidOutSize: CGSize = .zero

        func layout() {
            guard let scroll = scrollView, let iv = imageView, scroll.bounds.size != laidOutSize,
                  scroll.bounds.width > 0 else { return }
            laidOutSize = scroll.bounds.size
            scroll.zoomScale = 1
            let inset: CGFloat = 12
            iv.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width - 2 * inset, height: scroll.bounds.height - 2 * inset)
            scroll.contentSize = iv.frame.size
            scroll.contentInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// "本卷可用計算器" style chip.
struct CalculatorChip: View {
    let text: String
    var allowed = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: allowed ? "plusminus.circle" : "nosign")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
        }
        .appFont(12, relativeTo: .caption1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(allowed ? Palette.ink : Palette.muted)
        .background(Capsule().fill(Palette.card))
        .fixedSize()
    }
}

/// One answer option. In exams `.selected` marks the pick without revealing correctness.
struct OptionRow: View {
    enum State { case idle, selected, correct, mine }

    let letter: String
    let text: String
    let state: State
    let tag: String
    /// The options are part of the figure: show the letter only.
    var lettersOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(letter)
                    .appFont(14, .bold, relativeTo: .subheadline)
                    .frame(width: 28, height: 28)
                    .background(Circle().animation(Motion.answerReveal) { $0.foregroundStyle(badge) })
                    .animation(Motion.answerReveal) { $0.foregroundStyle(state == .idle ? Palette.ink : Palette.onAccentOrWhite(state)) }
                if lettersOnly {
                    Text("選項 \(letter)（見圖）")
                        .appFont(15)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text.isEmpty ? "（見附圖）" : text)
                        .appFont(16)
                        .foregroundStyle(text.isEmpty ? Palette.muted : Palette.ink)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A fixed gutter is reserved before and after answering, so the option text keeps its width
                // and never re-wraps when the mark appears. VoiceOver reads the tag text instead.
                Image(systemName: state == .mine ? "xmark" : "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state == .mine ? Palette.warn : Palette.accent)
                    .frame(width: Self.markWidth)
                    .animation(Motion.answerReveal) { $0.opacity(showsMark ? 1 : 0) }
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14).animation(Motion.answerReveal) { $0.foregroundStyle(fill) })
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(lineWidth: 2)
                .animation(Motion.answerReveal) { $0.foregroundStyle(stroke) })
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("選項 \(letter)：\(lettersOnly || text.isEmpty ? "見附圖" : text)")
        .accessibilityValue(tag.replacingOccurrences(of: "\n", with: "，"))
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }

    static let markWidth: CGFloat = 24

    /// Checkmark on accepted answers, xmark on the user's wrong pick; nothing in exams (`.selected`).
    private var showsMark: Bool { state == .correct || state == .mine }

    private var fill: Color {
        switch state {
        case .idle: Palette.card
        case .selected, .correct: Palette.accentSoft
        case .mine: Palette.warnSoft
        }
    }

    private var stroke: Color {
        switch state {
        case .idle: Palette.border
        case .selected, .correct: Palette.accent
        case .mine: Palette.warn
        }
    }

    private var badge: Color {
        switch state {
        case .idle: Palette.badge
        case .selected, .correct: Palette.accent
        case .mine: Palette.warn
        }
    }
}

extension Palette {
    /// Letter color on a filled option badge.
    static func onAccentOrWhite(_ state: OptionRow.State) -> Color {
        state == .mine ? Palette.onWarn : Palette.onAccent
    }
}
