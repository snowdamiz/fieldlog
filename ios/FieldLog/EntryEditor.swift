import CoreTransferable
import FieldLogModels
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EntryEditor: View {
  @EnvironmentObject private var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State var draft: EntryDraft
  @State private var selection: PhotosPickerItem?
  @State private var attaching = false
  @State private var committing = false
  @State private var photoError: String?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Entry title", text: $draft.title, axis: .vertical).font(
            .title3.weight(.semibold)
          ).accessibilityIdentifier("entry-title")
          Picker("Category", selection: $draft.category) {
            ForEach(EntryCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }
          DatePicker("Date", selection: $draft.occurredAt)
        }
        Section("NOTE") {
          TextEditor(text: $draft.note).frame(minHeight: 180).accessibilityLabel("Field note")
            .accessibilityIdentifier("entry-note")
        }
        Section {
          ForEach(currentPhotoIDs, id: \.self) { PhotoPreview(id: $0) }
          PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
            Label("Choose photo", systemImage: "photo.badge.plus")
          }.disabled(attaching || currentPhotoIDs.count >= 8)
          if attaching { ProgressView("Preparing photo…") }
        } header: {
          Text("PHOTOS · \(currentPhotoIDs.count)/8")
        } footer: {
          Text("Selected images are resized and saved locally. They have not been uploaded.")
        }
        Section {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.unsavedDrafts[draft.id] != nil ? "clock" : "checkmark.circle")
              .foregroundStyle(model.unsavedDrafts[draft.id] != nil ? .secondary : FieldStyle.green)
            Text(status).font(.footnote).foregroundStyle(.secondary)
          }
          if model.saveError != nil {
            Button("Retry saving draft") { Task { _ = await model.keepDraft(draft) } }
          }
        }
        Section {
          Button {
            committing = true
            Task {
              if await model.commit(draft) { dismiss() }
              committing = false
            }
          } label: {
            Text("Save entry").frame(maxWidth: .infinity).fontWeight(.semibold)
          }.disabled(
            draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || committing
              || attaching
          ).accessibilityIdentifier("save-entry")
        }
      }
      .navigationTitle("Field note").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { Task { if await model.keepDraft(draft, close: true) { dismiss() } } }
            .disabled(committing || attaching)
        }
      }
    }
    .interactiveDismissDisabled(
      model.pendingSaves > 0 || model.unsavedDrafts[draft.id] != nil || attaching || committing
    )
    .onChange(of: draft) { _, _ in model.scheduleDraft(draft) }
    .onChange(of: selection) { _, item in
      guard let item else { return }
      attaching = true
      Task {
        do {
          guard let picked = try await item.loadTransferable(type: SelectedPhoto.self) else {
            throw FieldLogError.validation("This photo couldn't be opened.")
          }
          defer { try? FileManager.default.removeItem(at: picked.file) }
          let jpeg = try Self.resizedJPEG(picked.file)
          let ids = try await model.addPhoto(jpeg, draftID: draft.id)
          draft.attachmentIDs = ids
          selection = nil
        } catch { photoError = error.localizedDescription }
        attaching = false
      }
    }
    .alert(
      "Photo couldn't be attached",
      isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(photoError ?? "")
    }
  }
  private var currentPhotoIDs: [UUID] {
    model.workspace?.drafts.first { $0.id == draft.id }?.attachmentIDs ?? draft.attachmentIDs
  }
  private var status: String {
    if let error = model.saveError { return error }
    if model.unsavedDrafts[draft.id] != nil || model.pendingSaves > 0 {
      return "Saving draft on this device…"
    }
    return "Draft saved on this device. You can return to it later."
  }
  private static func resizedJPEG(_ file: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.82),
      data.count <= 6_291_456
    else {
      throw FieldLogError.validation(
        "This image couldn't be resized within the supported photo limit.")
    }
    return data
  }
}

private struct SelectedPhoto: Transferable, Sendable {
  let file: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let attrs = try FileManager.default.attributesOfItem(atPath: received.file.path)
      guard let bytes = attrs[.size] as? NSNumber, bytes.intValue > 0,
        bytes.intValue <= 32 * 1024 * 1024
      else { throw FieldLogError.validation("Choose an image smaller than 32 MiB.") }
      let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fieldlog-photo-\(UUID().uuidString)")
      try FileManager.default.copyItem(at: received.file, to: copy)
      return SelectedPhoto(file: copy)
    }
  }
}

struct PhotoPreview: View {
  @EnvironmentObject private var model: WorkspaceModel
  let id: UUID
  @State private var image: UIImage?
  @State private var loaded = false
  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(
          RoundedRectangle(cornerRadius: 12)
        ).accessibilityLabel("Attached field photo")
      } else if loaded {
        Label("Photo unavailable on this device", systemImage: "photo.badge.exclamationmark")
          .foregroundStyle(.secondary)
      } else {
        ProgressView("Opening photo…")
      }
    }
    .task(id: id) {
      if let url = await model.photoURL(id) { image = UIImage(contentsOfFile: url.path) }
      loaded = true
    }
  }
}
