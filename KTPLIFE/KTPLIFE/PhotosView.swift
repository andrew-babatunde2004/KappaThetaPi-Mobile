//
//  PhotosView.swift
//  KTPLIFE
//

import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVKit
import CoreTransferable

struct PhotosView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var thumbnailRepository: GalleryThumbnailRepository
    @EnvironmentObject private var galleryContentCache: GalleryContentCache
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var photos: [PhotoItem] = []
    @State private var preparedThumbnails: [String: UIImage] = [:]
    @State private var albums: [PhotoAlbum] = [.general]
    @State private var selectedAlbum = PhotoAlbum.general
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var selectedMedia: MediaSelection?
    @State private var isLoadingGallery = true
    @State private var galleryLoadProgress = 0.0
    @State private var isUploading = false
    @State private var loadError: String?
    @State private var photoPendingDeletion: PhotoItem?
    @State private var deletingPhotoIDs: Set<String> = []
    @State private var deleteErrorMessage: String?

    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }
    
    private var photoService: PhotoService {
        PhotoService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }
    
    
    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 0),
        GridItem(.flexible(minimum: 0), spacing: 0),
        GridItem(.flexible(minimum: 0), spacing: 0),
    ]

    var body: some View {
        let service = photoService

        ZStack(alignment: .topTrailing) {
            PageScaffold(showsPageHeader: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoadingGallery {
                        GalleryLoadingView(progress: galleryLoadProgress)
                            .frame(maxWidth: .infinity, minHeight: 280)
                            .padding(.horizontal, 20)
                    } else if let loadError {
                        PhotosStatusCard(message: loadError)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    } else if photos.isEmpty {
                        ContentUnavailableView(
                            "No chapter media yet",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Use the add button to share the first photo or video.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, 20)
                    }

                    // Zero row and column spacing creates one continuous, edge-to-edge grid.
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            GeometryReader { proxy in
                                AuthenticatedPhotoTile(
                                    photo: photo,
                                    photoService: service,
                                    preparedImage: preparedThumbnails[photo.id],
                                    select: { selectedMedia = MediaSelection(index: index) },
                                    canDelete: canDelete(photo),
                                    requestDeletion: { photoPendingDeletion = photo },
                                    isDeleting: deletingPhotoIDs.contains(photo.id)
                                )
                                .frame(width: proxy.size.width, height: proxy.size.width)
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }

            photoActionsMenu
                .padding(12)
                .zIndex(1)
        }
        // The dismiss control occupies its own top safe-area region, so the first photo
        // cannot receive a tap intended for the back control.
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsCloseButton {
                HStack {
                    Button(action: { dismiss() }) {
                        PhotoCloseButtonLabel()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return to home")

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(PhotosDesign.galleryBackground(for: colorScheme))
            }
        }
        // A downward swipe beginning in the gallery header is an alternate exit for
        // the full-screen presentation. Keeping it out of the grid preserves normal
        // vertical scrolling and photo selection.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard showsCloseButton,
                          value.startLocation.y < 210,
                          value.translation.height > 110,
                          abs(value.translation.height) > abs(value.translation.width) * 1.5
                    else {
                        return
                    }

                    dismiss()
                }
        )
        .task {
            await loadAlbums()
            await loadPhotos()
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .sheet(item: $selectedMedia) { selection in
            AuthenticatedMediaViewer(
                photos: photos,
                initialIndex: selection.index,
                photoService: service
            )
        }
        .confirmationDialog(
            "Delete this media?",
            isPresented: Binding(
                get: { photoPendingDeletion != nil },
                set: { if !$0 { photoPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let photo = photoPendingDeletion else { return }
                photoPendingDeletion = nil
                Task { await deletePhoto(photo) }
            }
            Button("Cancel", role: .cancel) { photoPendingDeletion = nil }
        } message: {
            Text("This permanently removes the photo or video from the chapter gallery.")
        }
        .alert("Couldn’t Delete Media", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "Please try again.")
        }
    }

    /// The client only offers deletion when the gallery response positively
    /// identifies the signed-in member as the uploader. The server still owns
    /// authorization for the DELETE request.
    private func canDelete(_ photo: PhotoItem) -> Bool {
        guard let currentUserID = authManager.currentUserID,
              let uploadedBy = photo.uploadedBy?.nonEmptyTrimmed
        else {
            return false
        }

        return uploadedBy == currentUserID
    }

    private func selectAlbum(_ album: PhotoAlbum) {
        guard selectedAlbum.id != album.id else { return }
        selectedAlbum = album
        selectedMedia = nil
        photos = []
        preparedThumbnails = [:]
        galleryLoadProgress = 0
        isLoadingGallery = true
        loadError = nil
        Task { await loadPhotos() }
    }

    @MainActor
    private func deletePhoto(_ photo: PhotoItem) async {
        guard deletingPhotoIDs.insert(photo.id).inserted else { return }
        deleteErrorMessage = nil
        defer { deletingPhotoIDs.remove(photo.id) }

        do {
            try await photoService.deletePhoto(id: photo.id)
            photos.removeAll { $0.id == photo.id }
            preparedThumbnails[photo.id] = nil
            if selectedAlbum.apiAlbumID == nil {
                galleryContentCache.store(photos: photos, thumbnails: preparedThumbnails)
            }
        } catch is CancellationError {
            return
        } catch {
            deleteErrorMessage = photoDeleteErrorMessage(for: error)
        }
    }
    
    @MainActor
    private func loadPhotos() async {
        let album = selectedAlbum
        if album.apiAlbumID == nil, galleryContentCache.hasLoaded {
            photos = galleryContentCache.photos
            preparedThumbnails = galleryContentCache.thumbnails
            galleryLoadProgress = 1
            isLoadingGallery = false
            loadError = nil
            return
        }

        isLoadingGallery = true
        galleryLoadProgress = 0
#if DEBUG
        if isPreview {
            photos = PhotoItem.previewSamples
            galleryLoadProgress = 1
            isLoadingGallery = false
            loadError = nil
            return
        }
#endif
        
        do {
            let loadedPhotos = try await photoService.fetchPhotos(albumId: album.apiAlbumID)
            var loadedThumbnails: [String: UIImage] = [:]
            let batchSize = 6
            for batchStart in stride(from: 0, to: loadedPhotos.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, loadedPhotos.count)
                let tasks = loadedPhotos[batchStart..<batchEnd].map { photo in
                    Task { @MainActor in
                        (photo.id, await prepareThumbnail(for: photo))
                    }
                }

                for (batchIndex, task) in tasks.enumerated() {
                    guard !Task.isCancelled else {
                        tasks.forEach { $0.cancel() }
                        return
                    }

                    let (photoID, thumbnail) = await task.value
                    if let thumbnail {
                        loadedThumbnails[photoID] = thumbnail
                    }
                    let completedCount = batchStart + batchIndex + 1
                    galleryLoadProgress = Double(completedCount) / Double(max(loadedPhotos.count, 1))
                }
            }

            preparedThumbnails = loadedThumbnails
            photos = loadedPhotos
            if album.apiAlbumID == nil {
                galleryContentCache.store(photos: loadedPhotos, thumbnails: loadedThumbnails)
            }
            if loadedPhotos.isEmpty {
                galleryLoadProgress = 1
            }
            loadError = nil
        } catch {
            photos = []
            preparedThumbnails = [:]
            loadError = photosErrorMessage(for: error)
        }
        isLoadingGallery = false
    }

    @MainActor
    private func loadAlbums() async {
        do {
            let loadedAlbums = try await photoService.fetchAlbums()
            let namedAlbums = loadedAlbums.filter { $0.id != PhotoAlbum.general.id }
            albums = [.general] + namedAlbums.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            if !albums.contains(where: { $0.id == selectedAlbum.id }) {
                selectedAlbum = .general
            }
        } catch is CancellationError {
            return
        } catch {
            // The shared album remains available even if named-album metadata is
            // temporarily unavailable.
            albums = [.general]
        }
    }

    @MainActor
    private func prepareThumbnail(for photo: PhotoItem) async -> UIImage? {
        if photo.isVideo {
            do {
                let data = try await photoService.fetchMediaData(for: photo)
                let url = try await MediaTemporaryFile.write(data: data, suggestedPath: photo.imagePath)
                defer { try? FileManager.default.removeItem(at: url) }
                return await VideoThumbnailGenerator.image(from: url)
            } catch {
                return nil
            }
        }

        return await thumbnailRepository.image(
            for: "gallery-\(photo.id)",
            pointSize: 180,
            displayScale: displayScale,
            loadData: { try await photoService.fetchMediaData(for: photo) }
        )
    }
    
    
    private var photoActionsMenu: some View {
        Menu {
            Section("Albums") {
                ForEach(albums) { album in
                    Button {
                        selectAlbum(album)
                    } label: {
                        Label(
                            album.name,
                            systemImage: selectedAlbum.id == album.id ? "checkmark" : "photo.on.rectangle"
                        )
                    }
                }
            }

            Section {
                Button {
                    isPhotoPickerPresented = true
                } label: {
                    Label("Upload Photos or Videos", systemImage: "photo.badge.plus")
                }
            }
        } label: {
            PhotoGalleryMenuLabel(
                albumName: selectedAlbum.name,
                isUploading: isUploading
            )
        }
        .fixedSize()
        .disabled(isUploading)
        .buttonStyle(.plain)
        .onChange(of: selectedItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await uploadPhotos(from: newItems)
            }
        }
    }

    @MainActor
    private func uploadPhotos(from items: [PhotosPickerItem]) async {
        isUploading = true
        defer {
            isUploading = false
            selectedItems = []
        }

        do {
            var uploadedPhotos: [PhotoItem] = []
            for item in items {
                let data: Data
                let contentType: UTType

                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                        throw PhotoTransferError.unreadableMedia
                    }
                    defer { try? FileManager.default.removeItem(at: video.url) }
                    data = try Data(contentsOf: video.url)
                    contentType = mediaContentType(
                        for: video.url,
                        supportedTypes: item.supportedContentTypes,
                        fallback: .mpeg4Movie
                    )
                } else {
                    // Data.self is the native PhotosPicker representation and is
                    // the path used by older working builds. Some iOS versions
                    // cannot vend a generic Data value for HEIC/Live Photo items,
                    // so retain the file fallback for those cases.
                    if let imageData = try await item.loadTransferable(type: Data.self) {
                        data = imageData
                        contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) && $0.preferredMIMEType != nil }) ?? .jpeg
                    } else {
                        guard let image = try await item.loadTransferable(type: PickedImage.self) else {
                            throw PhotoTransferError.unreadableMedia
                        }
                        defer { try? FileManager.default.removeItem(at: image.url) }
                        data = try Data(contentsOf: image.url)
                        contentType = mediaContentType(
                            for: image.url,
                            supportedTypes: item.supportedContentTypes,
                            fallback: .jpeg
                        )
                    }
                }

                let uploadImage = contentType.conforms(to: .image)
                    ? try ImageUploadEncoder.encodeForUpload(data: data, contentType: contentType)
                    : nil
                let mimeType = uploadImage?.mimeType ?? contentType.preferredMIMEType ?? "image/jpeg"
                let fileExtension = uploadImage?.fileExtension ?? contentType.preferredFilenameExtension ?? "jpg"
                let title = contentType.conforms(to: .movie) ? "Chapter Video" : "Chapter Photo"
                let fileName = "ktp-media-\(UUID().uuidString).\(fileExtension)"
                // Keep the same in-memory multipart request used by the last
                // known-good iOS build for both photos and videos.
                let uploadedPhoto = try await photoService.uploadPhoto(
                    data: uploadImage?.data ?? data,
                    fileName: fileName,
                    mimeType: mimeType,
                    title: title,
                    albumId: selectedAlbum.apiAlbumID
                )
                uploadedPhotos.append(uploadedPhoto)
            }

            if !uploadedPhotos.isEmpty {
                photos.insert(contentsOf: uploadedPhotos.reversed(), at: 0)

                for photo in uploadedPhotos {
                    if let thumbnail = await prepareThumbnail(for: photo) {
                        preparedThumbnails[photo.id] = thumbnail
                    }
                }

                if selectedAlbum.apiAlbumID == nil {
                    galleryContentCache.store(photos: photos, thumbnails: preparedThumbnails)
                }
            }

            loadError = nil
        } catch {
            // An upload failure is not a gallery-loading failure. Keep the
            // existing gallery visible and report the operation that failed.
            loadError = photoUploadErrorMessage(for: error)
        }
    }

    private func photoUploadErrorMessage(for error: Error) -> String {
        if let transferError = error as? PhotoTransferError {
            return transferError.errorDescription ?? "Could not read the selected image or video."
        }

        if case AuthManagerError.notAuthenticated = error {
            return "Your sign-in session has expired. Sign in again and retry the upload."
        }

        if case KTPAPIError.missingAccessToken = error {
            return "Your sign-in session has expired. Sign in again and retry the upload."
        }

        if case KTPAPIError.badStatusCode(let statusCode, _) = error {
            switch statusCode {
            case 401:
                return "Your sign-in session has expired. Sign in again and retry the upload."
            case 403:
                return "This account is not allowed to upload to the chapter gallery."
            case 413:
                return "That photo or video is larger than the 250 MB gallery limit."
            case 415:
                return "That media format could not be processed. Try exporting it as a JPEG, PNG, or MOV."
            default:
                return "The chapter gallery rejected the upload (HTTP \(statusCode))."
            }
        }

        if let urlError = error as? URLError {
            return "The upload could not reach the chapter gallery (\(urlError.localizedDescription))."
        }

        if case KTPAPIError.decodeFailed(_) = error {
            return "The chapter gallery returned an unsupported upload response."
        }

        return "The photo upload failed. Please try again."
    }

    private func photoDeleteErrorMessage(for error: Error) -> String {
        if case AuthManagerError.notAuthenticated = error {
            return "Your sign-in session has expired. Sign in again and retry the deletion."
        }

        if case KTPAPIError.missingAccessToken = error {
            return "Your sign-in session has expired. Sign in again and retry the deletion."
        }

        if case KTPAPIError.badStatusCode(let statusCode, _) = error {
            switch statusCode {
            case 403:
                return "Only the member who uploaded this media can delete it."
            case 404:
                return "This media is no longer in the chapter gallery."
            default:
                return "The chapter gallery could not delete this media (HTTP \(statusCode))."
            }
        }

        return "The media could not be deleted. Please try again."
    }

    private func mediaContentType(for url: URL, supportedTypes: [UTType], fallback: UTType) -> UTType {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type
        }

        // PhotosPicker may provide a temporary file without an extension. In
        // that case preserve the library's declared HEIC/HEIF type instead of
        // falsely labelling its bytes as JPEG, which causes server validation
        // and HEIC transcoding to fail.
        if fallback.conforms(to: .movie) {
            return supportedTypes.first(where: { $0.conforms(to: .movie) && $0 != .movie })
                ?? supportedTypes.first(where: { $0.conforms(to: .movie) })
                ?? fallback
        }

        return supportedTypes.first(where: { $0.conforms(to: .image) && $0 != .image })
            ?? supportedTypes.first(where: { $0.conforms(to: .image) })
            ?? fallback
    }

    private func photosErrorMessage(for error: Error) -> String {
        if let transferError = error as? PhotoTransferError {
            return transferError.errorDescription ?? "Could not read the selected image or video."
        }

        if case AuthManagerError.notAuthenticated = error {
            return "Sign in with SSO to load photos."
        }

        if case KTPAPIError.missingAccessToken = error {
            return "Sign in with SSO to load photos."
        }

        if case KTPAPIError.badStatusCode(let statusCode, _) = error {
            if statusCode == 401 {
                return "Your photo access has expired. Sign out and sign in again."
            }

            if statusCode == 403 {
                return "This account is not allowed to upload to the chapter gallery."
            }

            if statusCode == 413 {
                return "That photo or video is larger than the 250 MB gallery limit."
            }

            if statusCode == 415 {
                return "That media format could not be processed. Try exporting it as a JPEG, PNG, or MOV."
            }

            return "The chapter gallery is temporarily unavailable. Please try again later."
        }

        if case KTPAPIError.decodeFailed(_) = error {
            return "The chapter gallery returned an unsupported response. Please try again later."
        }

        return "Could not load the chapter gallery. Please check your connection and try again."
    }
}

