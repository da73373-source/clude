import SwiftUI

struct ResultView: View {
    @Bindable var vm: DetectionViewModel
    @State private var showSettings = false
    @State private var widthText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                imageSection
                if let a = vm.analysis {
                    summary(a)
                    scaleField
                    crackList(a)
                }
                Text("※結果はAIによる簡易的な目安です。建物の安全性の判断は、専門家による調査を受けてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("検出設定", systemImage: "slider.horizontal.3") { showSettings = true }
            }
            ToolbarItem(placement: .bottomBar) {
                if let img = vm.overlay {
                    ShareLink(item: Image(uiImage: img), preview: SharePreview("ひび割れ検出結果", image: Image(uiImage: img))) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm).presentationDetents([.medium, .large])
        }
        .onChange(of: vm.options) { _, _ in vm.optionsChanged() }
    }

    private var imageSection: some View {
        VStack(spacing: 8) {
            Picker("表示", selection: $vm.showOverlay) {
                Text("検出結果").tag(true)
                Text("元画像").tag(false)
            }
            .pickerStyle(.segmented)

            ZStack {
                Group {
                    if vm.showOverlay && !vm.isCalibrating, let img = vm.overlay {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else if let cg = vm.baseImage {
                        Image(decorative: cg, scale: 1).resizable().scaledToFit()
                    }
                }
                .overlay { calibrationLayer }
                if vm.isBusy { progressBadge }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if vm.isCalibrating {
                Label(vm.calibrationPoints.count < 2 ? "定規の目盛りの2点をタップしてください(\(vm.calibrationPoints.count)/2)" : "2点の間の長さを下に入力してください",
                      systemImage: "hand.tap")
                    .font(.footnote).foregroundStyle(.tint)
            }
            if case .failed(let msg) = vm.phase {
                Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        }
    }

    /// 画像の上で2点をタップして縮尺を合わせるためのレイヤー
    private var calibrationLayer: some View {
        GeometryReader { geo in
            let iw = CGFloat(vm.baseImage?.width ?? 1), ih = CGFloat(vm.baseImage?.height ?? 1)
            let k = min(geo.size.width / iw, geo.size.height / ih)
            let ox = (geo.size.width - iw * k) / 2, oy = (geo.size.height - ih * k) / 2
            let toView = { (p: CGPoint) in CGPoint(x: ox + p.x * k, y: oy + p.y * k) }
            ZStack {
                if vm.calibrationPoints.count == 2 {
                    Path { path in
                        path.move(to: toView(vm.calibrationPoints[0]))
                        path.addLine(to: toView(vm.calibrationPoints[1]))
                    }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                ForEach(Array(vm.calibrationPoints.enumerated()), id: \.offset) { _, p in
                    Circle().stroke(Color.cyan, lineWidth: 2).background(Circle().fill(.cyan.opacity(0.3)))
                        .frame(width: 18, height: 18).position(toView(p))
                }
            }
            .contentShape(Rectangle())
            .allowsHitTesting(vm.isCalibrating)
            .onTapGesture { loc in
                let x = (loc.x - ox) / k, y = (loc.y - oy) / k
                guard x >= 0, y >= 0, x < iw, y < ih else { return }
                vm.addCalibrationPoint(CGPoint(x: x, y: y))
            }
        }
    }

    private var progressBadge: some View {
        HStack(spacing: 8) {
            ProgressView()
            switch vm.phase {
            case .loadingModel: Text("AIモデルを準備中…")
            case .inferring(let p): Text("AIで解析中… \(Int(p * 100))%")
            default: Text("計測中…")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private func summary(_ a: CrackAnalysis) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatCard(title: "検出したひび", value: "\(a.cracks.count) 本")
                StatCard(title: "総延長", value: a.cracks.isEmpty ? "—" : vm.formatLength(a.totalLengthPx))
            }
            GridRow {
                StatCard(title: "最大幅", value: a.cracks.isEmpty ? "—" : vm.formatWidth(a.maxWidthPx))
                if let s = vm.overallSeverity {
                    StatCard(title: "総合判定", value: s == .unknown ? "実寸未入力" : s.label, color: s == .unknown ? nil : s.color)
                } else {
                    StatCard(title: "総合判定", value: "ひびなし")
                }
            }
        }
    }

    @State private var rulerText = ""

    private var scaleField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("実寸の設定").font(.headline)
            // 方法1: 定規の2点
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("定規で合わせる(おすすめ)").font(.subheadline.bold())
                    Spacer()
                    Button(vm.isCalibrating ? "完了" : (vm.calibrationPoints.count == 2 ? "やり直す" : "2点を指定")) {
                        if vm.isCalibrating { vm.isCalibrating = false; vm.redraw() }
                        else { vm.calibrationPoints = []; vm.isCalibrating = true }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if vm.calibrationPoints.count == 2 {
                    HStack {
                        Text(String(format: "2点の間(%.0f px)=", vm.calibrationPixelDistance ?? 0)).font(.footnote)
                        TextField("例: 100", text: $rulerText)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            .onChange(of: rulerText) { _, t in
                                vm.calibrationMM = Double(t.replacingOccurrences(of: ",", with: "."))
                                vm.redraw()
                            }
                        Text("mm")
                        Button("消去", systemImage: "xmark.circle.fill") { rulerText = ""; vm.clearCalibration() }
                            .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                }
                Text("写真に写した定規やメジャーの目盛りを2点タップし、その間の長さを入力します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("または、写真の横幅に写っている実際の長さ").font(.subheadline.bold())
            HStack {
                TextField("例: 30", text: $widthText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: widthText) { _, t in
                        vm.realWidthCm = Double(t.replacingOccurrences(of: ",", with: "."))
                        vm.redraw()
                    }
                Text("cm")
            }
            if let src = vm.scaleSourceDescription {
                Label(src, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                Text("入力すると幅を mm で表示し、危険度を判定します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func crackList(_ a: CrackAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !a.cracks.isEmpty {
                Text("検出したひび").font(.headline).padding(.bottom, 6)
            }
            ForEach(a.cracks) { c in
                let s = vm.severity(of: c)
                Button {
                    vm.selectedCrack = vm.selectedCrack == c.id ? nil : c.id
                    vm.showOverlay = true
                    vm.redraw()
                } label: {
                    HStack {
                        Text("#\(c.id)").font(.body.monospacedDigit().bold()).frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("長さ \(vm.formatLength(c.lengthPx))")
                            Text("幅 平均 \(vm.formatWidth(c.meanWidthPx)) / 最大 \(vm.formatWidth(c.maxWidthPx))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s != .unknown {
                            Text(s.label).font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(s.color, in: Capsule())
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(vm.selectedCrack == c.id ? Color.accentColor.opacity(0.1) : .clear)
                Divider()
            }
            if let s = vm.overallSeverity, s != .unknown {
                Text(s.detail).font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsSheet: View {
    @Bindable var vm: DetectionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("感度: \(Int(vm.options.sensitivity))")
                        Slider(value: $vm.options.sensitivity, in: 0...100, step: 5)
                    }
                } footer: { Text("上げると薄いひびも拾いますが、模様や汚れの誤検出も増えます") }
                Section {
                    VStack(alignment: .leading) {
                        Text("最小の長さ: 画像対角の \(Int(vm.options.minLengthPercent))%")
                        Slider(value: $vm.options.minLengthPercent, in: 1...20, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("細長さの下限: 長さ ÷ 幅 ≧ \(Int(vm.options.minElongation))")
                        Slider(value: $vm.options.minElongation, in: 2...20, step: 1)
                    }
                    Toggle("途切れたひびをつなげる", isOn: $vm.options.connect)
                } footer: { Text("細長さの下限を上げると、シミや穴など丸い暗部を除外します") }
                Section {
                    Button("初期値に戻す") { vm.options = AnalyzerOptions() }
                }
            }
            .navigationTitle("検出設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}

extension Severity {
    var color: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
}
