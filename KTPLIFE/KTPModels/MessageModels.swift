import Foundation

struct MessageConversation: Identifiable, Hashable, Decodable {
    let id: String
    let userId: String
    let displayName: String
    let preview: String
    let lastMessageDate: Date?
    let unreadCount: Int
    let profileImageURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case authentikId = "authentik_id"
        case conversationId = "conversation_id"
        case userId = "user_id"
        case otherUserId = "other_user_id"
        case memberId = "member_id"
        case recipientId = "recipient_id"
        case senderId = "sender_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case preferredName = "preferred_name"
        case name
        case displayName = "display_name"
        case fullName = "full_name"
        case username
        case profileImageURL = "profile_image_url"
        case profilePictureURL = "profile_picture_url"
        case avatarURL = "avatar_url"
        case photoURL = "photo_url"
        case imageURL = "image_url"
        case lastMessage = "last_message"
        case latestMessage = "latest_message"
        case preview
        case content
        case body
        case text
        case message
        case lastMessageAt = "last_message_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case unreadCount = "unread_count"
        case unread
        case isUnread = "is_unread"
    }

    nonisolated init(
        id: String,
        userId: String,
        displayName: String,
        preview: String,
        lastMessageDate: Date?,
        unreadCount: Int,
        profileImageURL: URL? = nil
    ) {
        self.id = id
        self.userId = userId
        self.displayName = displayName
        self.preview = preview
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.profileImageURL = profileImageURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let resolvedUserId = try container.decodeFirstPresentString(
            for: [.userId, .otherUserId, .memberId, .authentikId, .recipientId, .senderId],
            fallback: ""
        )
        userId = resolvedUserId
        id = try container.decodeFirstPresentString(
            for: [.id, .conversationId, .userId, .otherUserId, .memberId, .authentikId],
            fallback: resolvedUserId
        )
        if let directName = try container.decodeFirstPresentStringIfPresent(
            for: [.name, .displayName, .fullName, .username],
        ) {
            displayName = directName
        } else {
            let firstName = try container.decodeFirstPresentStringIfPresent(for: [.preferredName, .firstName])
            let lastName = try container.decodeFirstPresentStringIfPresent(for: [.lastName])
            let composedName = [firstName, lastName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            displayName = composedName.isEmpty ? "Member" : composedName
        }
        profileImageURL = try container.decodeFirstPresentURLIfPresent(
            for: [.profileImageURL, .profilePictureURL, .avatarURL, .photoURL, .imageURL]
        )

        if let nestedMessage = try container.decodeIfPresent(KTPMessage.self, forKey: .lastMessage) {
            preview = nestedMessage.inboxPreview
            lastMessageDate = nestedMessage.createdAt
        } else if let nestedMessage = try container.decodeIfPresent(KTPMessage.self, forKey: .latestMessage) {
            preview = nestedMessage.inboxPreview
            lastMessageDate = nestedMessage.createdAt
        } else {
            preview = try container.decodeFirstPresentString(
                for: [.preview, .content, .body, .text, .message],
                fallback: "No messages yet."
            )
            lastMessageDate = try container.decodeFirstPresentDateIfPresent(
                for: [.lastMessageAt, .updatedAt, .createdAt]
            )
        }

        if let count = try container.decodeIfPresent(Int.self, forKey: .unreadCount) {
            unreadCount = count
        } else if let countString = try container.decodeIfPresent(String.self, forKey: .unreadCount),
                  let count = Int(countString) {
            unreadCount = count
        } else {
            let unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
            let isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
            unreadCount = unread || isUnread ? 1 : 0
        }
    }
}

