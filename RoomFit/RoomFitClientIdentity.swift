import Foundation

/// 앱 익명 Client ID 관리를 한 곳에 모은 타입. 최초 실행 시 UUID를 한 번 생성해
/// UserDefaults에 영구 저장하고, 이후에는 항상 같은 값을 재사용한다 — Room 업로드
/// Header(X-RoomFit-Client-Id)와 Web handoff URL의 clientId 쿼리에 동일한 값을
/// 실어 보내, 백엔드/Web이 "이 기기에서 올린 방"을 식별할 수 있게 한다.
///
/// 로그인 토큰이나 인증 비밀값이 아니라 단순 클라이언트 식별자다 — 다만 전체 값을
/// 일반 로그에 반복 노출하지는 않는다(디버그가 필요하면 `maskedForLogging`처럼
/// 마지막 8자리만 잘라 쓴다).
enum RoomFitClientIdentity {

    /// Room 업로드 요청에 실어 보낼 헤더 이름 — 백엔드 ClientScopeService가
    /// 읽는 이름과 정확히 일치해야 한다.
    static let headerName = "X-RoomFit-Client-Id"

    private static let storageKey = "roomfitClientId"

    /// 저장된 값이 있고 유효한 UUID면 그대로, 없거나(최초 실행) 손상됐으면
    /// 새로 만들어 저장한 뒤 반환한다 — 스캔을 새로 하거나 업로드를 재시도해도
    /// 항상 같은 값을 돌려준다.
    @discardableResult
    static func getOrCreateClientId() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: storageKey), let normalized = normalizedIfValid(stored) {
            return normalized
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: storageKey)
        return generated
    }

    /// 새로 만들지 않는 조회 전용 값 — 저장된 게 없거나 손상됐으면 nil.
    static var currentClientId: String? {
        guard let stored = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return normalizedIfValid(stored)
    }

    /// 디버그/테스트 전용 — Production UI(설정 화면, 버튼 등)에 노출하지 않는다.
    /// 앱을 삭제 후 재설치하면 이 함수를 거치지 않고도 자연스럽게 새 UUID가
    /// 생성되므로(UserDefaults가 함께 삭제됨), 정상 사용 흐름에서는 필요 없다.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func normalizedIfValid(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString
    }
}
