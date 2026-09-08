//
//  ContentView.swift
//  KTPLIFE
//
//  Created by Seyi Babatunde on 6/16/26.
//

import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appAppearance) private var appAppearance
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var avatarRepository: AvatarRepository
    @EnvironmentObject private var galleryThumbnailRepository: GalleryThumbnailRepository
    @EnvironmentObject private var galleryContentCache: GalleryContentCache
    @EnvironmentObject private var messageAttachmentThumbnailRepository: MessageAttachmentThumbnailRepository
    @EnvironmentObject private var pushNotificationManager: PushNotificationManager
    @State private var selectedTab: AppTab = .home
    @State private var didBootstrap = false
    @State private var presentedFullScreen: AppFullScreenDestination?
    @State private var isKeyboardPresented = false
    @State private var isMessageConversationPresented = false
    @State private var presentedSheet: AppSheetDestination?
    @State private var qrAlert: QRAlert?
    @State private var isSubmittingCheckIn = false
    @State private var pushMessageUserID: String?
    @State private var pushGroupChat: GroupChatPushDestination?
    @State private var pushEventID: String?
    @State private var unreadMessageCount = 0

    var body: some View {
        ZStack {
            PageBackground(theme: activePageTheme, animationValue: selectedTab)
            rootContent
                // Let the system join scrolling content to the fixed masthead and tab bar.
                // The hard edge preserves contrast when Reduce Transparency is enabled.
                .scrollEdgeEffectStyle(reduceTransparency ? .hard : .soft, for: [.top, .bottom])
        }
        .environment(\.pageTheme, activePageTheme)
        .preferredColorScheme(preferredColorScheme)
        // Reading the appearance value here invalidates the app shell when the
        // user switches between Dark and Gray, which share a dark color scheme
        // but use different semantic surface colors.
        .animation(.easeInOut(duration: 0.18), value: appAppearance)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await authManager.bootstrap()
        }
        .task {
            await pushNotificationManager.refreshAuthorizationStatus()

            if pushNotificationManager.authorizationStatus == .notDetermined {
                _ = await pushNotificationManager.requestAuthorization()
            }

            pushNotificationManager.registerWithAPNsIfAuthorized()
            await pushNotificationManager.clearBadge()
        }
        .task(id: "\(authManager.phase)-\(pushNotificationManager.deviceToken ?? "none")") {
            guard authManager.phase == .signedIn else { return }
            await pushNotificationManager.syncRegistration(using: apiService)
        }
        .task(id: "notification-preferences-\(authManager.phase)") {
            guard authManager.phase == .signedIn else { return }
            do {
                let preferences = try await apiService.fetchNotificationPreferences()
                preferences.cacheLocally()
                await EventReminderScheduler().updateEnabledState()
            } catch is CancellationError {
                return
            } catch {
                // Keep the last-known settings when the notification API is unavailable.
            }
        }
        .task(id: "unread-\(authManager.phase)") {
            guard authManager.phase == .signedIn else {
                unreadMessageCount = 0
                return
            }
            await monitorUnreadMessages()
        }
        .onChange(of: authManager.phase) { _, newPhase in
            if newPhase != .signedIn {
                selectedTab = .home
                isMessageConversationPresented = false
                presentedSheet = nil
                presentedFullScreen = nil
            }

            if newPhase == .signedIn {
                routePendingPushNotificationIfPossible()
            }

            if newPhase == .signedOut {
                avatarRepository.clear()
                galleryThumbnailRepository.clear()
                galleryContentCache.clear()
                messageAttachmentThumbnailRepository.clear()
            }
        }
        .onChange(of: selectedTab) { _, _ in
            isMessageConversationPresented = false
        }
        .onChange(of: authManager.currentUserGroup) { _, group in
            if group?.canAccessFilesAndPhotos == false, selectedTab == .photos {
                selectedTab = .home
            }
        }
        .onChange(of: pushNotificationManager.pendingDestination) { _, _ in
            routePendingPushNotificationIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await pushNotificationManager.refreshAuthorizationStatus()
                pushNotificationManager.registerWithAPNsIfAuthorized()
                await pushNotificationManager.clearBadge()

                if authManager.phase == .signedIn {
                    await pushNotificationManager.syncRegistration(using: apiService)
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            // This iOS 26 bar API extends the system scroll-edge effect into the custom
            // tab bar. Conversation detail owns the bottom safe area for its composer.
            if authManager.profileIsComplete && !isKeyboardPresented && !isMessageConversationPresented {
                AppTabBar(
                    selectedTab: $selectedTab,
                    unreadMessageCount: unreadMessageCount,
                    activeGroup: authManager.currentUserGroup,
                    openProfile: { presentedFullScreen = .profile }
                )
            }
        }
        .fullScreenCover(item: $presentedFullScreen) { destination in
            switch destination {
            case .documents:
                DocumentsView()
                    .environmentObject(authManager)
            case .committees:
                CommitteesView()
                    .environmentObject(authManager)
            case .polls:
                PollsView()
                    .environmentObject(authManager)
            case .announcements:
                AnnouncementsView()
                    .environmentObject(authManager)
            case .meetings:
                MeetingsView()
                    .environmentObject(authManager)
            case .interviews:
                InterviewsView()
                    .environmentObject(authManager)
            case .profile:
                ProfileView()
            }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .qrScanner:
                QRCodeScannerView { payload in
                    handleScannedQRCode(payload)
                }
            }
        }
        .alert(item: $qrAlert, content: makeQRAlert)
        .overlay {
            if isSubmittingCheckIn {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()

                    ProgressView("Checking in...")
                        .font(AppFont.subheadline(weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checking in to event")
            }
        }
        // Universal Link entry point: an attendance QR scanned with the iOS
        // Camera arrives here instead of opening Safari, provided the app has
        // the Associated Domains entitlement for ugaktp.com.
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardPresented = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageThreadShouldRefresh)) { _ in
            Task { await refreshUnreadMessageCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageUnreadCountShouldRefresh)) { _ in
            Task { await refreshUnreadMessageCount() }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch authManager.phase {
        case .loading:
            KTPSplashView()
        case .signedOut, .signingIn:
            SSOLoginView(
                isLoading: authManager.isBusy,
                errorMessage: authManager.errorMessage,
                signIn: {
                    Task {
                        await authManager.signInWithSSO()
                    }
                },
                signInWithDifferentAccount: {
                    Task {
                        await authManager.signInWithSSO(useEphemeralSession: true)
                    }
                }
            )
        case .profileIncomplete:
            ProfileIncompleteView(
                errorMessage: authManager.errorMessage,
                retrySync: {
                    Task {
                        await authManager.checkProfileStatus()
                    }
                },
                signOut: {
                    Task {
                        await authManager.signOut()
                    }
                }
            )
            .contentShellPadding(bottom: 32)
        case .signedIn:
            appShellView
                // Keep the navigation container full width. MessageThreadsView owns the
                // inset for its inbox, which allows a pushed conversation to transition
                // across the entire screen instead of inside the app-shell margins.
                .contentShellPadding(
                    top: selectedTab == .photos || selectedTab == .home ? 0 : 16,
                    bottom: selectedTab == .photos
                        ? 0
                        : (isKeyboardPresented || isMessageConversationPresented ? 24 : 122),
                    horizontal: selectedTab.isMessagesTab || selectedTab == .photos || selectedTab == .home ? 0 : 24
                )
        }
    }

    private var activePageTheme: PageTheme {
        authManager.profileIsComplete ? selectedTab.theme : .auth
    }

    /// Authentication always follows the device. The saved in-app appearance
    /// applies only after authentication has completed.
    private var preferredColorScheme: ColorScheme? {
        switch authManager.phase {
        case .loading, .signedOut, .signingIn:
            nil
        case .profileIncomplete, .signedIn:
            appAppearance.preferredColorScheme
        }
    }

    @ViewBuilder
    private var appShellView: some View {
        switch selectedTab {
        case .home:
            HomeView(
                showDocuments: { presentedFullScreen = .documents },
                showCommittees: { presentedFullScreen = .committees },
                showPolls: { presentedFullScreen = .polls },
                showAnnouncements: { presentedFullScreen = .announcements },
                showMeetings: { presentedFullScreen = .meetings },
                showInterviews: { presentedFullScreen = .interviews },
                openQRScanner: { presentedSheet = .qrScanner },
                openEvent: { eventID in
                    pushEventID = eventID
                    selectedTab = .calendar
                },
                activeGroup: authManager.currentUserGroup
            )
        case .community:
            MessagesView(
                isConversationPresented: $isMessageConversationPresented,
                deepLinkedUserID: $pushMessageUserID,
                deepLinkedGroupChat: $pushGroupChat
            )
        case .messages:
            MessagesView(
                isConversationPresented: $isMessageConversationPresented,
                deepLinkedUserID: $pushMessageUserID,
                deepLinkedGroupChat: $pushGroupChat
            )
        case .directory:
            MemberDirectoryView(
                messageMember: { member in
                    pushMessageUserID = member.id
                    // Keep the existing Community navigation stack alive while it
                    // resolves and pushes the requested conversation.
                    selectedTab = .community
                },
                allowedGroups: authManager.currentUserGroup?.directoryContactGroups
            )
        case .opportunities:
            OpportunitiesView()
        case .calendar:
            CalendarView(deepLinkedEventID: $pushEventID)
        case .photos:
            PhotosView()
        }
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private var attendanceCheckInService: AttendanceCheckInService {
        AttendanceCheckInService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private func handleScannedQRCode(_ payload: String) {
        guard let attendanceCode = AttendanceQRCode(payload: payload) else {
            qrAlert = .scannedCode(ScannedQRCode(payload: payload))
            return
        }

        guard !isSubmittingCheckIn else { return }
        isSubmittingCheckIn = true

        Task { @MainActor in
            defer { isSubmittingCheckIn = false }

            do {
                let response = try await attendanceCheckInService.checkIn(using: attendanceCode)
                let eventTitle = response.event?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = if let eventTitle, !eventTitle.isEmpty {
                    "\(response.message): \(eventTitle)"
                } else {
                    response.message
                }
                qrAlert = .checkInResult(title: "Checked In", message: message)
            } catch {
                qrAlert = .checkInResult(
                    title: "Check-in Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Keeping this out of the `body` prevents the SwiftUI result builder from
    /// having to infer every alert branch as one large expression.
    private func makeQRAlert(_ alert: QRAlert) -> Alert {
        switch alert.kind {
        case .checkInResult:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        case .scannedCode(let code):
            if let url = code.webURL {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Link")) {
                        openURL(url)
                    },
                    secondaryButton: .cancel()
                )
            }

            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Copy")) {
                    UIPasteboard.general.string = code.payload
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func routePendingPushNotificationIfPossible() {
        guard authManager.phase == .signedIn,
              let destination = pushNotificationManager.consumePendingDestination()
        else { return }

        switch destination {
        case .directMessage(let userID):
            selectedTab = .community
            pushMessageUserID = userID
        case .groupMessage(let chat):
            selectedTab = .community
            pushGroupChat = chat
        case .announcement:
            presentedFullScreen = .announcements
        case .poll:
            presentedFullScreen = .polls
        case .meeting:
            presentedFullScreen = .meetings
        case .event(let eventID):
            selectedTab = .calendar
            pushEventID = eventID
        case .interview:
            presentedFullScreen = .interviews
        }
    }

    @MainActor
    private func monitorUnreadMessages() async {
        while !Task.isCancelled {
            await refreshUnreadMessageCount()

            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func refreshUnreadMessageCount() async {
        guard authManager.phase == .signedIn else {
            unreadMessageCount = 0
            return
        }

        async let directResult = try? apiService.fetchDirectMessageUnreadCount()
        async let groupResult = try? apiService.fetchGroupChatUnreadCount()
        let (directUnread, groupUnread) = await (directResult, groupResult)

        guard !Task.isCancelled,
              directUnread != nil || groupUnread != nil else { return }

        unreadMessageCount = (directUnread ?? 0) + (groupUnread ?? 0)
    }

}

private struct KTPAppHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pageTheme) private var pageTheme
    let openQRScanner: () -> Void

    var body: some View {
        ZStack {
            KTPLogoMark(maxWidth: 94, maxHeight: 36)

            HStack {
                Button(action: openQRScanner) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTextColor.primary(on: pageTheme, colorScheme: colorScheme))
                        .frame(width: 40, height: 40)
                        .background(AppSystemColor.elevatedBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("Scan a QR code")
                .padding(.leading, 20)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(pageTheme.backgroundColor(for: colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTextColor.primary(on: pageTheme, colorScheme: colorScheme).opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

private enum AppSheetDestination: String, Identifiable {
    case qrScanner

    var id: String { rawValue }
}

private extension ContentView {
    /// Universal Link arrivals. Non-check-in URLs are ignored rather than
    /// shown as a scan result — the app only claims /checkin/* in its
    /// apple-app-site-association, so nothing else should reach this.
    func handleIncomingURL(_ url: URL) {
        guard AttendanceQRCode(payload: url.absoluteString) != nil else { return }
        handleScannedQRCode(url.absoluteString)
    }
}

private struct ScannedQRCode {
    let payload: String

    var webURL: URL? {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return url
    }
}

private struct QRAlert: Identifiable {
    enum Kind {
        case checkInResult
        case scannedCode(ScannedQRCode)
    }

    let id = UUID()
    let title: String
    let message: String
    let kind: Kind

    static func checkInResult(title: String, message: String) -> QRAlert {
        QRAlert(title: title, message: message, kind: .checkInResult)
    }

    static func scannedCode(_ code: ScannedQRCode) -> QRAlert {
        QRAlert(title: "QR Code Scanned", message: code.payload, kind: .scannedCode(code))
    }
}

private enum AppFullScreenDestination: String, Identifiable {
    case documents
    case committees
    case polls
    case announcements
    case meetings
    case interviews
    case profile

    var id: String { rawValue }
}

private extension View {
    func contentShellPadding(top: CGFloat = 24, bottom: CGFloat, horizontal: CGFloat = 20) -> some View {
        padding(.horizontal, horizontal)
            .padding(.top, top)
            .safeAreaPadding(.bottom, bottom)
    }
}

private extension AppTab {
    var isMessagesTab: Bool {
        self == .community || self == .messages
    }
}

#if DEBUG
#Preview {
    ContentView()
        .modelContainer(PreviewModelContainer.shared)
        .environmentObject(AuthManager.previewSignedOut)
        .environmentObject(AvatarRepository())
        .environmentObject(GalleryThumbnailRepository())
        .environmentObject(GalleryContentCache())
}
#endif
