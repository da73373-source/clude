import CoreML
import CoreGraphics
import UIKit

/// Core ML の U-Net で画像からひびの確率マップを推定する
final class CrackModel {
    static let tile = 512
    static let overlap = 48
    /// 推論・解析する解像度(長辺)
    static let maxSide = 1024

    private let model: MLModel
    private let imageConstraint: MLImageConstraint?

    init(bundle: Bundle = .main) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let url: URL
        if let compiled = bundle.url(forResource: "CrackUNet", withExtension: "mlmodelc") {
            url = compiled
        } else if let pkg = bundle.url(forResource: "CrackUNet", withExtension: "mlpackage") {
            url = try MLModel.compileModel(at: pkg)
        } else {
            throw CrackModelError.modelNotFound
        }
        model = try MLModel(contentsOf: url, configuration: config)
        imageConstraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
    }

    /// 長辺 maxSide に縮小した RGBA 画像を作る(向きも補正)
    static func normalizedImage(_ image: UIImage, maxSide: Int = CrackModel.maxSide) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let s = min(1, CGFloat(maxSide) / max(size.width, size.height))
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return img.cgImage
    }

    private static func tileStarts(_ len: Int) -> [Int] {
        if len <= tile { return [0] }
        var out: [Int] = []
        var x = 0
        while true {
            if x + tile >= len { out.append(len - tile); break }
            out.append(x)
            x += tile - overlap * 2
        }
        return out
    }

    /// 確率マップ(width*height, 0〜1)を返す
    func predict(_ cg: CGImage, progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let w = cg.width, h = cg.height, T = Self.tile
        var acc = [Float](repeating: 0, count: w * h)
        var cnt = [Float](repeating: 0, count: w * h)
        let xs = Self.tileStarts(w), ys = Self.tileStarts(h)
        var done = 0
        for ty in ys {
            for tx in xs {
                let tw = min(T, w), th = min(T, h)
                guard let tileImage = Self.makeTile(cg, x: tx, y: ty, w: tw, h: th) else { throw CrackModelError.imageConversion }
                let value: MLFeatureValue
                if let c = imageConstraint {
                    value = try MLFeatureValue(cgImage: tileImage, constraint: c, options: nil)
                } else {
                    value = try MLFeatureValue(cgImage: tileImage, pixelsWide: T, pixelsHigh: T, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
                }
                let input = try MLDictionaryFeatureProvider(dictionary: ["image": value])
                let out = try model.prediction(from: input)
                guard let arr = out.featureValue(for: "prob")?.multiArrayValue else { throw CrackModelError.badOutput }
                let probs = Self.floats(arr)
                for y in 0..<th {
                    for x in 0..<tw {
                        let i = (ty + y) * w + tx + x
                        acc[i] += probs[y * T + x]
                        cnt[i] += 1
                    }
                }
                done += 1
                progress?(Double(done) / Double(xs.count * ys.count))
            }
        }
        for i in 0..<acc.count where cnt[i] > 0 { acc[i] /= cnt[i] }
        return acc
    }

    /// 512x512 のタイル画像。画像が小さい場合は端の画素を引き伸ばして埋める
    private static func makeTile(_ cg: CGImage, x: Int, y: Int, w: Int, h: Int) -> CGImage? {
        let T = tile
        guard let ctx = CGContext(data: nil, width: T, height: T, bitsPerComponent: 8, bytesPerRow: T * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        guard let crop = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
        ctx.interpolationQuality = .none
        // CGContext は左下原点なので、上端に合わせて描く
        if w < T, let edge = crop.cropping(to: CGRect(x: w - 1, y: 0, width: 1, height: h)) {
            ctx.draw(edge, in: CGRect(x: w, y: T - h, width: T - w, height: h))
        }
        if h < T, let edge = crop.cropping(to: CGRect(x: 0, y: h - 1, width: w, height: 1)) {
            ctx.draw(edge, in: CGRect(x: 0, y: 0, width: w, height: T - h))
            if w < T, let corner = crop.cropping(to: CGRect(x: w - 1, y: h - 1, width: 1, height: 1)) {
                ctx.draw(corner, in: CGRect(x: w, y: 0, width: T - w, height: T - h))
            }
        }
        ctx.draw(crop, in: CGRect(x: 0, y: T - h, width: w, height: h))
        return ctx.makeImage()
    }

    /// MLMultiArray [1,1,T,T] を Float 配列(行優先 T*T)に変換
    static func floats(_ a: MLMultiArray) -> [Float] {
        let T = tile
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        let sy = strides[shape.count - 2], sx = strides[shape.count - 1]
        var out = [Float](repeating: 0, count: T * T)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for y in 0..<T { for x in 0..<T { out[y * T + x] = p[y * sy + x * sx] } }
        #if arch(arm64)
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
            for y in 0..<T { for x in 0..<T { out[y * T + x] = Float(p[y * sy + x * sx]) } }
        #endif
        default:
            for y in 0..<T {
                for x in 0..<T {
                    out[y * T + x] = a[[0, 0, NSNumber(value: y), NSNumber(value: x)] as [NSNumber]].floatValue
                }
            }
        }
        return out
    }
}

enum CrackModelError: LocalizedError {
    case modelNotFound, imageConversion, badOutput
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "AIモデルが見つかりません"
        case .imageConversion: return "画像を変換できませんでした"
        case .badOutput: return "AIモデルの出力が不正です"
        }
    }
}
