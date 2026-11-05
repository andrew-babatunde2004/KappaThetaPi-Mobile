import Foundation

struct AttendanceSemester: Decodable, Identifiable {
    let id: Int
    let name: String
    let startsOn: String
    let endsOn: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case startsOn = "starts_on"
        case endsOn = "ends_on"
    }

    func contains(day: String) -> Bool {
        startsOn <= day && day <= endsOn
    }
}

struct PersonalAttendanceSummary: Decodable {
    let attended: Int
    let total: Int
    let absences: Int
    let remaining: Int
    let overLimit: Int

    var allowance: Int {
        absences - overLimit + remaining
    }

    enum CodingKeys: String, CodingKey {
        case attended
        case total
        case absences
        case remaining
        case overLimit = "over_limit"
    }
}

struct PersonalAttendanceResponse: Decodable {
    let summary: PersonalAttendanceSummary
}
