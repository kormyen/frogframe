import SwiftUI
import ImageIO

@main
struct FrogframeApp: App {
    @State private var library = LibraryModel()
    var body: some Scene {
        Window("Frogframe", id: "library") {
            LibraryView(library: library)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Select All") { library.selection = Set(library.selectableIDs) }
                    .keyboardShortcut("a", modifiers: .command)
            }
        }
        Settings { ConnectionView(library: library) }
    }
}

struct LibraryView: View {
    @Bindable var library: LibraryModel
    @State private var importing = false
    @State private var confirmingDelete = false
    @State private var connectionOpen = false
    @State private var choosingSyncFolder = false
    @State private var photoFrames: [String: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var dragBaseSelection: Set<String>?


    var body: some View {
        VStack(spacing: 0) {
            if let folder = library.syncFolder {
                HStack {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .help(folder.path)
                    Text(library.folderStatus).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Show Folder") { NSWorkspace.shared.open(folder) }
                    Button("Stop Sync") { library.stopFolderSync() }.disabled(library.busy)
                }
                .font(.callout).padding(.horizontal, 20).padding(.vertical, 9)
                Divider()
            }
            if library.service == nil {
                ContentUnavailableView {
                    Label("Connect to your photo bucket", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add the photo server address and management token to get started.")
                } actions: {
                    Button("Connect…") { connectionOpen = true }
                }
            } else if library.photos.isEmpty && !library.busy {
                ContentUnavailableView {
                    Label("Add your first images", systemImage: "photo.badge.plus")
                } description: {
                    Text("Drop image files here, or choose Add Images.")
                } actions: {
                    Button("Add Images…") { importing = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(library.photos) { photo in
                            if let service = library.service {
                                PhotoTile(photo: photo, service: service, selected: library.selection.contains(photo.id),
                                          select: { modifiers in
                                              library.select(photo, extending: modifiers.contains(.command),
                                                             range: modifiers.contains(.shift))
                                          }, preview: { library.preview = photo },
                                          openInFinder: { Task { await library.openInFinder(photo) } },
                                          canOpenInFinder: library.syncFolder != nil)
                            }
                        }
                        ForEach(library.pendingUploads) { upload in
                            UploadTile(upload: upload, selected: library.selection.contains(upload.selectionID)) { modifiers in
                                library.selectUpload(upload, extending: modifiers.contains(.command), range: modifiers.contains(.shift))
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                    .coordinateSpace(name: "photoGrid")
                    .contentShape(Rectangle())
                    .onPreferenceChange(PhotoFramePreference.self) { photoFrames = $0 }
                    .overlay(alignment: .topLeading) {
                        if let selectionRect {
                            Rectangle()
                                .fill(Color(nsColor: .controlAccentColor).opacity(0.15))
                                .overlay { Rectangle().stroke(Color(nsColor: .controlAccentColor), lineWidth: 1) }
                                .frame(width: selectionRect.width, height: selectionRect.height)
                                .offset(x: selectionRect.minX, y: selectionRect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("photoGrid"))
                            .onChanged { value in
                                if dragBaseSelection == nil {
                                    let extending = !(NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).intersection([.command, .shift]).isEmpty
                                    dragBaseSelection = extending ? library.selection : []
                                }
                                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                                  y: min(value.startLocation.y, value.location.y),
                                                  width: abs(value.location.x - value.startLocation.x),
                                                  height: abs(value.location.y - value.startLocation.y))
                                selectionRect = rect
                                let hits = Set(photoFrames.filter { $0.value.intersects(rect) }.map(\.key))
                                library.selection = (dragBaseSelection ?? []).union(hits)
                            }
                            .onEnded { _ in
                                selectionRect = nil
                                dragBaseSelection = nil
                            }
                    )
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("photoGrid"))
                        .onEnded { value in
                            let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
                            guard !modifiers.contains(.shift),
                                  !photoFrames.values.contains(where: { $0.contains(value.location) }) else { return }
                            library.deselectAll()
                        }
                )
            }
            Divider()
            HStack(spacing: 10) {
                if library.busy { ProgressView().controlSize(.small) }
                Text(library.status.isEmpty
                     ? (library.uploadSummary.isEmpty ? "\(library.photos.count) images" : library.uploadSummary)
                     : library.status)
                Spacer()
                if !library.selection.isEmpty { Text("\(library.selection.count) selected") }
                Text("Drop images to add · Drag or Shift-click to select")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.bar)
        }
        .tint(Color(nsColor: .controlAccentColor))
        .frame(minWidth: 650, minHeight: 420)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Images", systemImage: "plus") { importing = true }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(library.busy || library.service == nil)
                Button(library.hasSelectedUploads ? "Cancel Uploads" : "Delete", systemImage: "trash") {
                    if library.hasSelectedUploads { library.cancelSelectedUploads() }
                    else { confirmingDelete = true }
                }
                    .disabled(!library.hasSelectedUploads && (library.busy || library.selection.isEmpty))
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(library.busy || library.service == nil)
                Button(library.syncFolder == nil ? "Sync Folder" : "Change Sync Folder", systemImage: "folder.badge.gearshape") {
                    choosingSyncFolder = true
                }
                .disabled(library.busy || library.service == nil)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .disabled(library.busy)
            }
        }
        .dropDestination(for: URL.self, isEnabled: !library.busy && library.service != nil) { urls, _ in
            Task { await library.add(urls) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): Task { await library.add(files) }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingSyncFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): Task { await library.chooseSyncFolder(folder) }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .onDeleteCommand {
            if library.hasSelectedUploads { library.cancelSelectedUploads() }
            else if !library.busy && !library.selection.isEmpty { confirmingDelete = true }
        }
        .confirmationDialog("Delete \(library.selection.count) selected images from the bucket?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Images", role: .destructive) { Task { await library.deleteSelection() } }
        } message: {
            Text(library.syncFolder == nil
                 ? "Local files on your Mac will stay in place."
                 : "Copies in the sync folder will be moved to the Trash. Other local files will stay in place.")
        }
        .alert("Frogframe", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: $connectionOpen) { ConnectionView(library: library) }
        .sheet(item: $library.preview) { photo in
            if let service = library.service { PreviewView(photo: photo, service: service) }
        }
        .task { await library.refresh() }
    }
}

private struct PhotoFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PhotoTile: View {
    let photo: Photo
    let service: PhotoService
    let selected: Bool
    let select: (NSEvent.ModifierFlags) -> Void
    let preview: () -> Void
    let openInFinder: () -> Void
    let canOpenInFinder: Bool
    @State private var modifiersOnPress: NSEvent.ModifierFlags = []

