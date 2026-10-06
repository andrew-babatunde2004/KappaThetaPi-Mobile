import Foundation

class PhotoService {
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

    func fetchPhotos(albumId: String? = nil) async throws -> [PhotoItem] {
        var components = URLComponents(url: baseURL.appendingPathComponent("photos"), resolvingAgainstBaseURL: false)
        if let albumId, !albumId.isEmpty {
            components?.queryItems = [URLQueryItem(name: "album_id", value: albumId)]
        }

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let data = try await fetchProtectedData(from: url, logLabel: "photos")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([PhotoItem].self, from: data)
    }

    /// Fetches member-visible named albums. The general shared album is modeled
    /// locally because its photos are represented by a null `album_id`.
    func fetchAlbums() async throws -> [PhotoAlbum] {
        let data = try await fetchProtectedData(
            from: baseURL.appendingPathComponent("albums"),
            logLabel: "photo albums"
        )
        let decoder = JSONDecoder()

        if let albums = try? decoder.decode([PhotoAlbum].self, from: data) {
            return albums
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let response = object as? [String: Any] else {
            throw KTPAPIError.decodeFailed("Expected an array or keyed albums response.")
        }

        for key in ["albums", "data"] {
            guard let value = response[key], JSONSerialization.isValidJSONObject(value) else { continue }
            let nestedData = try JSONSerialization.data(withJSONObject: value)
            if let albums = try? decoder.decode([PhotoAlbum].self, from: nestedData) {
                return albums
            }
        }

        throw KTPAPIError.decodeFailed("The response did not contain a supported albums list.")
    }

    func mediaURL(for photo: PhotoItem) -> URL {
        baseURL
            .appendingPathComponent("photos")
            .appendingPathComponent(photo.id)
            .appendingPathComponent("media")
    }

    /// A small, server-generated derivative for gallery tiles. The full-size
    /// original remains reserved for the media viewer and explicit downloads.
    func thumbnailURL(for photo: PhotoItem) -> URL {
        mediaURL(for: photo)
            .appending(queryItems: [URLQueryItem(name: "size", value: "thumbnail")])
    }

    func fetchMediaData(for photo: PhotoItem) async throws -> Data {
        try await fetchProtectedData(from: mediaURL(for: photo), logLabel: "photo media \(photo.id)")
    }

    func fetchThumbnailData(for photo: PhotoItem) async throws -> Data {
        try await fetchProtectedData(from: thumbnailURL(for: photo), logLabel: "photo thumbnail \(photo.id)")
    }

    func uploadPhoto(
        data: Data,
        fileName: String,
        mimeType: String,
        title: String? = nil,
        caption: String? = nil,
        albumId: String? = nil
    ) async throws -> PhotoItem {
        var request = URLRequest(url: baseURL.appendingPathComponent("photos"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "title": title,
                "caption": caption,
                "album_id": albumId
            ],
            fileFieldName: "file",
            fileName: fileName,
            mimeType: mimeType,
            fileData: data
        )

        let responseData = try await fetchProtectedData(for: request, logLabel: "upload photo")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PhotoItem.self, from: responseData)
    }

    func deletePhoto(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("photos").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        _ = try await fetchProtectedData(for: request, logLabel: "delete photo \(id)")
    }

    private func fetchProtectedData(from url: URL, logLabel: String) async throws -> Data {
        try await fetchProtectedData(for: URLRequest(url: url), logLabel: logLabel)
    }

    private func fetchProtectedData(for request: URLRequest, logLabel: String) async throws -> Data {
        guard let accessToken = try await accessTokenProvider(), !accessToken.isEmpty else {
            throw KTPAPIError.missingAccessToken
        }

        var authenticatedRequest = request
        authenticatedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: authenticatedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            AuthDebugLog.log("KTP photo API failed status=\(httpResponse.statusCode), body=\(responseBody)")
            throw KTPAPIError.badStatusCode(httpResponse.statusCode, responseBody)
        }

        AuthDebugLog.log("KTP photo API request succeeded for \(logLabel).")
        return data
    }

    private func fetchProtectedData(
        uploading request: URLRequest,
        fromFile fileURL: URL,
        logLabel: String
    ) async throws -> Data {
        guard let accessToken = try await accessTokenProvider(), !accessToken.isEmpty else {
            throw KTPAPIError.missingAccessToken
        }

        var authenticatedRequest = request
        authenticatedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.upload(for: authenticatedRequest, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            AuthDebugLog.log("KTP photo API failed status=\(httpResponse.statusCode), body=\(responseBody)")
            throw KTPAPIError.badStatusCode(httpResponse.statusCode, responseBody)
        }

        AuthDebugLog.log("KTP photo API request succeeded for \(logLabel).")
        return data
    }

    private static func multipartBody(
        boundary: String,
        fields: [String: String?],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields {
            guard let value, !value.isEmpty else { continue }
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")

        return body
    }

    private var photoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func multipartFile(
        boundary: String,
        fields: [String: String?],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        sourceURL: URL
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ktp-multipart-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)

            do {
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                let lineBreak = "\r\n"

                func write(_ value: String) throws {
                    try output.write(contentsOf: Data(value.utf8))
                }

                for (name, value) in fields {
                    guard let value, !value.isEmpty else { continue }
                    try write("--\(boundary)\(lineBreak)")
                    try write("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
                    try write("\(value)\(lineBreak)")
                }

                try write("--\(boundary)\(lineBreak)")
                try write("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(lineBreak)")
                try write("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")

                let input = try FileHandle(forReadingFrom: sourceURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }

                try write(lineBreak)
                try write("--\(boundary)--\(lineBreak)")
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }.value
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
