// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
#if AIRRECORD_AUTOMATION
import SwiftUI

private enum AirRecordTab: Hashable {
    case home, settings, activity, contact
}

/// Navigation stays separate from monitoring: switching tabs never changes a
/// location session, a pending recording reservation, or the saved preference.
@MainActor
struct AirRecordGlassView: View {
    @StateObject private var monitor = AirRecordMonitor.shared
    @StateObject private var standby = AirRecordLocationKeepAlive.shared
    @StateObject private var standbyAlert = AirRecordStandbyAlert.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab = AirRecordTab.home
    @State private var showCompactHomeTitle = false
    @State private var showMount = false
    @State private var shortcutOpeningError: String?

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.52, blue: 0.65)
            : Color(red: 0.76, green: 0.20, blue: 0.36)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "Ver v\(name) 빌드 \(build) - 알파"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("홈", systemImage: "waveform", value: AirRecordTab.home) {
                NavigationStack { homeScreen }
            }
            Tab("설정", systemImage: "slider.horizontal.3", value: AirRecordTab.settings) {
                NavigationStack { settingsScreen }
            }
            Tab("기록", systemImage: "clock.arrow.circlepath", value: AirRecordTab.activity) {
                NavigationStack { activityScreen }
            }
            Tab("문의", systemImage: "bubble.left.and.bubble.right", value: AirRecordTab.contact) {
                NavigationStack {
                    AirRecordContactView(accent: accent, version: version,
                                         diagnosticSummary: monitor.diagnosticSummary,
                                         isSelected: selectedTab == .contact)
                }
            }
        }
        .tint(accent)
        // The system draws the floating Liquid Glass tab bar, including its
        // accessibility, contrast, and Reduce Transparency adaptations.
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showMount) { DDIMountView() }
        .task { await monitor.resumeIfEnabled() }
        .task(id: scenePhase) {
            if scenePhase == .active { await standbyAlert.refreshPermission() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await monitor.resumeIfEnabled() } }
            if phase == .background { monitor.appDidEnterBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.resumeIfEnabled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            monitor.appDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            standbyAlert.reportTermination()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
            standby.refreshEnvironment()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            standby.refreshEnvironment()
        }
    }

    private var homeScreen: some View {
        AirRecordPage(accent: accent) {
            brandHeader
                .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                    showCompactHomeTitle = !isVisible
                }
            monitoringCard
            standbySummary
            AirRecordShortcutStatusView(accent: accent)
            AirRecordShortcutStatusView(accent: accent, kind: .incoming)
            AirRecordShortcutStatusView(accent: accent, kind: .end)
            AirRecordPlannedFeatureView(title: "AirRec 메모 이름 수정", systemImage: "note.text", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep (통화 녹음 고지 제거)", systemImage: "speaker.slash", accent: accent)
            AirRecordPlannedFeatureView(title: "AirBeep2 (통화 녹음 카운트다운 제거)", systemImage: "timer", accent: accent)
        }
        .navigationTitle(showCompactHomeTitle ? "AirRec" : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image("AirRecordMark")
                    .resizable().scaledToFit()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("AirRec")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                AirRecordVersionLabel(version: version)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var monitoringCard: some View {
        AirRecordCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: monitor.isRunning ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(monitor.isRunning ? Color.green : accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(monitoringTitle)
                        .font(.title2.weight(.bold))
                    Text(monitor.isRunning ? "AirRec 일하는 중 🧐" : "AirRec 쉬는 중 😴")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if monitor.activationError != nil || monitor.isPreparing || (monitor.isEnabled && !monitor.isRunning) {
                Text(monitor.status)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            monitoringControls
        }
    }

    private var monitoringTitle: String {
        if monitor.activationError != nil { return "AirRec 404 Error" }
        if monitor.isPreparing { return "AirRec 연결 중" }
        if monitor.isRunning { return "AirRec 활성화됨" }
        return monitor.isEnabled ? "AirRec 404 Error" : "AirRec 비활성화됨"
    }

    @ViewBuilder
    private var monitoringControls: some View {
        if monitor.isRunning && monitor.activationError == nil {
            Button(role: .destructive) { monitor.stop() } label: {
                Label("AirRec 비활성화", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        } else {
            Button { Task { await monitor.start() } } label: {
                HStack(spacing: 8) {
                    if monitor.isPreparing { ProgressView().controlSize(.small) }
                    Text(monitor.isPreparing ? "연결 중…" : "AirRec 활성화")
                        .fontWeight(.semibold)
                    if !monitor.isPreparing { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(monitor.isPreparing)
            if monitor.activationError == nil && monitor.isPreparing {
                Button("AirRec 비활성화", role: .destructive) { monitor.stop() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var standbySummary: some View {
        AirRecordCard {
            AirRecordStatusRow(title: "백그라운드 AirRec", systemImage: "location.fill",
                               isConfirmed: standby.isRunning && monitor.isRunning, accent: accent,
                               accessibilityValue: standby.isRunning && monitor.isRunning ? "활성화됨" : "비활성화됨")
        }
    }

    private var settingsScreen: some View {
        AirRecordPage(accent: accent) {
            preparationCard
            backgroundCard
            shortcutCard
            incomingCard
            AirRecordVersionLabel(version: version)
                .font(.footnote)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
    }

    private var preparationCard: some View {
        AirRecordCard {
            AirRecordHeading("AirRec 초기 설정", systemImage: "checklist", tint: accent)
            Divider()
            Text("LocalDevVPN 연결과 개발자 디스크 준비를 마친 뒤 AirRec을 활성화하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showMount = true } label: {
                Label("페어링 파일 · 개발자 디스크", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            DisclosureGroup("AirRec 초기 설정이란?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AirRec이 이 아이폰의 개발자 서비스에 연결할 수 있도록 페어링 파일과 개발자 디스크를 준비하는 과정입니다.")
                    AirRecordInfoRow("1. 페어링 파일 가져오기", value: "iLoader 또는 idevice_pair 등으로 준비한 RemotePairing 파일을 선택하세요. Windows PC에서 만든 파일도 사용할 수 있습니다. 개인 페어링 파일은 다른 사람에게 공유하지 마세요.")
                    AirRecordInfoRow("2. 개발자 디스크 다운로드", value: "셀룰러 데이터를 끄거나 VPN을 연결하기 전에 디스크 파일을 다운로드하세요. 다운로드한 파일은 다음 연결에도 다시 사용합니다.")
                    AirRecordInfoRow("3. LocalDevVPN 연결", value: "LocalDevVPN을 연결하고 이 화면의 연결 확인 결과를 확인하세요. Wi-Fi가 없을 때는 셀룰러 데이터를 잠시 끈 연결을 시험할 수 있습니다. 직접 데이터를 껐다면 준비를 마친 뒤 다시 켜 주세요.")
                    AirRecordInfoRow("4. 개발자 디스크 연결", value: "‘개발자 디스크 연결’을 누르고 성공할 때까지 기다리세요. 처음 연결할 때는 인터넷이 필요할 수 있습니다. 준비가 끝나면 홈에서 AirRec을 활성화하세요.")
                    AirRecordInfoRow("다시 준비해야 할 때", value: "아이폰을 재부팅하면 개발자 디스크를 다시 연결해야 합니다. 연결 오류가 나면 LocalDevVPN과 페어링 파일 상태를 확인하세요. 실행 중에도 LocalDevVPN 연결이 필요합니다.")
                    AirRecordInfoRow("첫 통화 확인", value: "아이폰의 잠금을 해제한 상태에서 먼저 시험하고, 실제 녹음 타이머와 메모 앱의 저장 결과를 확인하세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var backgroundCard: some View {
        AirRecordCard {
            AirRecordHeading("백그라운드 AirRec", systemImage: "location.fill", tint: accent)
            Divider()
            Toggle("백그라운드 AirRec 활성화", isOn: Binding(
                get: { standby.isEnabled },
                set: { enabled in Task { await monitor.setLocationStandbyEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(monitor.isPreparing || (standby.isLiveContainer && !standby.isEnabled))
            if standby.isLiveContainer {
                Label("백그라운드 기능은 SideStore에 독립 설치한 앱에서 사용하세요.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if standby.isEnabled {
                Divider()
                Toggle("다이내믹 아일랜드 위치 표시 숨기기", isOn: Binding(
                    get: { standby.indicatorMinimizationEnabled },
                    set: { standby.setIndicatorMinimizationEnabled($0) }
                ))
                .font(.headline)
                .disabled(monitor.isPreparing || standby.isLiveContainer)
                if standby.indicatorMinimizationEnabled {
                    indicatorPermissionControls
                }
            }
            Divider()
            Toggle("앱 종료 알림", isOn: Binding(
                get: { standbyAlert.isEnabled },
                set: { enabled in Task { await standbyAlert.setEnabled(enabled) } }
            ))
            .font(.headline)
            .disabled(standbyAlert.isRequestingPermission || standby.isLiveContainer)
            Text("홈에서 AirRec이 활성화되고 백그라운드 AirRec에 체크가 있을 때 알림을 예약합니다. iOS가 종료 신호를 전달하지 않으면 마지막 상태 확인에서 약 3분 뒤에 알립니다.")
                .font(.footnote).foregroundStyle(.secondary)
            if standbyAlert.isEnabled {
                Button("알림 테스트", systemImage: "bell.badge") {
                    Task { await standbyAlert.sendTestNotification() }
                }
                .font(.subheadline.weight(.semibold))
                if let message = standbyAlert.testMessage {
                    Text(message)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if standbyAlert.needsPermission {
                Text("iOS 설정에서 알림과 배너를 허용해 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("알림 설정 열기", systemImage: "arrow.up.forward.app") {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.subheadline.weight(.semibold))
            }
            Divider()
            Button { openAppSettings() } label: {
                Label("AirRec 설정 열기", systemImage: "arrow.up.forward.app")
            }
            .font(.subheadline.weight(.semibold))
            Divider()
            backgroundDetails
        }
    }

    @ViewBuilder
    private var indicatorPermissionControls: some View {
        if standby.hasAlwaysAuthorization {
            Label("항상 허용 확인됨", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.green)
        } else {
            Text("위치 표시를 숨기려면 위치 권한을 ‘항상 허용’으로 설정해야 합니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { standby.requestAlwaysAuthorization() } label: {
                Label("항상 허용 요청", systemImage: "hand.raised")
            }
            .font(.subheadline.weight(.semibold))
            .disabled(monitor.isPreparing || standby.isLiveContainer)
            Text("권한 창이 나타나지 않으면 iOS 설정에서 변경해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var backgroundDetails: some View {
        DisclosureGroup("백그라운드 AirRec이란?") {
            VStack(alignment: .leading, spacing: 12) {
                AirRecordInfoRow("어떤 기능인가요?", value: "다른 앱을 사용하거나 화면이 꺼진 동안에도 통화 상태를 확인할 수 있도록 AirRec의 대기를 유지합니다.")
                AirRecordInfoRow("위치 권한은 왜 필요한가요?", value: "iOS의 백그라운드 위치 기능을 이용합니다. 위치 업데이트는 받지만 좌표는 읽거나 저장·전송하지 않고, 업데이트 시각만 확인합니다.")
                AirRecordInfoRow("어떻게 시작하나요?", value: "이 옵션을 켜고 홈에서 AirRec을 활성화하세요. ‘앱을 사용하는 동안 허용’을 선택한 뒤 연결 준비가 끝날 때까지 앱을 열어 두세요.")
                AirRecordInfoRow("‘항상 허용’도 필요한가요?", value: "기본 대기에는 정밀 위치나 ‘항상 허용’이 필요하지 않습니다. ‘다이내믹 아일랜드 위치 표시 숨기기’를 사용하려면 ‘항상 허용’이 필요합니다. 표시 여부는 iOS가 관리하므로 모든 위치·개인정보 표시가 사라지는 것은 아닙니다.")
                AirRecordInfoRow("사용할 때 알아두세요", value: "위치 사용 표시와 배터리 소모가 생길 수 있습니다. iOS가 실행을 중단할 수 있으며, 앱을 강제 종료하거나 기기를 재부팅했다면 다시 열어 활성화하세요. AirRec을 비활성화하면 위치 업데이트도 중지합니다.")
                Divider()
                AirRecordInfoRow("현재 대기 상태", value: standby.status)
                AirRecordInfoRow("현재 위치 권한", value: standby.authorizationText)
                Text(standby.indicatorStatusText)
                if !standby.isEnabled {
                    Text("백그라운드 기능을 켜기 전에 위치 권한을 준비할 수 있습니다.")
                    indicatorPermissionControls
                }
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        }
        .font(.subheadline)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var shortcutCard: some View {
        AirRecordCard {
            AirRecordHeading("AirRec 자동화", systemImage: "square.stack.3d.up", tint: accent)
            Divider()
            Link(destination: URL(string: "https://www.icloud.com/shortcuts/b888fa97da424299aa6cc67cbc4c7402")!) {
                Label("AirRec(발신) 단축어 추가", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            Button("추가한 단축어 열기", systemImage: "arrow.up.forward.app") { openOutgoingShortcut() }
                .font(.subheadline.weight(.semibold))
            if let shortcutOpeningError {
                Text(shortcutOpeningError).font(.footnote).foregroundStyle(.orange)
            }
            Divider()
            Button("실시간 현황 설정 열기", systemImage: "livephoto") { openAppSettings() }
                .font(.subheadline.weight(.semibold))
            Text("다이내믹 아일랜드 진행 표시는 iOS의 ‘실시간 현황’ 설정에서 관리합니다. 단축어에서 표시되는 경우 설정의 ‘단축어’ 항목도 확인해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("AirRec 자동화란?") {
                VStack(alignment: .leading, spacing: 12) {
                    if standby.isLiveContainer {
                        Text("AirRec을 SideStore에 독립 설치한 뒤 단축어 동작을 사용하세요.")
                    }
                    AirRecordInfoRow("1. 준비하기", value: "AirRec 초기 설정을 마치고 백그라운드 AirRec과 홈의 AirRec을 활성화하세요. 단축어를 추가한 뒤, 단축어 앱의 자동화에서 ‘전화 앱이 열릴 때’ LocalDevVPN을 연결하고 ‘AirRec(발신)’을 실행하도록 설정하세요.")
                    AirRecordInfoRow("2. Wi-Fi 확인하기", value: "Wi-Fi 네트워크 이름이 있으면 셀룰러 설정을 그대로 두세요. 이름이 비어 있을 때만 AirRec의 ‘발신’ 동작을 실행하세요.")
                    AirRecordInfoRow("3. 발신을 감지하면 데이터 끄기", value: "‘발신’의 최대 대기 시간에 1~180초를 입력할 수 있습니다. 기본값은 20초이며, 25초를 넘기면 대기 중 iOS 진행 표시가 나타날 수 있습니다. 결과가 ‘예’일 때만 ‘셀룰러 데이터 끄기 → 발신종료 → 셀룰러 데이터 켜기’를 실행하세요.")
                    AirRecordInfoRow("4. 통화가 끝나면 데이터 복구하기", value: "‘발신종료’는 활성 통화가 모두 끝날 때까지 기다립니다. 기본 60분, 최대 180분이며 대기 중 진행 표시가 나타납니다. 시간 초과에도 데이터를 복구하도록 ‘켜기’는 종료 결과와 관계없이 실행하세요. 단축어가 중단됐다면 데이터를 직접 켜 주세요.")
                    AirRecordInfoRow("첫 통화 확인", value: "발신 감지는 단축어에서 따로 시험할 수 있습니다. 실제 녹음은 전화 화면의 타이머와 메모 앱에서 확인하세요. 전화 앱을 닫아도 통화는 이어질 수 있으므로 앱이 닫힐 때 VPN을 끄도록 설정하면 녹음 준비가 끊길 수 있습니다.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private var incomingCard: some View {
        AirRecordCard {
            AirRecordHeading("수신 자동화 (실험)", systemImage: "phone.arrow.down.left", tint: accent)
            Divider()
            Toggle("잠금 상태 통화도 녹음 시도", isOn: Binding(
                get: { monitor.allowsLockedAttempts },
                set: { monitor.setAllowsLockedAttempts($0) }
            ))
            .font(.headline)
            Text("기본 AirRec은 잠금이 풀린 상태에서만 녹음 버튼을 누릅니다. 켜면 잠금 화면에서 받은 전화도 시도합니다. 실기기에서 아직 검증하지 않은 기능입니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Toggle("녹음 준비 시간 60초", isOn: Binding(
                get: { monitor.extendsPreparationWindow },
                set: { monitor.setExtendsPreparationWindow($0) }
            ))
            .font(.headline)
            Text("통화가 연결된 뒤 녹음 버튼을 찾는 시간을 20초에서 60초로 늘립니다. 전화를 받고 늦게 잠금을 풀어도 녹음을 시작할 수 있습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("수신 자동화란?") {
                VStack(alignment: .leading, spacing: 12) {
                    AirRecordInfoRow("Wi-Fi에서는", value: "LocalDevVPN이 연결돼 있고 홈과 백그라운드 AirRec이 켜져 있으면 단축어 없이도 받은 전화의 녹음을 시작합니다. 설정 > 앱 > 전화 > 수신 전화를 ‘전체 화면’으로 두세요.")
                    AirRecordInfoRow("셀룰러에서는", value: "‘수신’ 동작은 새 수신 전화가 울리면 예를 반환합니다. Wi-Fi가 없을 때만 ‘셀룰러 데이터 끄기 → 발신종료 → 셀룰러 데이터 켜기’를 실행하고, 이 과정을 반복하는 단축어를 만드세요.")
                    AirRecordInfoRow("인터넷 통화", value: "‘일반 전화만’을 켜 두면 보이스톡·FaceTime 같은 통화에는 예를 반환하지 않아 데이터가 꺼지지 않습니다. 일반 전화도 감지하지 못하면 기록 탭을 확인한 뒤 이 옵션을 끄고 시험하세요.")
                    AirRecordInfoRow("수동으로 쓸 때", value: "뒷면 탭에 ‘셀룰러 데이터 끄기 → 발신종료 → 셀룰러 데이터 켜기’ 단축어를 연결하고 전화가 울릴 때 또는 받은 직후에 실행하세요.")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private func openOutgoingShortcut() {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: AirRecordShortcutPresence.targetName)]
        guard let url = components.url else { return }
        shortcutOpeningError = nil
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in
                if !opened { shortcutOpeningError = "단축어 앱을 열지 못했습니다." }
                // Opening the editor does not prove that the shortcut exists.
            }
        }
    }

    private var activityScreen: some View {
        AirRecordPage(accent: accent) {
            AirRecordCard {
                AirRecordHeading("최근 실행 기록", systemImage: "clock.arrow.circlepath", tint: accent)
                if monitor.recentEvents.isEmpty {
                    ContentUnavailableView("아직 기록이 없습니다", systemImage: "clock",
                                           description: Text("AirRec을 활성화하면 실행 상태가 여기에 표시됩니다."))
                } else {
                    ForEach(Array(monitor.recentEvents.enumerated().reversed()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(accent.opacity(0.6)).frame(width: 7, height: 7)
                                .padding(.top, 7).accessibilityHidden(true)
                            Text(entry.element)
                                .font(.subheadline).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                        if entry.offset != 0 { Divider() }
                    }
                }
            }
            AirRecordCard {
                DisclosureGroup("상태 정보 자세히 보기") {
                    Text(monitor.diagnosticSummary)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                ShareLink(item: monitor.diagnosticSummary) {
                    Label("상태 기록 공유", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .navigationTitle("기록")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct AirRecordPage<Content: View>: View {
    let accent: Color
    let content: Content

    init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 28)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                LinearGradient(colors: [accent.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .center)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
}

struct AirRecordCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct AirRecordHeading: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Home status cards share typography and spacing without adding card padding.
struct AirRecordStatusRow: View {
    let title: String
    let systemImage: String
    let isConfirmed: Bool
    let accent: Color
    let accessibilityValue: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: isConfirmed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isConfirmed ? Color.green : Color.secondary)
                .accessibilityHidden(true)
        }
        .font(.headline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isHeader)
    }
}

struct AirRecordInfoRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) { self.title = title; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
