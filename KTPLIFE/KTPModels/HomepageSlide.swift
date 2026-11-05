import Foundation

/// A visible homepage slide returned by authenticated `GET /ios-homepage-photos`.
struct HomepageSlide: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let altText: String
    let linkURL: URL?
    let linkLabel: String?
    let sortOrder: Int
    let isActive: Bool
    let audience: [String]
    let startsAt: Date?
    let endsAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case altText = "alt_text"
        case linkURL = "link_url"
        case linkLabel = "link_label"
        case sortOrder = "sort_order"
        case isActive = "is_active"
        case audience
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        altText = try container.decodeIfPresent(String.self, forKey: .altText) ?? "Chapter highlight"
        linkURL = try container.decodeIfPresent(URL.self, forKey: .linkURL)
        linkLabel = try container.decodeIfPresent(String.self, forKey: .linkLabel)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        audience = try container.decodeIfPresent([String].self, forKey: .audience) ?? []
        startsAt = try container.decodeISO8601DateIfPresent(forKey: .startsAt)
        endsAt = try container.decodeISO8601DateIfPresent(forKey: .endsAt)
    }
}

struct HomepageSlidesResponse: Decodable {
    let slides: [HomepageSlide]
}

struct HomepageSlideUpdateRequest: Encodable {
    let title: String
    let subtitle: String
    let altText: String
    let linkURL: String
    let linkLabel: String
    let isActive: Bool
    let audience: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case altText = "alt_text"
        case linkURL = "link_url"
        case linkLabel = "link_label"
        case isActive = "is_active"
        case audience
    }
}

private extension KeyedDecodingContainer {
    func decodeISO8601DateIfPresent(forKey key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return ISO8601DateFormatter.homepageDateTimeWithFractionalSeconds.date(from: value)
            ?? ISO8601DateFormatter.homepageDateTime.date(from: value)
    }
}

private extension ISO8601DateFormatter {
    static let homepageDateTimeWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let homepageDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
