import UIKit

/// 動作確認用の合成画像(コンクリート壁にひびとシミ)
enum SampleImage {
    static func make() -> UIImage {
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            let g = r.cgContext
            let colors = [UIColor(white: 0.78, alpha: 1).cgColor, UIColor(white: 0.65, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            // ざらつき
            for _ in 0..<60000 {
                let v = 0.5 + (rnd() - 0.5) * 0.5
                g.setFillColor(UIColor(white: v, alpha: 0.12).cgColor)
                g.fill(CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 2, height: 2))
            }
            // シミ
            g.setFillColor(UIColor(red: 0.35, green: 0.33, blue: 0.29, alpha: 0.35).cgColor)
            g.fillEllipse(in: CGRect(x: 880, y: 555, width: 140, height: 90))
            g.fillEllipse(in: CGRect(x: 236, y: 636, width: 28, height: 28))
            // ひび
            g.setStrokeColor(UIColor(red: 0.18, green: 0.16, blue: 0.14, alpha: 0.9).cgColor)
            g.setLineCap(.round)
            func crack(_ x0: Double, _ y0: Double, _ a0: Double, _ steps: Int, _ width: Double) {
                var x = x0, y = y0, a = a0
                for i in 0..<steps {
                    a += (rnd() - 0.5) * 0.6
                    let nx = x + cos(a) * 6, ny = y + sin(a) * 6
                    g.setLineWidth(max(1, width * (1 - Double(i) / Double(steps) * 0.6)))
                    g.move(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: nx, y: ny)); g.strokePath()
                    x = nx; y = ny
                    if rnd() < 0.015 && width > 2 { crack(x, y, a + (rnd() - 0.5) * 1.6, steps / 3, width * 0.5) }
                }
            }
            crack(120, 120, 0.55, 150, 6)
            crack(700, 80, 1.9, 90, 2.5)
        }
    }
}
