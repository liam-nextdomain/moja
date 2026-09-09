import Foundation
import ServiceManagement

/// 로그인 시 자동 실행 (FR-9).
///
/// `SMAppService`는 앱의 **코드 서명**에 등록을 묶는다. ad-hoc 서명은 빌드할 때마다
/// 서명이 달라지므로, 개발 중에는 등록이 끊기는 것이 정상이다. 배포판에서는
/// 서명이 고정되므로 문제가 없다.
@MainActor
enum LoginItem {

    /// 지금 등록돼 있는가.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자가 시스템 설정에서 막아 두었는가.
    ///
    /// 이 경우 앱에서 다시 켤 수 없다. 시스템 설정으로 안내해야 한다.
    static var isBlockedBySystemSettings: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// 등록하거나 해제한다. 실패하면 이유를 문구로 돌려준다.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if isBlockedBySystemSettings {
                return "시스템 설정 → 일반 → 로그인 항목에서 Moja를 켜 주세요."
            }
            return "자동 실행을 설정하지 못했습니다. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도해 주세요."
        }
    }

    /// 시스템 설정의 로그인 항목 화면을 연다.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