struct GroupChat: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let preview: String
    let lastMessageDate: Date?
    let unreadCount: Int
    let photoAssetID: String?
    let createdBy: String?
    let isMemberCreated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastMessage = "last_message"
        case preview
        case body
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
        case unreadCount = "unread_count"
        case photoAssetID = "photo_asset_id"
        case createdBy = "created_by"
        case isMemberCreated = "is_member_created"
    }

    nonisolated init(
        id: String,
        name: String,
        preview: String,
        lastMessageDate: Date?,
        unreadCount: Int,
        photoAssetID: String? = nil,
        createdBy: String? = nil,
        isMemberCreated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.photoAssetID = photoAssetID
        self.createdBy = createdBy
        self.isMemberCreated = isMemberCreated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFirstPresentString(for: [.id], fallback: UUID().uuidString)
        name = try container.decodeFirstPresentString(for: [.name], fallback: "Group Chat")

        if let lastMessage = try container.decodeIfPresent(KTPMessage.self, forKey: .lastMessage) {
            preview = lastMessage.inboxPreview
            lastMessageDate = lastMessage.createdAt
        } else {
            preview = try container.decodeFirstPresentString(for: [.preview, .body], fallback: "No messages yet.")
            lastMessageDate = try container.decodeFirstPresentDateIfPresent(for: [.lastMessageAt, .createdAt])
        }

        if let count = try container.decodeIfPresent(Int.self, forKey: .unreadCount) {
            unreadCount = count
        } else if let countString = try container.decodeIfPresent(String.self, forKey: .unreadCount),
                  let count = Int(countString) {
            unreadCount = count
        } else {
            unreadCount = 0
        }

        photoAssetID = try container.decodeFirstPresentStringIfPresent(for: [.photoAssetID])
        createdBy = try container.decodeFirstPresentStringIfPresent(for: [.createdBy])
        isMemberCreated = try container.decodeIfPresent(Bool.self, forKey: .isMemberCreated) ?? false
    }
}

enum MessageThread: Identifiable, Hashable {
    case direct(MessageConversation)
    case group(GroupChat)

    var id: String {
        switch self {
        case .direct(let conversation):
            return "direct-\(conversation.userId)"
        case .group(let chat):
            return "group-\(chat.id)"
        }
    }

    var displayName: String {
        switch self {
        case .direct(let conversation):
            return conversation.displayName
        case .group(let chat):
            return chat.name
        }
    }

    var preview: String {
        switch self {
        case .direct(let conversation):
            return conversation.preview
        case .group(let chat):
            return chat.preview
        }
    }

    var lastMessageDate: Date? {
        switch self {
        case .direct(let conversation):
            return conversation.lastMessageDate
        case .group(let chat):
            return chat.lastMessageDate
        }
    }

    var unreadCount: Int {
        switch self {
        case .direct(let conversation):
            return conversation.unreadCount
        case .group(let chat):
            return chat.unreadCount
        }
    }

    var profileImageURL: URL? {
        switch self {
        case .direct(let conversation):
            return conversation.profileImageURL
        case .group:
            return nil
        }
    }

    var isGroup: Bool {
        if case .group = self {
            return true
        }
        return false
    }

    var groupChatID: String? {
        guard case .group(let chat) = self else { return nil }
        return chat.id
    }
}

