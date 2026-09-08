import Foundation

struct NotificationPreferences: Codable, Equatable {
    var directMessagesEnabled: Bool
    var announcementsEnabled: Bool
    var pollsEnabled: Bool
    var meetingsEnabled: Bool
    var eventsEnabled: Bool
    var eventRemindersEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case directMessagesEnabled = "direct_messages_enabled"
        case announcementsEnabled = "announcements_enabled"
        case pollsEnabled = "polls_enabled"
        case meetingsEnabled = "meetings_enabled"
        case eventsEnabled = "events_enabled"
        case eventRemindersEnabled = "event_reminders_enabled"
    }

    init(
        directMessagesEnabled: Bool = true,
        announcementsEnabled: Bool = true,
        pollsEnabled: Bool = true,
        meetingsEnabled: Bool = true,
        eventsEnabled: Bool = true,
        eventRemindersEnabled: Bool = true
    ) {
        self.directMessagesEnabled = directMessagesEnabled
        self.announcementsEnabled = announcementsEnabled
        self.pollsEnabled = pollsEnabled
        self.meetingsEnabled = meetingsEnabled
        self.eventsEnabled = eventsEnabled
        self.eventRemindersEnabled = eventRemindersEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directMessagesEnabled = try container.decodeIfPresent(Bool.self, forKey: .directMessagesEnabled) ?? true
        announcementsEnabled = try container.decodeIfPresent(Bool.self, forKey: .announcementsEnabled) ?? true
        pollsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pollsEnabled) ?? true
        meetingsEnabled = try container.decodeIfPresent(Bool.self, forKey: .meetingsEnabled) ?? true
        eventsEnabled = try container.decodeIfPresent(Bool.self, forKey: .eventsEnabled) ?? true
        eventRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .eventRemindersEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directMessagesEnabled, forKey: .directMessagesEnabled)
        try container.encode(announcementsEnabled, forKey: .announcementsEnabled)
        try container.encode(pollsEnabled, forKey: .pollsEnabled)
        try container.encode(meetingsEnabled, forKey: .meetingsEnabled)
        try container.encode(eventsEnabled, forKey: .eventsEnabled)
        try container.encode(eventRemindersEnabled, forKey: .eventRemindersEnabled)
    }

    static var cached: NotificationPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else {
            return NotificationPreferences()
        }
        return preferences
    }

    func cacheLocally() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static let storageKey = "notificationPreferences"
}

struct NotificationDeviceRegistration: Encodable {
    let token: String
    let platform = "ios"
    let environment: String
}

struct MessageMutePreferences: Codable, Equatable {
    var directUserIDs: [String]
    var groupChatIDs: [String]

    enum CodingKeys: String, CodingKey {
        case directUserIDs = "direct_user_ids"
        case groupChatIDs = "group_chat_ids"
    }

    static var cached: MessageMutePreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(MessageMutePreferences.self, from: data)
        else {
            return MessageMutePreferences(directUserIDs: [], groupChatIDs: [])
        }
        return preferences
    }

    func cacheLocally() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: .messageMutePreferencesDidChange, object: nil)
    }

    private static let storageKey = "messageMutePreferences"
}

enum DirectMessageMutePreferences {
    static func isMuted(_ userID: String) -> Bool {
        MessageMutePreferences.cached.directUserIDs.contains(userID)
    }

    static func setMuted(_ isMuted: Bool, for userID: String) {
        var preferences = MessageMutePreferences.cached
        var ids = Set(preferences.directUserIDs)
        if isMuted {
            ids.insert(userID)
        } else {
            ids.remove(userID)
        }
        preferences.directUserIDs = Array(ids).sorted()
        preferences.cacheLocally()
    }

    static var mutedUserIDs: Set<String> {
        Set(MessageMutePreferences.cached.directUserIDs)
    }
}

/// Keeps a local copy for an immediate inbox update and offline display. The
/// API remains the source of truth and suppresses remote notifications.
enum GroupChatMutePreferences {
    static func isMuted(_ chatID: String) -> Bool {
        MessageMutePreferences.cached.groupChatIDs.contains(chatID)
    }

    static func setMuted(_ isMuted: Bool, for chatID: String) {
        var preferences = MessageMutePreferences.cached
        var ids = Set(preferences.groupChatIDs)
        if isMuted {
            ids.insert(chatID)
        } else {
            ids.remove(chatID)
        }
        preferences.groupChatIDs = Array(ids).sorted()
        preferences.cacheLocally()
    }

    static var mutedChatIDs: Set<String> {
        Set(MessageMutePreferences.cached.groupChatIDs)
    }
}

extension Notification.Name {
    static let messageMutePreferencesDidChange = Notification.Name("messageMutePreferencesDidChange")
}

enum PushNotificationDestination: Equatable {
    case directMessage(userID: String)
    case groupMessage(chat: GroupChatPushDestination)
    case announcement(id: String?)
    case poll(id: String?)
    case meeting(id: String?)
    case event(eventID: String)
    case interview
}

struct GroupChatPushDestination: Equatable {
    let id: String
    let name: String?
}