    var body: some View {
        Button {
            select(modifiersOnPress.union(NSApp.currentEvent?.modifierFlags ?? []))
            modifiersOnPress = []
        } label: {
            ThumbnailView(photo: photo, service: service, pixels: 500)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color(nsColor: .controlAccentColor) : .clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            modifiersOnPress = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        })
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PhotoFramePreference.self,
                                       value: [photo.id: geometry.frame(in: .named("photoGrid"))])
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded(preview))
        .accessibilityLabel(photo.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("View Image", action: preview)
            Button("Open in Finder", action: openInFinder)
                .disabled(!canOpenInFinder)
        }
    }
}

struct UploadTile: View {
    let upload: PendingUpload
    let selected: Bool
    let select: (NSEvent.ModifierFlags) -> Void
    @State private var image: CGImage?
    @State private var failed = false
    @State private var modifiersOnPress: NSEvent.ModifierFlags = []

    var body: some View {
        Button {
            select(modifiersOnPress.union(NSApp.currentEvent?.modifierFlags ?? []))
            modifiersOnPress = []
        } label: {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: failed ? "photo" : "photo.badge.arrow.down")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(upload.completed ? 1 : 0.45)
            .overlay(alignment: .bottomTrailing) {
                if !upload.completed {
                    ProgressView().controlSize(.small).padding(8).background(.regularMaterial, in: Circle()).padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color(nsColor: .controlAccentColor) : .clear, lineWidth: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(upload.completed)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            modifiersOnPress = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        })
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PhotoFramePreference.self,
                    value: upload.completed ? [:] : [upload.selectionID: geometry.frame(in: .named("photoGrid"))])
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(upload.file.lastPathComponent)
        .accessibilityValue(upload.completed ? "Uploaded" : "Waiting for upload")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: upload.id) {
            let file = upload.file
            let task = Task.detached(priority: .utility) { () -> CGImage? in
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 500,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            let thumbnail = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            image = thumbnail
            failed = thumbnail == nil
        }
    }
}

struct ThumbnailView: View {
    let photo: Photo
    let service: PhotoService
    let pixels: Int
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.primary.opacity(0.06))
                    .aspectRatio(5.0 / 3.0, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08))
                    }
                    .overlay {
                        if failed {
                            Label("Image unavailable", systemImage: "photo")
                                .foregroundStyle(.secondary).font(.callout)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: "\(photo.url)-\(pixels)") {
            failed = false
            do { image = try await service.thumbnail(photo, pixels: pixels) }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct PreviewView: View {
    let photo: Photo
    let service: PhotoService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ThumbnailView(photo: photo, service: service, pixels: 2000)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20).frame(width: 900, height: 650)
    }
}

struct ConnectionView: View {
    let library: LibraryModel
    @State private var endpoint = ""
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Photo server", text: $endpoint).textContentType(.URL)
            SecureField("Management token", text: $token)
            Text("The token is stored in your Mac Keychain.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Connect") {
                    Task {
                        await library.configure(BucketConfiguration(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
                        if library.error == nil { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(library.busy)
            }
        }
        .formStyle(.grouped).padding(12).frame(width: 500)
        .onAppear {
            endpoint = library.configuration?.endpoint ?? ""
            token = library.configuration?.token ?? ""
        }
    }
}
