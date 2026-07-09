import Foundation

enum BackendConfig {
    // 기본 백엔드는 Render 배포 서버를 사용합니다.
    // 로컬 백엔드 테스트가 필요하면 baseURL을 Mac의 로컬 IP로 임시 변경할 수 있습니다.
    static let baseURL = URL(string: "https://roomfit-backend.onrender.com")!

    static var roomUploadURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("rooms")
            .appendingPathComponent("upload")
    }
}