struct KTPMessage: Identifiable, Hashable, Decodable {
    let id: String
    let senderId: String?
    let recipientId: String?
    let senderDisplayName: String?
    let senderProfileImageURL: URL?
    let body: String
    let attachment: MessageAttachment?
    let createdAt: Date?
    let isRead: Bool
    /// Incremental-sync responses can represent deletions as message tombstones.
    /// The conversation store removes those records instead of rendering them.
    let isDeleted: Bool
    /// When present, this message is an inline reply to another message in the
    /// same conversation. The API may provide either a full reply preview or
    /// only its message identifier.
    let replyTo: MessageReplyReference?
    let reactions: [MessageReactionSummary]

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case senderId = "sender_id"
        case fromUserId = "from_user_id"
        case senderName = "sender_name"
        case senderDisplayName = "sender_display_name"
        case senderFirstName = "sender_first_name"
        case senderLastName = "sender_last_name"
        case senderProfileImageURL = "sender_profile_image_url"
        case senderProfilePictureURL = "sender_profile_picture_url"
        case senderAvatarURL = "sender_avatar_url"
        case recipientId = "recipient_id"
        case toUserId = "to_user_id"
        case content
        case body
        case text
        case message
        case attachment
        case attachmentKind = "attachment_kind"
        case attachmentFilename = "attachment_filename"
        case attachmentMIMEType = "attachment_mime_type"
        case attachmentSize = "attachment_size"
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case timestamp
        case isRead = "is_read"
        case read
        case readAt = "read_at"
        case isDeleted = "is_deleted"
        case deleted
        case deletedAt = "deleted_at"
        case replyTo = "reply_to"
        case camelReplyTo = "replyTo"
        case replyToMessage = "reply_to_message"
        case replyToMessageID = "reply_to_message_id"
        case replyToID = "reply_to_id"
        case parentMessageID = "parent_message_id"
        case reactions
    }

    nonisolated init(
        id: String,
        senderId: String?,
        recipientId: String?,
        senderDisplayName: String? = nil,
        senderProfileImageURL: URL? = nil,
        body: String,
        attachment: MessageAttachment? = nil,
        createdAt: Date?,
        isRead: Bool,
        isDeleted: Bool = false,
        replyTo: MessageReplyReference? = nil,
        reactions: [MessageReactionSummary] = []
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.senderDisplayName = senderDisplayName
        self.senderProfileImageURL = senderProfileImageURL
        self.body = body
        self.attachment = attachment
        self.createdAt = createdAt
        self.isRead = isRead
        self.isDeleted = isDeleted
        self.replyTo = replyTo
        self.reactions = reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFirstPresentString(for: [.id, .messageId], fallback: UUID().uuidString)
        senderId = try container.decodeFirstPresentStringIfPresent(for: [.senderId, .fromUserId])
        recipientId = try container.decodeFirstPresentStringIfPresent(for: [.recipientId, .toUserId])
        if let directName = try container.decodeFirstPresentStringIfPresent(for: [.senderName, .senderDisplayName]) {
            senderDisplayName = directName
        } else {
            let firstName = try container.decodeFirstPresentStringIfPresent(for: [.senderFirstName])
            let lastName = try container.decodeFirstPresentStringIfPresent(for: [.senderLastName])
            let name = [firstName, lastName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            senderDisplayName = name.isEmpty ? nil : name
        }
        senderProfileImageURL = try container.decodeFirstPresentURLIfPresent(
            for: [.senderProfileImageURL, .senderProfilePictureURL, .senderAvatarURL]
        )
        body = try container.decodeFirstPresentString(for: [.content, .body, .text, .message], fallback: "")
        if let nestedAttachment = try container.decodeIfPresent(MessageAttachment.self, forKey: .attachment) {
            attachment = nestedAttachment
        } else if let kind = try container.decodeIfPresent(String.self, forKey: .attachmentKind) {
            attachment = MessageAttachment(
                kind: kind,
                filename: try container.decodeIfPresent(String.self, forKey: .attachmentFilename),
                mimeType: try container.decodeIfPresent(String.self, forKey: .attachmentMIMEType),
                size: try container.decodeFlexibleIntIfPresent(forKey: .attachmentSize)
            )
        } else {
            attachment = nil
        }
        createdAt = try container.decodeFirstPresentDateIfPresent(for: [.createdAt, .sentAt, .timestamp])
        let directReadValue = try container.decodeIfPresent(Bool.self, forKey: .isRead)
        let fallbackReadValue = try container.decodeIfPresent(Bool.self, forKey: .read)
        let readAt = try container.decodeIfPresent(String.self, forKey: .readAt)
        isRead = directReadValue ?? fallbackReadValue ?? (readAt != nil)
        let directDeletedValue = try container.decodeIfPresent(Bool.self, forKey: .isDeleted)
        let fallbackDeletedValue = try container.decodeIfPresent(Bool.self, forKey: .deleted)
        let deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
        isDeleted = directDeletedValue ?? fallbackDeletedValue ?? (deletedAt != nil)
        var decodedReply: MessageReplyReference?
        decodedReply = try? container.decodeIfPresent(MessageReplyReference.self, forKey: .replyTo)
        if decodedReply == nil {
            decodedReply = try? container.decodeIfPresent(MessageReplyReference.self, forKey: .camelReplyTo)
        }
        if decodedReply == nil {
            decodedReply = try? container.decodeIfPresent(MessageReplyReference.self, forKey: .replyToMessage)
        }
        if decodedReply == nil {
            let replyID = try? container.decodeFirstPresentStringIfPresent(
                for: [.replyToMessageID, .replyToID, .parentMessageID, .replyTo, .camelReplyTo]
            )
            if let replyID {
                decodedReply = MessageReplyReference(id: replyID)
            }
        }
        replyTo = decodedReply
        reactions = MessageReactionSummary.decode(from: container, forKey: .reactions)
    }
}

