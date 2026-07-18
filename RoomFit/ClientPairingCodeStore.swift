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
    func loadIfNeeded() {
        guard code == nil, !isLoading else { return }
        Task { await fetch() }
    }

    func fetch() async {
        guard !isLoading else { return }
        isLoading = true
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
}
