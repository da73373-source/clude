import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var vm = DetectionViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.baseImage == nil {
                    StartView(pickerItem: $pickerItem, showCamera: $showCamera, onSample: { vm.load(SampleImage.make()) })
                } else {
                    ResultView(vm: vm)
                }
            }
            .navigationTitle("ひび割れ検出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vm.baseImage != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る", systemImage: "chevron.left") { vm.reset(); pickerItem = nil }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("撮影", systemImage: "camera") { showCamera = true }
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    vm.load(img)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in vm.load(img) }
                .ignoresSafeArea()
        }
    }
}

struct StartView: View {
    @Binding var pickerItem: PhotosPickerItem?
    @Binding var showCamera: Bool
    var onSample: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "rectangle.split.3x3")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                Text("壁のひび割れを写真から検出")
                    .font(.title2.bold())
                Text("外壁・内壁・基礎などの写真から、AIがひび割れを見つけて長さと幅の目安を表示します。写真は端末内で処理され、外部に送信されません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            Label("写真を撮る", systemImage: "camera.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("ライブラリから選ぶ", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button("サンプル画像で試す", action: onSample)
                        .buttonStyle(.borderless)
                }
                .controlSize(.large)

                TipsView()
            }
            .padding()
        }
    }
}

struct TipsView: View {
    var body: some View {
        GroupBox("撮影のコツ") {
            VStack(alignment: .leading, spacing: 8) {
                Label("壁に正対して、ひびに近づいて撮影", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("定規やクラックスケールを写し込むと、実寸で幅を判定できます", systemImage: "ruler")
                Label("強い斜光や影、目地・タイルの継ぎ目は誤検出の原因になります", systemImage: "sun.max")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
