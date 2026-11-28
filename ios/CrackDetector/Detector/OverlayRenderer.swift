import UIKit

/// 検出結果を元画像に重ねて描画する
enum OverlayRenderer {
    static func render(base: CGImage, analysis a: CrackAnalysis, severity: (Crack) -> Severity, selected: Int?) -> UIImage? {
        let w = a.width, h = a.height
        guard base.width == w, base.height == h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let colors = a.cracks.map { c -> (UInt8, UInt8, UInt8) in
            let (r, g, b) = severity(c).rgb
            return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
        }
        // ビットマップは上から順に並ぶ
        for i in 0..<(w * h) {
            let p = i * 4
            let n = Int(a.labels[i])
            if n > 0 {
                let c = colors[n - 1]
                px[p] = c.0; px[p + 1] = c.1; px[p + 2] = c.2
            } else {
                px[p] = UInt8(Double(px[p]) * 0.75)
                px[p + 1] = UInt8(Double(px[p + 1]) * 0.75)
                px[p + 2] = UInt8(Double(px[p + 2]) * 0.75)
            }
        }
        guard let tinted = ctx.makeImage() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { r in
            UIImage(cgImage: tinted).draw(at: .zero)
            let g = r.cgContext
            let lw = max(2, CGFloat(w) / 500)
            let fontSize = max(14, CGFloat(w) / 50)
            let font = UIFont.boldSystemFont(ofSize: fontSize)
            for c in a.cracks {
                let (cr, cg, cb) = severity(c).rgb
                let color = UIColor(red: cr, green: cg, blue: cb, alpha: 1)
                let pad = lw * 3
                let rect = CGRect(x: CGFloat(c.bbox.x) - pad, y: CGFloat(c.bbox.y) - pad,
                                  width: CGFloat(c.bbox.width) + pad * 2, height: CGFloat(c.bbox.height) + pad * 2)
                let isSel = selected == c.id
                g.setStrokeColor(color.cgColor)
                g.setLineWidth(isSel ? lw * 2 : lw)
                g.setLineDash(phase: 0, lengths: isSel ? [] : [lw * 4, lw * 3])
                g.stroke(rect)
                g.setLineDash(phase: 0, lengths: [])
                let text = "#\(c.id)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let ts = text.size(withAttributes: attrs)
                let lx = min(max(0, rect.minX), CGFloat(w) - ts.width - 10)
                let ly = rect.minY - ts.height - 6 >= 0 ? rect.minY - ts.height - 6 : rect.maxY
                color.setFill()
                UIRectFill(CGRect(x: lx, y: ly, width: ts.width + 10, height: ts.height + 6))
                text.draw(at: CGPoint(x: lx + 5, y: ly + 3), withAttributes: attrs)
            }
        }
    }
}
