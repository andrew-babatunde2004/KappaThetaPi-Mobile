import QuickLook
import SafariServices
import SwiftUI

struct DocumentsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var documentDestination: DocumentDestination?
    @State private var openingDocumentID: String?
    @State private var previewError: String?

    private var service: ChapterResourcesService {
        ChapterResourcesService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        NavigationStack {
            DocumentLevelView(
                folder: nil,
                service: service,
                openingDocumentID: openingDocumentID,
                openDocument: openDocument
            )
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AppFont.subheadline(weight: .semibold))
                }
            }
        }
        .tint(AppSystemColor.primaryLabel)
        .background(AppSystemColor.background.ignoresSafeArea())
        .sheet(item: $documentDestination) { destination in
            switch destination {
            case .preview(let item):
                DocumentQuickLookView(url: item.url)
                    .ignoresSafeArea()
            case .externalLink(let item):
                ExternalDocumentView(url: item.url)
                    .ignoresSafeArea()
            }
        }
        .alert("Could Not Open Document", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "Please try again.")
        }
    }

    @MainActor
    private func openDocument(_ document: ChapterDocument) {
        guard openingDocumentID == nil else { return }

        // Linked resources such as Google Docs do not have a file payload for
        // Quick Look. Present them in the app's browser instead of requesting
        // the upload-only preview endpoint.
        if let externalURL = document.externalURL {
            documentDestination = .externalLink(ExternalDocumentLink(url: externalURL))
            return
        }

        openingDocumentID = document.id

        Task {
            defer { openingDocumentID = nil }
            do {
                let payload = try await service.previewDocument(document)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("KTPDocumentPreviews", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let filename = sanitizedFilename(payload.suggestedFilename, fallback: document.name)
                let fileURL = directory.appendingPathComponent(filename)
                try payload.data.write(to: fileURL, options: .atomic)
                documentDestination = .preview(LocalDocumentPreview(url: fileURL))
            } catch is CancellationError {
                return
            } catch {
                previewError = chapterResourceErrorMessage(for: error)
            }
        }
    }

    private func sanitizedFilename(_ suggestedFilename: String, fallback: String) -> String {
        let candidate = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback
            : suggestedFilename
        return candidate.replacingOccurrences(of: "/", with: "-")
    }
}

