import PhotosUI
import SwiftUI
import UIKit

struct MemberEditorView: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    @State private var member: FamilyMember
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showPhotoOptions = false

    private let isNew: Bool

    init(store: FListStore, member: FamilyMember, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _member = State(initialValue: member)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Button {
                        showPhotoOptions = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            MemberAvatar(member: member, size: 112)
                            Image(systemName: "camera.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.accentColor, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add photo")
                }
                .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Name", text: $member.name)
                    .textInputAutocapitalization(.words)
            }

            if store.canRemove(member) && !isNew {
                Section {
                    Button("Remove from list", role: .destructive) {
                        Task {
                            await store.deleteMember(member)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add person" : "Edit person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await store.saveMember(member)
                        dismiss()
                    }
                }
                .disabled(member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("Photo", isPresented: $showPhotoOptions, titleVisibility: .visible) {
            Button("Choose photo") { showLibrary = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take photo") { showCamera = true }
            }
            if member.photoData != nil {
                Button("Remove photo", role: .destructive) {
                    member.photoData = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = ProfileImage.jpegData(from: data) {
                    member.photoData = jpeg
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let jpeg = ProfileImage.jpegData(from: image) {
                    member.photoData = jpeg
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                onCapture(image)
            }
            dismiss()
        }
    }
}
