//
//  MessageThreadsView.swift
//  KTPLIFE
//

import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MessageThreadsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authManager: AuthManager
    @State private var threads: [MessageThread] = []
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var isShowingCachedThreads = false
    @State private var mutedGroupChatIDs: Set<String> = []

    private let offlineStore = MessageOfflineStore.shared

    let refreshVersion: Int

    init(refreshVersion: Int = 0) {
        self.refreshVersion = refreshVersion
    }

    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        Group {
            if isLoading {
                MessagesStatusCard(message: "Loading messages...")
            } else if let loadError {
                MessagesStatusCard(message: loadError)
            } else if threads.isEmpty {
                MessagesStatusCard(message: "No conversations yet.")
            } else {
                VStack(alignment: .leading, spacing: MessageThreadLayout.sectionSpacing) {
                    if isShowingCachedThreads {
                        MessageOfflineBanner(message: "Showing saved conversations")
                    }

                    if !directThreads.isEmpty {
                        MessageThreadSection(
                            title: nil,
                            threads: directThreads,
                            mutedGroupChatIDs: mutedGroupChatIDs,
                            apiService: apiService
                        )
                    }

                    if !groupThreads.isEmpty {
                        MessageThreadSection(
                            title: "Group Chats",
                            threads: groupThreads,
                            mutedGroupChatIDs: mutedGroupChatIDs,
                            apiService: apiService
                        )
                    }
                }
            }
        }
        .task(id: refreshVersion) {
            await monitorConversations()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadConversations(showsLoadingState: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageThreadShouldRefresh)) { _ in
            Task { await loadConversations(showsLoadingState: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task {
                await flushPendingMessages()
                await loadConversations(showsLoadingState: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupChatMutePreferencesDidChange)) { _ in
            mutedGroupChatIDs = GroupChatMutePreferences.mutedChatIDs
        }
    }

    private var directThreads: [MessageThread] {
        threads.filter { !$0.isGroup }
    }

    private var groupThreads: [MessageThread] {
        threads.filter(\.isGroup)
    }

    @MainActor
    private func monitorConversations() async {
        mutedGroupChatIDs = GroupChatMutePreferences.mutedChatIDs
        await hydrateInboxCache()
        await flushPendingMessages()
        await loadConversations(showsLoadingState: true)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }

            await loadConversations(showsLoadingState: false)
        }
    }

    @MainActor
    private func loadConversations(showsLoadingState: Bool) async {
#if DEBUG
        if isPreview {
            threads = MessageConversation.previewSamples.map(MessageThread.direct) + GroupChat.previewSamples.map(MessageThread.group)
            loadError = nil
            return
        }
#endif

        guard !isRefreshing else { return }
        isRefreshing = true
        if showsLoadingState, threads.isEmpty {
            isLoading = true
        }
        loadError = nil

        async let directResult = fetchDirectConversationsResult()
        async let groupResult = fetchGroupChatsResult()
        let (loadedDirectResult, loadedGroupResult) = await (directResult, groupResult)

        guard !Task.isCancelled else {
            isLoading = false
            isRefreshing = false
            return
        }

        let previousDirectThreads = directThreads
        let previousGroupThreads = groupThreads
        let resolvedDirectThreads: [MessageThread]
        let resolvedGroupThreads: [MessageThread]
        var loadFailures: [Error] = []
        var loadedFromNetwork = false

        switch loadedDirectResult {
        case .success(let conversations):
            resolvedDirectThreads = conversations.map(MessageThread.direct)
            loadedFromNetwork = true
        case .failure(let error):
            resolvedDirectThreads = previousDirectThreads
            loadFailures.append(error)
        }

        switch loadedGroupResult {
        case .success(let chats):
            resolvedGroupThreads = chats.map(MessageThread.group)
            loadedFromNetwork = true
        case .failure(let error):
            resolvedGroupThreads = previousGroupThreads
            loadFailures.append(error)
        }

        threads = sortedThreads(resolvedDirectThreads + resolvedGroupThreads)
        isShowingCachedThreads = !loadFailures.isEmpty && !threads.isEmpty
        if loadedFromNetwork {
            await offlineStore.saveInbox(threads, accountID: accountID)
        }

        // A group-chat outage should not erase working direct messages (or vice
        // versa). Only replace the inbox with an error when neither request
        // succeeded and there is no previously loaded content to preserve.
        if loadFailures.count == 2, threads.isEmpty, let error = loadFailures.first {
            loadError = messagesErrorMessage(for: error)
        }

        isLoading = false
        isRefreshing = false
    }

    @MainActor
    private func hydrateInboxCache() async {
        let cachedThreads = await offlineStore.loadInbox(accountID: accountID)
        guard threads.isEmpty, !cachedThreads.isEmpty else { return }
        threads = sortedThreads(cachedThreads)
        isLoading = false
        isShowingCachedThreads = true
    }

    @MainActor
    private func flushPendingMessages() async {
        guard ConnectivityMonitor.shared.isConnected else { return }
        let deliveries = await offlineStore.claimPendingDeliveries(accountID: accountID)
        guard !deliveries.isEmpty else { return }

        for delivery in deliveries {
            do {
                switch delivery.destination {
                case .direct:
                    _ = try await apiService.sendMessage(
                        to: delivery.destinationID,
                        body: delivery.body,
                        attachment: delivery.attachment,
                        replyToMessageID: delivery.replyTo?.id
                    )
                case .group:
                    _ = try await apiService.sendGroupChatMessage(
                        chatId: delivery.destinationID,
                        body: delivery.body,
                        attachment: delivery.attachment,
                        replyToMessageID: delivery.replyTo?.id
                    )
                }
                await offlineStore.removeDelivery(id: delivery.id, accountID: accountID)
            } catch is CancellationError {
                await offlineStore.releaseDeliveries(ids: deliveries.map(\.id))
                return
            } catch {
                await offlineStore.releaseDeliveries(ids: [delivery.id])
                if isOfflineTransportError(error) {
                    await offlineStore.releaseDeliveries(ids: deliveries.map(\.id))
                    return
                }
            }
        }
    }

    private var accountID: String {
        authManager.currentUserID ?? "authenticated-user"
    }

    private func fetchDirectConversationsResult() async -> Result<[MessageConversation], Error> {
        do {
            return .success(try await apiService.fetchMessageConversations())
        } catch {
            return .failure(error)
        }
    }

    private func fetchGroupChatsResult() async -> Result<[GroupChat], Error> {
        do {
            return .success(try await apiService.fetchGroupChats())
        } catch {
            return .failure(error)
        }
    }

    private func sortedThreads(_ threads: [MessageThread]) -> [MessageThread] {
        threads.sorted { left, right in
            switch (left.lastMessageDate, right.lastMessageDate) {
            case let (leftDate?, rightDate?):
                return leftDate > rightDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left.displayName < right.displayName
            }
        }
    }
}

/// Layout values for the inbox sections. Keeping this here documents the intentional visual separation.
private enum MessageThreadLayout {
    /// Separates Direct Messages from Group Chats while keeping both on the same inbox screen.
    static let sectionSpacing: CGFloat = 28

    /// Separates individual conversations without placing them inside card rectangles.
    static let rowSpacing: CGFloat = 22
}