private struct MediaSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct AuthenticatedPhotoTile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var thumbnailRepository: GalleryThumbnailRepository
    let photo: PhotoItem
    let photoService: PhotoService
    let preparedImage: UIImage?
    let select: () -> Void
    let canDelete: Bool
    let requestDeletion: () -> Void
    let isDeleting: Bool

    @State private var image: UIImage?
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        Button(action: select) {
            PhotosDesign.tileBackground(for: colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let displayedImage = image ?? preparedImage {
                        Image(uiImage: displayedImage)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.58), in: Circle())
                            .padding(7)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await downloadMedia() }
            } label: {
                Label(isDownloading ? "Saving…" : "Save to Photos", systemImage: "arrow.down.to.line")
            }
            .disabled(isDownloading)

            if canDelete {
                Divider()

                Button(role: .destructive, action: requestDeletion) {
                    Label(isDeleting ? "Deleting…" : "Delete", systemImage: "trash")
                }
                .disabled(isDeleting)
            }
        }
        .accessibilityLabel("\(photo.title). Tap to view full size. Long press to save\(canDelete ? " or delete" : "").")
        .background {
            GeometryReader { proxy in
                Color.clear
                    .task(id: thumbnailRequestID(for: proxy.size)) {
                        await loadThumbnail(for: proxy.size)
                    }
            }
        }
        .alert("Couldn’t Save Media", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    private func thumbnailRequestID(for size: CGSize) -> String {
        "\(photo.id)-\(Int((size.width * displayScale).rounded(.up)))"
    }

    @MainActor
    private func loadThumbnail(for size: CGSize) async {
        if preparedImage != nil {
            image = nil
            return
        }

        guard size.width > 0 else {
            image = nil
            return
        }

        if photo.isVideo {
            do {
                let data = try await photoService.fetchMediaData(for: photo)
                let url = try await MediaTemporaryFile.write(data: data, suggestedPath: photo.imagePath)
                defer { try? FileManager.default.removeItem(at: url) }
                image = await VideoThumbnailGenerator.image(from: url)
            } catch is CancellationError {
                return
            } catch {
                image = nil
            }
            return
        }

        let thumbnail = await thumbnailRepository.image(
            for: "gallery-\(photo.id)",
            pointSize: size.width,
            displayScale: displayScale,
            loadData: { try await photoService.fetchMediaData(for: photo) }
        )
        guard !Task.isCancelled else { return }
        image = thumbnail
    }

    @MainActor
    private func downloadMedia() async {
        isDownloading = true
        defer { isDownloading = false }

        do {
            let data = try await photoService.fetchMediaData(for: photo)
            try await PhotoLibrarySaver.save(data: data, isVideo: photo.isVideo)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

private struct AuthenticatedMediaViewer: View {
    @Environment(\.dismiss) private var dismiss

    let photos: [PhotoItem]
    let photoService: PhotoService

    @State private var selectedIndex: Int
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var reportTarget: ReportTarget?

    init(photos: [PhotoItem], initialIndex: Int, photoService: PhotoService) {
        self.photos = photos
        self.photoService = photoService
        _selectedIndex = State(initialValue: min(max(0, initialIndex), max(0, photos.count - 1)))
    }

    private var selectedPhoto: PhotoItem? {
        guard photos.indices.contains(selectedIndex) else { return nil }
        return photos[selectedIndex]
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedIndex) {
                ForEach(photos.indices, id: \.self) { index in
                    AuthenticatedMediaPage(
                        photo: photos[index],
                        photoService: photoService
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(selectedPhoto?.title ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveMedia() }
                    } label: {
                        Image(systemName: isSaving ? "hourglass" : "arrow.down.to.line")
                    }
                    .disabled(isSaving || selectedPhoto == nil)
                    .accessibilityLabel("Save to Photos")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Report", role: .destructive) {
                        if let selectedPhoto {
                            reportTarget = .photo(selectedPhoto)
                        }
                    }
                    .disabled(selectedPhoto == nil)
                }
            }
        }
        .alert("Couldn’t Save Media", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .sheet(item: $reportTarget) { target in
            ReportContentSheet(target: target)
        }
    }

    @MainActor
    private func saveMedia() async {
        guard let selectedPhoto else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let data = try await photoService.fetchMediaData(for: selectedPhoto)
            try await PhotoLibrarySaver.save(data: data, isVideo: selectedPhoto.isVideo)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

private struct AuthenticatedMediaPage: View {
    let photo: PhotoItem
    let photoService: PhotoService

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                ContentUnavailableView(
                    "Media Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "This media could not be loaded.")
                )
                .foregroundStyle(.white)
            }
        }
        .task(id: photo.id) {
            await loadMedia()
        }
        .accessibilityLabel("\(photo.title), \(photo.isVideo ? "video" : "photo")")
    }

    @MainActor
    private func loadMedia() async {
        image = nil
        player?.pause()
        player = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await photoService.fetchMediaData(for: photo)
            guard !Task.isCancelled else { return }

            if photo.isVideo {
                let url = try await MediaTemporaryFile.write(data: data, suggestedPath: photo.imagePath)
                player = AVPlayer(url: url)
            } else if let loadedImage = await decodeViewerImage(from: data) {
                image = loadedImage
            } else {
                errorMessage = "This file is not a supported image."
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decodeViewerImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }
}

private enum PhotoTransferError: LocalizedError {
    case unreadableMedia

    var errorDescription: String? {
        "Could not read the selected image or video."
    }
}

private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copiedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: received.file, to: copiedURL)
            return PickedVideo(url: copiedURL)
        }
    }
}