extension KTPMessage {
    /// Inbox rows should identify media even when an attachment has no text body.
    var inboxPreview: String {
        guard let attachment else { return body }

        let mimeType = attachment.mimeType?.lowercased() ?? ""
        let filename = attachment.filename?.lowercased() ?? ""
        if mimeType == "image/gif" || filename.hasSuffix(".gif") {
            return "GIF"
        }

        if mimeType.hasPrefix("image/") || attachment.kind.lowercased() == "image" {
            return "Image"
        }

        return body
    }
}

struct MessageAttachment: Hashable, Codable {
    let kind: String
    let filename: String?
    let mimeType: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case filename
        case mimeType = "mime_type"
        case size
    }
}

struct MessageAttachmentUpload {
    let data: Data
    let fileName: String
    let mimeType: String
}

/// A lightweight representation of a message that is being replied to. It is
/// deliberately independent from `KTPMessage` so nested API responses cannot
/// recurse indefinitely and locally queued replies can still render a preview.
struct MessageReplyReference: Hashable, Codable {
    let id: String
    let senderID: String?
    let senderDisplayName: String?
    let body: String?
    let attachment: MessageAttachment?

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case senderID = "sender_id"
        case fromUserID = "from_user_id"
        case senderName = "sender_name"
        case senderDisplayName = "sender_display_name"
        case name
        case content
        case body
        case text
        case message
        case attachment
    }

    nonisolated init(
        id: String,
        senderID: String? = nil,
        senderDisplayName: String? = nil,
        body: String? = nil,
        attachment: MessageAttachment? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.attachment = attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFirstPresentString(for: [.id, .messageId], fallback: UUID().uuidString)
        senderID = try container.decodeFirstPresentStringIfPresent(for: [.senderID, .fromUserID])
        senderDisplayName = try container.decodeFirstPresentStringIfPresent(
            for: [.senderName, .senderDisplayName, .name]
        )
        body = try container.decodeFirstPresentStringIfPresent(for: [.content, .body, .text, .message])
        attachment = try container.decodeIfPresent(MessageAttachment.self, forKey: .attachment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(senderID, forKey: .senderID)
        try container.encodeIfPresent(senderDisplayName, forKey: .senderDisplayName)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }

    var preview: String {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        if attachment != nil { return "Attachment" }
        return "Message"
    }
}

