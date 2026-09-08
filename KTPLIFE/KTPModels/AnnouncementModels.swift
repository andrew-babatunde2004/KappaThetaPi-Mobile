import Foundation

struct Announcement: Identifiable, Equatable, Decodable {
    let id: String
    let title: String
    let body: String
    let createdAt: Date
    let updatedAt: Date?
    let authorName: String?
    let authorExecutiveTitle: String?
    let links: [AnnouncementLink]
    let media: [AnnouncementMedia]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case message
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case authorName = "author_name"
        case authorExecutiveTitle = "author_exec_title"
        case links
        case media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try container.decodeIfPresent(String.self, forKey: .id), !stringID.isEmpty {
            id = stringID
        } else if let integerID = try container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(integerID)
        } else {
            id = UUID().uuidString
        }

        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = (decodedTitle?.isEmpty == false ? decodedTitle : nil) ?? "Chapter update"
        body = try container.decodeIfPresent(String.self, forKey: .body)
            ?? container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .content)
            ?? ""
        createdAt = try container.announcementDate(for: .createdAt) ?? .distantPast
        updatedAt = try container.announcementDate(for: .updatedAt)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorExecutiveTitle = try container.decodeIfPresent(String.self, forKey: .authorExecutiveTitle)
        links = try container.decodeIfPresent([AnnouncementLink].self, forKey: .links) ?? []
        media = try container.decodeIfPresent([AnnouncementMedia].self, forKey: .media) ?? []
    }

    static func decodeAnnouncements(from data: Data) throws -> [Announcement] {
        let decoder = JSONDecoder()
        if let announcements = try? decoder.decode([Announcement].self, from: data) {
            return announcements
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let response = object as? [String: Any] else {
            throw KTPAPIError.decodeFailed("Expected an announcement array or response object.")
        }

        for key in ["announcements", "data"] {
            guard let value = response[key], JSONSerialization.isValidJSONObject(value) else { continue }
            let nestedData = try JSONSerialization.data(withJSONObject: value)
            if let announcements = try? decoder.decode([Announcement].self, from: nestedData) {
                return announcements
            }
        }

        throw KTPAPIError.decodeFailed("The response did not contain a supported announcement list.")
    }
}

struct AnnouncementLink: Identifiable, Equatable, Decodable {
    let label: String
    let url: URL

    var id: String { "\(label)-\(url.absoluteString)" }
}

struct AnnouncementMedia: Identifiable, Equatable, Decodable {
    let id: String
    let kind: String
    let filename: String?
    let mimeType: String?

    var isVideo: Bool {
        kind.caseInsensitiveCompare("video") == .orderedSame
            || mimeType?.lowercased().hasPrefix("video/") == true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case filename
        case mimeType = "mime_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "image"
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    }
}

private extension KeyedDecodingContainer {
    func announcementDate(for key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return AnnouncementDateParser.date(from: value)
    }
}

private enum AnnouncementDateParser {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    static func date(from value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? iso8601.date(from: value)
    }
}
