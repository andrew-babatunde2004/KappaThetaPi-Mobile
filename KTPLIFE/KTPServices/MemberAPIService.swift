import Foundation

enum KTPAPIError: Error {
    case missingAccessToken
    case badStatusCode(Int, String)
    case decodeFailed(String)
    case emptyResponse
}

enum ConversationSyncResponse {
    case notModified
    case updated(page: ConversationMessagePage, eTag: String?)
}

private struct ProtectedAPIResponse {
    let data: Data
    let response: HTTPURLResponse
}

/// Client for the KTP API. Protected routes require an Authentik access token.
final class KTPAPIService {

    private let baseURL: URL
    private let session: URLSession
    private let accessTokenProvider: () async throws -> String?

    init(
        baseURL: URL = APIConfig.baseURL,
        session: URLSession = .shared,
        accessTokenProvider: @escaping () async throws -> String? = { APIConfig.developmentAccessToken }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.accessTokenProvider = accessTokenProvider
    }

    /// Fetches all completed member profiles from protected `GET /members`.
    func fetchDirectoryMembers() async throws -> [DirectoryMember] {
        let url = baseURL.appendingPathComponent("members")
        let data = try await fetchProtectedData(from: url, logLabel: "directory members")

        do {
            return try DirectoryMembersResponse.decodeMembers(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Directory decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches the limited directory available to rushees from `GET /members/leadership`.
    func fetchLeadershipMembers() async throws -> [DirectoryMember] {
        let url = baseURL
            .appendingPathComponent("members")
            .appendingPathComponent("leadership")
        let data = try await fetchProtectedData(from: url, logLabel: "leadership members")

        do {
            return try DirectoryMembersResponse.decodeMembers(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Leadership directory decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches one complete directory profile from protected `GET /members/:id`.
    func fetchDirectoryMember(id: String) async throws -> DirectoryMember {
        let url = baseURL.appendingPathComponent("members").appendingPathComponent(id)
        let data = try await fetchProtectedData(from: url, logLabel: "directory member \(id)")
        do {
            return try JSONDecoder().decode(DirectoryMember.self, from: data)
        } catch {
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches the authenticated member profile from protected `GET /users/me`.
    func fetchCurrentUserProfile() async throws -> UserProfile {
        let url = baseURL.appendingPathComponent("users/me")
        let data = try await fetchProtectedData(from: url, logLabel: "current user profile")

        do {
            return try UserProfile.decodeResponse(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Current profile decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Updates editable fields through protected `PUT /users/me/profile`.
    func updateCurrentUserProfile(_ profile: UpdateUserProfileRequest) async throws -> UserProfile {
        let url = baseURL.appendingPathComponent("users/me/profile")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(profile)

        let data = try await fetchProtectedData(for: request, logLabel: "update current user profile")
        if !data.isEmpty, let updatedProfile = try? UserProfile.decodeResponse(from: data) {
            return updatedProfile
        }

        return try await fetchCurrentUserProfile()
    }

    /// Replaces the authenticated user's profile picture through protected
    /// `PUT /users/me/profile-picture`.
    func updateCurrentUserProfilePicture(_ image: MessageAttachmentUpload) async throws -> UserProfile {
        let url = baseURL.appendingPathComponent("users/me/profile-picture")
        let request = Self.multipartRequest(url: url, method: "PUT", fields: [:], file: image)
        let data = try await fetchProtectedData(for: request, logLabel: "update current user profile picture")

        if !data.isEmpty, let updatedProfile = try? UserProfile.decodeResponse(from: data) {
            return updatedProfile
        }

        return try await fetchCurrentUserProfile()
    }

    /// Anonymizes the authenticated user's account through protected `DELETE /users/me`.
    func deleteCurrentUser() async throws {
        let url = baseURL.appendingPathComponent("users/me")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "delete current user")
    }

    /// Fetches the authenticated user's block list through protected `GET /users/blocked`.
    func fetchBlockedUserIDs() async throws -> Set<String> {
        let url = baseURL.appendingPathComponent("users/blocked")
        let data = try await fetchProtectedData(from: url, logLabel: "blocked users")

        do {
            return try BlockedUsersResponse.decodeIDs(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Blocked users decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Blocks a member through protected `POST /users/:id/block`.
    func blockUser(id: String) async throws {
        let url = baseURL
            .appendingPathComponent("users")
            .appendingPathComponent(id)
            .appendingPathComponent("block")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await fetchProtectedData(for: request, logLabel: "block user \(id)")
    }

    /// Unblocks a member through protected `DELETE /users/:id/block`.
    func unblockUser(id: String) async throws {
        let url = baseURL
            .appendingPathComponent("users")
            .appendingPathComponent(id)
            .appendingPathComponent("block")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "unblock user \(id)")
    }

    /// Fetches message conversations from protected `GET /messages/conversations`.
    func fetchMessageConversations() async throws -> [MessageConversation] {
        let url = baseURL.appendingPathComponent("messages/conversations")
        let data = try await fetchProtectedData(from: url, logLabel: "message conversations")

        do {
            return try MessageConversationsResponse.decodeConversations(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Message conversations decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    func fetchDirectMessageUnreadCount() async throws -> Int {
        let data = try await fetchProtectedData(
            from: baseURL.appendingPathComponent("messages/unread-count"),
            logLabel: "direct message unread count"
        )
        return try UnreadCountResponse.decode(from: data)
    }

    /// Fetches group chats from protected `GET /group-chats`.
    func fetchGroupChats() async throws -> [GroupChat] {
        let url = baseURL.appendingPathComponent("group-chats")
        let data = try await fetchProtectedData(from: url, logLabel: "group chats")

        do {
            return try GroupChatsResponse.decodeChats(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Group chats decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    func fetchGroupChatUnreadCount() async throws -> Int {
        let data = try await fetchProtectedData(
            from: baseURL.appendingPathComponent("group-chats/unread-count"),
            logLabel: "group chat unread count"
        )
        return try UnreadCountResponse.decode(from: data)
    }

    /// Fetches server-backed direct and group-chat mute choices.
    func fetchMessageMutePreferences() async throws -> MessageMutePreferences {
        let data = try await fetchProtectedData(
            from: baseURL.appendingPathComponent("messages/mutes"),
            logLabel: "message mute preferences"
        )
        return try JSONDecoder().decode(MessageMutePreferences.self, from: data)
    }

    /// Mutes or unmutes notifications from one direct-message member.
    func setDirectMessageMuted(_ muted: Bool, userID: String) async throws -> Bool {
        let url = baseURL
            .appendingPathComponent("messages/conversations")
            .appendingPathComponent(userID)
            .appendingPathComponent("mute")
        return try await updateMessageMute(muted, at: url, logLabel: "direct message mute")
    }

    /// Mutes or unmutes notifications from one group chat.
    func setGroupChatMuted(_ muted: Bool, chatID: String) async throws -> Bool {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("mute")
        return try await updateMessageMute(muted, at: url, logLabel: "group chat mute")
    }

    private func updateMessageMute(_ muted: Bool, at url: URL, logLabel: String) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MessageMuteUpdateRequest(muted: muted))
        let data = try await fetchProtectedData(for: request, logLabel: logLabel)
        return try JSONDecoder().decode(MessageMuteUpdateResponse.self, from: data).muted
    }

    /// Fetches a group chat's member-only profile image.
    func fetchGroupChatPhotoData(chatID: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("photo")
            .appendingPathComponent("media")
        return try await fetchProtectedData(from: url, logLabel: "group chat photo for \(chatID)")
    }

    func fetchMessageAttachmentData(messageID: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("messages")
            .appendingPathComponent(messageID)
            .appendingPathComponent("attachment")
        return try await fetchProtectedData(from: url, logLabel: "message \(messageID) attachment")
    }

    func fetchGroupChatMessageAttachmentData(chatID: String, messageID: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("messages")
            .appendingPathComponent(messageID)
            .appendingPathComponent("attachment")
        return try await fetchProtectedData(from: url, logLabel: "group message \(messageID) attachment")
    }

    /// Fetches one direct conversation from protected `GET /messages/conversations/:userId`.
    func fetchConversation(with userId: String) async throws -> [KTPMessage] {
        let url = baseURL
            .appendingPathComponent("messages/conversations")
            .appendingPathComponent(userId)
        let data = try await fetchProtectedData(from: url, logLabel: "conversation with \(userId)")

        do {
            return try ConversationMessagesResponse.decodeMessages(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Conversation decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches only changes after a conversation cursor. Responses are also
    /// conditionally requested with the last ETag, so an unchanged history has
    /// no response body to decode.
    func syncConversation(
        with userId: String,
        after cursor: String?,
        eTag: String?
    ) async throws -> ConversationSyncResponse {
        let url = baseURL
            .appendingPathComponent("messages/conversations")
            .appendingPathComponent(userId)
        return try await fetchConversationSync(
            from: url,
            after: cursor,
            eTag: eTag,
            logLabel: "conversation sync with \(userId)"
        )
    }

    /// Fetches messages from protected `GET /group-chats/:id/messages`.
    func fetchGroupChatMessages(chatId: String) async throws -> [KTPMessage] {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("messages")
        let data = try await fetchProtectedData(from: url, logLabel: "group chat \(chatId) messages")

        do {
            return try ConversationMessagesResponse.decodeMessages(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Group chat messages decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches only changes after a group-chat cursor.
    func syncGroupChatMessages(
        chatId: String,
        after cursor: String?,
        eTag: String?
    ) async throws -> ConversationSyncResponse {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("messages")
        return try await fetchConversationSync(
            from: url,
            after: cursor,
            eTag: eTag,
            logLabel: "group chat sync \(chatId)"
        )
    }

    /// Marks one direct conversation read via protected `PUT /messages/conversations/:userId/read`.
    func markConversationRead(with userId: String) async throws {
        let url = baseURL
            .appendingPathComponent("messages/conversations")
            .appendingPathComponent(userId)
            .appendingPathComponent("read")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        _ = try await fetchProtectedData(for: request, logLabel: "mark conversation read for \(userId)")
    }

    /// Marks one group chat read via protected `PUT /group-chats/:id/read`.
    func markGroupChatRead(chatId: String) async throws {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("read")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        _ = try await fetchProtectedData(for: request, logLabel: "mark group chat \(chatId) read")
    }

    /// Sends a direct message via protected `POST /messages`.
    func sendMessage(to userId: String, content: String) async throws -> KTPMessage {
        try await sendMessage(to: userId, body: content, attachment: nil)
    }

    /// Sends text, an attachment, or both as the multipart contract requires.
    func sendMessage(
        to userId: String,
        body: String?,
        attachment: MessageAttachmentUpload?,
        replyToMessageID: String? = nil
    ) async throws -> KTPMessage {
        let url = baseURL.appendingPathComponent("messages")
        let request = Self.multipartRequest(
            url: url,
            method: "POST",
            fields: [
                "recipient_id": userId,
                "body": body,
                "reply_to_id": replyToMessageID,
            ],
            file: attachment
        )

        let data = try await fetchProtectedData(for: request, logLabel: "send message to \(userId)")
        if let message = try? SentMessageResponse.decodeMessage(from: data) {
            return message
        }

        // Some successful API versions return an acknowledgement or an empty
        // body instead of the created message. The 2xx status still means the
        // send succeeded, so render a local copy until the next inbox refresh.
        let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
        AuthDebugLog.log("Send message returned no decodable message. Using a local copy. Body=\(responseBody)")
        return KTPMessage(
            id: "local-\(UUID().uuidString)",
            senderId: nil,
            recipientId: userId,
            body: body ?? "",
            attachment: attachment.map {
                MessageAttachment(kind: "file", filename: $0.fileName, mimeType: $0.mimeType, size: $0.data.count)
            },
            createdAt: Date(),
            isRead: true,
            replyTo: replyToMessageID.map { MessageReplyReference(id: $0) }
        )
    }

    /// Deletes a direct message owned by the authenticated user via protected `DELETE /messages/:id`.
    func deleteMessage(id: String) async throws {
        let url = baseURL
            .appendingPathComponent("messages")
            .appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "delete message \(id)")
    }

    /// Deletes a group-chat message owned by the authenticated user.
    func deleteGroupChatMessage(chatId: String, messageId: String) async throws {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("messages")
            .appendingPathComponent(messageId)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "delete group chat \(chatId) message \(messageId)")
    }

    /// Toggles the authenticated user's emoji reaction on one direct message.
    func toggleMessageReaction(messageId: String, emoji: String) async throws -> [MessageReactionSummary] {
        let url = baseURL
            .appendingPathComponent("messages")
            .appendingPathComponent(messageId)
            .appendingPathComponent("reactions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MessageReactionRequest(emoji: emoji))
        let data = try await fetchProtectedData(for: request, logLabel: "toggle reaction on message \(messageId)")
        return try JSONDecoder().decode([MessageReactionSummary].self, from: data)
    }

    /// Toggles the authenticated user's emoji reaction on one group-chat message.
    func toggleGroupChatMessageReaction(chatId: String, messageId: String, emoji: String) async throws -> [MessageReactionSummary] {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("messages")
            .appendingPathComponent(messageId)
            .appendingPathComponent("reactions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MessageReactionRequest(emoji: emoji))
        let data = try await fetchProtectedData(for: request, logLabel: "toggle reaction on group chat \(chatId) message \(messageId)")
        return try JSONDecoder().decode([MessageReactionSummary].self, from: data)
    }

    func createGroupChat(name: String, memberIDs: [String]) async throws -> GroupChat {
        let url = baseURL.appendingPathComponent("group-chats")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateGroupChatRequest(name: name, memberIDs: memberIDs))
        let data = try await fetchProtectedData(for: request, logLabel: "create group chat")
        return try JSONDecoder().decode(GroupChat.self, from: data)
    }

    func deleteGroupChat(id: String) async throws {
        let url = baseURL.appendingPathComponent("group-chats").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "delete group chat \(id)")
    }

    func updateGroupChatPhoto(chatID: String, file: MessageAttachmentUpload) async throws {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("photo")
        let request = Self.multipartRequest(url: url, method: "PUT", fields: [:], file: file)
        _ = try await fetchProtectedData(for: request, logLabel: "update group chat \(chatID) photo")
    }

    func fetchGroupChatMembers(chatID: String) async throws -> [DirectoryMember] {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("members")
        let data = try await fetchProtectedData(from: url, logLabel: "group chat \(chatID) members")
        return try DirectoryMembersResponse.decodeMembers(from: data)
    }

    func addGroupChatMember(chatID: String, userID: String) async throws {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("members")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_id": userID])
        _ = try await fetchProtectedData(for: request, logLabel: "add member to group chat \(chatID)")
    }

    func removeGroupChatMember(chatID: String, userID: String) async throws {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatID)
            .appendingPathComponent("members")
            .appendingPathComponent(userID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "remove member from group chat \(chatID)")
    }

    func issueCalendarFeed() async throws -> CalendarFeedSubscription {
        let url = baseURL.appendingPathComponent("calendar/feed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let data = try await fetchProtectedData(for: request, logLabel: "issue calendar feed")
        let response = try JSONDecoder().decode(CalendarFeedTokenResponse.self, from: data)
        let feedURL = baseURL
            .appendingPathComponent("calendar/feed")
            .appendingPathComponent("\(response.token).ics")
        return CalendarFeedSubscription(token: response.token, url: feedURL)
    }

    func revokeCalendarFeed() async throws {
        let url = baseURL.appendingPathComponent("calendar/feed")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "revoke calendar feed")
    }

    /// Fetches polls visible to the authenticated member.
    func fetchPolls() async throws -> [Poll] {
        let url = baseURL.appendingPathComponent("polls")
        let data = try await fetchProtectedData(from: url, logLabel: "polls")

        do {
            return try Poll.decodePolls(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Polls decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches the announcement board that matches the authenticated account.
    /// Rush announcements live in their own API table and endpoint, matching
    /// the separate feed displayed by the website.
    func fetchAnnouncements(for group: MemberGroup?) async throws -> [Announcement] {
        let isRush = group == .rush
        let endpoint = isRush ? "rush-announcements" : "announcements"
        let url = baseURL.appendingPathComponent(endpoint)
        let data = try await fetchProtectedData(from: url, logLabel: endpoint)

        do {
            return try Announcement.decodeAnnouncements(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Announcements decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches a protected announcement thumbnail from the matching board.
    func fetchAnnouncementMediaThumbnail(
        mediaID: String,
        isRushAnnouncement: Bool
    ) async throws -> Data {
        let endpoint = isRushAnnouncement ? "rush-announcements" : "announcements"
        let url = baseURL
            .appendingPathComponent(endpoint)
            .appendingPathComponent("media")
            .appendingPathComponent(mediaID)
            .appending(queryItems: [URLQueryItem(name: "size", value: "thumbnail")])
        return try await fetchProtectedData(from: url, logLabel: "\(endpoint) media \(mediaID)")
    }

    /// Fetches meetings organized by or inviting the authenticated member.
    func fetchMeetings() async throws -> [Meeting] {
        let url = baseURL.appendingPathComponent("meetings")
        let data = try await fetchProtectedData(from: url, logLabel: "meetings")

        do {
            return try Meeting.decodeMeetings(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Meetings decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Creates a private meeting invitation for the selected members.
    func createMeeting(_ meeting: CreateMeetingRequest) async throws {
        let url = baseURL.appendingPathComponent("meetings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(meeting)
        _ = try await fetchProtectedData(for: request, logLabel: "create meeting")
    }

    /// Fetches interview schedules with slots still open to the current member.
    func fetchAvailableInterviews() async throws -> [InterviewSchedule] {
        let url = baseURL
            .appendingPathComponent("interviews")
            .appendingPathComponent("available")
        let data = try await fetchProtectedData(from: url, logLabel: "available interviews")
        return try InterviewSchedule.decodeSchedules(from: data)
    }

    func bookInterview(slotID: String) async throws {
        let url = baseURL
            .appendingPathComponent("interviews")
            .appendingPathComponent("slots")
            .appendingPathComponent(slotID)
            .appendingPathComponent("book")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await fetchProtectedData(for: request, logLabel: "book interview")
    }

    func cancelInterview(bookingID: String) async throws {
        let url = baseURL
            .appendingPathComponent("interviews")
            .appendingPathComponent("bookings")
            .appendingPathComponent(bookingID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "cancel interview")
    }

    /// Sets or changes the caller's RSVP on a meeting invitation.
    func respond(to meetingID: String, response: MeetingResponse) async throws {
        let url = baseURL
            .appendingPathComponent("meetings")
            .appendingPathComponent(meetingID)
            .appendingPathComponent("respond")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["response": response.rawValue])
        _ = try await fetchProtectedData(for: request, logLabel: "respond to meeting \(meetingID)")
    }

    /// Replaces the caller's vote selection for one open poll.
    func vote(on pollID: String, optionIDs: [String]) async throws {
        let url = baseURL
            .appendingPathComponent("polls")
            .appendingPathComponent(pollID)
            .appendingPathComponent("vote")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PollVoteRequest(optionIDs: optionIDs))
        _ = try await fetchProtectedData(for: request, logLabel: "vote on poll \(pollID)")
    }

    /// Sends a group chat message via protected `POST /group-chats/:id/messages`.
    func sendGroupChatMessage(chatId: String, body: String) async throws -> KTPMessage {
        try await sendGroupChatMessage(chatId: chatId, body: body, attachment: nil)
    }

    func sendGroupChatMessage(
        chatId: String,
        body: String?,
        attachment: MessageAttachmentUpload?,
        replyToMessageID: String? = nil
    ) async throws -> KTPMessage {
        let url = baseURL
            .appendingPathComponent("group-chats")
            .appendingPathComponent(chatId)
            .appendingPathComponent("messages")
        let request = Self.multipartRequest(
            url: url,
            method: "POST",
            fields: [
                "body": body,
                "reply_to_id": replyToMessageID,
            ],
            file: attachment
        )

        let data = try await fetchProtectedData(for: request, logLabel: "send group chat \(chatId) message")
        do {
            if let message = try? JSONDecoder().decode(KTPMessage.self, from: data) {
                return message
            }

            return try ConversationMessagesResponse.decodeMessages(from: data).last ?? {
                throw KTPAPIError.emptyResponse
            }()
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Send group chat message decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Submits a member, message, group-message, or photo report via protected `POST /reports`.
    func submitReport(_ report: SubmitReportRequest) async throws {
        let url = baseURL.appendingPathComponent("reports")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        _ = try await fetchProtectedData(for: request, logLabel: "submit \(report.contentType.rawValue) report")
    }

    /// Fetches moderation reports through eboard-only `GET /reports`.
    func fetchReports(status: ReportStatus? = nil) async throws -> [ContentReport] {
        var components = URLComponents(url: baseURL.appendingPathComponent("reports"), resolvingAgainstBaseURL: false)
        if let status {
            components?.queryItems = [URLQueryItem(name: "status", value: status.rawValue)]
        }
        guard let url = components?.url else { throw URLError(.badURL) }

        let data = try await fetchProtectedData(from: url, logLabel: "moderation reports")
        do {
            return try ContentReport.decodeReports(from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Reports decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Updates a moderation decision through eboard-only `PUT /reports/:id/status`.
    func updateReportStatus(
        reportID: String,
        status: ReportStatus,
        moderatorResponse: String?
    ) async throws {
        let url = baseURL
            .appendingPathComponent("reports")
            .appendingPathComponent(reportID)
            .appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            UpdateReportStatusRequest(status: status, moderatorResponse: moderatorResponse)
        )
        _ = try await fetchProtectedData(for: request, logLabel: "update report \(reportID) status")
    }

    /// Fetches a member profile picture from protected `GET /users/:id/profile-picture/media`.
    func fetchProfilePictureData(for userId: String) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("users")
            .appendingPathComponent(userId)
            .appendingPathComponent("profile-picture/media")
        return try await fetchProtectedData(from: url, logLabel: "profile picture for \(userId)")
    }

    /// Fetches visible homepage highlights from authenticated `GET /ios-homepage-photos`.
    func fetchHomepageSlides() async throws -> [HomepageSlide] {
        let url = baseURL.appendingPathComponent("ios-homepage-photos")
        let data = try await fetchProtectedData(from: url, logLabel: "homepage slides")

        do {
            return try JSONDecoder().decode(HomepageSlidesResponse.self, from: data).slides
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Homepage slides decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetches the protected image for a homepage highlight from `/:id/media`.
    func fetchHomepageSlideMediaData(for slide: HomepageSlide) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("ios-homepage-photos")
            .appendingPathComponent(slide.id)
            .appendingPathComponent("media")
        return try await fetchProtectedData(from: url, logLabel: "homepage slide media for \(slide.id)")
    }

    /// Registers the current iOS device with protected `POST /notifications/devices`.
    func registerNotificationDevice(_ device: NotificationDeviceRegistration) async throws {
        let url = baseURL.appendingPathComponent("notifications/devices")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(device)
        _ = try await fetchProtectedData(for: request, logLabel: "register push device")
    }

    /// Removes this device's APNs registration through `DELETE /notifications/devices/:token`.
    func unregisterNotificationDevice(token: String) async throws {
        let url = baseURL
            .appendingPathComponent("notifications/devices")
            .appendingPathComponent(token)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "unregister push device")
    }

    func fetchNotificationPreferences() async throws -> NotificationPreferences {
        let url = baseURL.appendingPathComponent("notifications/preferences")
        let data = try await fetchProtectedData(from: url, logLabel: "notification preferences")
        do {
            return try JSONDecoder().decode(NotificationPreferences.self, from: data)
        } catch {
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    func updateNotificationPreferences(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        let url = baseURL.appendingPathComponent("notifications/preferences")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(preferences)
        let data = try await fetchProtectedData(for: request, logLabel: "update notification preferences")
        do {
            return try JSONDecoder().decode(NotificationPreferences.self, from: data)
        } catch {
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    private static func multipartRequest(
        url: URL,
        method: String,
        fields: [String: String?],
        file: MessageAttachmentUpload?
    ) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        let lineBreak = "\r\n"
        var body = Data()

        for (name, value) in fields {
            guard let value, !value.isEmpty else { continue }
            body.appendUTF8("--\(boundary)\(lineBreak)")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.appendUTF8("\(value)\(lineBreak)")
        }

        if let file {
            body.appendUTF8("--\(boundary)\(lineBreak)")
            body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.fileName)\"\(lineBreak)")
            body.appendUTF8("Content-Type: \(file.mimeType)\(lineBreak)\(lineBreak)")
            body.append(file.data)
            body.appendUTF8(lineBreak)
        }

        body.appendUTF8("--\(boundary)--\(lineBreak)")

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func fetchProtectedData(from url: URL, logLabel: String) async throws -> Data {
        try await fetchProtectedData(for: URLRequest(url: url), logLabel: logLabel)
    }

    private func fetchConversationSync(
        from url: URL,
        after cursor: String?,
        eTag: String?,
        logLabel: String
    ) async throws -> ConversationSyncResponse {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let cursor, !cursor.isEmpty {
            components?.queryItems = [URLQueryItem(name: "after", value: cursor)]
        }

        guard let syncURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: syncURL)
        if let eTag, !eTag.isEmpty {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }

        let protectedResponse = try await fetchProtectedResponse(
            for: request,
            logLabel: logLabel,
            allowsNotModified: true
        )
        if protectedResponse.response.statusCode == 304 {
            return .notModified
        }

        do {
            return .updated(
                page: try ConversationMessagesResponse.decodePage(from: protectedResponse.data),
                eTag: protectedResponse.response.value(forHTTPHeaderField: "ETag")
            )
        } catch {
            let responseBody = String(data: protectedResponse.data, encoding: .utf8) ?? "Unable to read response body"
            AuthDebugLog.log("Conversation sync decode failed: \(error.localizedDescription). Body=\(responseBody)")
            throw KTPAPIError.decodeFailed(error.localizedDescription)
        }
    }

    private func fetchProtectedData(for request: URLRequest, logLabel: String) async throws -> Data {
        try await fetchProtectedResponse(for: request, logLabel: logLabel).data
    }

    private func fetchProtectedResponse(
        for request: URLRequest,
        logLabel: String,
        allowsNotModified: Bool = false
    ) async throws -> ProtectedAPIResponse {
        guard let accessToken = try await accessTokenProvider(), !accessToken.isEmpty else {
            throw KTPAPIError.missingAccessToken
        }

        AuthDebugLog.log("Fetching \(logLabel) from \(request.url?.absoluteString ?? "unknown URL")")
        var authenticatedRequest = request
        authenticatedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: authenticatedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard 200..<300 ~= httpResponse.statusCode || (allowsNotModified && httpResponse.statusCode == 304) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            AuthDebugLog.log("KTP API failed status=\(httpResponse.statusCode), body=\(responseBody)")
            throw KTPAPIError.badStatusCode(httpResponse.statusCode, responseBody)
        }

        if httpResponse.statusCode == 304 {
            AuthDebugLog.log("KTP API request not modified for \(logLabel).")
        } else {
            AuthDebugLog.log("KTP API request succeeded for \(logLabel).")
        }
        return ProtectedAPIResponse(data: data, response: httpResponse)
    }
}

struct CalendarFeedSubscription: Equatable {
    let token: String
    let url: URL
}

private struct CalendarFeedTokenResponse: Decodable {
    let token: String
}

private struct CreateGroupChatRequest: Encodable {
    let name: String
    let memberIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case memberIDs = "member_ids"
    }
}

private enum UnreadCountResponse {
    static func decode(from data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        if let count = object as? Int { return count }
        if let value = object as? [String: Any] {
            if let count = value["count"] as? Int { return count }
            if let count = value["unread_count"] as? Int { return count }
            if let count = value["count"] as? String, let integer = Int(count) { return integer }
            if let count = value["unread_count"] as? String, let integer = Int(count) { return integer }
        }
        throw KTPAPIError.decodeFailed("Expected an unread count response.")
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}

private struct SendMessageRequest: Encodable {
    let recipientId: String
    let body: String

    init(recipientId: String, content: String) {
        self.recipientId = recipientId
        self.body = content
    }

    enum CodingKeys: String, CodingKey {
        case recipientId = "recipient_id"
        case body
    }
}

private struct MessageMuteUpdateRequest: Encodable {
    let muted: Bool
}

private struct MessageMuteUpdateResponse: Decodable {
    let muted: Bool
}

private struct SentMessageResponse: Decodable {
    let message: KTPMessage

    enum CodingKeys: String, CodingKey {
        case message
        case data
        case result
    }

    static func decodeMessage(from data: Data) throws -> KTPMessage {
        let decoder = JSONDecoder()
        if let directMessage = try? decoder.decode(KTPMessage.self, from: data),
           hasContent(directMessage) {
            return directMessage
        }

        if let messages = try? ConversationMessagesResponse.decodeMessages(from: data),
           let message = messages.last(where: hasContent) {
            return message
        }

        let message = try decoder.decode(SentMessageResponse.self, from: data).message
        guard hasContent(message) else {
            throw KTPAPIError.emptyResponse
        }
        return message
    }

    nonisolated private static func hasContent(_ message: KTPMessage) -> Bool {
        !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || message.attachment != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try container.decodeIfPresent(KTPMessage.self, forKey: .message) {
            self.message = message
        } else if let message = try container.decodeIfPresent(KTPMessage.self, forKey: .data) {
            self.message = message
        } else {
            self.message = try container.decode(KTPMessage.self, forKey: .result)
        }
    }
}

private struct MessageReactionRequest: Encodable {
    let emoji: String
}

private struct PollVoteRequest: Encodable {
    let optionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case optionIDs = "option_ids"
    }
}

private struct SendGroupChatMessageRequest: Encodable {
    let body: String
}

private enum BlockedUsersResponse {
    static func decodeIDs(from data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data)
        let values: [Any]

        if let directValues = object as? [Any] {
            values = directValues
        } else if let envelope = object as? [String: Any] {
            values = (envelope["blocked_users"] as? [Any])
                ?? (envelope["blocked_user_ids"] as? [Any])
                ?? (envelope["users"] as? [Any])
                ?? (envelope["data"] as? [Any])
                ?? []
        } else {
            values = []
        }

        var ids = Set<String>()
        for value in values {
            if let id = userID(from: value) {
                ids.insert(id)
            }
        }
        return ids
    }

    private static func userID(from value: Any) -> String? {
        if let value = value as? String, !value.isEmpty {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        guard let object = value as? [String: Any] else { return nil }

        for key in ["blocked_user_id", "user_id", "id", "authentik_id"] {
            if let id = object[key] as? String, !id.isEmpty {
                return id
            }
            if let id = object[key] as? NSNumber {
                return id.stringValue
            }
        }
        return nil
    }
}

private struct DirectoryMembersResponse: Decodable {
    let members: [DirectoryMember]

    enum CodingKeys: String, CodingKey {
        case members
        case data
        case users
    }

    static func decodeMembers(from data: Data) throws -> [DirectoryMember] {
        let decoder = JSONDecoder()
        if let directMembers = try? decoder.decode([DirectoryMember].self, from: data) {
            return directMembers
        }

        let wrappedResponse = try decoder.decode(DirectoryMembersResponse.self, from: data)
        return wrappedResponse.members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let members = try container.decodeIfPresent([DirectoryMember].self, forKey: .members) {
            self.members = members
        } else if let data = try container.decodeIfPresent([DirectoryMember].self, forKey: .data) {
            self.members = data
        } else {
            self.members = try container.decode([DirectoryMember].self, forKey: .users)
        }
    }
}
