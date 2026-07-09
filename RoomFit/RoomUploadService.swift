import Foundation

struct RoomUploadService {

    func uploadRoomJSON(_ data: Data) async throws -> RoomUploadResponse {
        var request = URLRequest(url: BackendConfig.roomUploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoomUploadError.invalidResponse
        }

        let decodedResponse = try? JSONDecoder().decode(CommonResponse<RoomUploadResponse>.self, from: responseData)

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = decodedResponse?.error {
                throw RoomUploadError.backend(error.message)
            }
            throw RoomUploadError.serverStatus(httpResponse.statusCode)
        }

        guard let decodedResponse else {
            throw RoomUploadError.decodingFailed
        }

        guard decodedResponse.success, let data = decodedResponse.data else {
            throw RoomUploadError.backend(decodedResponse.error?.message ?? "Upload failed.")
        }

        return data
    }
}

struct CommonResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: ErrorPayload?
}

struct ErrorPayload: Decodable {
    let code: String
    let message: String
}

struct RoomUploadResponse: Decodable {
    let roomId: Int
    let name: String?
}

enum RoomUploadError: LocalizedError {
    case invalidResponse
    case serverStatus(Int)
    case backend(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server response was not valid."
        case .serverStatus(let statusCode):
            return "Server returned HTTP \(statusCode)."
        case .backend(let message):
            return message
        case .decodingFailed:
            return "Could not read the upload response."
        }
    }
}
