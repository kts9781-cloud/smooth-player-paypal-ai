import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

enum MacDeck {
    static let background = Color(red: 27 / 255, green: 29 / 255, blue: 31 / 255)
    static let panel = Color(red: 33 / 255, green: 35 / 255, blue: 37 / 255)
    static let raised = Color(red: 42 / 255, green: 44 / 255, blue: 46 / 255)
    static let amber = Color(red: 214 / 255, green: 179 / 255, blue: 95 / 255)
    static let text = Color(red: 233 / 255, green: 233 / 255, blue: 230 / 255)
    static let muted = Color(red: 159 / 255, green: 162 / 255, blue: 164 / 255)
    static let line = Color.white.opacity(0.08)

    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(359_999, max(0, seconds))) : 0
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

@MainActor
struct MacPlayerView: View {
    @ObservedObject var model: MacPlayerModel
    @ObservedObject var playerWindow: MacWindowController
    @StateObject private var network = MacNetworkBrowserModel()
    @AppStorage("mac.sidebarVisible") private var sidebarVisible = true
    @State private var dropTargeted = false
    @State private var showingQuality = false
    @State private var showingSound = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var previousVolume = 0.75
    @State private var showingNetwork = false
    @State private var showingAccount = false
    @State private var showingNASUnlock = false
    @State private var nasPIN = ""
    @State private var nasPINConfirmation = ""
    @State private var nasPINMessage: String?
    @State private var videoViewport = VideoViewport()
    @GestureState private var pinch: MagnifyGesture.Value?
    @GestureState private var pictureDrag = CGSize.zero

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible && !playerWindow.isFullscreen {
                sidebar.frame(width: 260)
                Rectangle().fill(MacDeck.line).frame(width: 1)
            }
            VStack(spacing: 0) {
                if !playerWindow.isFullscreen { header }
                // Keep this surface in the same structural slot across full-screen
                // transitions. Only its layout changes; the decoder/MTKView survives.
                videoCanvas
                if !playerWindow.isFullscreen { transport }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacDeck.background)
        .foregroundStyle(MacDeck.text).tint(MacDeck.amber).preferredColorScheme(.dark)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(MacDeck.amber, lineWidth: 2)
                    .padding(7).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
        .background(MacPlayerKeyboardMonitor(model: model, playerWindow: playerWindow))
        .onChange(of: model.currentID) { _, _ in scrubbing = false; scrubPosition = 0 }
        .onChange(of: scrubbing) { _, held in playerWindow.setControlsHeld(held, reason: "scrubbing") }
        .onChange(of: showingSound) { _, held in playerWindow.setControlsHeld(held, reason: "sound") }
        .onChange(of: showingQuality) { _, held in playerWindow.setControlsHeld(held, reason: "quality") }
        .onChange(of: model.isPlaying) { _, playing in
            playerWindow.setControlsHeld(!playing, reason: "paused")
            if playing { NASVideoThumbnails.shared.cancelPending() }
        }
        .onChange(of: model.account.session?.userId) { _, _ in
            model.closeNetworkPlaylist()
        }
        .onChange(of: network.privacy.unlocked) { _, unlocked in
            if !unlocked { model.enforceNetworkPrivacy(network.privacy) }
        }
        .onAppear { playerWindow.setControlsHeld(!model.isPlaying, reason: "paused") }
        .task { await attachAccountSync() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in network.privacy.lock() }
        .sheet(isPresented: $showingNASUnlock) {
            VStack(spacing: 16) {
                Text(network.privacy.hasPIN ? SPText("숨긴 NAS 항목 열기") : SPText("이 Mac의 폴더 암호 설정")).font(.headline)
                SecureField(SPText("숫자 4자리"), text: $nasPIN)
                if !network.privacy.hasPIN { SecureField(SPText("암호 다시 입력"), text: $nasPINConfirmation) }
                if let nasPINMessage { Text(nasPINMessage) }
                Button(SPText("확인")) { Task {
                    nasPINMessage = await network.privacy.unlock(pin: nasPIN, confirmation: nasPINConfirmation)
                    nasPIN = ""; nasPINConfirmation = ""
                    if nasPINMessage == nil { showingNASUnlock = false }
                } }
                Button(SPText("닫기")) { showingNASUnlock = false }
            }.padding(24).frame(width: 350)
        }
        .sheet(isPresented: $showingNetwork) {
            if model.account.nasSync?.accessReady == true { MacNetworkBrowserView(model: network) { selection in
                Task { await model.openNetwork(selection) }
            }.onDisappear { network.close() } } else { Text(SPText("NAS 계정 정보를 확인하고 있습니다.")).padding(30) }
        }
        .sheet(isPresented: $showingSound) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(SPText("사운드")).font(.title2)
                    SoundControls(profile: $model.sound,
                        outputTarget: Binding(get: { model.soundTarget }, set: { model.selectSoundTarget($0) }),
                        comparison: $model.soundComparison,
                        audioSync: Binding(get: { model.audioSyncHundredths }, set: { model.setAudioSyncHundredths($0) }),
                        audioSyncDeviceName: model.audioSyncOutput?.name ?? SPText("출력 기기 확인 중"),
                        audioSyncEnabled: model.audioSyncOutput != nil)
                        .onAppear { model.refreshAudioSyncOutput() }
                    HStack { Spacer(); Button(SPText("완료")) { showingSound = false } }
                }.padding(24)
            }.frame(width: 550, height: 680).background(MacDeck.background)
                .onDisappear { model.soundComparison = .off }
        }
        .sheet(isPresented: $showingAccount) {
            VStack {
                if model.account.configuration?.environment == "test" {
                    Text(SPText("테스트 계정 · 실제 요금은 청구되지 않습니다."))
                        .font(.callout).foregroundStyle(MacDeck.amber).padding(.top, 20)
                }
                AccountView(account: model.account)
                Button(SPText("닫기")) { showingAccount = false }.keyboardShortcut(.cancelAction).padding(.bottom, 16)
            }.frame(width: 520, height: 560)
        }
        .alert(SPText("이용권 안내"), isPresented: Binding(get: { model.accountMessage != nil }, set: { if !$0 { model.accountMessage = nil } })) {
            Button(SPText("계정 · 이용권")) { model.accountMessage = nil; showingAccount = true }
            Button(SPText("닫기"), role: .cancel) { model.accountMessage = nil }
        } message: { Text(model.accountMessage ?? "") }
        .alert(SPText("자막 안내"), isPresented: Binding(get: { model.subtitleMessage != nil }, set: { if !$0 { model.subtitleMessage = nil } })) {
            Button(SPText("확인"), role: .cancel) { model.subtitleMessage = nil }
        } message: { Text(model.subtitleMessage ?? SPText("다른 자막 파일이나 내장 자막을 선택해 주세요.")) }
    }

    private func attachAccountSync() async {
            guard !CommandLine.arguments.contains("--self-test") else { return }
            if model.account.nasSync == nil {
                model.account.nasSync = NASAccountSync(account: model.account, namespace: "mac", snapshot: { [weak model, weak network] in
                    guard let model, let network, network.canReadStorage else { throw NASError.credentialStorage }
                    return try NASCloudAdapter.snapshot(connections: network.connections, recents: model.nasRecents, privacy: network.privacy)
                }, apply: { [weak model, weak network] values in
                    guard let model, let network else { throw NASError.credentialStorage }
                    let before = try NASCloudAdapter.snapshot(connections: network.connections, recents: model.nasRecents, privacy: network.privacy)
                    NASVideoThumbnails.shared.preserveCachedPreviews(NASPreviewIdentity.migrations(from: before, to: values))
                    let aliases = NASCloudAdapter.connectionAliases(from: before, to: values)
                    let (connections, recents, rules) = try NASCloudAdapter.decode(values)
                    try network.privacy.replaceNetworkRules(rules)
                    model.enforceNetworkPrivacy(network.privacy)
                    try network.replaceFromAccount(connections, aliases: aliases)
                    try model.nasRecents.replaceFromAccount(recents, aliases: aliases, validConnectionIDs: Set(connections.map { $0.0.id }))
                })
            }
            await model.account.nasSync?.run()
    }

    private var visibleNASRecents: [NASRecentVideo] {
        guard model.account.nasSync?.accessReady == true else { return [] }
        return model.nasRecents.videos.filter { record in
            guard let c = try? model.nasRecents.connection(for: record, in: network.connections) else { return false }
            return network.privacy.visible(FolderPrivacyStore.networkLocation(c, path: record.path))
        }
    }

    private var nasContinueWatching: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SPText("NAS 이어보기")).font(.system(size: 11, weight: .semibold)).foregroundStyle(MacDeck.muted)
                .padding(.horizontal, 6)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visibleNASRecents) { record in
                        if let connection = try? model.nasRecents.connection(for: record, in: network.connections) {
                            Button { Task {
                                NASVideoThumbnails.shared.cancelPending()
                                do { await model.openNetwork(try await network.selection(for: record, recents: model.nasRecents)) }
                                catch { model.errorMessage = SPText("NAS 영상을 열지 못했습니다. 서버 연결과 파일을 확인해 주세요.") }
                            } } label: {
                                HStack(spacing: 9) {
                                    MacNASRecentPreview(connection: connection, record: record, enabled: !model.isPlaying)
                                        .frame(width: 72, height: 46)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(record.name).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(MacDeck.time(record.position) + " / " + MacDeck.time(record.duration))
                                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(MacDeck.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(6).background(MacDeck.raised, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(height: min(224, CGFloat(visibleNASRecents.count) * 66))
        }.padding(.horizontal, 17).padding(.top, 18).accessibilityIdentifier("nasContinueWatching")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !network.privacy.hiddenFolders.isEmpty {
                Button { if network.privacy.unlocked { network.privacy.lock() } else { showingNASUnlock = true } } label: {
                    Label(SPText("NAS 숨김 항목"), systemImage: network.privacy.unlocked ? "lock.open" : "lock.fill")
                }.padding(.top, 10)
            }
            HStack(spacing: 11) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 25, weight: .light)).foregroundStyle(MacDeck.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SMOOTH").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(2.2)
                    Text("PLAYER FOR MAC").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.3)
                        .foregroundStyle(MacDeck.muted)
                }
            }.padding(.horizontal, 23).padding(.top, 25).padding(.bottom, 28)

            Button { showingAccount = true } label: {
                AccountEntryLabel(account: model.account, compact: true)
            }.buttonStyle(.plain).padding(.horizontal, 17).padding(.bottom, 12)
                .accessibilityLabel(model.account.session == nil ? SPText("로그인 · 이용권 연결") : SPText("계정 · 이용권"))
                .accessibilityValue(model.account.session?.email ?? SPText("다른 기기에서도 같은 이용권을 사용하세요."))
                .accessibilityIdentifier("openAccount")

            AppPromotionActions(compact: true).font(.caption)
                .padding(.horizontal, 17).padding(.bottom, 12)

            Button { MacFilePanels.openMedia(model) } label: {
                HStack {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text(SPText("동영상 열기")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("⌘O").font(.system(size: 11, design: .monospaced)).foregroundStyle(MacDeck.muted)
                }.padding(12).background(MacDeck.raised, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.horizontal, 17).accessibilityIdentifier("openMedia")

            Button { showingNetwork = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "network").font(.system(size: 12))
                    Text(SPText("FTP 연결")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }.padding(12).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.horizontal, 17).padding(.top, 8)
                .accessibilityIdentifier("openFTP")

            if !visibleNASRecents.isEmpty { nasContinueWatching }

            HStack {
                Text(SPText("재생목록")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.playlist.count)").font(.system(size: 11, design: .monospaced))
            }.foregroundStyle(MacDeck.muted).padding(.horizontal, 23).padding(.top, 28).padding(.bottom, 12)

            if model.playlist.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(SPText("아직 담긴 영상이 없어요")).font(.system(size: 12))
                    Text(SPText("파일이나 폴더를 이 창으로\n끌어 놓으면 시작할 수 있어요."))
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(MacDeck.muted)
                }.padding(.horizontal, 23).padding(.vertical, 12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(model.playlist.enumerated()), id: \.element.id) { index, item in
                                playlistRow(item, index: index).id(item.id)
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 15)
                    }
                    .onChange(of: model.currentID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            Rectangle().fill(MacDeck.line).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder").padding(.top, 1)
                Text(SPText("로컬 파일 · Finder에 연결된 NAS\n선택한 위치에서 바로 재생합니다."))
                    .font(.system(size: 10)).lineSpacing(4)
            }.foregroundStyle(MacDeck.muted).padding(20)
        }.background(MacDeck.panel)
    }

    private func playlistRow(_ item: MacPlaylistItem, index: Int) -> some View {
        let selected = item.id == model.currentID
        return Button { Task { await model.select(id: item.id) } } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(selected ? MacDeck.amber.opacity(0.15) : Color.white.opacity(0.04))
                    Image(systemName: selected && model.isPlaying ? "waveform" : "film")
                        .font(.system(size: 15)).foregroundStyle(selected ? MacDeck.amber : MacDeck.muted)
                }.frame(width: 39, height: 39)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(String(format: "%02d", index + 1) + "  ·  " + item.fileExtension.uppercased())
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(MacDeck.muted)
                }
                Spacer(minLength: 0)
                if selected { RoundedRectangle(cornerRadius: 1).fill(MacDeck.amber).frame(width: 2, height: 22) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.white.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(item.title).accessibilityLabel("\(index + 1). \(item.title)")
    }

    private var header: some View {
        HStack(spacing: 14) {
            iconButton("sidebar.left", SPText("재생목록 표시/숨기기")) { sidebarVisible.toggle() }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.currentID == nil ? SPText("나의 상영관") : model.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(model.currentID == nil ? "SMOOTH PLAYER" : model.sourceDescription)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(MacDeck.muted).lineLimit(1)
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(VideoScaleMode.allCases, id: \.rawValue) { mode in
                    Button { videoViewport = VideoViewport(); model.videoScaleMode = mode } label: {
                        Label(mode.label, systemImage: model.videoScaleMode == mode ? "checkmark" : "rectangle")
                    }.help(mode.hint)
                }
            } label: { Image(systemName: "aspectratio").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().help(SPText("화면 맞춤: \(model.videoScaleMode.label)"))
                .accessibilityLabel(SPText("화면 비율"))
            iconButton("arrow.up.left.and.arrow.down.right", SPText("전체 화면 · ⌃⌘F") + " · Enter") {
                playerWindow.toggleFullscreen()
            }
        }.padding(.horizontal, 22).frame(height: 66)
    }

    private var videoCanvas: some View {
        GeometryReader { geometry in
            let zoomed = pinch.map { value in
                let anchor = CGPoint(x: value.startAnchor.x, y: value.startAnchor.y)
                return videoViewport.transformed(by: value.magnification, from: anchor, to: anchor)
            } ?? videoViewport
            let viewport = zoomed.panned(x: pictureDrag.width / max(1, geometry.size.width),
                                        y: pictureDrag.height / max(1, geometry.size.height))
            ZStack {
                Color.black
                MacVideoSurface(model: model, playerWindow: playerWindow, onScrollPan: { delta in
                    guard videoViewport.scale > 1 else { return false }
                    videoViewport = videoViewport.panned(x: delta.width / max(1, geometry.size.width),
                                                         y: delta.height / max(1, geometry.size.height))
                    return true
                })
                    .scaleEffect(viewport.scale)
                    .offset(x: viewport.x * geometry.size.width, y: viewport.y * geometry.size.height)
                if model.currentID == nil { emptyPlayer }
                if let native = model.nativeSubtitles {
                    MacNativeSubtitleLayer(controller: native, mode: model.videoScaleMode)
                        .scaleEffect(viewport.scale)
                        .offset(x: viewport.x * geometry.size.width, y: viewport.y * geometry.size.height)
                }
                if let text = model.subtitleText, !text.isEmpty {
                    VStack {
                        Spacer()
                        Text(text).font(.system(size: min(32, max(18, geometry.size.width * 0.026)) * model.subtitleScale, weight: .semibold))
                            .multilineTextAlignment(.center).foregroundStyle(.white)
                            .shadow(color: .black, radius: 2, x: 1, y: 1)
                            .shadow(color: .black, radius: 2, x: -1, y: -1)
                            .padding(.horizontal, 18).padding(.vertical, 5)
                            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: geometry.size.width * 0.9)
                            .padding(.bottom, max(18, geometry.size.height * 0.055))
                    }.allowsHitTesting(false)
                }
                if model.isLoading {
                    VStack(spacing: 12) { ProgressView().controlSize(.small); Text(SPText("영상을 준비하고 있어요")).font(.system(size: 12)) }
                        .padding(22).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                }
                if let message = model.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 27)).foregroundStyle(MacDeck.amber)
                        Text(SPText("영상을 열지 못했어요")).font(.system(size: 17, weight: .semibold))
                        Text(message).font(.system(size: 12)).foregroundStyle(MacDeck.muted).multilineTextAlignment(.center)
                        Button(SPText("다른 영상 열기…")) { MacFilePanels.openMedia(model) }.buttonStyle(.bordered)
                    }.frame(maxWidth: 380).padding(26).background(MacDeck.background, in: RoundedRectangle(cornerRadius: 12))
                }
            }.clipped().contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard !model.isLoading, model.errorMessage == nil else { return }
                    model.togglePlayback()
                }
                .simultaneousGesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        let anchor = CGPoint(x: value.startAnchor.x, y: value.startAnchor.y)
                        videoViewport = videoViewport.transformed(by: value.magnification, from: anchor, to: anchor)
                    })
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .updating($pictureDrag) { value, state, _ in
                        if videoViewport.scale > 1 { state = value.translation }
                    }
                    .onEnded { value in
                        if videoViewport.scale > 1 {
                            videoViewport = videoViewport.panned(x: value.translation.width / max(1, geometry.size.width),
                                                                 y: value.translation.height / max(1, geometry.size.height))
                        }
                    })
                .onChange(of: model.currentID) { _, _ in videoViewport = VideoViewport() }
                .overlay(alignment: .top) {
                    if playerWindow.isFullscreen {
                        fullscreenTitle
                            .opacity(playerWindow.controlsVisible ? 1 : 0)
                            .allowsHitTesting(playerWindow.controlsVisible)
                            .accessibilityHidden(!playerWindow.controlsVisible)
                    }
                }
                .overlay(alignment: .bottom) {
                    if playerWindow.isFullscreen {
                        transport
                            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MacDeck.line))
                            .frame(maxWidth: 1040)
                            .padding(.horizontal, 28).padding(.bottom, 24)
                            .onHover { playerWindow.setControlsHeld($0, reason: "transportHover") }
                            .opacity(playerWindow.controlsVisible ? 1 : 0)
                            .allowsHitTesting(playerWindow.controlsVisible)
                            .accessibilityHidden(!playerWindow.controlsVisible)
                    }
                }
        }.frame(minHeight: 260)
    }

    private var fullscreenTitle: some View {
        HStack(spacing: 14) {
            iconButton("arrow.down.right.and.arrow.up.left", SPText("전체 화면 종료 · Escape")) {
                playerWindow.exitFullscreen()
            }.accessibilityIdentifier("exitFullscreen")
            Text(model.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text(SPText("ESC  돌아가기")).font(.system(size: 10, design: .monospaced)).foregroundStyle(MacDeck.muted)
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
            .onHover { playerWindow.setControlsHeld($0, reason: "titleHover") }
    }

    private var emptyPlayer: some View {
        VStack(spacing: 0) {
            Image(systemName: "play.rectangle").font(.system(size: 49, weight: .ultraLight))
                .foregroundStyle(MacDeck.amber.opacity(0.8)).padding(.bottom, 24)
            Text(SPText("영상에 집중하는 시간.")).font(.system(size: 25, weight: .medium)).padding(.bottom, 12)
            Text(SPText("동영상이나 폴더를 끌어 놓으세요."))
                .font(.system(size: 13)).foregroundStyle(MacDeck.muted).padding(.bottom, 25)
            Button { MacFilePanels.openMedia(model) } label: {
                Label(SPText("동영상 열기"), systemImage: "folder").padding(.horizontal, 12).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).foregroundStyle(MacDeck.background)
            if MacFilePanels.demoURL != nil {
                Button(SPText("예제 영상으로 먼저 보기")) { MacFilePanels.playDemo(model) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(MacDeck.muted).padding(.top, 14)
            }
            Text(SPText("⌘O  파일 열기   ·   Space  재생 / 일시정지"))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(MacDeck.muted.opacity(0.8)).padding(.top, 21)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(MacDeck.background.opacity(0.3))
    }

    private var transport: some View {
        VStack(spacing: 15) {
            HStack(spacing: 14) {
                Text(MacDeck.time(scrubbing ? scrubPosition : model.position)).frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(max(0, model.position), max(1, model.duration)) },
                                      set: { scrubPosition = $0; scrubbing = true }),
                       in: 0...max(1, model.duration), onEditingChanged: { editing in
                    if !editing {
                        let target = scrubPosition
                        scrubbing = false
                        Task { await model.seek(to: target) }
                    }
                }).disabled(model.duration <= 0 || model.isLoading).accessibilityLabel(SPText("재생 위치"))
                Text(MacDeck.time(model.duration)).frame(width: 55, alignment: .trailing)
            }.font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(MacDeck.muted)

            HStack(spacing: 18) {
                HStack(spacing: 13) {
                    iconButton("backward.end.fill", SPText("이전 영상")) { Task { await model.previous() } }.disabled(!canMove(-1))
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18)).foregroundStyle(MacDeck.background)
                            .frame(width: 42, height: 42).background(MacDeck.amber, in: Circle())
                    }.buttonStyle(.plain).disabled(model.currentID == nil || model.isLoading)
                        .help(SPText("재생 / 일시정지 · Space")).accessibilityLabel(model.isPlaying ? SPText("일시정지") : SPText("재생"))
                    iconButton("forward.end.fill", SPText("다음 영상")) { Task { await model.next() } }.disabled(!canMove(1))
                    Button { model.repeatMode = model.repeatMode.next } label: {
                        Image(systemName: model.repeatMode.symbolName).font(.system(size: 18))
                            .foregroundStyle(model.repeatMode == .off ? MacDeck.muted : MacDeck.amber)
                            .frame(width: 32, height: 32)
                    }.buttonStyle(.plain).help(SPText(model.repeatMode.titleKey))
                        .accessibilityLabel(SPText(model.repeatMode.titleKey)).accessibilityIdentifier("repeatMode")
                }
                Rectangle().fill(MacDeck.line).frame(width: 1, height: 24)
                Button { Task { await model.setSmooth(!model.smoothEnabled) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path").font(.system(size: 12))
                        Text(model.smoothEnabled ? SPText("부드럽게 켬") : SPText("부드럽게 끔")).font(.system(size: 12, weight: .medium))
                    }.padding(.horizontal, 11).frame(height: 32)
                        .foregroundStyle(model.smoothEnabled ? MacDeck.amber : MacDeck.muted)
                        .background(model.smoothEnabled ? MacDeck.amber.opacity(0.1) : MacDeck.raised, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).disabled(model.currentID == nil || model.isLoading || model.isSeeking)
                    .accessibilityIdentifier("smoothToggle")
                Button { showingSound = true } label: {
                    Image(systemName: "waveform").font(.system(size: 16))
                }.buttonStyle(.plain).help(SPText("사운드 · \(model.sound.mode.label)")).accessibilityIdentifier("openSound")
                Button { showingQuality.toggle() } label: {
                    Label(SPText("화질"), systemImage: "slider.horizontal.3").font(.system(size: 12))
                }.buttonStyle(.plain).help(SPText("화질 보정")).popover(isPresented: $showingQuality, arrowEdge: .top) { qualityPanel }
                subtitleMenu
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    iconButton(model.volume == 0 ? "speaker.slash" : "speaker.wave.2", SPText("음소거")) {
                        if model.volume > 0 { previousVolume = model.volume; model.volume = 0 }
                        else { model.volume = max(0.05, previousVolume) }
                    }
                    Slider(value: $model.volume, in: 0...1).frame(width: 76).accessibilityLabel(SPText("음량"))
                }
                if playerWindow.isFullscreen {
                    iconButton("arrow.down.right.and.arrow.up.left", SPText("전체 화면 종료 · Escape")) {
                        playerWindow.exitFullscreen()
                    }
                }
            }
            HStack(spacing: 7) {
                Circle().fill(model.smoothEnabled ? MacDeck.amber : MacDeck.muted.opacity(0.5)).frame(width: 4, height: 4)
                Text(model.currentID == nil ? SPText("파일을 열면 재생을 시작합니다") : model.smoothStatus)
                    .lineLimit(1).help(model.smoothStatus)
                Spacer()
                Text(model.videoScaleMode.label)
            }.font(.system(size: 10)).foregroundStyle(MacDeck.muted)
        }.padding(.horizontal, 23).padding(.top, 17).padding(.bottom, 15)
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SPText("화질 보정")).font(.system(size: 16, weight: .semibold))
            Picker(SPText("보정 방식"), selection: $model.enhancementMode) {
                ForEach(VideoEnhancementMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            Text(model.enhancementMode.detail).font(.system(size: 11)).foregroundStyle(MacDeck.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(SPText("저해상도 자동 보정"), isOn: $model.lowResolutionEnhancement).disabled(model.enhancementMode == .off)
            Text(SPText("360p·480p 확대 시 윤곽을 다듬습니다. AI 복원 기능은 아닙니다.")).font(.system(size: 11)).foregroundStyle(MacDeck.muted)
            Toggle(SPText("윤곽 확대"), isOn: $model.edgeUpscaling).disabled(model.enhancementMode == .off)
            Text(SPText("영상을 확대할 때 윤곽을 정리합니다. 영상에 따라 질감이 달라질 수 있습니다."))
                .font(.system(size: 11)).foregroundStyle(MacDeck.muted).fixedSize(horizontal: false, vertical: true)
            Text(model.enhancementStatus).font(.system(size: 11)).foregroundStyle(MacDeck.amber).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(SPText("새 영상에서 부드럽게 시작"), isOn: $model.smoothAtStart)
            Text(SPText("다음에 여는 영상부터 적용합니다. 현재 영상은 재생 조작부의 ‘부드럽게’ 버튼으로 바꿀 수 있습니다."))
                .font(.system(size: 11)).foregroundStyle(MacDeck.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 310).background(MacDeck.panel).preferredColorScheme(.dark)
    }

    private var subtitleMenu: some View {
        Menu {
            Picker(SPText("자막 크기"), selection: Binding(get: { model.subtitleScale }, set: { model.setSubtitleScale($0) })) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { scale in
                    Text("\(Int(scale * 100))%").tag(scale)
                }
            }
            Divider()
            Button(SPText("자막 파일 열기…")) { MacFilePanels.openSubtitle(model) }
            Button(SPText("자막 끄기")) { Task { await model.clearSubtitle() } }
            if !model.subtitleTracks.isEmpty {
                Divider()
                ForEach(model.subtitleTracks) { track in
                    Button { Task { await model.selectSubtitle(track.id) } } label: {
                        Label(track.label, systemImage: model.selectedSubtitleTrackID == track.id ? "checkmark" : "captions.bubble")
                    }.disabled(!track.supported)
                }
            }
            if let filename = model.subtitleFilename { Divider(); Text(filename) }
        } label: {
            Label(SPText("자막"), systemImage: "captions.bubble").font(.system(size: 12))
        }.menuStyle(.borderlessButton).fixedSize().disabled(model.currentID == nil || model.isLoading)
            .help(SPText("외부 자막 및 내장 자막"))
    }

    private func iconButton(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 14)).frame(width: 28, height: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(MacDeck.muted).help(help).accessibilityLabel(help)
    }

    private func canMove(_ offset: Int) -> Bool {
        guard let index = model.playlist.firstIndex(where: { $0.id == model.currentID }) else { return false }
        return model.playlist.indices.contains(index + offset)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders.prefix(500) {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let url = value as? URL { continuation.resume(returning: url) }
                        else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { await model.open(urls: urls) }
        }
        return true
    }
}

