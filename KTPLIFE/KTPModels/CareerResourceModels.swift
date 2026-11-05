import Foundation

struct CareerCompany: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let slug: String?
    let insightCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case insightCount = "insight_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        insightCount = try container.decodeIfPresent(Int.self, forKey: .insightCount) ?? 0
    }
}

struct CareerCompanyDetail: Decodable {
    let company: CareerCompany
    let insights: [CareerInsight]
}

struct CareerInsight: Identifiable, Decodable, Hashable {
    let id: Int
    let companyID: Int
    let companyName: String?
    let authorID: String?
    let authorName: String?
    let roleTitle: String
    let employmentType: String?
    let term: String?
    let rounds: String?
    let difficulty: String?
    let outcome: String?
    let interviewWriteup: String?
    let roleWriteup: String?

    enum CodingKeys: String, CodingKey {
        case id
        case companyID = "company_id"
        case companyName = "company_name"
        case authorID = "author_id"
        case authorName = "author_name"
        case roleTitle = "role_title"
        case employmentType = "employment_type"
        case term
        case rounds
        case difficulty
        case outcome
        case interviewWriteup = "body"
        case roleWriteup = "role_body"
    }

    var summary: String {
        let source = roleWriteup?.nonEmptyTrimmed ?? interviewWriteup?.nonEmptyTrimmed ?? ""
        return source
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

struct MerchAccess: Decodable {
    let canView: Bool

    enum CodingKeys: String, CodingKey {
        case canView = "can_view"
    }
}

struct MerchShirtSizesResponse: Decodable {
    let sizes: [String]
    let members: [MerchMemberSize]
}

struct MerchMemberSize: Identifiable, Decodable, Hashable {
    let authentikID: String
    let firstName: String?
    let lastName: String?
    let memberGroup: String
    let shirtSize: String?
    let sweatshirtSize: String?

    var id: String { authentikID }

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0?.nonEmptyTrimmed }.joined(separator: " ")
        return name.isEmpty ? "KTP Member" : name
    }

    enum CodingKeys: String, CodingKey {
        case authentikID = "authentik_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case memberGroup = "member_group"
        case shirtSize = "shirt_size"
        case sweatshirtSize = "sweatshirt_size"
    }
}
