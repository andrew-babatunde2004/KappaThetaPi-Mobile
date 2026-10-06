import Foundation

struct AttendanceSemester: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let startsOn: String
    let endsOn: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case startsOn = "starts_on"
        case endsOn = "ends_on"
    }

    func contains(_ date: Date = .now) -> Bool {
        guard let start = Self.dayFormatter.date(from: startsOn),
              let end = Self.dayFormatter.date(from: endsOn)
        else { return false }
        return date >= start && date < Calendar.current.date(byAdding: .day, value: 1, to: end)!
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct AttendanceSummary: Decodable, Hashable {
    let attended: Int
    let credited: Int
    let total: Int
    let pending: Int
    let absences: Int
    let excused: Int
    let waived: Int
    let remaining: Int
    let overLimit: Int

    enum CodingKeys: String, CodingKey {
        case attended, credited, total, pending, absences, excused, waived, remaining
        case overLimit = "over_limit"
    }
}

struct AttendanceRecord: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let status: String?
    let isWaived: Bool
    let countsTowardTotal: Bool
    let checkInOpen: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case startDate = "start_date"
        case endDate = "end_date"
        case isWaived = "waived"
        case countsTowardTotal = "counts_toward_total"
        case checkInOpen = "checkin_open"
    }

    /// Mandatory attendance rows use the database obligation's numeric ID,
    /// while supplemental history rows use a stable `history:<event>:<user>`
    /// string. Both appear in the same API response.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        title = try container.decode(String.self, forKey: .title)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        isWaived = try container.decode(Bool.self, forKey: .isWaived)
        countsTowardTotal = try container.decode(Bool.self, forKey: .countsTowardTotal)
        checkInOpen = try container.decode(Bool.self, forKey: .checkInOpen)
    }

    var displayStatus: AttendanceRecordStatus {
        if status == "present" { return .present }
        if isWaived { return .waived }
        if status == "excused" { return .excused }
        if checkInOpen { return .pending }
        return .absent
    }
}

enum AttendanceRecordStatus: String {
    case present, excused, waived, pending, absent

    var label: String {
        switch self {
        case .present: "Present"
        case .excused: "Excused"
        case .waived: "Emergency waived"
        case .pending: "Pending"
        case .absent: "Absent"
        }
    }

    var systemImage: String {
        switch self {
        case .present: "checkmark.circle.fill"
        case .excused, .waived: "checkmark.seal.fill"
        case .pending: "clock.fill"
        case .absent: "xmark.circle.fill"
        }
    }
}

struct AttendanceLog: Decodable {
    let records: [AttendanceRecord]
    let summary: AttendanceSummary
}
