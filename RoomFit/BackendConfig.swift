import Foundation

/// 앱이 실제로 통신하는 Production 주소를 이 파일 한 곳에 모아둔다 — Release
/// 빌드는 반드시 여기 값을 그대로 사용해야 하고, localhost/사설 IP/ngrok/Vercel
/// Preview URL 같은 임시 주소가 여기 섞여 들어가면 안 된다(App Store 심사 빌드
/// 기준 고정 주소).
enum BackendConfig {
    // 기본 백엔드는 Render 배포 서버를 사용합니다.
    // 로컬 백엔드 테스트가 필요하면 baseURL을 Mac의 로컬 IP로 임시 변경할 수 있습니다.
    // 단, 이 변경은 로컬 디버그 빌드에서만 하고 Release/Archive 전에는 반드시
    // 아래 Production 주소로 되돌려야 합니다.
    static let baseURL = URL(string: "https://roomfit-backend.onrender.com")!

    /// Room 업로드 성공 후 사용자를 넘겨줄 RoomFit Web의 Production 주소.
    static let webBaseURL = URL(string: "https://roomfit-web-tau.vercel.app")!

    static var roomUploadURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("rooms")
            .appendingPathComponent("upload")
    }

    private static var pairingCodeBaseURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("clients")
            .appendingPathComponent("pairing-code")
    }

    /// 발급/조회(멱등) — 이미 이 clientId로 발급된 코드가 있으면 그대로 돌려받는다.
    static var pairingCodeURL: URL { pairingCodeBaseURL }

    /// 기존 코드를 무효화하고 새 코드를 발급한다.
    static var pairingCodeRegenerateURL: URL {
        pairingCodeBaseURL.appendingPathComponent("regenerate")
    }

    /// Web으로 넘어갈 때 쓰는 handoff URL. roomId/clientId는 문자열 이어붙이기가
    /// 아니라 URLComponents/URLQueryItem으로 구성해 인코딩 오류나 잘못된 URL을
    /// 만들 위험을 없앤다. Web 쪽이 아직 이 roomId/clientId 쿼리를 받는 라우트를
    /// 구현 중이라, 기존에 유지해야 할 route/파라미터 이름이 없어 루트(`/`)에
    /// `roomId`, `clientId` 쿼리 파라미터를 얹는 형태를 그대로 쓴다.
    static func webHandoffURL(roomId: Int, clientId: String) -> URL? {
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "roomId", value: String(roomId)),
            URLQueryItem(name: "clientId", value: clientId)
        ]
        return components?.url
    }
}