private struct PickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let copiedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: received.file, to: copiedURL)
            return PickedImage(url: copiedURL)
        }
    }
}

private enum MediaTemporaryFile {
    static func write(data: Data, suggestedPath: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let extensionValue = URL(fileURLWithPath: suggestedPath).pathExtension
            let hasVideoExtension = UTType(filenameExtension: extensionValue)?.conforms(to: .movie) == true
            let fileExtension = hasVideoExtension ? extensionValue : "mp4"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }
}

private enum VideoThumbnailGenerator {
    static func image(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let requestedTime = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let (cgImage, _) = try? await generator.image(at: requestedTime) {
            return UIImage(cgImage: cgImage)
        }
        if let (cgImage, _) = try? await generator.image(at: .zero) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}

private enum PhotoLibrarySaver {
    static func save(data: Data, isVideo: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.accessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.unknown)
                }
            }
        }
    }
}

private enum PhotoLibrarySaveError: LocalizedError {
    case accessDenied
    case unknown

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Allow KTP Me to add photos in Settings to save this media."
        case .unknown:
            return "The media could not be saved to your photo library."
        }
    }
}

private struct PhotoGalleryMenuLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let albumName: String
    let isUploading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isUploading ? "hourglass" : "photo.on.rectangle.angled")
                .font(.system(size: 16, weight: .semibold))

            Text(isUploading ? "Uploading" : albumName)
                .font(AppFont.headline())
                .lineLimit(1)

            if !isUploading {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundStyle(PhotosDesign.addButtonForeground(for: colorScheme))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(isUploading ? "Uploading media" : "Choose album or upload media")
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(PhotosDesign.tileBorder(for: colorScheme), lineWidth: 1)
        }
    }
}

