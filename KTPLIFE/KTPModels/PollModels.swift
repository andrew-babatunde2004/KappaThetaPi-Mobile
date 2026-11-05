import Foundation

struct Poll: Identifiable, Equatable, Decodable {
    let id: String
    let question: String
    let description: String?
    let options: [PollOption]
    let allowsMultipleSelections: Bool
    let isClosed: Bool
    let expiresAt: Date?
    let myOptionIDs: Set<String>
    let totalVotes: Int
    let showVoters: Bool
    let votersVisible: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case title
        case description
        case options
        case multiSelect = "multi_select"
        case multiChoice = "multi_choice"
        case isClosed = "is_closed"
        case closed
        case expiresAt = "expires_at"
        case myOptionIDs = "my_option_ids"
        case totalVotes = "total_votes"
        case showVoters = "show_voters"
        case votersVisible = "voters_visible"
    }

    var isCurrentlyClosed: Bool {
        isClosed || (expiresAt.map { $0 <= Date() } ?? false)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.pollString(for: .id) ?? UUID().uuidString
        question = (try? container.decodeIfPresent(String.self, forKey: .question))
            ?? (try? container.decodeIfPresent(String.self, forKey: .title))
            ?? "Untitled Poll"
        description = (try? container.decodeIfPresent(String.self, forKey: .description))?.nonEmptyTrimmed
        options = (try? container.decodeIfPresent([PollOption].self, forKey: .options)) ?? []
        allowsMultipleSelections = container.pollBool(for: .multiSelect)
            ?? container.pollBool(for: .multiChoice)
            ?? false
        isClosed = container.pollBool(for: .isClosed)
            ?? container.pollBool(for: .closed)
            ?? false
        expiresAt = container.pollDate(for: .expiresAt)
        myOptionIDs = Set(container.pollStringArray(for: .myOptionIDs))
        totalVotes = container.pollInt(for: .totalVotes) ?? 0
        showVoters = container.pollBool(for: .showVoters) ?? false
        votersVisible = container.pollBool(for: .votersVisible) ?? false
    }

    static func decodePolls(from data: Data) throws -> [Poll] {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([Poll].self, from: data) {
            return direct
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let response = object as? [String: Any] else {
            throw KTPAPIError.decodeFailed("Expected a poll array or response object.")
        }

        for key in ["polls", "data", "items", "results"] {
            guard let value = response[key], JSONSerialization.isValidJSONObject(value) else { continue }
            let nestedData = try JSONSerialization.data(withJSONObject: value)
            if let polls = try? decoder.decode([Poll].self, from: nestedData) {
                return polls
            }
        }

        throw KTPAPIError.decodeFailed("The response did not contain a supported poll list.")
    }
}

struct PollOption: Identifiable, Equatable, Decodable {
    let id: String
    let title: String
    let voteCount: Int
    let voters: [PollVoter]

    enum CodingKeys: String, CodingKey {
        case id
        case optionID = "option_id"
        case text
        case optionText = "option_text"
        case label
        case title
        case name
        case voteCount = "vote_count"
        case votes
        case count
        case voters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.pollString(for: .id)
            ?? container.pollString(for: .optionID)
            ?? UUID().uuidString
        title = (try? container.decodeIfPresent(String.self, forKey: .text))
            ?? (try? container.decodeIfPresent(String.self, forKey: .optionText))
            ?? (try? container.decodeIfPresent(String.self, forKey: .label))
            ?? (try? container.decodeIfPresent(String.self, forKey: .title))
            ?? (try? container.decodeIfPresent(String.self, forKey: .name))
            ?? "Option"
        voteCount = container.pollInt(for: .voteCount)
            ?? container.pollInt(for: .votes)
            ?? container.pollInt(for: .count)
            ?? 0
        voters = (try? container.decodeIfPresent([PollVoter].self, forKey: .voters)) ?? []
    }
}

struct PollVoter: Identifiable, Equatable, Decodable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let preferredName: String?

    enum CodingKeys: String, CodingKey {
        case id = "authentik_id"
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case preferredName = "preferred_name"
    }

    var displayName: String {
        if let preferredName = preferredName?.nonEmptyTrimmed { return preferredName }
        let fullName = [firstName, lastName].compactMap { $0?.nonEmptyTrimmed }.joined(separator: " ")
        if !fullName.isEmpty { return fullName }
        return username?.nonEmptyTrimmed ?? "Member"
    }
}

private extension KeyedDecodingContainer {
    func pollString(for key: Key) -> String? {
        if let value = (try? decodeIfPresent(String.self, forKey: key))?.nonEmptyTrimmed {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func pollStringArray(for key: Key) -> [String] {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let values = try? decodeIfPresent([Int].self, forKey: key) {
            return values.map(String.init)
        }
        return []
    }

    func pollInt(for key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func pollBool(for key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func pollDate(for key: Key) -> Date? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return PollDateParser.date(from: value)
    }
}

private enum PollDateParser {
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
