import Foundation

/// Authenticated client for a member's personal attendance history.
final class AttendanceLogService {
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

    func fetchSemesters() async throws -> [AttendanceSemester] {
        let url = baseURL
            .appendingPathComponent("attendance-log")
            .appendingPathComponent("semesters")
        return try await request(URLRequest(url: url), label: "attendance semesters")
    }

    func fetchLog(semesterID: Int) async throws -> AttendanceLog {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("attendance-log")
                .appendingPathComponent("mine"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "semester_id", value: String(semesterID))]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(URLRequest(url: url), label: "attendance log")
    }

    private func request<Response: Decodable>(_ request: URLRequest, label: String) async throws -> Response {
        guard let token = try await accessTokenProvider(), !token.isEmpty else {
            throw KTPAPIError.missingAccessToken
        }

        var authenticatedRequest = request
        authenticatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        AuthDebugLog.log("Fetching \(label) from \(request.url?.absoluteString ?? "unknown URL")")
        let (data, response) = try await session.data(for: authenticatedRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw KTPAPIError.badStatusCode(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "No response body")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            guard let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date: \(value)"
                )
            }
            return date
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw KTPAPIError.decodeFailed("The attendance response could not be read.")
        }
    }
}
