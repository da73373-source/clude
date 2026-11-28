import XCTest
@testable import CrackDetector

final class CrackAnalyzerTests: XCTestCase {

    /// 斜めの線(ひび)と丸い塊(シミ)を含む確率マップ
    private func syntheticMap(w: Int, h: Int) -> [Float] {
        var p = [Float](repeating: 0.02, count: w * h)
        for t in stride(from: 0.0, through: 1.0, by: 0.001) {
            let cx = 20 + 160 * t, cy = 20 + 160 * t
            for dy in -1...1 { for dx in -1...1 {
                let x = Int(cx.rounded()) + dx, y = Int(cy.rounded()) + dy
                p[y * w + x] = 0.95
            } }
        }
        for y in 0..<h { for x in 0..<w where (x - 150) * (x - 150) + (y - 45) * (y - 45) <= 15 * 15 {
            p[y * w + x] = 0.95
        } }
        return p
    }

    func testDetectsLineAndRejectsBlob() {
        let w = 200, h = 200
        let r = CrackAnalyzer.analyze(probability: syntheticMap(w: w, h: h), width: w, height: h, options: AnalyzerOptions())
        XCTAssertEqual(r.cracks.count, 1, "線だけが検出され、丸いシミは除外されるはず")
        let c = try! XCTUnwrap(r.cracks.first)
        let expected = 160 * 2.0.squareRoot()
        XCTAssertEqual(c.lengthPx, expected, accuracy: expected * 0.1)
        XCTAssertEqual(c.meanWidthPx, 3.5, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(c.maxWidthPx, 2)
        XCTAssertLessThanOrEqual(c.maxWidthPx, 7)
        // ラベルはひびの画素だけに付く
        XCTAssertEqual(r.labels[100 * w + 100], 1)
        XCTAssertEqual(r.labels[45 * w + 150], 0)
    }

    func testSensitivityThreshold() {
        let w = 100, h = 100
        var p = [Float](repeating: 0, count: w * h)
        for x in 10..<90 { p[50 * w + x] = 0.45; p[51 * w + x] = 0.45 }
        var opt = AnalyzerOptions()
        opt.sensitivity = 0   // 閾値 0.8 → 検出しない
        XCTAssertEqual(CrackAnalyzer.analyze(probability: p, width: w, height: h, options: opt).cracks.count, 0)
        opt.sensitivity = 100 // 閾値 0.2 → 検出する
        XCTAssertEqual(CrackAnalyzer.analyze(probability: p, width: w, height: h, options: opt).cracks.count, 1)
    }

    func testEmptyMap() {
        let r = CrackAnalyzer.analyze(probability: [Float](repeating: 0, count: 64 * 48), width: 64, height: 48, options: AnalyzerOptions())
        XCTAssertTrue(r.cracks.isEmpty)
    }

    /// AI の出力が太い帯でも、写真の暗さから細いひびの幅を正しく測る
    func testHairlineWidthFromDarkness() {
        let w = 300, h = 120
        var gray = [Float](repeating: 150, count: w * h)
        var prob = [Float](repeating: 0, count: w * h)
        for x in 20..<280 {
            for y in 59...60 { gray[y * w + x] = 70 }          // 幅2pxの暗い線
            for y in 50...69 { prob[y * w + x] = 0.9 }         // AI は幅20pxの帯を出力
        }
        // 軽いざらつき
        var seed: UInt32 = 1
        for i in 0..<(w * h) { seed = seed &* 1664525 &+ 1013904223; gray[i] += Float(seed >> 28) - 8 }

        let regionOnly = CrackAnalyzer.analyze(probability: prob, width: w, height: h, options: AnalyzerOptions())
        let withGray = CrackAnalyzer.analyze(probability: prob, gray: CrackAnalyzer.boxMean(gray, w, h, 1), width: w, height: h, options: AnalyzerOptions())
        let r = try! XCTUnwrap(regionOnly.cracks.first), d = try! XCTUnwrap(withGray.cracks.first)
        XCTAssertGreaterThan(r.maxWidthPx, 15, "領域の幅は帯の太さになる")
        XCTAssertTrue(d.widthFromDarkness)
        XCTAssertLessThanOrEqual(d.maxWidthPx, 6, "暗さから測ると細いひびの幅になる")
        XCTAssertGreaterThanOrEqual(d.meanWidthPx, 1)
        XCTAssertLessThanOrEqual(d.meanWidthPx, d.maxWidthPx + 1e-9)
    }

    func testSeverity() {
        XCTAssertEqual(Severity(maxWidthMM: nil), .unknown)
        XCTAssertEqual(Severity(maxWidthMM: 0.2), .hairline)
        XCTAssertEqual(Severity(maxWidthMM: 0.3), .caution)
        XCTAssertEqual(Severity(maxWidthMM: 0.5), .inspect)
    }
}
