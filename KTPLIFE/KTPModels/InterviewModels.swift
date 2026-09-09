import Foundation

struct InterviewSchedule: Identifiable, Decodable {
    let id: String
    let title: String
    let description: String?
    let location: String?
    let slots: [InterviewSlot]

    enum CodingKeys: String, CodingKey { case id, title, name, description, location, slots }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.stringID(from: container, key: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? "Interview"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        slots = try container.decodeIfPresent([InterviewSlot].self, forKey: .slots) ?? []
    }

    static func decodeSchedules(from data: Data) throws -> [InterviewSchedule] {
        let decoder = JSONDecoder()
        if let schedules = try? decoder.decode([InterviewSchedule].self, from: data) { return schedules }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let response = object as? [String: Any] else { throw KTPAPIError.decodeFailed("Expected interview schedules.") }
        for key in ["schedules", "interviews", "data"] {
            guard let value = response[key], JSONSerialization.isValidJSONObject(value) else { continue }
            if let schedules = try? decoder.decode([InterviewSchedule].self, from: JSONSerialization.data(withJSONObject: value)) { return schedules }
        }
        throw KTPAPIError.decodeFailed("The response did not contain interview schedules.")
    }

    private static func stringID(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> String {
        if let value = try container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        throw KTPAPIError.decodeFailed("An interview schedule is missing its ID.")
    }
}

struct InterviewSlot: Identifiable, Decodable {
    let id: String
    let startsAt: Date
    let endsAt: Date?
    let location: String?
    let capacity: Int
    let bookedCount: Int
    let mine: Bool
    let bookingID: String?

    enum CodingKeys: String, CodingKey {
        case id, location, capacity, mine
        case startsAt = "starts_at", startDate = "start_date"
        case apiStartDate = "startDate"
        case endsAt = "ends_at", endDate = "end_date"
        case apiEndDate = "endDate"
        case bookedCount = "booked_count", bookingsCount = "bookings_count"
        case bookingID = "booking_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .id) { id = value }
        else if let value = try container.decodeIfPresent(Int.self, forKey: .id) { id = String(value) }
        else { throw KTPAPIError.decodeFailed("An interview slot is missing its ID.") }
        startsAt = try container.interviewDate(for: .apiStartDate)
            ?? container.interviewDate(for: .startsAt)
            ?? container.interviewDate(for: .startDate)
            ?? .distantPast
        endsAt = try container.interviewDate(for: .apiEndDate)
            ?? container.interviewDate(for: .endsAt)
            ?? container.interviewDate(for: .endDate)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? 1
        bookedCount = try container.decodeIfPresent(Int.self, forKey: .bookedCount)
            ?? container.decodeIfPresent(Int.self, forKey: .bookingsCount) ?? 0
        mine = try container.decodeIfPresent(Bool.self, forKey: .mine) ?? false
        bookingID = try container.decodeIfPresent(String.self, forKey: .bookingID)
    }

    var isAvailable: Bool { !mine && bookedCount < capacity }
}

private extension KeyedDecodingContainer where Key == InterviewSlot.CodingKeys {
    func interviewDate(for key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
