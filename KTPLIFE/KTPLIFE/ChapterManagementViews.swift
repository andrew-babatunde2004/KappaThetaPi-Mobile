import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MerchManagementView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var response: MerchShirtSizesResponse?
    @State private var selectedGroup = "all"
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: String?

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private var availableGroups: [String] {
        Array(Set(response?.members.map(\.memberGroup) ?? [])).sorted()
    }

    private var filteredMembers: [MerchMemberSize] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (response?.members ?? []).filter { member in
            (selectedGroup == "all" || member.memberGroup == selectedGroup)
                && (query.isEmpty || member.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                AppSectionHeading(
                    eyebrow: "Merch Committee",
                    title: "Shirt sizes",
                    systemImage: "tshirt.fill"
                )

                if isLoading && response == nil {
                    ProgressView("Loading shirt sizes...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .appElevatedSurface()
                } else if let loadError, response == nil {
                    Text(loadError)
                        .font(AppFont.subheadline())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                        .padding(18)
                        .appElevatedSurface()
                } else if let response {
                    Picker("Member group", selection: $selectedGroup) {
                        Text("All groups").tag("all")
                        ForEach(availableGroups, id: \.self) { group in
                            Text(MemberGroup(groupValue: group)?.title ?? group.capitalized).tag(group)
                        }
                    }
                    .pickerStyle(.menu)

                    MerchTotalsView(sizes: response.sizes, members: filteredMembers)

                    ForEach(filteredMembers) { member in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.displayName)
                                    .font(AppFont.subheadline(weight: .semibold))
                                    .foregroundStyle(AppSystemColor.primaryLabel)
                                Text(MemberGroup(groupValue: member.memberGroup)?.title ?? member.memberGroup.capitalized)
                                    .font(AppFont.caption())
                                    .foregroundStyle(AppSystemColor.secondaryLabel)
                            }

                            Spacer(minLength: 8)

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("T-shirt: \(member.shirtSize ?? "—")")
                                Text("Sweatshirt: \(member.sweatshirtSize ?? "—")")
                            }
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(AppSystemColor.secondaryLabel)
                        }
                        .padding(14)
                        .appElevatedSurface()
                    }
                }
            }
            .padding(20)
        }
        .background(AppSystemColor.background)
        .navigationTitle("Merch Management")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search members")
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = response == nil
        loadError = nil
        do {
            response = try await apiService.fetchMerchShirtSizes()
        } catch is CancellationError {
            return
        } catch {
            if response == nil {
                loadError = "Shirt sizes could not be loaded. Pull to refresh and try again."
            }
        }
        isLoading = false
    }
}

private struct MerchTotalsView: View {
    let sizes: [String]
    let members: [MerchMemberSize]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Size totals")
                .font(AppFont.headline())

            ForEach(sizes, id: \.self) { size in
                let shirts = members.filter { $0.shirtSize == size }.count
                let sweatshirts = members.filter { $0.sweatshirtSize == size }.count
                HStack {
                    Text(size)
                        .font(AppFont.subheadline(weight: .semibold))
                    Spacer()
                    Text("\(shirts) tees • \(sweatshirts) sweatshirts")
                        .font(AppFont.caption())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }
            }
        }
        .padding(16)
        .appElevatedSurface()
    }
}

