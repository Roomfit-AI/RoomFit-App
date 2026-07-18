import Foundation

/// 백엔드의 영구 페어링 코드 API(POST /api/clients/pairing-code[/regenerate])와
/// 통신한다. 발급/조회는 멱등이라 여러 번 불러도 코드가 바뀌지 않고, 재발급만
/// 명시적으로 기존 코드를 무효화한다.
struct PairingCodeService {

    private static let requestTimeout: TimeInterval = 90

    func fetchOrCreateCode(clientId: String) async throws -> String {
        try await request(url: BackendConfig.pairingCodeURL, clientId: clientId)
    }

    func regenerateCode(clientId: String) async throws -> String {
        try await request(url: BackendConfig.pairingCodeRegenerateURL, clientId: clientId)
    }

    private func request(url: URL, clientId: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: RoomFitClientIdentity.headerName)
        request.timeoutInterval = Self.requestTimeout

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RoomUploadError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoomUploadError.invalidResponse
        }

        let decodedResponse = try? JSONDecoder().decode(CommonResponse<PairingCodePayload>.self, from: responseData)

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = decodedResponse?.error {
                throw RoomUploadError.backend(error.message)
            }
            throw RoomUploadError.serverStatus(httpResponse.statusCode)
        }

        guard let decodedResponse, decodedResponse.success, let data = decodedResponse.data else {
            throw RoomUploadError.decodingFailed
        }

        return data.code
    }
}

private struct PairingCodePayload: Decodable {
    let code: String
}
