import Foundation
import CoreGraphics

/// 1本のひび割れの計測結果
struct Crack: Identifiable, Hashable {
    let id: Int              // 1始まりの番号(長い順)
    let bbox: CGRectInt
    let area: Int
    let lengthPx: Double
    let meanWidthPx: Double
    let maxWidthPx: Double
    /// 幅を写真の暗さから測ったか(false: AIの領域の幅)
    var widthFromDarkness: Bool = false
}

struct CGRectInt: Hashable {
    let x: Int, y: Int, width: Int, height: Int
}

/// 解析結果
struct CrackAnalysis {
    let width: Int
    let height: Int
    let cracks: [Crack]
    /// 画素ごとのひび番号(0 = なし)
    let labels: [Int32]

    var totalLengthPx: Double { cracks.reduce(0) { $0 + $1.lengthPx } }
    var maxWidthPx: Double { cracks.map(\.maxWidthPx).max() ?? 0 }
}

/// 検出の設定
struct AnalyzerOptions: Equatable {
    /// 0〜100。大きいほど薄いひびも拾う
    var sensitivity: Double = 50
    /// 画像対角線に対する最小長さ(%)
    var minLengthPercent: Double = 3
    /// 長さ ÷ 平均幅 の下限
    var minElongation: Double = 6
    /// 途切れたひびをつなげる
    var connect: Bool = true
    /// 暗さから測った幅に掛ける係数(DeepCrack 学習画像の正解幅で校正)
    var darkWidthScale: Double = 1.6
}

/// 確率マップからひび割れを抽出し、長さ・幅を計測する(Web版 detector.js と同じアルゴリズム)
enum CrackAnalyzer {

    /// - Parameters:
    ///   - gray: 輝度(0〜255, width*height)。渡すと幅を写真の暗さから測る(細いひびの幅の過大評価を防ぐ)
    static func analyze(probability prob: [Float], gray: [Float]? = nil, width w: Int, height h: Int, options opt: AnalyzerOptions) -> CrackAnalysis {
        precondition(prob.count == w * h)
        let n = w * h
        let diag = (Double(w * w + h * h)).squareRoot()

        // 1. ヒステリシス二値化
        let thr = Float(0.8 - opt.sensitivity / 100 * 0.6)
        let weak = thr * 0.6
        var mask = [UInt8](repeating: 0, count: n)
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        for i in 0..<n where prob[i] > thr { mask[i] = 1; stack.append(i) }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            for dy in -1...1 {
                let yy = y + dy
                if yy < 0 || yy >= h { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    if xx < 0 || xx >= w { continue }
                    let q = yy * w + xx
                    if mask[q] == 0 && prob[q] > weak { mask[q] = 1; stack.append(q) }
                }
            }
        }
        if opt.connect { mask = erode(dilate(mask, w, h), w, h) }

        // 2. 連結成分と粗い足切り
        let minLen = opt.minLengthPercent / 100 * diag
        let (labels, comps) = label(mask, w, h)
        var keep = [Bool](repeating: false, count: comps.count + 1)
        for c in comps {
            let span = (Double((c.maxX - c.minX + 1) * (c.maxX - c.minX + 1) + (c.maxY - c.minY + 1) * (c.maxY - c.minY + 1))).squareRoot()
            if c.area >= 10 && span >= minLen { keep[c.id] = true }
        }
        var cand = [UInt8](repeating: 0, count: n)
        for i in 0..<n where keep[Int(labels[i])] { cand[i] = 1 }

        // 3. 細線化と距離変換
        let skel = thin(cand, w, h)
        let dist = distance(cand, w, h)
        var skelPix: [Int32: [Int]] = [:]
        for i in 0..<n where skel[i] != 0 { skelPix[labels[i], default: []].append(i) }

