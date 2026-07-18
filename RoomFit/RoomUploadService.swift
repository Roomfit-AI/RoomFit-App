import Foundation

struct RoomUploadService {

    // Render 무료 플랜은 콜드 스타트 시 요청이 수십 초 걸릴 수 있어, URLSession
    // 기본 타임아웃(60초)보다 넉넉하게 잡는다 — 짧으면 실제로는 성공했을 요청이
    // 성급하게 네트워크 실패로 잘못 보고된다.
    private static let requestTimeout: TimeInterval = 90

    /// - Parameter clientId: `RoomFitClientIdentity.getOrCreateClientId()`가 돌려주는
    ///   영구 UUID를 그대로 전달해야 한다 — 이 방을 업로드한 클라이언트를 Web
    ///   handoff와 동일하게 식별하는 값이라, 요청마다 다른 값을 넣으면 안 된다.
    func uploadRoomJSON(_ data: Data, clientId: String) async throws -> RoomUploadResponse {
        var request = URLRequest(url: BackendConfig.roomUploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: RoomFitClientIdentity.headerName)
        request.httpBody = data
        request.timeoutInterval = Self.requestTimeout

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            // URLSession 레벨 실패(오프라인, 타임아웃, DNS 실패 등) — 서버가 응답을
            // 주지도 못한 상태라 backend 에러 메시지는 없다. 사용자에게는 재시도를
            // 유도하는 일반적인 네트워크 안내만 보여준다.
            throw RoomUploadError.network(error)
        }

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

        // roomId는 RoomUploadResponse.roomId가 Int(옵셔널 아님)라, 응답에 roomId가
        // 없거나 형식이 다르면 위 JSONDecoder 단계에서 이미 디코딩 자체가 실패해
        // decodedResponse가 nil이 된다 — 즉 "roomId 누락"은 항상 .decodingFailed로
        // 걸러진다.
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
    /// 백엔드 RoomImportStatus: "ACCEPTED" 또는 "ACCEPTED_WITH_WARNINGS" —
    /// 둘 다 업로드 성공이다. 값 자체(문자열)만 사용하고, 개별 warning의 좌표나
    /// 원본 메시지(importWarnings)는 사용자에게 그대로 보여주지 않으므로 이 타입은
    /// 아예 디코딩하지 않는다.
    let importStatus: String?

    var hadWarnings: Bool {
        importStatus == "ACCEPTED_WITH_WARNINGS"
    }
}

enum RoomUploadError: LocalizedError {
    case invalidResponse
    case serverStatus(Int)
    case backend(String)
    case decodingFailed
    case network(Error)

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
        case .network:
            return "서버 연결에 실패했습니다. 네트워크를 확인한 뒤 다시 시도해 주세요."
        }
    }
}