struct AttendanceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var events: [CalendarEvent] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var attendanceSummary: PersonalAttendanceSummary?
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = true) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    AppSectionHeading(
                        eyebrow: "Chapter Resources",
                        title: "Attendance tracker",
                        systemImage: "checkmark.seal.fill"
                    )

                    MyAttendanceSection(
                        events: events,
                        summary: attendanceSummary,
                        isLoading: isLoading,
                        error: loadError
                    )
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Attendance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .font(AppFont.subheadline(weight: .semibold))
                    }
                }
            }
            .task {
                await loadAttendance()
            }
            .refreshable {
                await loadAttendance()
            }
        }
        .tint(AppSystemColor.primaryLabel)
        .background(AppSystemColor.background.ignoresSafeArea())
    }

    @MainActor
    private func loadAttendance() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let service = CalendarNetworkService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
        let apiService = KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })

        do {
            let refreshedEvents = try await service.fetchCalendarEvents()
                .filter { $0.myAttendance != nil }
                .sorted { $0.startDate > $1.startDate }

            // Attendance records are historical. Keep the last successful
            // result if a refresh temporarily returns an empty projection.
            if !refreshedEvents.isEmpty || events.isEmpty {
                events = refreshedEvents
            }
        } catch is CancellationError {
            return
        } catch {
            if events.isEmpty {
                loadError = "Attendance could not be loaded. Pull to refresh and try again."
            }
        }

        do {
            let semesters = try await apiService.fetchAttendanceSemesters()
            if let currentSemester = semesters.first(where: { $0.contains(day: Self.todayInChapterTimeZone) }) {
                attendanceSummary = try await apiService
                    .fetchPersonalAttendance(semesterID: currentSemester.id)
                    .summary
            } else {
                attendanceSummary = nil
            }
        } catch is CancellationError {
            return
        } catch {
            // The event history remains useful if the semester summary is temporarily unavailable.
        }
    }

    private static var todayInChapterTimeZone: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct DocumentLevelView: View {
    let folder: DocumentFolder?
    let service: ChapterResourcesService
    let openingDocumentID: String?
    let openDocument: (ChapterDocument) -> Void

    @State private var folders: [DocumentFolder] = []
    @State private var documents: [ChapterDocument] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                if folder == nil {
                    AppSectionHeading(
                        eyebrow: "Chapter Library",
                        title: "Shared resources",
                        systemImage: "doc.on.doc.fill"
                    )
                    .padding(.bottom, 6)
                }

                if isLoading {
                    ChapterResourceStatusView(message: "Loading documents...")
                } else if let loadError {
                    ChapterResourceStatusView(message: loadError)
                } else if folders.isEmpty && documents.isEmpty {
                    ChapterResourceStatusView(message: "This folder is empty.")
                } else {
                    if !folders.isEmpty {
                        resourceSectionTitle("Folders")
                        ForEach(folders) { folder in
                            NavigationLink {
                                DocumentLevelView(
                                    folder: folder,
                                    service: service,
                                    openingDocumentID: openingDocumentID,
                                    openDocument: openDocument
                                )
                                .navigationTitle(folder.name)
                                .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                DocumentFolderRow(folder: folder)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !documents.isEmpty {
                        resourceSectionTitle("Files")
                            .padding(.top, folders.isEmpty ? 0 : 12)
                        ForEach(documents) { document in
                            Button {
                                openDocument(document)
                            } label: {
                                DocumentRow(
                                    document: document,
                                    isOpening: openingDocumentID == document.id
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(openingDocumentID != nil)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(AppSystemColor.background)
        .task(id: folder?.id ?? "root") {
            await loadLevel()
        }
        .refreshable {
            await loadLevel()
        }
    }

    private func resourceSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.1)
            .foregroundStyle(AppSystemColor.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func loadLevel() async {
        isLoading = true
        loadError = nil
        do {
            async let loadedFolders = service.fetchFolders(parentID: folder?.id)
            async let loadedDocuments = service.fetchDocuments(folderID: folder?.id)
            folders = try await loadedFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            documents = try await loadedDocuments.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch is CancellationError {
            return
        } catch {
            folders = []
            documents = []
            loadError = chapterResourceErrorMessage(for: error)
        }
        isLoading = false
    }

}

private struct MyAttendanceSection: View {
    let events: [CalendarEvent]
    let summary: PersonalAttendanceSummary?
    let isLoading: Bool
    let error: String?

    private var presentCount: Int { events.filter { $0.myAttendance?.lowercased() == "present" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Attendance", systemImage: "checkmark.seal.fill")
                    .font(AppFont.title(20))
                    .foregroundStyle(AppSystemColor.primaryLabel)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(presentCount) of \(events.count) attended")
                        if let summary {
                            Text("\(summary.absences) of \(summary.allowance) absences used")
                        }
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(AppSurfaceColor.primaryControl)
                }
            }

            if events.isEmpty {
                if let error {
                    Text(error)
                        .font(AppFont.footnote())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                } else if isLoading {
                    Text("Loading your attendance history...")
                        .font(AppFont.footnote())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                } else {
                    Text("Your recorded event attendance will appear here.")
                        .font(AppFont.footnote())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }
            } else {
                ForEach(events) { event in
                    HStack(spacing: 12) {
                        Image(systemName: event.myAttendance?.lowercased() == "present" ? "checkmark.circle.fill" : "calendar.badge.clock")
                            .foregroundStyle(event.myAttendance?.lowercased() == "present" ? AppSurfaceColor.primaryControl : AppSystemColor.secondaryLabel)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(AppFont.subheadline(weight: .semibold)).foregroundStyle(AppSystemColor.primaryLabel)
                            Text(event.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(AppFont.caption()).foregroundStyle(AppSystemColor.secondaryLabel)
                        }
                        Spacer()
                        Text(event.myAttendance?.capitalized ?? "Recorded")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(AppSystemColor.secondaryLabel)
                    }
                    .padding(12)
                    .background(AppSystemColor.insetBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(16)
        .appElevatedSurface(radius: 22)
    }
}

private struct DocumentFolderRow: View {
    let folder: DocumentFolder

    var body: some View {
        HStack(spacing: 14) {
            AppIconBadge(systemImage: "folder.fill")

            Text(folder.name)
                .font(AppFont.headline())
                .foregroundStyle(AppSystemColor.primaryLabel)
                .lineLimit(2)

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(AppSystemColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(16)
        .appElevatedSurface()
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct DocumentRow: View {
    let document: ChapterDocument
    let isOpening: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconBadge(systemImage: documentSystemImage)

            VStack(alignment: .leading, spacing: 5) {
                Text(document.name)
                    .font(AppFont.headline())
                    .foregroundStyle(AppSystemColor.primaryLabel)
                    .multilineTextAlignment(.leading)

                if let detailText {
                    Text(detailText)
                        .font(AppFont.caption())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }
            }

            Spacer(minLength: 12)

            if isOpening {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.up.right")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(16)
        .appElevatedSurface()
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var detailText: String? {
        if document.opensExternalLink { return "Web link" }
        guard let byteCount = document.byteCount else { return document.mimeType }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var documentSystemImage: String {
        if document.opensExternalLink {
            return "safari.fill"
        }
        let loweredName = document.name.lowercased()
        if loweredName.hasSuffix(".pdf") {
            return "doc.richtext.fill"
        }
        if loweredName.hasSuffix(".jpg") || loweredName.hasSuffix(".jpeg") || loweredName.hasSuffix(".png") {
            return "photo.fill"
        }
        return "doc.fill"
    }
}

private struct ChapterResourceStatusView: View {
    let message: String

    var body: some View {
        AppStatusSurface(message: message, systemImage: "doc.text.magnifyingglass")
    }
}

private struct LocalDocumentPreview: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ExternalDocumentLink: Identifiable {
    let url: URL
    var id: URL { url }
}

private enum DocumentDestination: Identifiable {
    case preview(LocalDocumentPreview)
    case externalLink(ExternalDocumentLink)

    var id: String {
        switch self {
        case .preview(let item): "preview-\(item.url.absoluteString)"
        case .externalLink(let item): "external-\(item.url.absoluteString)"
        }
    }
}

private struct DocumentQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// `SFSafariViewController` keeps a linked chapter resource within the
/// documents experience while still letting Google Drive, Notion, and similar
/// providers handle their own authentication and document rendering.
private struct ExternalDocumentView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

func chapterResourceErrorMessage(for error: Error) -> String {
    if case AuthManagerError.notAuthenticated = error {
        return "Sign in with SSO to load chapter resources."
    }
    if case KTPAPIError.missingAccessToken = error {
        return "Sign in with SSO to load chapter resources."
    }
    if case KTPAPIError.badStatusCode(let statusCode, _) = error {
        if statusCode == 401 || statusCode == 403 {
            return "Your account does not have access to this resource."
        }
        return "The chapter API returned status \(statusCode)."
    }
    return "Could not load this resource. Please try again."
}
