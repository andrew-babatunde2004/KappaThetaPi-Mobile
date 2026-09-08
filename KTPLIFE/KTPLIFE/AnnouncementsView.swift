import SwiftUI
import UIKit

struct AnnouncementsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var announcements: [Announcement] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var isRushFeed: Bool {
        authManager.currentUserGroup == .rush
    }

    // im not gonna lie im KINDA confused here
    // we create the variable apiService that uses the class?
    private var apiService: KTPAPIService {
        // Why do we call this here?
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    // everything contained in var body is purley design
    var body: some View {
        // just the outline of the current page, you can see with NavStack
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // the header of the app 
                    AppSectionHeading(
                        eyebrow: isRushFeed ? "Rush news" : "Chapter news",
                        title: isRushFeed ? "Rush Announcements" : "Announcements",
                        systemImage: "megaphone.fill"
                    )
                    .padding(.bottom, 22)
                    
                    if isLoading {
                        AnnouncementStatusView(message: "Loading announcements...")
                    } else if let loadError {
                        AnnouncementStatusView(message: loadError, systemImage: "exclamationmark.circle")
                    } else if announcements.isEmpty {
                        AnnouncementStatusView(message: "There are no announcements yet.", systemImage: "megaphone")
                    } else {
                        // for each announcement the app grabs "ordered from 1 being least recent and X being most recent"
                        ForEach(Array(announcements.enumerated()), id: \.element.id) { index, announcement in
                            AnnouncementThreadPost(
                                announcement: announcement,
                                showsConnector: index < announcements.count - 1,
                                isRushAnnouncement: isRushFeed,
                                loadMediaThumbnail: { mediaID in
                                    try await apiService.fetchAnnouncementMediaThumbnail(
                                        mediaID: mediaID,
                                        isRushAnnouncement: isRushFeed
                                    )
                                }
                            )
                        }
                    }
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Announcements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AppFont.subheadline(weight: .semibold))
                }
            }
            .task { await loadAnnouncements() }
            .refreshable { await loadAnnouncements() }
        }
        .background(AppSystemColor.background.ignoresSafeArea())
    }

    // this is where the functionality of the annoucment page starts
    @MainActor
    private func loadAnnouncements() async {
        isLoading = true
        loadError = nil

        do {
            // just like java apiService calls from a diff class 
            // in this instance thats going to be @MemberAPIService.swift
            let fetchedAnnouncements = try await apiService.fetchAnnouncements(
                for: authManager.currentUserGroup
            )
            // Match the website and API: the newest announcement appears first.
            announcements = fetchedAnnouncements.sorted { $0.createdAt > $1.createdAt }
        } catch is CancellationError {
            return
        } catch {
            if announcements.isEmpty {
                loadError = announcementErrorMessage(for: error)
            }
        }

        isLoading = false
    }

    private func announcementErrorMessage(for error: Error) -> String {
        if case KTPAPIError.missingAccessToken = error {
            return "Sign in with SSO to view announcements."
        }

        if case KTPAPIError.badStatusCode(let statusCode, _) = error,
           statusCode == 401 || statusCode == 403 {
            return "Your announcement access has expired. Sign out and sign in again."
        }

        return "Announcements are temporarily unavailable. Please try again."
    }
}

private struct AnnouncementThreadPost: View {
    let announcement: Announcement
    let showsConnector: Bool
    let isRushAnnouncement: Bool
    let loadMediaThumbnail: (String) async throws -> Data

    private var authorTitle: String {
        announcement.authorName ?? (isRushAnnouncement ? "KTP Rush Team" : "Kappa Theta Pi")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppSystemColor.background)
                    .frame(width: 34, height: 34)
                    .background(AppSystemColor.primaryLabel, in: Circle())

                if showsConnector {
                    Rectangle()
                        .fill(AppSystemColor.separator.opacity(0.65))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 7)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(authorTitle)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(AppSystemColor.primaryLabel)

                    Text(announcement.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(AppFont.caption())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                        .lineLimit(1)
                }

                Text(announcement.title)
                    .font(AppFont.headline())
                    .foregroundStyle(AppSystemColor.primaryLabel)

                Text(announcement.body)
                    .font(AppFont.subheadline())
                    .foregroundStyle(AppSystemColor.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                if let executiveTitle = announcement.authorExecutiveTitle {
                    Label(executiveTitle, systemImage: "person.badge.shield.checkmark.fill")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }

                if !announcement.media.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(announcement.media) { media in
                                AnnouncementMediaThumbnail(
                                    media: media,
                                    loadData: { try await loadMediaThumbnail(media.id) }
                                )
                            }
                        }
                    }
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                }

                if !announcement.links.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(announcement.links) { link in
                            Link(destination: link.url) {
                                HStack(spacing: 9) {
                                    Image(systemName: "arrow.up.right.square.fill")
                                    Text(link.label)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .font(AppFont.footnote(weight: .semibold))
                                .foregroundStyle(AppSystemColor.primaryLabel)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AppSystemColor.insetBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }

                if let updatedAt = announcement.updatedAt, updatedAt > announcement.createdAt {
                    Text("Edited \(updatedAt.formatted(.relative(presentation: .named)))")
                        .font(AppFont.caption())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }
            }
            .padding(.bottom, showsConnector ? 24 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AnnouncementMediaThumbnail: View {
    let media: AnnouncementMedia
    let loadData: () async throws -> Data

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppSystemColor.insetBackground)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: media.isVideo ? "video.slash.fill" : "photo.badge.exclamationmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            } else {
                ProgressView()
                    .tint(AppSystemColor.secondaryLabel)
            }

            if media.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.62), in: Circle())
            }
        }
        .frame(width: 148, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppSystemColor.separator.opacity(0.45), lineWidth: 1)
        }
        .accessibilityLabel(media.filename ?? (media.isVideo ? "Video attachment" : "Image attachment"))
        .task(id: media.id) {
            do {
                let data = try await loadData()
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
                didFail = image == nil
            } catch is CancellationError {
                return
            } catch {
                didFail = true
            }
        }
    }
}

private struct AnnouncementStatusView: View {
    let message: String
    var systemImage: String = "arrow.triangle.2.circlepath"

    var body: some View {
        AppStatusSurface(message: message, systemImage: systemImage)
            .padding(.vertical, 18)
    }
}
