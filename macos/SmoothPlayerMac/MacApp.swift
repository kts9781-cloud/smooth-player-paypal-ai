import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct SmoothPlayerMacApp: App {
    init() {
        if MacAppStorage.isDemo && UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) == nil {
            AppLanguage.shared.select("en")
        } else { AppLanguage.shared.activate() }
    }
    @StateObject private var model = MacPlayerModel()
    @StateObject private var playerWindow = MacWindowController()
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var startupChecked = false

    var body: some Scene {
        Window(MacAppStorage.isDemo ? "Smooth Player · Sandbox Demo" : "Smooth Player", id: "player") {
            MacPlayerView(model: model, playerWindow: playerWindow)
                .environment(\.locale, AppLanguage.shared.locale)
                .frame(minWidth: 980, minHeight: 580)
                .onAppear {
                    delegate.connect(model)
                }
                .task {
                    guard !startupChecked else { return }
                    startupChecked = true
                    await MacSelfTest.runIfRequested(model: model, playerWindow: playerWindow)
                }
                .task { if !CommandLine.arguments.contains("--self-test") { await model.account.start() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    guard !CommandLine.arguments.contains("--self-test") else { return }
                    Task { await model.account.refresh() }
                }
                .onDisappear { model.close() }
        }
        .defaultSize(width: 1220, height: 780)
        .windowStyle(.titleBar)
        .commands { MacPlayerCommands(model: model, playerWindow: playerWindow) }
        Settings {
            NavigationStack {
                Form {
                    if model.account.isAdmin {
                        Section(SPText("관리자 · 전체 기능 무료")) {
                            NavigationLink(SPText("관리자 현황 · 가입자·구독·결제")) { AdminOverviewView(account: model.account) }
                                .accessibilityIdentifier("openAdminOverview")
                        }
                    }
                    Section(SPText("계정 · 이용권")) {
                        NavigationLink { AccountView(account: model.account) } label: {
                            AccountEntryLabel(account: model.account)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(model.account.session == nil ? SPText("로그인 · 이용권 연결") : SPText("계정 · 이용권"))
                            .accessibilityValue(model.account.session?.email ?? SPText("다른 기기에서도 같은 이용권을 사용하세요."))
                            .accessibilityIdentifier("openAccount")
                        if let email = model.account.session?.email { Text(email).foregroundStyle(.secondary) }
                    }
                    Section(SPText("앱 소개 및 공유")) {
                        AppPromotionActions()
                    }
                    Section(SPText("TV로 보기")) {
                        Text(SPText("Mac의 제어 센터 → 화면 미러링에서 TV를 선택하세요."))
                        Text(SPText("고화질·고프레임 TV 전송에는 5GHz Wi-Fi를 권장합니다. 끊기면 같은 공유기의 5GHz 연결과 신호 상태를 확인해 주세요."))
                            .foregroundStyle(.secondary).accessibilityIdentifier("tvWifiGuidance")
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(SPText("설정"))
                .task { await model.account.refresh() }
            }
            .environment(\.locale, AppLanguage.shared.locale)
            .frame(width: 760, height: 680)
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: MacPlayerModel?
    private var pendingURLs: [URL] = []

    func connect(_ model: MacPlayerModel) {
        self.model = model
        if !pendingURLs.isEmpty {
            let urls = pendingURLs; pendingURLs.removeAll()
            Task { await model.open(urls: urls) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let model { Task { await model.open(urls: files) } }
        else { pendingURLs.append(contentsOf: files) }
        application.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.close() }
}

@MainActor
enum MacFilePanels {
    static var demoURL: URL? { Bundle.main.url(forResource: "smooth-preview", withExtension: "mp4") }

    static func playDemo(_ model: MacPlayerModel) {
        guard let url = demoURL else { return }
        Task { await model.open(urls: [url]) }
    }

    static func showGuide() {
        let alert = NSAlert()
        alert.messageText = SPText("Smooth Player 사용 안내")
        alert.informativeText = SPText("⌘O로 동영상이나 폴더를 열거나, Finder에서 이 창으로 끌어 놓으세요. Finder에 연결된 NAS도 같은 방법으로 열 수 있습니다. 왼쪽 ‘FTP 연결’에서 서버를 직접 열 수도 있습니다. 원본 파일은 이동하거나 복사하지 않습니다.\n\nSpace: 재생·일시정지\n← / →: 10초 이전·이후\n↑ / ↓: 음량 조절\n⌃⌘F 또는 영상 더블 클릭: 전체 화면\nEscape: 전체 화면에서 돌아오기\n⇧⌘S: 자막 파일 열기\n\n전체 화면에서는 마우스를 움직이면 조작부가 나타나고, 잠시 후 자동으로 숨겨집니다. 아래의 ‘부드럽게’와 ‘화질’에서 효과를 선택할 수 있습니다. 실제 적용 상태는 조작부와 화질 패널에서 확인하세요. 자막 메뉴에서는 외부 파일이나 영상의 내장 자막을 선택합니다.")
        alert.informativeText = alert.informativeText.replacingOccurrences(of: "⌃⌘F", with: "Enter / ⌃⌘F")
        alert.addButton(withTitle: SPText("확인"))
        alert.runModal()
    }

    static func openLicenses() {
        if let url = Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt"),
           NSWorkspace.shared.open(url) { return }
        let alert = NSAlert()
        alert.messageText = SPText("라이선스 문서를 열지 못했습니다")
        alert.informativeText = SPText("앱에 포함된 OpenSourceNotices.txt를 열지 못했습니다. 설치본을 다시 확인해 주세요.")
        alert.addButton(withTitle: SPText("확인"))
        alert.runModal()
    }

    static func openMedia(_ model: MacPlayerModel, foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = foldersOnly ? SPText("동영상 폴더 열기") : SPText("동영상 열기")
        panel.message = SPText("원본 위치에서 재생합니다. Finder에 연결된 NAS 폴더도 선택할 수 있습니다.")
        panel.prompt = SPText("열기")
        panel.canChooseFiles = !foldersOnly
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        present(panel) { urls in Task { await model.open(urls: urls) } }
    }

    static func openSubtitle(_ model: MacPlayerModel) {
        let panel = NSOpenPanel()
        panel.title = SPText("자막 파일 열기")
        panel.prompt = SPText("자막 열기")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "smi", "sami", "ass", "ssa", "vtt"]
            .compactMap { UTType(filenameExtension: $0) }
        present(panel) { urls in
            guard let url = urls.first else { return }
            Task { await model.loadSubtitle(url) }
        }
    }

    private static func present(_ panel: NSOpenPanel, selected: @escaping ([URL]) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { selected(panel.urls) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
}

@MainActor
private struct MacPlayerCommands: Commands {
    @ObservedObject var model: MacPlayerModel
    @ObservedObject var playerWindow: MacWindowController

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Menu(SPText("언어 / Language")) {
                Picker(SPText("앱 언어"), selection: Binding(get: { AppLanguage.shared.selection }, set: { AppLanguage.shared.select($0) })) {
                    ForEach(AppLanguage.choices, id: \.id) { language in
                        Text(language.id == "system" ? SPText("기기 언어 사용") : language.name).tag(language.id)
                    }
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(SPText("동영상 열기…")) { MacFilePanels.openMedia(model) }
                .keyboardShortcut("o", modifiers: .command)
            Button(SPText("폴더 열기…")) { MacFilePanels.openMedia(model, foldersOnly: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            if MacFilePanels.demoURL != nil {
                Button(SPText("예제 영상 재생")) { MacFilePanels.playDemo(model) }
            }
            Divider()
            Button(SPText("자막 열기…")) { MacFilePanels.openSubtitle(model) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.currentID == nil || model.isLoading)
        }
        CommandMenu(SPText("재생")) {
            // Unmodified Space/arrow keys are handled only in the player window,
            // outside text input and system panels, by MacPlayerKeyboardMonitor.
            Button(model.isPlaying ? SPText("일시정지 (Space)") : SPText("재생 (Space)")) { model.togglePlayback() }
                .disabled(model.currentID == nil || model.isLoading)
            Button(SPText("10초 이전 (←)")) { Task { await model.seek(to: max(0, model.position - 10)) } }
                .disabled(model.duration <= 0)
            Button(SPText("10초 이후 (→)")) { Task { await model.seek(to: min(model.duration, model.position + 10)) } }
                .disabled(model.duration <= 0)
            Divider()
            Button(SPText("이전 영상")) { Task { await model.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!canMove(-1))
            Button(SPText("다음 영상")) { Task { await model.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!canMove(1))
            Divider()
            Button(model.smoothEnabled ? SPText("부드럽게 끄기") : SPText("부드럽게 켜기")) {
                Task { await model.setSmooth(!model.smoothEnabled) }
            }.disabled(model.currentID == nil || model.isLoading)
        }
        CommandGroup(before: .windowArrangement) {
            Button(playerWindow.isFullscreen ? SPText("전체 화면 종료") : SPText("전체 화면 시작")) { playerWindow.toggleFullscreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .help) {
            Button(SPText("Smooth Player 사용 안내")) { MacFilePanels.showGuide() }
            Button(SPText("오픈소스 라이선스")) { MacFilePanels.openLicenses() }
        }
    }

    private func canMove(_ offset: Int) -> Bool {
        guard let index = model.playlist.firstIndex(where: { $0.id == model.currentID }) else { return false }
        return model.playlist.indices.contains(index + offset)
    }
}