        // 幅は「暗さ」から測る: 各ひび領域で中心の暗さの半分以上暗い画素(半値幅)を本体とみなし、校正係数を掛ける
        var coreWidths: [Int32: [Double]] = [:]
        if let gray {
            let rW = max(15, Int((Double(max(w, h)) / 30).rounded()))
            let meanW = boxMean(gray, w, h, rW)
            var depth = [Float](repeating: 0, count: n)
            for i in 0..<n { depth[i] = meanW[i] - gray[i] }
            var byComp: [Int32: [Float]] = [:]
            for i in 0..<n where cand[i] != 0 { byComp[labels[i], default: []].append(depth[i]) }
            var coreThr: [Int32: Float] = [:]
            for (id, v) in byComp {
                let sorted = v.sorted()
                coreThr[id] = max(3, 0.5 * sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
            }
            var core = [UInt8](repeating: 0, count: n)
            for i in 0..<n where cand[i] != 0 && depth[i] >= (coreThr[labels[i]] ?? .infinity) { core[i] = 1 }
            let coreSkel = thin(core, w, h)
            let coreDist = distance(core, w, h)
            for i in 0..<n where coreSkel[i] != 0 {
                coreWidths[labels[i], default: []].append(max(1.0, 2.0 * Double(coreDist[i]) - 1.0))
            }
        }

        // 4. 形状評価
        struct Tmp { let id: Int32; let c: Component; let length: Double; let mean: Double; let maxW: Double; let dark: Bool }
        var found: [Tmp] = []
        for c in comps where keep[c.id] {
            guard let pix = skelPix[Int32(c.id)], !pix.isEmpty else { continue }
            let length = skeletonLength(skel, w, pix)
            let widths = pix.map { max(1.0, 2.0 * Double(dist[$0]) - 1.0) }.sorted()
            let mean = Double(c.area) / length
            let maxW = widths[min(widths.count - 1, Int(Double(widths.count) * 0.95))]
            if length < minLen || length / max(1, mean) < opt.minElongation { continue }
            var meanOut = mean, maxOut = maxW, dark = false
            if let cw = coreWidths[Int32(c.id)], Double(cw.count) >= 0.3 * Double(pix.count) {
                let s = cw.sorted()
                meanOut = min(mean, opt.darkWidthScale * s.reduce(0, +) / Double(s.count))
                maxOut = min(maxW, opt.darkWidthScale * s[min(s.count - 1, Int(Double(s.count) * 0.95))])
                dark = true
            }
            found.append(Tmp(id: Int32(c.id), c: c, length: length, mean: meanOut, maxW: maxOut, dark: dark))
        }
        found.sort { $0.length > $1.length }

        var numberOf: [Int32: Int32] = [:]
        var cracks: [Crack] = []
        for (k, t) in found.enumerated() {
            numberOf[t.id] = Int32(k + 1)
            cracks.append(Crack(id: k + 1,
                                bbox: CGRectInt(x: t.c.minX, y: t.c.minY, width: t.c.maxX - t.c.minX + 1, height: t.c.maxY - t.c.minY + 1),
                                area: t.c.area, lengthPx: t.length, meanWidthPx: t.mean, maxWidthPx: t.maxW,
                                widthFromDarkness: t.dark))
        }
        var out = [Int32](repeating: 0, count: n)
        for i in 0..<n where cand[i] != 0 { out[i] = numberOf[labels[i]] ?? 0 }
        return CrackAnalysis(width: w, height: h, cracks: cracks, labels: out)
    }