/// The member identity supplied with an emoji reaction. Older API responses
/// only contain counts, so `displayName` remains optional and the UI degrades
/// cleanly to the count in that case.
struct MessageReactionUser: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case authentikID = "authentik_id"
        case memberID = "member_id"
        case name
        case displayName = "display_name"
        case senderName = "sender_name"
        case fullName = "full_name"
        case preferredName = "preferred_name"
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }

    nonisolated init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        let lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        let composedName = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let resolvedName = try container.decodeFirstPresentStringIfPresent(
            for: [.displayName, .name, .senderName, .fullName, .preferredName, .username]
        ) ?? (composedName.isEmpty ? nil : composedName)
        id = try container.decodeFirstPresentString(
            for: [.id, .userID, .authentikID, .memberID],
            fallback: resolvedName ?? UUID().uuidString
        )
        displayName = resolvedName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }
}

struct MessageReactionSummary: Identifiable, Hashable, Decodable {
    let emoji: String
    let count: Int
    let reactedByCurrentUser: Bool
    let users: [MessageReactionUser]

    var id: String { emoji }

    enum CodingKeys: String, CodingKey {
        case emoji
        case reaction
        case count
        case total
        case reactedByCurrentUser = "reacted_by_current_user"
        case userReacted = "user_reacted"
        case reacted
        case users
        case reactionUsers = "reaction_users"
        case reactedByUsers = "reacted_by_users"
        case reactors
        case members
        case user
        case reactor
        case reactedBy = "reacted_by"
        case userID = "user_id"
        case userName = "user_name"
        case displayName = "display_name"
    }

    nonisolated init(
        emoji: String,
        count: Int,
        reactedByCurrentUser: Bool,
        users: [MessageReactionUser] = []
    ) {
        self.emoji = emoji
        self.count = count
        self.reactedByCurrentUser = reactedByCurrentUser
        self.users = users
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? container.decode(String.self, forKey: .reaction)
        let decodedUsers = Self.decodeUsers(from: container)
        let directCount = try container.decodeIfPresent(Int.self, forKey: .count)
            ?? container.decodeIfPresent(Int.self, forKey: .total)
        count = directCount ?? max(1, decodedUsers.count)
        reactedByCurrentUser = try container.decodeIfPresent(Bool.self, forKey: .reactedByCurrentUser)
            ?? container.decodeIfPresent(Bool.self, forKey: .userReacted)
            ?? container.decodeIfPresent(Bool.self, forKey: .reacted)
            ?? false
        users = Self.uniqueUsers(decodedUsers)
    }

    fileprivate static func decode(
        from container: KeyedDecodingContainer<KTPMessage.CodingKeys>,
        forKey key: KTPMessage.CodingKeys
    ) -> [MessageReactionSummary] {
        if let summaries = try? container.decode([MessageReactionSummary].self, forKey: key) {
            return normalize(summaries)
        }

        if let counts = try? container.decode([String: Int].self, forKey: key) {
            return counts
                .map { MessageReactionSummary(emoji: $0.key, count: $0.value, reactedByCurrentUser: false) }
                .sorted { $0.emoji < $1.emoji }
        }

        return []
    }

    private static func normalize(_ reactions: [MessageReactionSummary]) -> [MessageReactionSummary] {
        var values: [String: MessageReactionSummary] = [:]

        for reaction in reactions {
            let existing = values[reaction.emoji]
            values[reaction.emoji] = MessageReactionSummary(
                emoji: reaction.emoji,
                count: (existing?.count ?? 0) + reaction.count,
                reactedByCurrentUser: (existing?.reactedByCurrentUser ?? false) || reaction.reactedByCurrentUser,
                users: uniqueUsers((existing?.users ?? []) + reaction.users)
            )
        }

        return values.values.sorted { $0.emoji < $1.emoji }
    }

