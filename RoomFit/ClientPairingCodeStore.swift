import Foundation

/// 컴퓨터 브라우저에 이 앱의 clientId를 옮겨 붙이기 위한 영구 페어링 코드를
/// 들고 있는다. 로컬에 캐시해서 화면을 열 때마다 네트워크를 기다리지 않고
/// 바로 보여주고, 백그라운드로 최신 값을 다시 확인한다.
@MainActor
final class ClientPairingCodeStore: ObservableObject {
    @Published private(set) var code: String?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private static let cacheKey = "roomfitCachedPairingCode"

    private let service = PairingCodeService()

    init() {
        code = UserDefaults.standard.string(forKey: Self.cacheKey)
    }

    /// 캐시된 값이 없을 때만 네트워크로 조회 — 화면 진입마다 매번 부르는 용도.
    /// `isLoading`을 여기서 동기적으로 먼저 세팅한다 — `Task { await ... }`가
    /// 실제로 실행되기 전에(비동기 스케줄링 지연 중) `loadIfNeeded()`가 한 번 더
    /// 불려도(예: SwiftUI가 onAppear를 두 번 트리거하는 경우) 중복으로 네트워크
    /// 요청을 두 번 보내지 않도록 막는다. 백엔드도 같은 clientId의 동시 최초
    /// 발급 요청을 안전하게 처리하도록 고쳐뒀지만(경쟁 상태 시 먼저 이긴 쪽 코드
    /// 재사용), 애초에 중복 요청 자체를 안 보내는 게 더 낫다.
    func loadIfNeeded() {
        guard code == nil, !isLoading else { return }
        isLoading = true
        Task { await performFetch() }
    }

    /// "다시 시도" 버튼처럼 직접 호출되는 경로 — loadIfNeeded와 달리 아직
    /// isLoading이 세팅돼 있지 않으므로 여기서 guard+세팅을 한 번 더 한다.
    func fetch() async {
        guard !isLoading else { return }
        isLoading = true
        await performFetch()
    }

    /// 코드가 노출됐다고 판단될 때 — 기존 코드는 그 즉시 못 쓰게 되고 새 코드로
    /// 교체된다.
    func regenerate() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let clientId = RoomFitClientIdentity.getOrCreateClientId()
            let newCode = try await service.regenerateCode(clientId: clientId)
            code = newCode
            UserDefaults.standard.set(newCode, forKey: Self.cacheKey)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// loadIfNeeded/fetch 둘 다 각자 guard+isLoading=true를 마친 뒤 이 공용
    /// 로직으로 합류한다 — 실제 네트워크 호출과 isLoading 해제는 한 곳에만 있다.
    private func performFetch() async {
        errorMessage = nil

        do {
            let clientId = RoomFitClientIdentity.getOrCreateClientId()
            let fetchedCode = try await service.fetchOrCreateCode(clientId: clientId)
            code = fetchedCode
            UserDefaults.standard.set(fetchedCode, forKey: Self.cacheKey)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