@MainActor
private struct MacVideoSurface: NSViewRepresentable {
    let model: MacPlayerModel
    let playerWindow: MacWindowController
    let onScrollPan: (CGSize) -> Bool
    func makeNSView(context: Context) -> MacPlayerMetalView {
        let view = MacPlayerMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.playerModel = model
        view.playerWindow = playerWindow
        view.onScrollPan = onScrollPan
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        return view
    }
    func updateNSView(_ view: MacPlayerMetalView, context: Context) {
        view.playerWindow = playerWindow
        view.playerModel = model
        view.onScrollPan = onScrollPan
        view.attachPlayerWindow()
    }
    static func dismantleNSView(_ view: MacPlayerMetalView, coordinator: ()) {
        view.stopDisplayClock(); view.isPaused = true; view.delegate = nil
    }
}

@MainActor
final class MacPlayerMetalView: MTKView, PresentationClockControl {
    var onScrollPan: ((CGSize) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if onScrollPan?(CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY)) != true {
            super.scrollWheel(with: event)
        }
    }
    weak var playerModel: MacPlayerModel?
    weak var playerWindow: MacWindowController?
    private var displayClock: CADisplayLink?
    private var clockRate = 0
    private var presentationClockPaused = false
    var isPresentationClockPaused: Bool { displayClock?.isPaused ?? true }
    func setPresentationClockPaused(_ paused: Bool) {
        presentationClockPaused = paused
        configureDisplayClock()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayClock() }
        attachPlayerWindow()
    }
    // Use AppKit's view-bound clock explicitly. MTKView's implicit timer
    // can stay idle when its first delegate is installed after Finder open.
    // The view-bound clock follows displays and suspends while hidden.
    func configureDisplayClock() {
        isPaused = true
        guard window != nil, delegate != nil else { stopDisplayClock(); return }
        if displayClock == nil {
            let target = ClockTarget(view: self)
            let clock = displayLink(target: target, selector: #selector(ClockTarget.tick(_:)))
            clock.add(to: .main, forMode: .common)
            displayClock = clock
        }
        displayClock?.isPaused = presentationClockPaused
        let rate = max(1, preferredFramesPerSecond)
        if clockRate != rate {
            displayClock?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
            clockRate = rate
        }
    }
    func stopDisplayClock() {
        displayClock?.invalidate(); displayClock = nil; clockRate = 0
    }
    @MainActor
    private final class ClockTarget: NSObject {
        weak var view: MacPlayerMetalView?
        init(view: MacPlayerMetalView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view, let renderer = view.delegate as? SmoothPlaybackCoordinator else { return }
            renderer.draw(view, at: link.targetTimestamp, interval: link.targetTimestamp - link.timestamp)
        }
    }
    func attachPlayerWindow() {
        guard let window else { return }
        // SwiftUI may prepare or reuse a representable during Finder open
        // delivery. Only the surface actually installed in a window owns
        // the renderer; rebind after a reused surface was dismantled.
        playerModel?.attach(self)
        configureDisplayClock()
        guard playerWindow?.window !== window else { return }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.playerWindow?.attach(window)
        }
    }
}