private struct PhotoCloseButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(PhotosDesign.addButtonForeground(for: colorScheme))
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .background(PhotosDesign.closeButtonBackground(for: colorScheme), in: Circle())
    }
}

private struct GalleryLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    let progress: Double

    var body: some View {
        VStack(spacing: 14) {
            Text("Preparing gallery")
                .font(AppFont.headline())
                .foregroundStyle(PhotosDesign.addButtonForeground(for: colorScheme))

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(AppSystemColor.primaryLabel)
                .frame(maxWidth: 260)

            Text(progress > 0 ? "\(Int((progress * 100).rounded()))%" : "Loading photos…")
                .font(AppFont.footnote())
                .foregroundStyle(PhotosDesign.secondaryText(for: colorScheme))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing gallery")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}


private struct PhotosStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String

    var body: some View {
        Text(message)
            .font(AppFont.footnote())
            .foregroundStyle(PhotosDesign.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(PhotosDesign.tileBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PhotosDesign.tileBorder(for: colorScheme), lineWidth: 1)
            }
    }
}

private enum PhotosDesign {
    static func galleryBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.background
    }

    static func tileBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.elevatedBackground
    }

    static func tileBorder(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.separator.opacity(colorScheme == .dark ? 0.60 : 0.35)
    }

    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.secondaryLabel
    }

    static func addButtonForeground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel
    }

    static func glassTint(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.elevatedBackground.opacity(colorScheme == .dark ? 0.76 : 0.86)
    }

    static func closeButtonBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.elevatedBackground
    }
}
         

#if DEBUG
#Preview("Photos") {
    PhotosView()
        .background(AppTab.photos.theme.previewBackground())
        .environmentObject(AuthManager.previewSignedOut)
        .environmentObject(GalleryThumbnailRepository())
        .environmentObject(GalleryContentCache())
}
#endif
