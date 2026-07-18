import SwiftUI

/// "컴퓨터에서 보기"에서 뜨는 시트 — 영구 페어링 코드를 크게 보여주고, 필요하면
/// 재발급할 수 있게 한다. 회원가입 없이도 컴퓨터 브라우저가 이 코드를 한 번
/// 입력하면 그 이후로는 계속 내 방으로 인식되는 게 목적(Web 쪽에서 구현).
struct PairingCodeSheetView: View {
    @ObservedObject var store: ClientPairingCodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingRegenerateConfirm = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("컴퓨터와 연결하기")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Color.appInk)

                Text("컴퓨터에서 RoomFit 웹사이트를 열고 이 코드를 입력하면,\n그 컴퓨터에서도 계속 내 방을 확인할 수 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appInkSoft)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 24)

            codeDisplay

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 10) {
                Button {
                    isShowingRegenerateConfirm = true
                } label: {
                    Label("코드 재발급", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
                .disabled(store.isLoading)

                Button("닫기") { dismiss() }
                    .buttonStyle(LinkButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Spacer(minLength: 0)
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appCream.ignoresSafeArea())
        .onAppear {
            store.loadIfNeeded()
        }
        .confirmationDialog(
            "코드를 재발급하면 예전 코드는 더 이상 쓸 수 없습니다. 계속할까요?",
            isPresented: $isShowingRegenerateConfirm,
            titleVisibility: .visible
        ) {
            Button("재발급", role: .destructive) {
                Task { await store.regenerate() }
            }
            Button("취소", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var codeDisplay: some View {
        if store.isLoading && store.code == nil {
            ProgressView()
                .frame(height: 84)
        } else if let code = store.code {
            Text(formattedCode(code))
                .font(.system(size: 32, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.appInk)
                .tracking(2)
                .padding(.vertical, 22)
                .padding(.horizontal, 28)
                .background(Color.appCard, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.appBorder, lineWidth: 1))
        } else {
            VStack(spacing: 10) {
                Text("코드를 불러오지 못했습니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appInkSoft)
                Button {
                    Task { await store.fetch() }
                } label: {
                    Label("다시 시도", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LinkButtonStyle())
            }
            .frame(height: 84)
        }
    }

    private func formattedCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 4)
        return "\(code[..<mid])-\(code[mid...])"
    }
}