    private static func decodeUsers(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [MessageReactionUser] {
        var decodedUsers: [MessageReactionUser] = []

        for key in [CodingKeys.users, .reactionUsers, .reactedByUsers, .reactors, .members] {
            if let users = try? container.decode([MessageReactionUser].self, forKey: key) {
                decodedUsers.append(contentsOf: users)
            } else if let names = try? container.decode([String].self, forKey: key) {
                decodedUsers.append(contentsOf: names.map { MessageReactionUser(id: $0, displayName: $0) })
            }
        }

        for key in [CodingKeys.user, .reactor, .reactedBy] {
            if let user = try? container.decode(MessageReactionUser.self, forKey: key) {
                decodedUsers.append(user)
            } else if let name = try? container.decode(String.self, forKey: key), !name.isEmpty {
                decodedUsers.append(MessageReactionUser(id: name, displayName: name))
            }
        }

        let directUserID = try? container.decodeFirstPresentStringIfPresent(for: [.userID])
        if let directUserID, !directUserID.isEmpty {
            let directName = try? container.decodeFirstPresentStringIfPresent(for: [.userName, .displayName])
            decodedUsers.append(MessageReactionUser(id: directUserID, displayName: directName))
        }

        return decodedUsers
    }

    private static func uniqueUsers(_ users: [MessageReactionUser]) -> [MessageReactionUser] {
        var seen = Set<String>()
        return users.filter { seen.insert($0.id).inserted }
    }
}

struct GroupChatsResponse: Decodable {
    let chats: [GroupChat]

    enum CodingKeys: String, CodingKey {
        case chats
        case data
        case groupChats = "group_chats"
    }

    static func decodeChats(from data: Data) throws -> [GroupChat] {
        let decoder = JSONDecoder()
        if let directChats = try? decoder.decode([GroupChat].self, from: data) {
            return directChats
        }

        return try decoder.decode(GroupChatsResponse.self, from: data).chats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let chats = try container.decodeIfPresent([GroupChat].self, forKey: .chats) {
            self.chats = chats
        } else if let data = try container.decodeIfPresent([GroupChat].self, forKey: .data) {
            self.chats = data
        } else {
            self.chats = try container.decode([GroupChat].self, forKey: .groupChats)
        }
    }
}

struct MessageConversationsResponse: Decodable {
    let conversations: [MessageConversation]

    enum CodingKeys: String, CodingKey {
        case conversations
        case data
        case threads
        case messages
    }

    static func decodeConversations(from data: Data) throws -> [MessageConversation] {
        let decoder = JSONDecoder()
        if let directConversations = try? decoder.decode([MessageConversation].self, from: data) {
            return directConversations
        }

        return try decoder.decode(MessageConversationsResponse.self, from: data).conversations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let conversations = try container.decodeIfPresent([MessageConversation].self, forKey: .conversations) {
            self.conversations = conversations
        } else if let data = try container.decodeIfPresent([MessageConversation].self, forKey: .data) {
            self.conversations = data
        } else if let threads = try container.decodeIfPresent([MessageConversation].self, forKey: .threads) {
            self.conversations = threads
        } else {
            self.conversations = try container.decode([MessageConversation].self, forKey: .messages)
        }
    }
}

struct ConversationMessagesResponse: Decodable {
    let messages: [KTPMessage]
    let nextCursor: String?
    let hasMoreBefore: Bool
    let deletedMessageIDs: Set<String>

    enum CodingKeys: String, CodingKey {
        case messages
        case data
        case conversation
        case nextCursor = "next_cursor"
        case cursor
        case hasMoreBefore = "has_more_before"
        case deletedMessageIDs = "deleted_message_ids"
        case deleted
    }

    static func decodeMessages(from data: Data) throws -> [KTPMessage] {
        try decodePage(from: data).messages
    }

