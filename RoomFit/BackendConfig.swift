import Foundation

enum BackendConfig {
    // iPhone 실기기에서는 localhost가 아니라 Mac의 로컬 IP를 사용해야 합니다.
    // Mac IP는 ipconfig getifaddr en0 명령으로 확인할 수 있습니다.
    static let baseURL = URL(string: "http://192.168.35.179:8080")!

    static var roomUploadURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("rooms")
            .appendingPathComponent("upload")
    }
}