@MainActor
private struct MacNativeSubtitleLayer: View {
    let controller: NativeSubtitleController
    let mode: VideoScaleMode
    var body: some View {
        GeometryReader { geometry in
            let source = controller.canvasSize
            let video = mode.rectangle(source: source, canvas: geometry.size)
            if source.width > 0, source.height > 0 {
                let sx = video.width / source.width
                let sy = video.height / source.height
                ForEach(controller.images) { item in
                    Image(decorative: item.image, scale: 1).resizable()
                        .frame(width: item.rectangle.width * sx, height: item.rectangle.height * sy)
                        .position(x: video.minX + item.rectangle.midX * sx, y: video.minY + item.rectangle.midY * sy)
                }
            }
        }.clipped().allowsHitTesting(false)
    }
}

/// An event monitor is limited to this window and leaves editors, system panels,
/// modified shortcuts and other applications alone.
@MainActor
private struct MacPlayerKeyboardMonitor: NSViewRepresentable {
    let model: MacPlayerModel
    let playerWindow: MacWindowController
    func makeCoordinator() -> Coordinator { Coordinator(model: model, playerWindow: playerWindow) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private let model: MacPlayerModel
        private let playerWindow: MacWindowController
        private var monitor: Any?
        init(model: MacPlayerModel, playerWindow: MacWindowController) {
            self.model = model; self.playerWindow = playerWindow
        }
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.view?.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil else { return event }
                self.playerWindow.revealControls()
                guard event.type == .keyDown,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if event.keyCode == 53, self.playerWindow.exitFullscreen() { return nil }
                guard self.model.currentID != nil, !self.model.isLoading else { return event }
                switch event.keyCode {
                case 36, 76: // Return and numeric-keypad Enter.
                    if !event.isARepeat { self.playerWindow.toggleFullscreen() }
                case 49:
                    if !event.isARepeat { self.model.togglePlayback() }
                case 123: Task { await self.model.seek(to: max(0, self.model.position - 10)) }
                case 124: Task { await self.model.seek(to: min(self.model.duration, self.model.position + 10)) }
                case 125: self.model.volume = max(0, self.model.volume - 0.05)
                case 126: self.model.volume = min(1, self.model.volume + 0.05)
                default: return event
                }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}
