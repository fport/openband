import PhotosUI
import SwiftUI

/// A square that is either a photo or a dashed invitation to add one. Tapping offers the
/// camera and the library; `PhotosPicker` runs out of process, so the library needs no
/// permission of its own.
struct PhotoWell: View {
    let label: String
    @Binding var image: UIImage?

    @State private var item: PhotosPickerItem?
    @State private var takingPhoto = false

    var body: some View {
        VStack(spacing: FBSpace.xxs) {
            Menu {
                Button {
                    takingPhoto = true
                } label: {
                    Label(String(localized: "Take a photo"), systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                    Label(String(localized: "Choose a photo"), systemImage: "photo")
                }
                if image != nil {
                    Button(String(localized: "Remove"), role: .destructive) { image = nil }
                }
            } label: {
                well
            }
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(.textSecondary)
        }
        .sheet(isPresented: $takingPhoto) { CameraPicker(image: $image) }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self) {
                    image = UIImage(data: data)
                }
                item = nil
            }
        }
        .accessibilityLabel(Text(label))
    }

    private var well: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous)
                    .strokeBorder(Color.action, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.action)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.85, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The system camera. `PHPicker` cannot take a photo, so this is the one place UIKit is needed.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
