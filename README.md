# RoomFit App

RoomFit App은 iPhone/iPad에서 방을 스캔하거나 방 정보를 준비해 RoomFit Backend로 업로드하고, RoomFit Web의 레이아웃 추천·편집 흐름으로 이어 주는 SwiftUI 앱입니다.

## 사용자 흐름

```text
RoomPlan 스캔 또는 샘플/수동 입력
  → RoomFit JSON 생성
  → Backend 업로드 (기기 Client ID 포함)
  → 업로드 이력·JSON·USDZ 보관
  → 페어링 코드 또는 Web handoff로 레이아웃 편집 계속하기
```

## 주요 기능

- Apple RoomPlan을 이용한 LiDAR 지원 기기의 방 스캔
- LiDAR 미지원 기기를 위한 내장 샘플 방과 방 크기 수동 입력
- 스캔 데이터의 JSON 및 USDZ 내보내기·공유
- 업로드된 방의 이름, 썸네일, 3D 모델, JSON을 기기에 보관하고 재업로드 지원
- 요청마다 바뀌지 않는 익명 Client ID로 Backend와 Web의 방 소유 범위를 일관되게 유지
- 기기와 브라우저를 연결하는 페어링 코드 조회·재발급
- 업로드 성공 후 `roomId`와 `clientId`를 포함한 Web handoff 링크 제공
- 카메라·로컬 네트워크 권한 안내 및 업로드/네트워크 오류의 사용자 친화적 표시

## 요구 사항

- macOS에서 Xcode 16 이상 권장
- iOS/iPadOS 16.0 이상
- RoomPlan 실스캔은 지원 기기와 카메라 권한 필요

LiDAR 또는 RoomPlan을 지원하지 않는 기기에서도 샘플 방·수동 입력으로 업로드 흐름을 확인할 수 있습니다.

## 실행

1. Xcode에서 `RoomFit.xcodeproj`를 엽니다.
2. `RoomFit` scheme을 선택합니다.
3. iOS 16 이상 시뮬레이터 또는 실제 기기에서 Run합니다.

실제 RoomPlan 스캔은 지원되는 실제 기기에서 검증해야 합니다. 시뮬레이터에서는 샘플/수동 입력 경로를 사용하세요.

## Backend 및 Web 연동

연결 주소는 [`RoomFit/BackendConfig.swift`](RoomFit/BackendConfig.swift)에 한곳에서 정의합니다.

| 용도 | 기본 설정 |
|---|---|
| Backend API | `https://roomfit-backend.onrender.com` |
| Web handoff | `https://roomfit-web-tau.vercel.app` |
| 방 업로드 | `POST /api/rooms/upload` |
| 페어링 코드 | `POST /api/clients/pairing-code` |
| 코드 재발급 | `POST /api/clients/pairing-code/regenerate` |

로컬 Backend를 테스트할 때만 `BackendConfig.baseURL`을 개발 머신의 접근 가능한 주소로 임시 변경하세요. Release/Archive 전에는 반드시 Production 주소로 되돌려야 하며, API 키·DB 비밀번호 같은 secret을 앱 코드 또는 plist에 넣으면 안 됩니다.

## 데이터 및 개인정보

- 앱은 로그인 토큰이 아닌 익명 UUID 기반 `X-RoomFit-Client-Id` 헤더를 사용합니다.
- 업로드 이력과 연관된 JSON·USDZ·썸네일은 기기의 앱 Documents 영역에 저장됩니다.
- 앱 삭제 후 재설치하면 로컬 Client ID와 이력이 새로 생성될 수 있습니다.
- 카메라 사용 목적은 [`RoomFit/Info.plist`](RoomFit/Info.plist)에 명시되어 있습니다.

## 관련 저장소

- [RoomFit Backend](https://github.com/Roomfit-AI/RoomFit-Backend)
- [RoomFit Web](https://github.com/Roomfit-AI/RoomFit-Web)