    /// 積分画像による箱型平均(半径 r)
    static func boxMean(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        let W = w + 1
        var integ = [Double](repeating: 0, count: W * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(src[y * w + x])
                integ[(y + 1) * W + x + 1] = integ[y * W + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let s = integ[y1 * W + x1] - integ[y0 * W + x1] - integ[y1 * W + x0] + integ[y0 * W + x0]
                out[y * w + x] = Float(s / Double((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }

    /// RGB 画像の輝度(3x3 平均で軽く平滑化。Web 版と同じ)
    static func luminance(_ cg: CGImage) -> [Float]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var g = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            g[i] = 0.299 * Float(buf[i * 4]) + 0.587 * Float(buf[i * 4 + 1]) + 0.114 * Float(buf[i * 4 + 2])
        }
        return boxMean(g, w, h, 1)
    }

    // MARK: - 形態演算

    static func dilate(_ m: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = 0
                outer: for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0 && xx < w && m[yy * w + xx] != 0 { v = 1; break outer }
                    }
                }
                o[y * w + x] = v
            }
        }
        return o
    }

    static func erode(_ m: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = 1
                outer: for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0 && xx < w && m[yy * w + xx] == 0 { v = 0; break outer }
                    }
                }
                o[y * w + x] = v
            }
        }
        return o
    }

    struct Component { let id: Int; let area: Int; let minX: Int; let minY: Int; let maxX: Int; let maxY: Int }

    /// 8近傍の連結成分ラベリング
    static func label(_ m: [UInt8], _ w: Int, _ h: Int) -> ([Int32], [Component]) {
        var labels = [Int32](repeating: 0, count: m.count)
        var comps: [Component] = []
        var stack: [Int] = []
        var next: Int32 = 0
        for i in 0..<m.count where m[i] != 0 && labels[i] == 0 {
            next += 1
            var count = 0, minX = w, minY = h, maxX = 0, maxY = 0
            labels[i] = next
            stack.append(i)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let q = yy * w + xx
                        if m[q] != 0 && labels[q] == 0 { labels[q] = next; stack.append(q) }
                    }
                }
            }
            comps.append(Component(id: Int(next), area: count, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
        }
        return (labels, comps)
    }

    /// Zhang-Suen 細線化
    static func thin(_ mask: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var m = mask
        var pts: [Int] = []
        for i in 0..<m.count where m[i] != 0 {
            let x = i % w, y = i / w
            if x > 0 && y > 0 && x < w - 1 && y < h - 1 { pts.append(i) } else { m[i] = 0 }
        }
        var changed = true
        var del: [Int] = []
        while changed {
            changed = false
            for step in 0..<2 {
                del.removeAll(keepingCapacity: true)
                for i in pts where m[i] != 0 {
                    let p2 = Int(m[i - w]), p3 = Int(m[i - w + 1]), p4 = Int(m[i + 1]), p5 = Int(m[i + w + 1])
                    let p6 = Int(m[i + w]), p7 = Int(m[i + w - 1]), p8 = Int(m[i - 1]), p9 = Int(m[i - w - 1])
                    let b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
                    if b < 2 || b > 6 { continue }
                    let seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                    var a = 0
                    for k in 0..<8 where seq[k] == 0 && seq[k + 1] == 1 { a += 1 }
                    if a != 1 { continue }
                    if step == 0 {
                        if p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0 { continue }
                    } else {
                        if p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0 { continue }
                    }
                    del.append(i)
                }
                if !del.isEmpty {
                    changed = true
                    for i in del { m[i] = 0 }
                }
            }
            pts = pts.filter { m[$0] != 0 }
        }
        return m
    }

    /// 3-4 チャンファー距離変換(単位: 画素)
    static func distance(_ mask: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        let inf: Float = 1e9
        var d = mask.map { $0 != 0 ? inf : 0 }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if d[i] == 0 { continue }
                var v = d[i]
                v = min(v, x > 0 ? d[i - 1] + 3 : 3)
                if y > 0 {
                    v = min(v, d[i - w] + 3)
                    if x > 0 { v = min(v, d[i - w - 1] + 4) }
                    if x < w - 1 { v = min(v, d[i - w + 1] + 4) }
                } else { v = min(v, 3) }
                d[i] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                if d[i] == 0 { continue }
                var v = d[i]
                v = min(v, x < w - 1 ? d[i + 1] + 3 : 3)
                if y < h - 1 {
                    v = min(v, d[i + w] + 3)
                    if x < w - 1 { v = min(v, d[i + w + 1] + 4) }
                    if x > 0 { v = min(v, d[i + w - 1] + 4) }
                } else { v = min(v, 3) }
                d[i] = v
            }
        }
        return d.map { $0 / 3 }
    }

    /// 骨格の長さ(斜めは √2)
    static func skeletonLength(_ s: [UInt8], _ w: Int, _ pixels: [Int]) -> Double {
        var len = 0.0
        let n = s.count
        func at(_ i: Int) -> Bool { i >= 0 && i < n && s[i] != 0 }
        for i in pixels {
            if at(i + 1) { len += 1 }
            if at(i + w) { len += 1 }
            if at(i + w + 1) && !at(i + 1) && !at(i + w) { len += 2.0.squareRoot() }
            if at(i + w - 1) && !at(i - 1) && !at(i + w) { len += 2.0.squareRoot() }
        }
        return max(len, pixels.isEmpty ? 0 : 1)
    }
}

/// 幅による判定
enum Severity: String {
    case unknown, hairline, caution, inspect

    init(maxWidthMM: Double?) {
        guard let mm = maxWidthMM else { self = .unknown; return }
        self = mm < 0.3 ? .hairline : (mm < 0.5 ? .caution : .inspect)
    }

    var label: String {
        switch self {
        case .unknown: return "幅不明"
        case .hairline: return "ヘアクラック"
        case .caution: return "要注意"
        case .inspect: return "要点検"
        }
    }

    var detail: String {
        switch self {
        case .unknown: return "実寸を入力すると判定します"
        case .hairline: return "幅0.3mm未満。表面の乾燥収縮などによる細いひび。経過観察で可"
        case .caution: return "幅0.3〜0.5mm。雨水が浸入する可能性。補修を検討"
        case .inspect: return "幅0.5mm以上。構造的なひび割れの可能性。専門家への相談を推奨"
        }
    }

    /// RGB(0〜1)
    var rgb: (Double, Double, Double) {
        switch self {
        case .unknown: return (0.88, 0.11, 0.28)
        case .hairline: return (0.92, 0.70, 0.03)
        case .caution: return (0.98, 0.45, 0.09)
        case .inspect: return (0.86, 0.15, 0.15)
        }
    }
}
