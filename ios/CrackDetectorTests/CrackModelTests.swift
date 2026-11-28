import XCTest
import UIKit
@testable import CrackDetector

/// Core ML モデルを実際の写真で動かし、正解ラベルと比較する
final class CrackModelTests: XCTestCase {

    private func image(_ name: String) throws -> UIImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png"), "\(name).png がテストバンドルにありません")
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }

    /// グレースケールの正解ラベル(>127 がひび)
    private func labelMask(_ img: UIImage, width w: Int, height h: Int) throws -> [Bool] {
        let cg = try XCTUnwrap(img.cgImage)
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf.map { $0 > 127 }
    }

    private func dilate(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        var o = [Bool](repeating: false, count: m.count)
        for y in 0..<h { for x in 0..<w where m[y * w + x] {
            for yy in max(0, y - r)...min(h - 1, y + r) { for xx in max(0, x - r)...min(w - 1, x + r) { o[yy * w + xx] = true } }
        } }
        return o
    }

    func testModelLoadsAndDetectsRealCracks() throws {
        let model = try CrackModel()
        var tp = 0, pp = 0, tg = 0, gg = 0
        for i in 1...3 {
            let img = try image("crack\(i)")
            let cg = try XCTUnwrap(CrackModel.normalizedImage(img))
            let start = Date()
            let prob = try model.predict(cg)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(prob.count, cg.width * cg.height)
            XCTAssertTrue(prob.allSatisfy { $0 >= 0 && $0 <= 1 })

            let gt = try labelMask(try image("crack\(i)_label"), width: cg.width, height: cg.height)
            let pr = prob.map { $0 > 0.5 }
            let gtD = dilate(gt, cg.width, cg.height, 2), prD = dilate(pr, cg.width, cg.height, 2)
            for k in 0..<pr.count {
                if pr[k] { pp += 1; if gtD[k] { tp += 1 } }
                if gt[k] { gg += 1; if prD[k] { tg += 1 } }
            }
            let analysis = CrackAnalyzer.analyze(probability: prob, width: cg.width, height: cg.height, options: AnalyzerOptions())
            print("crack\(i): \(cg.width)x\(cg.height) \(String(format: "%.2f", elapsed))s cracks=\(analysis.cracks.count)")
            XCTAssertGreaterThan(analysis.cracks.count, 0, "crack\(i) でひびが検出されない")
        }
        let p = Double(tp) / Double(max(pp, 1)), r = Double(tg) / Double(max(gg, 1))
        let f1 = 2 * p * r / max(p + r, 1e-9)
        print(String(format: "Core ML pixel P=%.3f R=%.3f F1=%.3f", p, r, f1))
        XCTAssertGreaterThan(p, 0.5, "適合率が低すぎる(前処理の色・向きの不一致の可能性)")
    }

    func testSampleImage() throws {
        let model = try CrackModel()
        let cg = try XCTUnwrap(CrackModel.normalizedImage(SampleImage.make()))
        let prob = try model.predict(cg)
        let a = CrackAnalyzer.analyze(probability: prob, width: cg.width, height: cg.height, options: AnalyzerOptions())
        print("sample: cracks=\(a.cracks.count)")
        XCTAssertGreaterThanOrEqual(a.cracks.count, 1)
        XCTAssertNotNil(OverlayRenderer.render(base: cg, analysis: a, severity: { _ in .unknown }, selected: nil))
    }
}
