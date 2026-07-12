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
            throw RoomUploadError.backend(decodedResponse.error?.message ?? "업로드에 실패했습니다.")
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
            return "서버 응답이 올바르지 않습니다."
        case .serverStatus(let statusCode):
            return "서버 오류가 발생했습니다. (HTTP \(statusCode))"
        case .backend(let message):
            return message
        case .decodingFailed:
            return "업로드 응답을 읽을 수 없습니다."
        }
    }
}
