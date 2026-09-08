//
//  MessagesView.swift
//  KTPLIFE
//

import SwiftUI

struct MessagesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var authManager: AuthManager
    @State private var selectedSection: CommunitySection = .messages
    @State private var messagePath: [MessageThread] = []
    @State private var inboxRefreshVersion = 0
    @State private var deepLinkTask: Task<Void, Never>?
    @Binding private var isConversationPresented: Bool
    @Binding private var deepLinkedUserID: String?
    @Binding private var deepLinkedGroupChat: GroupChatPushDestination?

    init(
        isConversationPresented: Binding<Bool> = .constant(false),
        deepLinkedUserID: Binding<String?> = .constant(nil),
        deepLinkedGroupChat: Binding<GroupChatPushDestination?> = .constant(nil)
    ) {
        _isConversationPresented = isConversationPresented
        _deepLinkedUserID = deepLinkedUserID
        _deepLinkedGroupChat = deepLinkedGroupChat
    }

    var body: some View {
        NavigationStack(path: $messagePath) {
            PageScaffold() {
                VStack(spacing: 16) {
                    communityNavigationBar

                    switch selectedSection {
                    case .messages:
                        MessageThreadsView(refreshVersion: inboxRefreshVersion)
                    case .directory:
                        MemberDirectoryView(
                            messageMember: openConversation(with:),
                            allowedGroups: authManager.currentUserGroup?.directoryContactGroups
                        )
                    }
                }
            }
            // This inset belongs to the inbox screen, not the NavigationStack. Keeping
            // the stack full width lets the conversation destination fill the screen.
            .padding(.horizontal, 20)
            .navigationDestination(for: MessageThread.self) { thread in
                MessageConversationView(thread: thread)
            }
        }
        // Keep the custom app shell informed when a thread is pushed or dismissed.
        .onChange(of: messagePath) { oldPath, newPath in
            isConversationPresented = !newPath.isEmpty

            if !oldPath.isEmpty, newPath.isEmpty {
                inboxRefreshVersion += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageThreadShouldRefresh)) { _ in
            // A successful send changes a thread's preview and sort position.
            // Refresh the inbox immediately instead of waiting for its poll or
            // for the user to leave and reopen the conversation.
            inboxRefreshVersion += 1
        }
        .onDisappear {
            deepLinkTask?.cancel()
            isConversationPresented = false
        }
        .onAppear { openPushConversationIfNeeded() }
        .onChange(of: deepLinkedUserID) { _, _ in openPushConversationIfNeeded() }
        .onChange(of: deepLinkedGroupChat) { _, _ in openPushConversationIfNeeded() }
        .background(MessageDesign.background(for: colorScheme).ignoresSafeArea())
    }

    @ViewBuilder
    private var communityNavigationBar: some View {
        HStack {
            switch selectedSection {
            case .messages:
                Text("Direct Messages")
                    .font(AppFont.headline())
                    .foregroundStyle(MessageDesign.primary(for: colorScheme))

                Spacer()

                Button {
                    selectedSection = .directory
                } label: {
                    Text("Directory")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(MessageDesign.primary(for: colorScheme))
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open member directory")

            case .directory:
                Button {
                    selectedSection = .messages
                } label: {
                    Label("Messages", systemImage: "chevron.left")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(MessageDesign.primary(for: colorScheme))
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to messages")

                Spacer()
            }
        }
    }

    private func openConversation(with member: DirectoryMember) {
        let conversation = MessageConversation(
            id: "directory-\(member.id)",
            userId: member.id,
            displayName: member.name,
            preview: "No messages yet.",
            lastMessageDate: nil,
            unreadCount: 0
        )
        messagePath.append(.direct(conversation))
    }

    private func openPushConversationIfNeeded() {
        if let target = deepLinkedGroupChat {
            deepLinkedGroupChat = nil
            deepLinkTask?.cancel()
            deepLinkTask = Task { @MainActor in
                let chat = await resolvedGroupChat(for: target)
                guard !Task.isCancelled else { return }
                selectedSection = .messages
                messagePath = [.group(chat)]
            }
            return
        }

        guard let userID = deepLinkedUserID else { return }
        deepLinkedUserID = nil
        deepLinkTask?.cancel()

        deepLinkTask = Task { @MainActor in
            let conversation = await resolvedConversation(for: userID)
            guard !Task.isCancelled else { return }

            selectedSection = .messages
            // A notification is a destination, not another level in the current
            // navigation history. Replacing the path prevents repeated notification
            // taps from stacking copies of the same conversation.
            messagePath = [.direct(conversation)]
        }
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private func resolvedConversation(for userID: String) async -> MessageConversation {
        if let conversations = try? await apiService.fetchMessageConversations(),
           let conversation = conversations.first(where: { $0.userId == userID }) {
            return conversation
        }

        if let members = try? await apiService.fetchDirectoryMembers(),
           let member = members.first(where: { $0.id == userID }) {
            return MessageConversation(
                id: "push-\(userID)",
                userId: userID,
                displayName: member.name,
                preview: "No messages yet.",
                lastMessageDate: nil,
                unreadCount: 0
            )
        }

        if let messages = try? await apiService.fetchConversation(with: userID),
           let senderMessage = messages.last(where: {
               $0.senderId == userID && $0.senderDisplayName?.isEmpty == false
           }) {
            return MessageConversation(
                id: "push-\(userID)",
                userId: userID,
                displayName: senderMessage.senderDisplayName ?? "Member",
                preview: messages.last?.inboxPreview ?? "",
                lastMessageDate: messages.last?.createdAt,
                unreadCount: 0,
                profileImageURL: senderMessage.senderProfileImageURL
            )
        }

        return MessageConversation(
            id: "push-\(userID)",
            userId: userID,
            displayName: "Member",
            preview: "",
            lastMessageDate: nil,
            unreadCount: 0
        )
    }

    private func resolvedGroupChat(for target: GroupChatPushDestination) async -> GroupChat {
        if let chats = try? await apiService.fetchGroupChats(),
           let chat = chats.first(where: { $0.id == target.id }) {
            return chat
        }

        let payloadName = target.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = payloadName.flatMap { $0.isEmpty ? nil : $0 } ?? "Group Chat"
        return GroupChat(
            id: target.id,
            name: resolvedName,
            preview: "",
            lastMessageDate: nil,
            unreadCount: 0
        )
    }
}

private enum CommunitySection {
    case messages
    case directory
}

#if DEBUG
#Preview("Messages") {
    MessagesView()
        .padding(20)
        .background(AppTab.community.theme.previewBackground())
        .environmentObject(AuthManager.previewSignedOut)
        .environmentObject(AvatarRepository())
}
#endif
