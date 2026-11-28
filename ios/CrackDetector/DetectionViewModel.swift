import SwiftUI
import Observation

@MainActor
@Observable
final class DetectionViewModel {
    enum Phase: Equatable { case idle, loadingModel, inferring(Double), analyzing, done, failed(String) }

    var phase: Phase = .idle
    var options = AnalyzerOptions()
    /// 写真の横幅に写っている実寸(cm)。nil なら px 表示
    var realWidthCm: Double?
    var showOverlay = true
    var selectedCrack: Int?

    private(set) var baseImage: CGImage?
    private(set) var analysis: CrackAnalysis?
    private(set) var overlay: UIImage?
    private var probability: [Float]?
    private var model: CrackModel?
    private var analyzeTask: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .inferring, .analyzing: return true
        default: return false
        }
    }

    /// 1画素あたりの mm
    var mmPerPixel: Double? {
        guard let cm = realWidthCm, cm > 0, let a = analysis else { return nil }
        return cm * 10 / Double(a.width)
    }

    func severity(of c: Crack) -> Severity {
        Severity(maxWidthMM: mmPerPixel.map { c.maxWidthPx * $0 })
    }

    var overallSeverity: Severity? {
        guard let a = analysis, !a.cracks.isEmpty else { return nil }
        return Severity(maxWidthMM: mmPerPixel.map { a.maxWidthPx * $0 })
    }

    func formatLength(_ px: Double) -> String {
        guard let s = mmPerPixel else { return String(format: "%.0f px", px) }
        let mm = px * s
        return mm >= 100 ? String(format: "%.1f cm", mm / 10) : String(format: "%.0f mm", mm)
    }

    func formatWidth(_ px: Double) -> String {
        guard let s = mmPerPixel else { return String(format: "%.1f px", px) }
        return String(format: "%.2f mm", px * s)
    }

    // MARK: - 処理

    func load(_ image: UIImage) {
        analyzeTask?.cancel()
        baseImage = nil; analysis = nil; overlay = nil; probability = nil; selectedCrack = nil
        guard let cg = CrackModel.normalizedImage(image) else { phase = .failed("画像を読み込めませんでした"); return }
        baseImage = cg
        phase = model == nil ? .loadingModel : .inferring(0)
        let existing = model
        analyzeTask = Task {
            do {
                let m = try await Task.detached(priority: .userInitiated) { try existing ?? CrackModel() }.value
                self.model = m
                self.phase = .inferring(0)
                let prob = try await Task.detached(priority: .userInitiated) {
                    try m.predict(cg) { p in Task { @MainActor in if case .inferring = self.phase { self.phase = .inferring(p) } } }
                }.value
                if Task.isCancelled { return }
                self.probability = prob
                await self.reanalyze()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func optionsChanged() {
        guard probability != nil else { return }
        analyzeTask?.cancel()
        analyzeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))  // スライダー操作中の連続実行を抑える
            if Task.isCancelled { return }
            await reanalyze()
        }
    }

    private func reanalyze() async {
        guard let prob = probability, let cg = baseImage else { return }
        phase = .analyzing
        let opt = options, w = cg.width, h = cg.height
        let result = await Task.detached(priority: .userInitiated) {
            CrackAnalyzer.analyze(probability: prob, width: w, height: h, options: opt)
        }.value
        if Task.isCancelled { return }
        analysis = result
        selectedCrack = nil
        redraw()
        phase = .done
    }

    func redraw() {
        guard let a = analysis, let cg = baseImage else { return }
        overlay = OverlayRenderer.render(base: cg, analysis: a, severity: { self.severity(of: $0) }, selected: selectedCrack)
    }

    func reset() {
        analyzeTask?.cancel()
        baseImage = nil; analysis = nil; overlay = nil; probability = nil; selectedCrack = nil
        phase = .idle
    }
}