    static func decodePage(from data: Data) throws -> ConversationMessagePage {
        let decoder = JSONDecoder()
        if let directMessages = try? decoder.decode([KTPMessage].self, from: data) {
            return ConversationMessagePage(
                messages: directMessages,
                nextCursor: nil,
                hasMoreBefore: false,
                deletedMessageIDs: Set(directMessages.filter(\.isDeleted).map(\.id))
            )
        }

        let response = try decoder.decode(ConversationMessagesResponse.self, from: data)
        return ConversationMessagePage(
            messages: response.messages,
            nextCursor: response.nextCursor,
            hasMoreBefore: response.hasMoreBefore,
            deletedMessageIDs: response.deletedMessageIDs.union(response.messages.filter(\.isDeleted).map(\.id))
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let messages = try container.decodeIfPresent([KTPMessage].self, forKey: .messages) {
            self.messages = messages
        } else if let data = try container.decodeIfPresent([KTPMessage].self, forKey: .data) {
            self.messages = data
        } else {
            self.messages = try container.decode([KTPMessage].self, forKey: .conversation)
        }

        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? container.decodeIfPresent(String.self, forKey: .cursor)
        hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
        deletedMessageIDs = Set(try container.decodeIfPresent([String].self, forKey: .deletedMessageIDs) ?? [])
            .union(try container.decodeIfPresent([String].self, forKey: .deleted) ?? [])
    }
}

struct ConversationMessagePage {
    let messages: [KTPMessage]
    let nextCursor: String?
    let hasMoreBefore: Bool
    let deletedMessageIDs: Set<String>
}

#if DEBUG
extension MessageConversation {
    static let previewSamples: [MessageConversation] = [
        MessageConversation(
            id: "1",
            userId: "1",
            displayName: "Jordan Lee",
            preview: "Chapter updates are live for this week.",
            lastMessageDate: Date(),
            unreadCount: 1
        ),
        MessageConversation(
            id: "2",
            userId: "2",
            displayName: "Maya Patel",
            preview: "Reminder: recruitment meeting starts at 7:00 PM.",
            lastMessageDate: Calendar.current.date(byAdding: .hour, value: -2, to: Date()),
            unreadCount: 0
        )
    ]
}

extension GroupChat {
    static let previewSamples: [GroupChat] = [
        GroupChat(
            id: "chapter",
            name: "Chapter Updates",
            preview: "Meeting room changed to MLC 214.",
            lastMessageDate: Calendar.current.date(byAdding: .minute, value: -32, to: Date()),
            unreadCount: 2
        )
    ]
}

extension KTPMessage {
    static let previewSamples: [KTPMessage] = [
        KTPMessage(
            id: "1",
            senderId: "1",
            recipientId: "2",
            body: "Chapter updates are live for this week.",
            createdAt: Date(),
            isRead: false,
            reactions: [
                MessageReactionSummary(emoji: "👍", count: 2, reactedByCurrentUser: true),
                MessageReactionSummary(emoji: "🎉", count: 1, reactedByCurrentUser: false),
            ]
        )
    ]
}
#endif

private extension KeyedDecodingContainer {
    func decodeFirstPresentString(for keys: [Key], fallback: String) throws -> String {
        try decodeFirstPresentStringIfPresent(for: keys) ?? fallback
    }

    func decodeFirstPresentStringIfPresent(for keys: [Key]) throws -> String? {
        for key in keys {
            if let stringValue = try decodeIfPresent(String.self, forKey: key), !stringValue.isEmpty {
                return stringValue
            }

            if let intValue = try decodeIfPresent(Int.self, forKey: key) {
                return String(intValue)
            }
        }

        return nil
    }

    func decodeFirstPresentDateIfPresent(for keys: [Key]) throws -> Date? {
        for key in keys {
            if let stringValue = try decodeIfPresent(String.self, forKey: key),
               let date = MessageDateParser.date(from: stringValue) {
                return date
            }

            if let timestamp = try decodeIfPresent(TimeInterval.self, forKey: key) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }

        return nil
    }

    func decodeFirstPresentURLIfPresent(for keys: [Key]) throws -> URL? {
        for key in keys {
            if let stringValue = try decodeIfPresent(String.self, forKey: key),
               let url = URL(string: stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }

        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

private enum MessageDateParser {
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    static func date(from value: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value)
    }
}