struct HomepageMediaManagementView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var slides: [HomepageSlide] = []
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingSlide: HomepageSlide?
    @State private var slidePendingDeletion: HomepageSlide?
    @State private var errorMessage: String?

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                AppSectionHeading(
                    eyebrow: "Chapter Leadership",
                    title: "Homepage media",
                    systemImage: "photo.stack.fill"
                )

                Text("Add, edit, activate, or remove slides shown on the app homepage.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(AppSystemColor.secondaryLabel)

                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Label(isUploading ? "Uploading..." : "Add Homepage Slide", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUploading)

                if isLoading && slides.isEmpty {
                    ProgressView("Loading homepage slides...")
                        .padding(.vertical, 20)
                } else if slides.isEmpty {
                    Text("No homepage slides are configured.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                        .padding(18)
                        .appElevatedSurface()
                } else {
                    ForEach(slides) { slide in
                        HomepageMediaRow(
                            slide: slide,
                            apiService: apiService,
                            edit: { editingSlide = slide },
                            toggleActive: { Task { await toggleActive(slide) } },
                            delete: { slidePendingDeletion = slide }
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(AppSystemColor.background)
        .navigationTitle("Homepage Media")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSlides() }
        .refreshable { await loadSlides() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .sheet(item: $editingSlide) { slide in
            HomepageSlideEditor(slide: slide) { update in
                let saved = try await apiService.updateHomepageSlide(id: slide.id, update: update)
                if let index = slides.firstIndex(where: { $0.id == saved.id }) {
                    slides[index] = saved
                }
            }
        }
        .alert("Delete Homepage Slide?", isPresented: Binding(
            get: { slidePendingDeletion != nil },
            set: { if !$0 { slidePendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { slidePendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let slide = slidePendingDeletion else { return }
                Task { await delete(slide) }
            }
        } message: {
            Text("This permanently removes the slide and its image.")
        }
        .alert("Homepage Media Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    @MainActor
    private func loadSlides() async {
        isLoading = slides.isEmpty
        do {
            slides = try await apiService.fetchHomepageSlides(includeHidden: true)
                .sorted { $0.sortOrder < $1.sortOrder }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Homepage slides could not be loaded."
        }
        isLoading = false
    }

    @MainActor
    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer {
            isUploading = false
            selectedPhoto = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw MessageAttachmentError.unreadableImage
            }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let image = try ImageUploadEncoder.encodeForUpload(data: data, contentType: type)
            let slide = try await apiService.createHomepageSlide(file: MessageAttachmentUpload(
                data: image.data,
                fileName: "homepage-slide.\(image.fileExtension)",
                mimeType: image.mimeType
            ))
            slides.append(slide)
            slides.sort { $0.sortOrder < $1.sortOrder }
            editingSlide = slide
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "The homepage slide could not be uploaded. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func toggleActive(_ slide: HomepageSlide) async {
        do {
            let saved = try await apiService.updateHomepageSlide(
                id: slide.id,
                update: HomepageSlideUpdateRequest(
                    title: slide.title,
                    subtitle: slide.subtitle,
                    altText: slide.altText,
                    linkURL: slide.linkURL?.absoluteString ?? "",
                    linkLabel: slide.linkLabel ?? "",
                    isActive: !slide.isActive,
                    audience: slide.audience.isEmpty ? ["active"] : slide.audience
                )
            )
            if let index = slides.firstIndex(where: { $0.id == saved.id }) {
                slides[index] = saved
            }
        } catch {
            errorMessage = "The slide could not be updated. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func delete(_ slide: HomepageSlide) async {
        slidePendingDeletion = nil
        do {
            try await apiService.deleteHomepageSlide(id: slide.id)
            slides.removeAll { $0.id == slide.id }
        } catch {
            errorMessage = "The slide could not be deleted. \(error.localizedDescription)"
        }
    }
}

private struct HomepageMediaRow: View {
    let slide: HomepageSlide
    let apiService: KTPAPIService
    let edit: () -> Void
    let toggleActive: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ManagedSlideThumbnail(slide: slide, apiService: apiService)

            VStack(alignment: .leading, spacing: 5) {
                Text(slide.title.isEmpty ? "Untitled slide" : slide.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(AppSystemColor.primaryLabel)
                Text(slide.isActive ? "Active" : "Inactive")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(slide.isActive ? AppSurfaceColor.primaryControl : AppSystemColor.secondaryLabel)
                Text(slide.audience.map(\.capitalized).joined(separator: ", "))
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Edit", systemImage: "pencil", action: edit)
                Button(slide.isActive ? "Deactivate" : "Activate", systemImage: slide.isActive ? "eye.slash" : "eye", action: toggleActive)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(14)
        .appElevatedSurface()
    }
}

private struct ManagedSlideThumbnail: View {
    let slide: HomepageSlide
    let apiService: KTPAPIService
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSystemColor.insetBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: slide.id) {
            guard let data = try? await apiService.fetchHomepageSlideMediaData(for: slide) else { return }
            image = UIImage(data: data)
        }
    }
}

private struct HomepageSlideEditor: View {
    @Environment(\.dismiss) private var dismiss
    let slide: HomepageSlide
    let save: (HomepageSlideUpdateRequest) async throws -> Void

    @State private var title: String
    @State private var subtitle: String
    @State private var altText: String
    @State private var linkURL: String
    @State private var linkLabel: String
    @State private var isActive: Bool
    @State private var audience: Set<String>
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let audienceOptions = ["active", "pledge", "alumni", "rush"]

    init(slide: HomepageSlide, save: @escaping (HomepageSlideUpdateRequest) async throws -> Void) {
        self.slide = slide
        self.save = save
        _title = State(initialValue: slide.title)
        _subtitle = State(initialValue: slide.subtitle)
        _altText = State(initialValue: slide.altText)
        _linkURL = State(initialValue: slide.linkURL?.absoluteString ?? "")
        _linkLabel = State(initialValue: slide.linkLabel ?? "")
        _isActive = State(initialValue: slide.isActive)
        _audience = State(initialValue: Set(slide.audience.isEmpty ? ["active"] : slide.audience))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Content") {
                    TextField("Title", text: $title)
                    TextField("Subtitle", text: $subtitle, axis: .vertical)
                    TextField("Image description", text: $altText, axis: .vertical)
                }

                Section("Link") {
                    TextField("https://...", text: $linkURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("Button label", text: $linkLabel)
                }

                Section("Audience") {
                    ForEach(audienceOptions, id: \.self) { option in
                        Toggle(option.capitalized, isOn: Binding(
                            get: { audience.contains(option) },
                            set: { enabled in
                                if enabled { audience.insert(option) } else { audience.remove(option) }
                            }
                        ))
                    }
                }

                Section {
                    Toggle("Active", isOn: $isActive)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Edit Slide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await saveChanges() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audience.isEmpty || isSaving)
                }
            }
        }
    }

    @MainActor
    private func saveChanges() async {
        isSaving = true
        errorMessage = nil
        do {
            try await save(HomepageSlideUpdateRequest(
                title: title,
                subtitle: subtitle,
                altText: altText,
                linkURL: linkURL,
                linkLabel: linkLabel,
                isActive: isActive,
                audience: audienceOptions.filter(audience.contains)
            ))
            dismiss()
        } catch {
            errorMessage = "The slide could not be saved. \(error.localizedDescription)"
            isSaving = false
        }
    }
}