/// A labeled inbox section that keeps one-to-one conversations distinct from group chats.
private struct MessageThreadSection: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String?
    let threads: [MessageThread]
    let mutedGroupChatIDs: Set<String>
    let apiService: KTPAPIService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(AppFont.headline())
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
            }

            threadRows
        }
    }

    private var threadRows: some View {
        LazyVStack(spacing: MessageThreadLayout.rowSpacing) {
            ForEach(threads) { thread in
                NavigationLink(value: thread) {
                    MessageThreadCard(
                        thread: thread,
                        isMuted: mutedGroupChatIDs.contains(thread.groupChatID ?? ""),
                        apiService: apiService
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MessageThreadCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let thread: MessageThread
    let isMuted: Bool
    let apiService: KTPAPIService

    private var profileID: String? {
        guard case .direct(let conversation) = thread else { return nil }
        return conversation.userId
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            threadAvatar

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(thread.displayName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(MessageDesign.primary(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(MessageDesign.muted(for: colorScheme))
                            .accessibilityLabel("Muted")
                    }
                }

                Text(thread.preview)
                    .font(AppFont.subheadline())
                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            if thread.unreadCount > 0 {
                Circle()
                    .fill(AppSurfaceColor.primaryControl)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var threadAvatar: some View {
        if case .group(let chat) = thread {
            GroupChatAvatar(chat: chat, size: 51, apiService: apiService)
        } else {
            ProfileAvatarView(
                imageURL: thread.profileImageURL,
                profileID: profileID,
                name: thread.displayName,
                isGroup: false,
                size: 51,
                apiService: apiService
            )
        }
    }
}

private struct GroupChatAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var avatarRepository: AvatarRepository
    let chat: GroupChat
    let size: CGFloat
    let apiService: KTPAPIService

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(MessageDesign.avatarBackground(for: colorScheme))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(chat.name) group photo")
        // The asset ID is part of the cache key. A replacement upload creates a
        // different asset, so this task and its URL-equivalent cache key update too.
        .task(id: "\(chat.id)-\(chat.photoAssetID ?? "no-photo")-\(Int(size * displayScale))") {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let photoAssetID = chat.photoAssetID, !photoAssetID.isEmpty else {
            image = nil
            return
        }

        image = nil
        image = await avatarRepository.image(
            for: "group-chat-\(chat.id)-\(photoAssetID)",
            pointSize: size,
            displayScale: displayScale,
            loadData: { try await apiService.fetchGroupChatPhotoData(chatID: chat.id) }
        )
    }
}

private struct ProfileAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var avatarRepository: AvatarRepository
    let imageURL: URL?
    let profileID: String?
    let name: String
    let isGroup: Bool
    let size: CGFloat
    let apiService: KTPAPIService

    @State private var image: UIImage?

    private var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)

        let value = String(parts).uppercased()
        return value.isEmpty ? "KT" : value
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(MessageDesign.avatarBackground(for: colorScheme))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(name) profile picture")
        .task(id: "\(profileID ?? imageURL?.absoluteString ?? name)-\(Int(size * displayScale))") {
            await loadImage()
        }
    }

    private var fallback: some View {
        Text(initials)
            .font(AppFont.caption(weight: .bold))
            .foregroundStyle(MessageDesign.primary(for: colorScheme))
    }

    @MainActor
    private func loadImage() async {
        guard !isGroup else {
            image = nil
            return
        }

        let sourceID = profileID ?? imageURL?.absoluteString ?? name
        let avatar = await avatarRepository.image(
            for: sourceID,
            pointSize: size,
            displayScale: displayScale,
            loadData: {
                if let imageURL {
                    return try await URLSession.shared.data(from: imageURL).0
                }

                guard let profileID else { throw URLError(.badURL) }
                return try await apiService.fetchProfilePictureData(for: profileID)
            }
        )
        guard !Task.isCancelled else { return }
        image = avatar
    }
}

struct MessageConversationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authManager: AuthManager
    @State private var messages: [KTPMessage] = []
    @State private var isLoading = false
    @State private var isRefreshingConversation = false
    @State private var loadError: String?
    @State private var sentMessageIDs: Set<String> = []
    @State private var renderWindow = ConversationRenderWindow()
    @State private var isAwayFromLatest = false
    @State private var scrollRequest: ConversationScrollRequest?
    @State private var reportTarget: ReportTarget?
    @State private var isBlocked = false
    @State private var isUpdatingBlock = false
    @State private var showsBlockConfirmation = false
    @State private var blockErrorMessage: String?
    @State private var reactionsByMessageID: [String: [String: MessageReactionSummary]] = [:]
    @State private var updatingReactionKeys: Set<String> = []
    @State private var reactionErrorMessage: String?
    @State private var reactionDetails: MessageReactionDetails?
    @State private var replyingTo: KTPMessage?
    @State private var messagePendingDeletion: KTPMessage?
    @State private var deletingMessageIDs: Set<String> = []
    @State private var deleteErrorMessage: String?
    @State private var attachmentDataByMessageID: [String: Data] = [:]
    @State private var groupDetailsChat: GroupChat?
    @State private var isGroupChatMuted = false
    @State private var isShowingCachedMessages = false
    @State private var pendingDeliveryCount = 0
    private let offlineStore = MessageOfflineStore.shared
    /// Group-message payloads do not always include sender display metadata.
    /// Keep the existing group-member endpoint as the source of truth for the
    /// name and profile image shown beside those messages.
    @State private var groupMembersByID: [String: DirectoryMember] = [:]
    @State private var isComposerFocused = false

    let thread: MessageThread

    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private var conversationBase: some View {
        VStack(spacing: 12) {
            if isShowingCachedMessages || pendingDeliveryCount > 0 {
                MessageOfflineBanner(message: offlineStatusMessage)
            }

            if isBlocked {
                MessagesStatusCard(message: "You blocked \(thread.displayName). Unblock them to resume this conversation.")
            } else if isLoading && messages.isEmpty {
                MessagesStatusCard(message: "Loading conversation...")
            } else if let loadError {
                ConversationLoadFailure(message: loadError) {
                    Task { await loadConversation(showsLoadingState: true) }
                }
            } else if messages.isEmpty {
                ConversationEmptyState(thread: thread)
            } else {
                messageTimeline
            }

        }
        // Fill the navigation destination so the safe-area composer is anchored to
        // the bottom of the screen instead of immediately following short content.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Clear every delivered alert for this thread, including older
            // notifications that were not the one the member tapped.
            await MessageNotificationCleaner.clearDeliveredNotifications(for: thread)
            await monitorConversation()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await MessageNotificationCleaner.clearDeliveredNotifications(for: thread)
                await flushPendingMessages()
                await loadConversation(showsLoadingState: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageThreadShouldRefresh)) { _ in
            Task { await loadConversation(showsLoadingState: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task {
                await flushPendingMessages()
                await loadConversation(showsLoadingState: false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                conversationTitleAvatar
            }

            if directConversation != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if isBlocked {
                            Button("Unblock Member") {
                                Task { await setBlocked(false) }
                            }
                        } else {
                            Button("Block Member", role: .destructive) {
                                showsBlockConfirmation = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(isUpdatingBlock)
                    .accessibilityLabel("Conversation options")
                }
            } else if case .group(let chat) = thread {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            groupDetailsChat = chat
                        } label: {
                            Label("Group Details", systemImage: "person.3")
                        }

                        Button {
                            isGroupChatMuted.toggle()
                            GroupChatMutePreferences.setMuted(isGroupChatMuted, for: chat.id)
                        } label: {
                            Label(
                                isGroupChatMuted ? "Unmute Group" : "Mute Group",
                                systemImage: isGroupChatMuted ? "bell" : "bell.slash"
                            )
                        }
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Group options")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isBlocked {
                MessageComposerView(
                    replyTo: replyingTo.map(replyReference(for:)),
                    cancelReply: { replyingTo = nil },
                    send: { content, attachment, reply in
                        try await sendMessage(content: content, attachment: attachment, reply: reply)
                    },
                    focusChanged: handleComposerFocusChange
                )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(MessageDesign.background(for: colorScheme))
            }
        }
        .background(MessageDesign.background(for: colorScheme).ignoresSafeArea())
    }

    var body: some View {
        conversationBase
        .sheet(item: $reportTarget) { target in
            ReportContentSheet(target: target)
        }
        .sheet(item: $groupDetailsChat) { chat in
            GroupChatDetailsView(chat: chat, apiService: apiService)
        }
        .sheet(item: $reactionDetails) { details in
            MessageReactionDetailsView(details: details)
        }
        .confirmationDialog(
            "Block \(thread.displayName)?",
            isPresented: $showsBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Block Member", role: .destructive) {
                Task { await setBlocked(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will not be able to start new direct messages with you, and their messages will be hidden from your conversation and group-chat views.")
        }
        .alert("Couldn’t Update Block", isPresented: Binding(
            get: { blockErrorMessage != nil },
            set: { if !$0 { blockErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockErrorMessage ?? "Please try again.")
        }
        .alert("Couldn’t Update Reaction", isPresented: Binding(
            get: { reactionErrorMessage != nil },
            set: { if !$0 { reactionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reactionErrorMessage ?? "Please try again.")
        }
        .overlay {
            if let message = messagePendingDeletion {
                MessageDeleteConfirmationOverlay(
                    cancel: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            messagePendingDeletion = nil
                        }
                    },
                    confirm: {
                        messagePendingDeletion = nil
                        Task { await deleteMessage(message) }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: messagePendingDeletion?.id)
        .alert("Couldn’t Delete Message", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "Please try again.")
        }
    }

    private var directConversation: MessageConversation? {
        guard case .direct(let conversation) = thread else { return nil }
        return conversation
    }

    private var accountID: String {
        authManager.currentUserID ?? "authenticated-user"
    }

    private func handleComposerFocusChange(_ isFocused: Bool) {
        isComposerFocused = isFocused
        guard isFocused, !messages.isEmpty else { return }

        // Let the keyboard finish resizing the timeline before aligning the
        // newest bubble. Scrolling during the transition can place content
        // underneath the composer.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard isComposerFocused else { return }
            scrollRequest = .latest(UUID())
        }
    }

    private var offlineStatusMessage: String {
        if pendingDeliveryCount == 1 {
            return "1 message waiting to send"
        }
        if pendingDeliveryCount > 1 {
            return "\(pendingDeliveryCount) messages waiting to send"
        }
        return "Showing saved messages"
    }

    @ViewBuilder
    private var conversationTitleAvatar: some View {
        switch thread {
        case .direct(let conversation):
            ProfileAvatarView(
                imageURL: conversation.profileImageURL,
                profileID: conversation.userId,
                name: conversation.displayName,
                isGroup: false,
                size: 34,
                apiService: apiService
            )
        case .group(let chat):
            GroupChatAvatar(chat: chat, size: 34, apiService: apiService)
        }
    }

    private var visibleMessages: [KTPMessage] {
        Array(messages.suffix(renderWindow.visibleCount))
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(showsIndicators: false) {
                    messageStack
                }
                // The timeline is inserted only after the initial API load, so
                // an earlier scroll request can predate the ScrollViewReader.
                // Giving the scroll view a bottom default guarantees that a
                // newly opened thread begins at its most recent message.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self, of: { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 32
                }, action: { _, isAwayFromLatest in
                    self.isAwayFromLatest = isAwayFromLatest
                })

                if isAwayFromLatest {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        scrollRequest = .latest(UUID())
                    }
                    .modifier(MessageTimelineActionSurface(prominent: true))
                    .padding(12)
                }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }

                Task { @MainActor in
                    await Task.yield()

                    switch request {
                    case .preservePosition(let messageID):
                        proxy.scrollTo(messageID, anchor: .top)
                    case .latest:
                        if let latestMessageID = visibleMessages.last?.id {
                            withAnimation {
                                proxy.scrollTo(latestMessageID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .onAppear {
                // The initial request is set while the loading state is still
                // displayed, before this reader exists. Scroll explicitly once
                // the timeline has been laid out so opening a conversation always
                // lands on its newest message.
                Task { @MainActor in
                    await Task.yield()
                    if let latestMessageID = visibleMessages.last?.id {
                        proxy.scrollTo(latestMessageID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var messageStack: some View {
        messageStackContent
    }

    private var messageStackContent: some View {
        LazyVStack(spacing: 10) {
            if renderWindow.hasEarlierMessages(totalCount: messages.count) {
                Button("Load earlier messages") {
                    let preservedMessageID = visibleMessages.first?.id
                    renderWindow.loadEarlierMessages(totalCount: messages.count)

                    if let preservedMessageID {
                        scrollRequest = .preservePosition(preservedMessageID)
                    }
                }
                .modifier(MessageTimelineActionSurface(prominent: false))
                .padding(.bottom, 4)
            }

            ForEach(visibleMessages) { message in
                MessageBubble(
                    message: message,
                    sender: sender(for: message),
                    isSentByCurrentUser: isSentByCurrentUser(message),
                    showsSenderIdentity: startsMessageGroup(for: message),
                    apiService: apiService,
                    attachmentSourceID: "\(thread.id)-\(message.id)",
                    attachmentData: attachmentDataByMessageID[message.id],
                    loadAttachmentData: { try await attachmentData(for: message) },
                    replyTo: resolvedReply(for: message),
                    replyMessage: { beginReply(to: message) },
                    allowsReactions: true,
                    reactions: reactionSummaries(for: message),
                    updatingEmojis: updatingEmojis(for: message),
                    toggleReaction: { emoji in
                        Task { await toggleReaction(emoji, on: message) }
                    },
                    showReactionDetails: { reaction in
                        reactionDetails = MessageReactionDetails(messageID: message.id, reaction: reaction)
                    },
                    deleteMessage: isSentByCurrentUser(message) && !message.id.hasPrefix("local-") ? {
                        messagePendingDeletion = message
                    } : nil,
                    isDeleting: deletingMessageIDs.contains(message.id),
                    reportMessage: isSentByCurrentUser(message) ? nil : {
                        reportTarget = ReportTarget.message(
                            message,
                            isGroupMessage: thread.isGroup,
                            senderName: sender(for: message).name
                        )
                    }
                )
            }

        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func startsMessageGroup(for message: KTPMessage) -> Bool {
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            return true
        }

        // A visible window can begin in the middle of a run. Show its sender so
        // the truncated timeline still has useful context.
        guard message.id != visibleMessages.first?.id, messageIndex > 0 else {
            return true
        }

        let previousMessage = messages[messageIndex - 1]
        guard isSameMessageSender(previousMessage, message) else {
            return true
        }

        guard let previousDate = previousMessage.createdAt,
              let messageDate = message.createdAt else {
            return false
        }

        return messageDate.timeIntervalSince(previousDate) > MessageGrouping.maximumInterval
    }

    private func isSameMessageSender(_ left: KTPMessage, _ right: KTPMessage) -> Bool {
        let leftIsCurrentUser = isSentByCurrentUser(left)
        guard leftIsCurrentUser == isSentByCurrentUser(right) else { return false }
        guard !leftIsCurrentUser else { return true }

        if let leftSenderID = left.senderId, let rightSenderID = right.senderId {
            return leftSenderID == rightSenderID
        }

        return sender(for: left).name.caseInsensitiveCompare(sender(for: right).name) == .orderedSame
    }

    private func sender(for message: KTPMessage) -> MessageSender {
        switch thread {
        case .direct(let conversation):
            if message.senderId == conversation.userId {
                return MessageSender(
                    id: conversation.userId,
                    name: conversation.displayName,
                    imageURL: message.senderProfileImageURL ?? conversation.profileImageURL
                )
            }

            return MessageSender(
                id: message.senderId,
                name: message.senderDisplayName ?? "You",
                imageURL: message.senderProfileImageURL
            )
        case .group:
            if let senderID = message.senderId,
               let member = groupMembersByID[senderID] {
                return MessageSender(
                    id: member.authentikID ?? member.id,
                    name: member.name,
                    imageURL: message.senderProfileImageURL
                )
            }

            if isSentByCurrentUser(message), let currentUser = authManager.currentUserProfile {
                return MessageSender(
                    id: currentUser.id,
                    name: currentUser.displayName,
                    imageURL: message.senderProfileImageURL
                )
            }

            return MessageSender(
                id: message.senderId,
                name: message.senderDisplayName ?? "Member",
                imageURL: message.senderProfileImageURL
            )
        }
    }

    private func replyReference(for message: KTPMessage) -> MessageReplyReference {
        MessageReplyReference(
            id: message.id,
            senderID: message.senderId,
            senderDisplayName: sender(for: message).name,
            body: message.body,
            attachment: message.attachment
        )
    }

    private func resolvedReply(for message: KTPMessage) -> MessageReplyReference? {
        guard let reply = message.replyTo else { return nil }

        // Some API versions send only `reply_to_id`. Fill in that preview from
        // the loaded timeline whenever the original message is still available.
        if reply.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           reply.attachment == nil,
           let original = messages.first(where: { $0.id == reply.id }) {
            return replyReference(for: original)
        }

        return reply
    }

    private func beginReply(to message: KTPMessage) {
        replyingTo = message
        isComposerFocused = true
    }

    private func preservingReply(
        _ reply: MessageReplyReference?,
        on message: KTPMessage
    ) -> KTPMessage {
        guard message.replyTo == nil, let reply else { return message }
        return KTPMessage(
            id: message.id,
            senderId: message.senderId,
            recipientId: message.recipientId,
            senderDisplayName: message.senderDisplayName,
            senderProfileImageURL: message.senderProfileImageURL,
            body: message.body,
            attachment: message.attachment,
            createdAt: message.createdAt,
            isRead: message.isRead,
            isDeleted: message.isDeleted,
            replyTo: reply,
            reactions: message.reactions
        )
    }

    private func isSentByCurrentUser(_ message: KTPMessage) -> Bool {
        if sentMessageIDs.contains(message.id) {
            return true
        }

        switch thread {
        case .direct(let conversation):
            if message.senderId == authManager.currentUserID {
                return true
            }

            if message.recipientId == authManager.currentUserID {
                return false
            }

            if message.senderId == conversation.userId {
                return false
            }

            if message.recipientId == conversation.userId {
                return true
            }

            return false
        case .group:
            return message.senderId == authManager.currentUserID ||
                message.senderDisplayName?.caseInsensitiveCompare("You") == .orderedSame
        }
    }

    @MainActor
    private func loadBlockState() async {
        guard let conversation = directConversation else { return }

        do {
            isBlocked = try await apiService.fetchBlockedUserIDs().contains(conversation.userId)
        } catch is CancellationError {
            return
        } catch {
            blockErrorMessage = "Could not load this member’s block status."
        }
    }

    @MainActor
    private func setBlocked(_ shouldBlock: Bool) async {
        guard let conversation = directConversation, !isUpdatingBlock else { return }
        isUpdatingBlock = true
        blockErrorMessage = nil

        do {
            if shouldBlock {
                try await apiService.blockUser(id: conversation.userId)
                messages = []
                isComposerFocused = false
            } else {
                try await apiService.unblockUser(id: conversation.userId)
            }
            isBlocked = shouldBlock

            if !shouldBlock {
                await loadConversation()
            }
        } catch {
            blockErrorMessage = shouldBlock
                ? "Could not block this member. Please try again."
                : "Could not unblock this member. Please try again."
        }

        isUpdatingBlock = false
    }

    @MainActor
    private func monitorConversation() async {
        await hydrateConversationCache()
        await loadBlockState()
        if case .group(let chat) = thread {
            isGroupChatMuted = GroupChatMutePreferences.isMuted(chat.id)
        }
        // Sender metadata should not delay the first history request.
        Task { await loadGroupMembers() }
        await flushPendingMessages()
        await loadConversation(showsLoadingState: true)

        while !Task.isCancelled {
            do {
                // Match the website's 5–10 second foreground polling window.
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }

            guard scenePhase == .active, !isBlocked else { continue }
            await loadConversation(showsLoadingState: false)
        }
    }

    /// Resolves group-message sender IDs to the same member identities used by
    /// direct conversations. A failure here must not prevent the message
    /// timeline from loading; the message payload remains the fallback.
    @MainActor
    private func loadGroupMembers() async {
        guard case .group(let chat) = thread else { return }

        do {
            let members = try await apiService.fetchGroupChatMembers(chatID: chat.id)
            var membersByID: [String: DirectoryMember] = [:]
            for member in members {
                membersByID[member.id] = member
                if let authentikID = member.authentikID, !authentikID.isEmpty {
                    membersByID[authentikID] = member
                }
            }
            groupMembersByID = membersByID
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    @MainActor
    private func loadConversation(showsLoadingState: Bool = true) async {
#if DEBUG
        if isPreview {
            messages = KTPMessage.previewSamples
            seedReactionState(from: messages)
            renderWindow.reset(totalCount: messages.count)
            scrollRequest = .latest(UUID())
            loadError = nil
            return
        }
#endif

        guard !isRefreshingConversation else { return }
        isRefreshingConversation = true
        defer { isRefreshingConversation = false }

        if showsLoadingState {
            isLoading = true
            loadError = nil
        }

        do {
            // The documented API returns complete histories for both direct and
            // group conversations. Poll that stable contract rather than relying
            // on optional cursor/ETag extensions that can leave a newly opened
            // conversation without rendered content.
            let loadedMessages: [KTPMessage]
            switch thread {
            case .direct(let conversation):
                loadedMessages = try await apiService.fetchConversation(with: conversation.userId)
            case .group(let chat):
                loadedMessages = try await apiService.fetchGroupChatMessages(chatId: chat.id)
            }

            let existingMessageIDs = Set(messages.map(\.id))
            let pendingDeliveries = await offlineStore.pendingDeliveries(
                accountID: accountID,
                threadID: thread.id
            )
            let pendingMessages = pendingDeliveries.map { $0.localMessage(currentUserID: authManager.currentUserID) }
            sentMessageIDs.formUnion(pendingMessages.map(\.id))
            pendingDeliveryCount = pendingDeliveries.count
            let resolvedMessages = (loadedMessages + pendingMessages)
                .filter { !$0.isDeleted }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            let hasNewMessages = !Set(resolvedMessages.map(\.id))
                .subtracting(existingMessageIDs)
                .isEmpty

            if resolvedMessages != messages {
                messages = resolvedMessages
                updateReactionState(
                    for: resolvedMessages,
                    removing: [],
                    replacesAll: true
                )
                renderWindow.reset(totalCount: resolvedMessages.count)
            }
            await offlineStore.saveConversation(messages, threadID: thread.id, accountID: accountID)
            isShowingCachedMessages = false

            if showsLoadingState || (hasNewMessages && !isAwayFromLatest) {
                scrollRequest = .latest(UUID())
            }

            if showsLoadingState || hasNewMessages {
                switch thread {
                case .direct(let conversation):
                    try? await apiService.markConversationRead(with: conversation.userId)
                case .group(let chat):
                    try? await apiService.markGroupChatRead(chatId: chat.id)
                }
                NotificationCenter.default.post(name: .messageUnreadCountShouldRefresh, object: nil)
            }
        } catch is CancellationError {
            if showsLoadingState {
                isLoading = false
            }
            return
        } catch {
            if showsLoadingState, messages.isEmpty {
                loadError = messagesErrorMessage(for: error)
            } else if !messages.isEmpty {
                isShowingCachedMessages = true
            }
        }

        if showsLoadingState {
            isLoading = false
        }
    }

    @MainActor
    private func hydrateConversationCache() async {
        let cachedMessages = await offlineStore.loadConversation(threadID: thread.id, accountID: accountID)
        let pendingDeliveries = await offlineStore.pendingDeliveries(
            accountID: accountID,
            threadID: thread.id
        )
        let pendingMessages = pendingDeliveries.map { $0.localMessage(currentUserID: authManager.currentUserID) }
        let pendingIDs = Set(pendingMessages.map(\.id))
        let combined = cachedMessages.filter { !pendingIDs.contains($0.id) } + pendingMessages
        guard !combined.isEmpty else { return }

        messages = combined.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        sentMessageIDs.formUnion(pendingIDs)
        pendingDeliveryCount = pendingDeliveries.count
        seedReactionState(from: messages)
        renderWindow.reset(totalCount: messages.count)
        scrollRequest = .latest(UUID())
        isLoading = false
        isShowingCachedMessages = true
        for delivery in pendingDeliveries {
            if let attachment = delivery.attachment {
                attachmentDataByMessageID["pending-\(delivery.id)"] = attachment.data
            }
        }
    }

    @MainActor
    private func flushPendingMessages() async {
        guard ConnectivityMonitor.shared.isConnected else { return }
        let deliveries = await offlineStore.claimPendingDeliveries(accountID: accountID, threadID: thread.id)
        pendingDeliveryCount = deliveries.count

        for delivery in deliveries {
            do {
                let sentMessage: KTPMessage
                switch delivery.destination {
                case .direct:
                    sentMessage = try await apiService.sendMessage(
                        to: delivery.destinationID,
                        body: delivery.body,
                        attachment: delivery.attachment,
                        replyToMessageID: delivery.replyTo?.id
                    )
                case .group:
                    sentMessage = try await apiService.sendGroupChatMessage(
                        chatId: delivery.destinationID,
                        body: delivery.body,
                        attachment: delivery.attachment,
                        replyToMessageID: delivery.replyTo?.id
                    )
                }

                let pendingID = "pending-\(delivery.id)"
                messages.removeAll { $0.id == pendingID }
                sentMessageIDs.remove(pendingID)
                let resolvedSentMessage = preservingReply(delivery.replyTo, on: sentMessage)
                messages.append(resolvedSentMessage)
                sentMessageIDs.insert(resolvedSentMessage.id)
                if let attachment = delivery.attachment {
                    attachmentDataByMessageID[resolvedSentMessage.id] = attachment.data
                }
                attachmentDataByMessageID[pendingID] = nil
                await offlineStore.removeDelivery(id: delivery.id, accountID: accountID)
                pendingDeliveryCount -= 1
            } catch is CancellationError {
                await offlineStore.releaseDeliveries(ids: deliveries.map(\.id))
                return
            } catch {
                await offlineStore.releaseDeliveries(ids: [delivery.id])
                if isOfflineTransportError(error) {
                    await offlineStore.releaseDeliveries(ids: deliveries.map(\.id))
                    break
                }
            }
        }

        messages.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        renderWindow.reset(totalCount: messages.count)
        await offlineStore.saveConversation(messages, threadID: thread.id, accountID: accountID)
        if deliveries.count > pendingDeliveryCount {
            NotificationCenter.default.post(name: .messageThreadShouldRefresh, object: nil)
        }
    }

    private func merge(
        _ page: ConversationMessagePage,
        incrementally: Bool
    ) -> ConversationMessageMerge {
        let incomingMessages = page.messages.filter { !$0.isDeleted }
        let deletedMessageIDs = page.deletedMessageIDs.union(
            page.messages.lazy.filter(\.isDeleted).map(\.id)
        )

        // Cursor responses are normally ordered, append-only deltas. Keep that
        // inexpensive path free of a dictionary rebuild and full sort.
        if incrementally,
           deletedMessageIDs.isEmpty,
           isAppendOnlyDelta(incomingMessages) {
            return ConversationMessageMerge(
                messages: messages + incomingMessages,
                updatedMessages: incomingMessages,
                newMessageIDs: Set(incomingMessages.map(\.id)),
                deletedMessageIDs: []
            )
        }

        var mergedMessages = incrementally ? messages : []
        var indexesByID = Dictionary(uniqueKeysWithValues: mergedMessages.enumerated().map { ($1.id, $0) })
        var didChange = !incrementally
        var newMessageIDs = Set<String>()

        if !deletedMessageIDs.isEmpty {
            let retainedMessages = mergedMessages.filter { !deletedMessageIDs.contains($0.id) }
            didChange = didChange || retainedMessages.count != mergedMessages.count
            mergedMessages = retainedMessages
            indexesByID = Dictionary(uniqueKeysWithValues: mergedMessages.enumerated().map { ($1.id, $0) })
        }

        for message in incomingMessages {
            if let index = indexesByID[message.id] {
                if mergedMessages[index] != message {
                    mergedMessages[index] = message
                    didChange = true
                }
            } else {
                indexesByID[message.id] = mergedMessages.count
                mergedMessages.append(message)
                newMessageIDs.insert(message.id)
                didChange = true
            }
        }

        guard didChange else {
            return ConversationMessageMerge(
                messages: messages,
                updatedMessages: [],
                newMessageIDs: [],
                deletedMessageIDs: []
            )
        }

        if !isChronologicallyOrdered(mergedMessages) {
            mergedMessages.sort {
                ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }
        }

        return ConversationMessageMerge(
            messages: mergedMessages,
            updatedMessages: incomingMessages,
            newMessageIDs: newMessageIDs,
            deletedMessageIDs: deletedMessageIDs
        )
    }

    private func isAppendOnlyDelta(_ incomingMessages: [KTPMessage]) -> Bool {
        guard !incomingMessages.isEmpty else { return true }
        guard isChronologicallyOrdered(incomingMessages) else { return false }
        guard let latestMessage = messages.last else { return true }

        return (incomingMessages.first?.createdAt ?? .distantPast)
            >= (latestMessage.createdAt ?? .distantPast)
    }

    private func isChronologicallyOrdered(_ messages: [KTPMessage]) -> Bool {
        zip(messages, messages.dropFirst()).allSatisfy {
            ($0.createdAt ?? .distantPast) <= ($1.createdAt ?? .distantPast)
        }
    }

    private func updateReactionState(
        for updatedMessages: [KTPMessage],
        removing deletedMessageIDs: Set<String>,
        replacesAll: Bool
    ) {
        if replacesAll {
            seedReactionState(from: messages)
            return
        }

        for messageID in deletedMessageIDs {
            reactionsByMessageID[messageID] = nil
        }

        for message in updatedMessages {
            reactionsByMessageID[message.id] = Dictionary(
                uniqueKeysWithValues: message.reactions.map { ($0.emoji, $0) }
            )
        }
    }

    @MainActor
    private func sendMessage(
        content: String,
        attachment: MessageAttachmentUpload?,
        reply: MessageReplyReference?
    ) async throws {
        do {
            let sentMessage: KTPMessage
            switch thread {
            case .direct(let conversation):
                sentMessage = try await apiService.sendMessage(
                    to: conversation.userId,
                    body: content.isEmpty ? nil : content,
                    attachment: attachment,
                    replyToMessageID: reply?.id
                )
            case .group(let chat):
                sentMessage = try await apiService.sendGroupChatMessage(
                    chatId: chat.id,
                    body: content.isEmpty ? nil : content,
                    attachment: attachment,
                    replyToMessageID: reply?.id
                )
            }
            let resolvedSentMessage = preservingReply(reply, on: sentMessage)
            if let attachment {
                attachmentDataByMessageID[resolvedSentMessage.id] = attachment.data
            }
            messages.append(resolvedSentMessage)
            messages.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            sentMessageIDs.insert(resolvedSentMessage.id)
            renderWindow.reset(totalCount: messages.count)
            scrollRequest = .latest(UUID())
            replyingTo = nil
            loadError = nil
            await offlineStore.saveConversation(messages, threadID: thread.id, accountID: accountID)
            NotificationCenter.default.post(name: .messageThreadShouldRefresh, object: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isOfflineTransportError(error) || !ConnectivityMonitor.shared.isConnected {
                let destination: MessageOfflineStore.PendingDelivery.Destination
                let destinationID: String
                switch thread {
                case .direct(let conversation):
                    destination = .direct
                    destinationID = conversation.userId
                case .group(let chat):
                    destination = .group
                    destinationID = chat.id
                }
                let delivery = await offlineStore.enqueue(
                    destination: destination,
                    destinationID: destinationID,
                    body: content.isEmpty ? nil : content,
                    attachment: attachment,
                    replyTo: reply,
                    accountID: accountID
                )
                let pendingMessage = delivery.localMessage(currentUserID: authManager.currentUserID)
                messages.append(pendingMessage)
                sentMessageIDs.insert(pendingMessage.id)
                pendingDeliveryCount += 1
                if let attachment {
                    attachmentDataByMessageID[pendingMessage.id] = attachment.data
                }
                renderWindow.reset(totalCount: messages.count)
                scrollRequest = .latest(UUID())
                replyingTo = nil
                loadError = nil
                isShowingCachedMessages = true
                await offlineStore.saveConversation(messages, threadID: thread.id, accountID: accountID)
                NotificationCenter.default.post(name: .messageThreadShouldRefresh, object: nil)
            } else {
                throw error
            }
        }
    }

    private func attachmentData(for message: KTPMessage) async throws -> Data {
        switch thread {
        case .direct:
            return try await apiService.fetchMessageAttachmentData(messageID: message.id)
        case .group(let chat):
            return try await apiService.fetchGroupChatMessageAttachmentData(chatID: chat.id, messageID: message.id)
        }
    }

    private func reactionSummaries(for message: KTPMessage) -> [MessageReactionSummary] {
        Array(reactionsByMessageID[message.id, default: [:]].values)
            .filter { $0.count > 0 }
            .sorted { left, right in
                let leftIndex = MessageReactionOptions.emojis.firstIndex(of: left.emoji) ?? .max
                let rightIndex = MessageReactionOptions.emojis.firstIndex(of: right.emoji) ?? .max
                return leftIndex == rightIndex ? left.emoji < right.emoji : leftIndex < rightIndex
            }
    }

    private func updatingEmojis(for message: KTPMessage) -> Set<String> {
        Set(MessageReactionOptions.emojis.filter {
            updatingReactionKeys.contains(reactionKey(messageID: message.id, emoji: $0))
        })
    }

    private func seedReactionState(from messages: [KTPMessage]) {
        reactionsByMessageID = Dictionary(uniqueKeysWithValues: messages.map { message in
            (
                message.id,
                Dictionary(uniqueKeysWithValues: message.reactions.map { ($0.emoji, $0) })
            )
        })
    }

    @MainActor
    private func toggleReaction(_ emoji: String, on message: KTPMessage) async {
        let updateKey = reactionKey(messageID: message.id, emoji: emoji)
        guard updatingReactionKeys.insert(updateKey).inserted else { return }
        defer { updatingReactionKeys.remove(updateKey) }

        let previous = reactionsByMessageID[message.id]?[emoji]
            ?? MessageReactionSummary(emoji: emoji, count: 0, reactedByCurrentUser: false)
        let isAdding = !previous.reactedByCurrentUser
        var updatedUsers = previous.users
        if let currentUserID = authManager.currentUserID {
            updatedUsers.removeAll { $0.id == currentUserID }
            if isAdding {
                updatedUsers.append(
                    MessageReactionUser(
                        id: currentUserID,
                        displayName: authManager.currentUserProfile?.displayName ?? "You"
                    )
                )
            }
        }
        let updated = MessageReactionSummary(
            emoji: emoji,
            count: max(0, previous.count + (isAdding ? 1 : -1)),
            reactedByCurrentUser: isAdding,
            users: updatedUsers
        )
        setReaction(updated, on: message.id)

        do {
            let serverReactions: [MessageReactionSummary]
            switch thread {
            case .direct:
                serverReactions = try await apiService.toggleMessageReaction(messageId: message.id, emoji: emoji)
            case .group(let chat):
                serverReactions = try await apiService.toggleGroupChatMessageReaction(
                    chatId: chat.id,
                    messageId: message.id,
                    emoji: emoji
                )
            }
            reactionsByMessageID[message.id] = Dictionary(
                uniqueKeysWithValues: serverReactions.map { ($0.emoji, $0) }
            )
        } catch is CancellationError {
            setReaction(previous, on: message.id)
        } catch {
            setReaction(previous, on: message.id)
            reactionErrorMessage = "The reaction could not be saved. Please try again."
        }
    }

    private func setReaction(_ reaction: MessageReactionSummary, on messageID: String) {
        if reaction.count == 0 {
            reactionsByMessageID[messageID]?[reaction.emoji] = nil
        } else {
            reactionsByMessageID[messageID, default: [:]][reaction.emoji] = reaction
        }
    }

    private func reactionKey(messageID: String, emoji: String) -> String {
        "\(messageID)|\(emoji)"
    }

    @MainActor
    private func deleteMessage(_ message: KTPMessage) async {
        guard deletingMessageIDs.insert(message.id).inserted else { return }
        messagePendingDeletion = nil
        deleteErrorMessage = nil
        defer { deletingMessageIDs.remove(message.id) }

        do {
            switch thread {
            case .direct:
                try await apiService.deleteMessage(id: message.id)
            case .group(let chat):
                try await apiService.deleteGroupChatMessage(chatId: chat.id, messageId: message.id)
            }

            messages.removeAll { $0.id == message.id }
            sentMessageIDs.remove(message.id)
            reactionsByMessageID[message.id] = nil
            renderWindow.reset(totalCount: messages.count)
            await offlineStore.saveConversation(messages, threadID: thread.id, accountID: accountID)
            NotificationCenter.default.post(name: .messageThreadShouldRefresh, object: nil)
        } catch is CancellationError {
            return
        } catch {
            deleteErrorMessage = "The message could not be deleted. Please try again."
        }
    }
}

private struct MessageDeleteConfirmationOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(colorScheme == .dark ? 0.16 : 0.09)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Delete Message?")
                        .font(AppFont.title(20))
                        .foregroundStyle(AppSystemColor.primaryLabel)

                    Text("This removes the message for everyone in the conversation.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    Button("Delete", role: .destructive, action: confirm)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(
                AppSystemColor.elevatedBackground,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppSystemColor.separator.opacity(0.40), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct ConversationEmptyState: View {
    let thread: MessageThread

    var body: some View {
        ContentUnavailableView(
            "No messages yet",
            systemImage: thread.isGroup ? "person.3" : "bubble.left.and.bubble.right",
            description: Text("Send the first message to start this conversation.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No messages in \(thread.displayName)")
    }
}

private struct ConversationLoadFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "Conversation unavailable",
                systemImage: "exclamationmark.bubble",
                description: Text(message)
            )

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A member-facing view of a group chat. Management stays on the website; this
/// sheet only surfaces the group identity and current participants.
private struct GroupChatDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let chat: GroupChat
    let apiService: KTPAPIService

    @State private var members: [DirectoryMember] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 12) {
                        GroupChatAvatar(chat: chat, size: 92, apiService: apiService)

                        Text(chat.name)
                            .font(AppFont.title(24))
                            .foregroundStyle(MessageDesign.primary(for: colorScheme))
                            .multilineTextAlignment(.center)

                        Text("Group chat")
                            .font(AppFont.footnote())
                            .foregroundStyle(MessageDesign.muted(for: colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)

                    Text("Members")
                        .font(AppFont.headline())
                        .foregroundStyle(MessageDesign.primary(for: colorScheme))

                    if isLoading {
                        MessagesStatusCard(message: "Loading members...")
                    } else if let loadError {
                        ConversationLoadFailure(message: loadError) {
                            Task { await loadMembers() }
                        }
                        .frame(minHeight: 180)
                    } else if members.isEmpty {
                        MessagesStatusCard(message: "No members are available for this group.")
                    } else {
                        ForEach(members) { member in
                            HStack(spacing: 12) {
                                ProfileAvatarView(
                                    imageURL: nil,
                                    profileID: member.authentikID ?? member.id,
                                    name: member.name,
                                    isGroup: false,
                                    size: 42,
                                    apiService: apiService
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.name)
                                        .font(AppFont.subheadline(weight: .semibold))
                                        .foregroundStyle(MessageDesign.primary(for: colorScheme))

                                    Text(member.group.title)
                                        .font(AppFont.caption())
                                        .foregroundStyle(MessageDesign.muted(for: colorScheme))
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(20)
            }
            .background(MessageDesign.background(for: colorScheme))
            .navigationTitle("Group Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: chat.id) {
                await loadMembers()
            }
        }
    }

    @MainActor
    private func loadMembers() async {
        isLoading = true
        loadError = nil

        do {
            members = try await apiService.fetchGroupChatMembers(chatID: chat.id)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch is CancellationError {
            return
        } catch {
            members = []
            loadError = messagesErrorMessage(for: error)
        }

        isLoading = false
    }
}

/// Limits the rendered conversation while the current API returns one unpaginated message array.
private struct ConversationRenderWindow {
    private let pageSize = 50
    private(set) var visibleCount = 0

    mutating func reset(totalCount: Int) {
        visibleCount = min(pageSize, totalCount)
    }

    mutating func loadEarlierMessages(totalCount: Int) {
        visibleCount = min(totalCount, visibleCount + pageSize)
    }

    /// Keeps a user-expanded history window intact when an incremental delta
    /// arrives, while still handling a concurrent deletion.
    mutating func clamp(to totalCount: Int) {
        visibleCount = min(visibleCount, totalCount)
    }

    func hasEarlierMessages(totalCount: Int) -> Bool {
        visibleCount < totalCount
    }
}

private struct ConversationMessageMerge {
    let messages: [KTPMessage]
    let updatedMessages: [KTPMessage]
    let newMessageIDs: Set<String>
    let deletedMessageIDs: Set<String>
}

private enum MessageGrouping {
    /// Consecutive messages from one person remain a single visual group unless
    /// there has been a meaningful pause in the conversation.
    static let maximumInterval: TimeInterval = 5 * 60
}

private enum ConversationScrollRequest: Equatable {
    case preservePosition(String)
    case latest(UUID)
}

private struct MessageSender {
    let id: String?
    let name: String
    let imageURL: URL?
}

private struct MessageReactionDetails: Identifiable {
    let messageID: String
    let reaction: MessageReactionSummary

    var id: String { "\(messageID)-\(reaction.emoji)" }
}

private struct MessageReplyPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let replyTo: MessageReplyReference

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(MessageDesign.primary(for: colorScheme).opacity(0.55))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                if let name = replyTo.senderDisplayName, !name.isEmpty {
                    Text(name)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(MessageDesign.primary(for: colorScheme))
                }

                Text(replyTo.preview)
                    .font(AppFont.caption())
                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MessageDesign.input(for: colorScheme).opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(replyTo.senderDisplayName ?? "message"): \(replyTo.preview)")
    }
}

struct MessageReplyComposerPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let replyTo: MessageReplyReference
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(MessageDesign.primary(for: colorScheme))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(replyTo.senderDisplayName ?? "message")")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))

                Text(replyTo.preview)
                    .font(AppFont.caption())
                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(AppFont.subheadline())
                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MessageDesign.card(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MessageDesign.border(for: colorScheme), lineWidth: 1)
        }
    }
}

private struct MessageReactionDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let details: MessageReactionDetails

    private var namedUsers: [MessageReactionUser] {
        details.reaction.users.filter {
            guard let name = $0.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !name.isEmpty
        }
    }

    private var totalLabel: String {
        let count = details.reaction.count
        return "\(count) \(count == 1 ? "person" : "people") reacted"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Text(details.reaction.emoji)
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(totalLabel)
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(MessageDesign.primary(for: colorScheme))
                            if details.reaction.reactedByCurrentUser {
                                Text("You reacted")
                                    .font(AppFont.caption())
                                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
                            }
                        }
                    }
                }

                if namedUsers.isEmpty {
                    Section {
                        Text("Names will appear here when the conversation refresh includes reaction details.")
                            .font(AppFont.subheadline())
                            .foregroundStyle(MessageDesign.muted(for: colorScheme))
                    }
                } else {
                    Section("Reactions") {
                        ForEach(namedUsers) { user in
                            Text(user.displayName ?? "Member")
                                .font(AppFont.subheadline())
                                .foregroundStyle(MessageDesign.primary(for: colorScheme))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MessageDesign.background(for: colorScheme))
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsMessageActions = false
    @State private var holdFeedbackTrigger = 0
    let message: KTPMessage
    let sender: MessageSender
    let isSentByCurrentUser: Bool
    let showsSenderIdentity: Bool
    let apiService: KTPAPIService
    let attachmentSourceID: String
    let attachmentData: Data?
    let loadAttachmentData: () async throws -> Data
    let replyTo: MessageReplyReference?
    let replyMessage: () -> Void
    let allowsReactions: Bool
    let reactions: [MessageReactionSummary]
    let updatingEmojis: Set<String>
    let toggleReaction: (String) -> Void
    let showReactionDetails: (MessageReactionSummary) -> Void
    let deleteMessage: (() -> Void)?
    let isDeleting: Bool
    let reportMessage: (() -> Void)?

    var body: some View {
        VStack(alignment: isSentByCurrentUser ? .trailing : .leading, spacing: 6) {
            messageHeader

            messageSurface
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35, maximumDistance: 22)
                        .onEnded { _ in
                            holdFeedbackTrigger += 1
                            showsMessageActions = true
                        }
                )
                .sensoryFeedback(.impact(weight: .medium), trigger: holdFeedbackTrigger)
                .popover(
                    isPresented: $showsMessageActions,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: isSentByCurrentUser ? .trailing : .leading
                ) {
                    messageActionsPopover
                        .presentationCompactAdaptation(.popover)
                }

            if allowsReactions, !reactions.isEmpty {
                reactionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: isSentByCurrentUser ? .trailing : .leading)
        .accessibilityHint(
            isSentByCurrentUser
                ? "Touch and hold for reactions and message options"
                : "Touch and hold for reactions and reporting options"
        )
    }

    private var messageSurface: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let replyTo {
                MessageReplyPreview(replyTo: replyTo)
            }

            if let attachment = message.attachment, attachment.isImage {
                MessageAttachmentPreview(
                    attachment: attachment,
                    sourceID: attachmentSourceID,
                    cachedData: attachmentData,
                    loadData: loadAttachmentData
                )
            }

            if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message.body)
                    .font(AppFont.subheadline())
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let createdAt = message.createdAt {
                Text(createdAt.relativeMessageTime)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(MessageDesign.muted(for: colorScheme))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .modifier(MessageBubbleSurface(
            isSentByCurrentUser: isSentByCurrentUser,
            colorScheme: colorScheme
        ))
    }

    private var messageActionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsMessageActions = false
                replyMessage()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }

            if allowsReactions {
                Divider()

                HStack(spacing: 4) {
                    ForEach(MessageReactionOptions.emojis, id: \.self) { emoji in
                        Button {
                            showsMessageActions = false
                            toggleReaction(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 22))
                                .frame(width: 38, height: 38)
                                .background(
                                    hasCurrentUserReaction(emoji)
                                        ? MessageDesign.selectionTint(for: colorScheme)
                                        : Color.clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(updatingEmojis.contains(emoji))
                        .accessibilityLabel(
                            hasCurrentUserReaction(emoji)
                                ? "Remove \(emoji) reaction"
                                : "React with \(emoji)"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if let reportMessage {
                Divider()

                Button(role: .destructive) {
                    showsMessageActions = false
                    reportMessage()
                } label: {
                    Label("Report Message", systemImage: "exclamationmark.bubble")
                        .font(AppFont.footnote(weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }

            if let deleteMessage {
                Divider()

                Button(role: .destructive) {
                    showsMessageActions = false
                    deleteMessage()
                } label: {
                    Label(isDeleting ? "Deleting…" : "Delete Message", systemImage: "trash")
                        .font(AppFont.footnote(weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(isDeleting)
            }
        }
        .padding(12)
        .frame(width: 230)
    }

    private func hasCurrentUserReaction(_ emoji: String) -> Bool {
        reactions.contains { $0.emoji == emoji && $0.reactedByCurrentUser }
    }

    @ViewBuilder
    private var messageHeader: some View {
        if showsSenderIdentity {
            HStack(spacing: 6) {
                if isSentByCurrentUser {
                    senderName
                    senderAvatar
                } else {
                    senderAvatar
                    senderName
                }
            }
        }
    }

    private var senderName: some View {
        Text(sender.name)
            .font(AppFont.caption(weight: .bold))
            .foregroundStyle(MessageDesign.muted(for: colorScheme))
            .lineLimit(1)
    }

    private var senderAvatar: some View {
        AuthenticatedMessageAvatar(sender: sender, size: 30, apiService: apiService)
            .frame(width: 30, height: 30)
    }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(reactions) { reaction in
                Button {
                    showReactionDetails(reaction)
                } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.count)")
                            .font(AppFont.caption(weight: .semibold))
                    }
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        reaction.reactedByCurrentUser
                            ? MessageDesign.selectionTint(for: colorScheme)
                            : MessageDesign.card(for: colorScheme),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(MessageDesign.border(for: colorScheme), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(reaction.emoji) reaction, \(reaction.count), "
                    + (reaction.reactedByCurrentUser ? "selected" : "not selected")
                )
                .accessibilityHint("Shows who reacted")
            }
        }
    }
}

private struct MessageAttachmentPreview: View {
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var thumbnailRepository: MessageAttachmentThumbnailRepository
    let attachment: MessageAttachment
    let sourceID: String
    let cachedData: Data?
    let loadData: () async throws -> Data

    @State private var image: UIImage?
    @State private var gifData: Data?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if attachment.isGIF, let gifData {
                AnimatedGIFView(data: gifData)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                unavailableMedia
            } else {
                ProgressView()
                    .frame(width: 220, height: 152)
            }
        }
        .frame(width: 220, height: 152)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: attachmentLoadID) {
            do {
                if attachment.isGIF {
                    if let cachedData {
                        gifData = cachedData
                    } else {
                        gifData = try await loadData()
                    }
                    // GIFs remain animated instead of being flattened into a
                    // thumbnail. They are not decoded by UIImage in the scroll path.
                    return
                }

                image = await thumbnailRepository.image(
                    for: sourceID,
                    pointSize: 220,
                    displayScale: displayScale,
                    loadData: {
                        if let cachedData { return cachedData }
                        return try await loadData()
                    }
                )
                loadFailed = image == nil
            } catch is CancellationError {
                return
            } catch {
                loadFailed = true
            }
        }
        .accessibilityLabel(attachment.isGIF ? "Animated GIF attachment" : "Image attachment")
    }

    private var attachmentLoadID: String {
        "\(sourceID)-\(attachment.filename ?? "attachment")-\(cachedData?.count ?? 0)-\(Int(displayScale * 220))"
    }

    private var unavailableMedia: some View {
        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(MessageDesign.muted(for: .light))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    final class Coordinator {
        var loadedContentHash: Int?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // SwiftUI can call updateUIView while an unrelated row state changes.
        // Reloading a WebKit GIF restarts its animation and unnecessarily
        // decodes the asset, so only hand WebKit new content.
        let contentHash = data.hashValue
        guard context.coordinator.loadedContentHash != contentHash else { return }
        context.coordinator.loadedContentHash = contentHash
        webView.load(
            data,
            mimeType: "image/gif",
            characterEncodingName: "utf-8",
            baseURL: URL(string: "about:blank")!
        )
    }
}

struct MessageAttachmentDraftPreview: View {
    let attachment: MessageAttachmentUpload
    let previewImage: UIImage?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if attachment.isGIF {
                AnimatedGIFView(data: attachment.data)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Spacer(minLength: 0)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(8)
        .background(MessageDesign.input(for: .light), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension MessageAttachment {
    var isImage: Bool {
        mimeType?.lowercased().hasPrefix("image/") == true || kind.lowercased() == "image"
    }

    var isGIF: Bool {
        mimeType?.lowercased() == "image/gif" || filename?.lowercased().hasSuffix(".gif") == true
    }
}

extension MessageAttachmentUpload {
    var isGIF: Bool {
        mimeType.lowercased() == "image/gif" || fileName.lowercased().hasSuffix(".gif")
    }
}

enum MessageAttachmentLimits {
    static let maximumBytes = 25 * 1024 * 1024
}

enum MessageAttachmentError: LocalizedError {
    case unreadableImage
    case unsupportedType
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Couldn’t read that image or GIF."
        case .unsupportedType:
            return "Choose an image or GIF file."
        case .fileTooLarge:
            return "Images and GIFs must be 25 MB or smaller."
        }
    }
}

struct MessagePickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let copiedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: received.file, to: copiedURL)
            return MessagePickedImage(url: copiedURL)
        }
    }
}

private enum MessageReactionOptions {
    static let emojis = ["👍", "❤️", "😂", "🎉", "😮"]
}

private struct AuthenticatedMessageAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var avatarRepository: AvatarRepository
    let sender: MessageSender
    let size: CGFloat
    let apiService: KTPAPIService

    @State private var image: UIImage?

    private var initials: String {
        let value = String(sender.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return value.isEmpty ? "KT" : value
    }

    var body: some View {
        ZStack {
            Circle().fill(MessageDesign.avatarBackground(for: colorScheme))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(AppFont.caption(weight: .bold))
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))
            }
        }
        .clipShape(Circle())
        .task(id: "\(sender.id ?? sender.imageURL?.absoluteString ?? sender.name)-\(Int(size * displayScale))") {
            await loadImage()
        }
        .accessibilityLabel("\(sender.name) profile picture")
    }

    @MainActor
    private func loadImage() async {
        let sourceID = sender.id ?? sender.imageURL?.absoluteString ?? sender.name
        let avatar = await avatarRepository.image(
            for: sourceID,
            pointSize: size,
            displayScale: displayScale,
            loadData: {
                if let imageURL = sender.imageURL {
                    return try await URLSession.shared.data(from: imageURL).0
                }

                guard let senderID = sender.id else { throw URLError(.badURL) }
                return try await apiService.fetchProfilePictureData(for: senderID)
            }
        )
        guard !Task.isCancelled else { return }
        image = avatar
    }
}

private struct MessageOfflineBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String

    var body: some View {
        Label(message, systemImage: "arrow.triangle.2.circlepath.icloud")
            .font(AppFont.footnote(weight: .medium))
            .foregroundStyle(MessageDesign.secondary(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

private struct MessagesStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String

    var body: some View {
        Text(message)
            .font(AppFont.subheadline())
            .foregroundStyle(MessageDesign.secondary(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(MessageDesign.card(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MessageDesign.border(for: colorScheme), lineWidth: 1)
            }
    }
}

enum MessageDesign {
    static func background(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.background
    }

    static func card(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.elevatedBackground
    }

    static func primary(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel
    }

    static func secondary(for colorScheme: ColorScheme) -> Color {
        primary(for: colorScheme).opacity(0.72)
    }

    static func muted(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.secondaryLabel
    }

    static func border(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.separator.opacity(colorScheme == .dark ? 0.65 : 0.45)
    }

    static func shadow(for colorScheme: ColorScheme) -> Color {
        Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035)
    }

    static func avatarBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.insetBackground
    }

    static func input(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.insetBackground
    }

    static func sentBubble(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel.opacity(colorScheme == .dark ? 0.20 : 0.10)
    }

    static func selectionTint(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel.opacity(colorScheme == .dark ? 0.18 : 0.12)
    }

    static var sendForeground: Color {
        AppSystemColor.background
    }
}

private struct MessageBubbleSurface: ViewModifier {
    let isSentByCurrentUser: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(
                isSentByCurrentUser
                    ? MessageDesign.sentBubble(for: colorScheme)
                    : MessageDesign.card(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MessageDesign.border(for: colorScheme), lineWidth: 1)
            }
    }
}

struct MessageComposerFieldSurface: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(
                MessageDesign.input(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MessageDesign.border(for: colorScheme), lineWidth: 1)
            }
    }
}

struct MessageSendButtonSurface: ViewModifier {
    let canSend: Bool

    func body(content: Content) -> some View {
        content.background(
            canSend ? AppSystemColor.primaryLabel : AppSystemColor.secondaryLabel,
            in: Circle()
        )
    }
}

private struct MessageTimelineActionSurface: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private func messagesErrorMessage(for error: Error) -> String {
    if case AuthManagerError.notAuthenticated = error {
        return "Sign in with SSO to load messages."
    }

    if case KTPAPIError.missingAccessToken = error {
        return "Sign in with SSO to load messages."
    }

    if case KTPAPIError.badStatusCode(let statusCode, _) = error {
        if statusCode == 401 || statusCode == 403 {
            return "Your message access has expired. Sign out and sign in again."
        }

        return "Messages are temporarily unavailable. Please try again later."
    }

    if case KTPAPIError.decodeFailed(_) = error {
        return "Messages returned an unsupported response. Please try again later."
    }

    return "Could not load messages. Please check your connection and try again."
}

func messageSendErrorMessage(for error: Error) -> String {
    if case AuthManagerError.notAuthenticated = error {
        return "Sign in with SSO before sending a message."
    }

    if case KTPAPIError.missingAccessToken = error {
        return "Sign in with SSO before sending a message."
    }

    if case KTPAPIError.badStatusCode(let statusCode, _) = error {
        if statusCode == 401 || statusCode == 403 {
            return "Your message access has expired. Sign out and sign in again."
        }

        return "The server could not send this message. Your conversation is still available—please try again."
    }

    return "The message could not be sent. Check your connection and try again."
}

private extension Date {
    var relativeMessageTime: String {
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInYesterday(self) {
            return "Yesterday"
        }

        return formatted(date: .abbreviated, time: .omitted)
    }
}

#if DEBUG
#Preview("Message Threads") {
    NavigationStack {
        MessageThreadsView()
            .padding(20)
            .background(AppTab.messages.theme.previewBackground())
            .navigationDestination(for: MessageThread.self) { thread in
                MessageConversationView(thread: thread)
            }
    }
    .environmentObject(AuthManager.previewSignedOut)
    .environmentObject(AvatarRepository())
    .environmentObject(MessageAttachmentThumbnailRepository())
}
#endif
