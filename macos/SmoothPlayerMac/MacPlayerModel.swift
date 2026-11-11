import AppKit
import AVFoundation
import Combine
import Foundation
import MetalKit

struct MacPlaylistItem: Identifiable, Sendable {
    let id: UUID
    let url: URL?
    let title: String
    fileprivate let sidecars: [URL]
    fileprivate let network: MacNetworkMedia?
    var fileExtension: String { (title as NSString).pathExtension }
}

/// A connected client owns its credential in native memory. No password or
/// authenticated URL is copied into the playlist or persisted as media history.
fileprivate struct MacNetworkMedia: Sendable {
    let client: NASClient
    let entry: NASEntry
    let sidecars: [NASEntry]
}

/// A file and FTP host for the shared decoder, audio clock, Core ML interpolation
/// and Metal presenter. Selected files stay in place; only NAS resume metadata is
/// persisted for account synchronization.
@MainActor
final class MacPlayerModel: ObservableObject {
    let account: AccountStore
    let nasRecents: NASRecentStore
    private var lastNASRecord = Date.distantPast
    private let accountTrial: TrialStore
    private let validationAccountService: String?
    @Published var accountMessage: String?
    private var canUseAccountSmooth: Bool {
        !account.isConfigured || account.hasPaidAccess || accountTrial.canUseSmoothWithoutPurchase
    }
    @Published private(set) var playlist: [MacPlaylistItem] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var title = "Smooth Player"
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSeeking = false
    @Published private(set) var smoothEnabled = false
    @Published private(set) var preparingSmooth = false
    @Published private(set) var smoothStatus = SPText("부드럽게 끔")
    @Published var errorMessage: String?
    @Published var enhancementMode: VideoEnhancementMode = .natural { didSet { applyVisualSettings(); savePreferences() } }
    @Published var lowResolutionEnhancement = false { didSet { applyVisualSettings(); savePreferences() } }
    @Published var edgeUpscaling = false { didSet { applyVisualSettings(); savePreferences() } }
    @Published var videoScaleMode: VideoScaleMode = .fit { didSet { applyVisualSettings(); savePreferences() } }
    @Published var smoothAtStart = false { didSet { savePreferences() } }
    @Published var repeatMode: PlaybackRepeatMode = .off { didSet { savePreferences() } }
    private var repeatTask: Task<Void, Never>?
    @Published var sound = SoundProfile() { didSet {
        playback?.setSoundProfile(sound)
        if !loadingPreferences { soundPresets[soundTarget.rawValue] = sound.sanitized() }
        savePreferences()
    } }
    @Published private(set) var soundTarget: SoundPresetTarget = .standard
    @Published var soundComparison: SoundComparison = .off { didSet { playback?.soundComparison = soundComparison } }
    @Published private(set) var audioSyncHundredths = 0
    @Published private(set) var audioSyncOutput: AudioSyncOutput?
    private var audioSyncOffsets: [String: Int] = [:]
    private var audioSyncTask: Task<Void, Never>?
    func refreshAudioSyncOutput() {
        let output = AudioSyncOutput.current()
        guard output != audioSyncOutput else { return }
        audioSyncOutput = output
        audioSyncHundredths = output.map { AudioSyncAdjustment.bounded(audioSyncOffsets[$0.key] ?? 0) } ?? 0
        scheduleAudioSync()
    }
    func setAudioSyncHundredths(_ value: Int) {
        guard let output = audioSyncOutput else { return }
        audioSyncHundredths = AudioSyncAdjustment.bounded(value)
        audioSyncOffsets[output.key] = audioSyncHundredths
        savePreferences(); scheduleAudioSync()
    }
    private func scheduleAudioSync() {
        audioSyncTask?.cancel()
        audioSyncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, let playback, !isLoading else { return }
            playback.requestedAudioSyncHundredths = audioSyncHundredths
            if playback.activeAudioSyncSeconds != AudioSyncAdjustment.seconds(audioSyncHundredths) {
                await seek(to: position)
            }
        }
    }
    private var soundPresets: [String: SoundProfile] = [:]
    func selectSoundTarget(_ target: SoundPresetTarget) {
        guard target != soundTarget else { return }
        soundPresets[soundTarget.rawValue] = sound.sanitized()
        soundTarget = target; soundComparison = .off
        sound = soundPresets[target.rawValue]?.sanitized() ?? target.initialProfile
    }
    @Published var volume = 1.0 { didSet {
        playback?.playbackVolume = Float(volume.isFinite ? min(1, max(0, volume)) : 1)
        savePreferences()
    } }
    @Published private(set) var enhancementStatus = SPText("현재 적용: 끔")
    @Published private(set) var sourceDescription = SPText("로컬 동영상을 열어 주세요.")
    @Published private(set) var subtitleText: String?
    @Published private(set) var subtitleFilename: String?
    @Published private(set) var subtitleScale = 1.0
    func setSubtitleScale(_ value: Double) {
        var settings = SubtitleSettings(); settings.scale = value
        subtitleScale = settings.sanitized.scale
        nativeSubtitles?.setStyle(scale: subtitleScale, outline: true)
        savePreferences()
    }
    @Published var subtitleMessage: String?
    @Published private(set) var subtitleTracks: [EmbeddedSubtitleTrack] = []
    @Published private(set) var selectedSubtitleTrackID: Int32?
    @Published private(set) var nativeSubtitles: NativeSubtitleController?
    @Published private(set) var renderer: SmoothPlaybackCoordinator?
    private(set) var playback: FFmpegPlayback?

    private weak var surface: MTKView?
    private var interpolator: FrameInterpolator?
    private var modelLoading: Task<FrameInterpolator, Error>?
    private var refreshTask: Task<Void, Never>?
    private var audioReloadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var pendingSeek: Double?
    private var playlistRequest: UInt = 0
    private var mediaGeneration: UInt = 0
    private var renderGeneration: UInt = 0
    private var requestedPlay = false
    let systemPlaybackControls = SystemPlaybackControls()
    private var requestedSmooth = false
    private var scopes: [MacFileScope] = []
    private var externalSubtitle: SubtitleTrack?
    private var subtitleGeneration: UInt = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferences: UserDefaults?
    private var loadingPreferences = true
    private var lastDebugSecond = -1

    init(preferencesOverride: UserDefaults? = nil) {
        let testing = CommandLine.arguments.contains("--self-test")
        let namespace = "com.nodelabs.smoothplayer.mac.validation." + UUID().uuidString
        validationAccountService = testing ? namespace + ".account" : nil
        account = AccountStore(service: validationAccountService ?? MacAppStorage.accountService)
        nasRecents = NASRecentStore(storageURL: testing ? URL.temporaryDirectory.appending(path: namespace + ".json") : MacAppStorage.file("nas-recents.json"))
        accountTrial = TrialStore(service: testing ? namespace + ".trial" : MacAppStorage.namespace + ".trial",
                                  featureAvailable: { true })
        if !testing || preferencesOverride != nil {
            let defaults = preferencesOverride ?? UserDefaults(suiteName: MacAppStorage.namespace + ".preferences")
            preferences = defaults
            if let value = defaults?.object(forKey: "subtitleScale") as? Double { setSubtitleScale(value) }
            if let data = defaults?.data(forKey: "audioSyncOffsets"), let stored = try? JSONDecoder().decode([String: Int].self, from: data) { audioSyncOffsets = stored }
            soundTarget = defaults?.string(forKey: "soundTarget").flatMap(SoundPresetTarget.init(rawValue:)) ?? .standard
            if let data = defaults?.data(forKey: "soundPresets"), let stored = try? JSONDecoder().decode([String: SoundProfile].self, from: data) { soundPresets = stored }
            if let data = defaults?.data(forKey: "sound"), let stored = try? JSONDecoder().decode(SoundProfile.self, from: data) { sound = stored.sanitized() }
            if let value = defaults?.object(forKey: "volume") as? Double, value.isFinite { volume = min(1, max(0, value)) }
            enhancementMode = VideoEnhancementMode.stored(defaults?.string(forKey: "enhancement"))
            edgeUpscaling = defaults?.bool(forKey: "edgeUpscaling") ?? false
            lowResolutionEnhancement = defaults?.bool(forKey: "lowResolutionEnhancement") ?? false
            videoScaleMode = defaults?.string(forKey: "scale").flatMap(VideoScaleMode.init(rawValue:)) ?? .fit
            smoothAtStart = defaults?.bool(forKey: "smoothAtStart") ?? false
            repeatMode = defaults?.string(forKey: "repeatMode").flatMap(PlaybackRepeatMode.init(rawValue:)) ?? .off
        }
        loadingPreferences = false
        refreshAudioSyncOutput()
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
        observers.append((workspace, sleep))
        let center = NotificationCenter.default
        let audioChange = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let engine = note.object as? AVAudioEngine else { return }
            Task { @MainActor [weak self, weak engine] in
                guard let engine else { return }
                self?.audioConfigurationChanged(engine)
            }
        }
        observers.append((center, audioChange))
    }

    /// The automatic harness must never consume or clear the user's account/trial records.
    func restoredValidationAccount() -> AccountStore? {
        guard let service = validationAccountService else { return nil }
        return AccountStore(configuration: account.configuration, service: service)
    }

    func finishValidationAccount() async {
        guard validationAccountService != nil else { return }
        await account.signOut()
        try? accountTrial.eraseLocalData()
    }

    /// Both NSOpenPanel and drag/drop provide the authorizing URLs. A selected
    /// directory contributes only its immediate visible regular files, never an
    /// unrequested recursive scan or symlink destination.
    func open(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        playlistRequest &+= 1
        let token = playlistRequest
        isLoading = true; errorMessage = nil
        let acquired = urls.filter(\.isFileURL).map(MacFileScope.init)
        var adopted = false
        defer { if !adopted { acquired.forEach { $0.close() } } }
        do {
            let entries = try await Task.detached(priority: .userInitiated) { try Self.enumerate(urls) }.value
            try Task.checkCancellation()
            guard playlistRequest == token else { return }
            guard !entries.isEmpty else { throw MacPlaybackError.noVideos }
            stopMedia()
            scopes.forEach { $0.close() }; scopes = acquired; adopted = true
            playlist = entries
            await select(id: entries[0].id)
        } catch {
            guard playlistRequest == token, !Task.isCancelled else { return }
            isLoading = false
            errorMessage = Self.message(error)
        }
    }

    func select(id: UUID) async {
        guard let item = playlist.first(where: { $0.id == id }) else { return }
        let position = item.network.map { nasRecents.resumePosition(connectionID: $0.client.connection.id, entry: $0.entry, share: $0.client.connection.kind == .smb ? $0.client.connection.share : nil) } ?? 0
        await prepare(item, at: position, shouldPlay: true, smoothing: smoothAtStart)
    }

    /// The browser supplies only its current directory listing. Keep the native
    /// client alive after the sheet closes, so next/previous and seek continue
    /// without embedding credentials in a URL or copying a whole video to disk.
    func openNetwork(_ selection: MacNetworkPlaybackSelection) async {
        guard selection.client.connection.kind == .ftp,
              !selection.entry.isDirectory, Self.supportsVideo(selection.entry.name),
              selection.entries.contains(selection.entry) else { return }
        let parent = (selection.entry.path as NSString).deletingLastPathComponent
        let siblings = selection.entries.filter {
            !$0.isDirectory && ($0.path as NSString).deletingLastPathComponent == parent
        }
        var seen: Set<String> = []
        let videos = siblings.filter { Self.supportsVideo($0.name) && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard videos.count <= 5_000 else { errorMessage = MacPlaybackError.tooManyFiles.localizedDescription; return }
        let items = videos.map { video in
            let matching = ExternalSubtitleFormat.matching(videoName: video.name, names: siblings.map(\.name))
            let media = MacNetworkMedia(client: selection.client, entry: video,
                sidecars: matching.compactMap { name in siblings.first { $0.name == name } })
            return MacPlaylistItem(id: UUID(), url: nil, title: video.name, sidecars: [], network: media)
        }
        guard let chosen = items.first(where: { $0.network?.entry.id == selection.entry.id }) else { return }
        playlistRequest &+= 1
        stopMedia()
        scopes.forEach { $0.close() }; scopes.removeAll()
        playlist = items
        await select(id: chosen.id)
    }
    private func playbackEnded(token: UInt, candidate: FFmpegPlayback) {
        guard repeatMode != .off, let index = currentIndex else { requestedPlay = false; refresh(); return }
        let item = playlist[index]
        let mode = repeatMode
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self, weak candidate] in
            guard let self, let candidate, current(token, candidate), !Task.isCancelled else { return }
            if mode == .one {
                await seek(to: 0) // seek honours a pause received while the decoder restarts.
                return
            }
            do {
                let siblings: [MacPlaylistItem]
                let currentFolderIndex: Int?
                if let url = item.url {
                    let parent = url.deletingLastPathComponent()
                    siblings = try await Task.detached(priority: .userInitiated) { try Self.enumerate([parent]) }.value
                    currentFolderIndex = siblings.firstIndex { $0.url?.standardizedFileURL == url.standardizedFileURL }
                } else if let network = item.network {
                    let parent = (network.entry.path as NSString).deletingLastPathComponent
                    siblings = playlist.filter {
                        $0.network?.client.connection.id == network.client.connection.id &&
                        $0.network.map { ($0.entry.path as NSString).deletingLastPathComponent == parent } == true
                    }
                    currentFolderIndex = siblings.firstIndex { $0.id == item.id }
                } else { return }
                guard current(token, candidate), requestedPlay, repeatMode == .folder, !Task.isCancelled,
                      let currentFolderIndex, let next = mode.nextIndex(current: currentFolderIndex, count: siblings.count) else { return }
                let smoothing = requestedSmooth
                playlist = siblings
                await prepare(siblings[next], at: 0, shouldPlay: true, smoothing: smoothing)
            } catch {
                guard current(token, candidate), !Task.isCancelled else { return }
                errorMessage = Self.message(error); pause()
            }
        }
    }

    func previous() async {
        guard let index = currentIndex, index > 0 else { return }
        await select(id: playlist[index - 1].id)
    }
    func next() async {
        guard let index = currentIndex, index + 1 < playlist.count else { return }
        await select(id: playlist[index + 1].id)
    }
    var currentIndex: Int? { currentID.flatMap { id in playlist.firstIndex(where: { $0.id == id }) } }

    func attach(_ view: MTKView) {
        guard view.window != nil else { return }
        if surface !== view { surface?.isPaused = true; surface?.delegate = nil; surface = view }
        if view.delegate !== renderer {
            if CommandLine.arguments.contains("--window-debug") {
                print("MAC_SURFACE rebind \(ObjectIdentifier(view)) window=\(view.window?.windowNumber ?? -1)")
                fflush(stdout)
            }
            view.isPaused = true
            renderer?.attach(view)
        }
        (view as? MacPlayerMetalView)?.configureDisplayClock()
    }
    func togglePlayback() {
        if requestedPlay { pause() } else { play() }
    }
    func play() {
        guard playback != nil else { return }
        requestedPlay = true
        guard !isLoading, !isSeeking, !preparingSmooth else { return }
        if duration > 0, position >= duration - 0.05 {
            Task { [weak self] in await self?.seek(to: 0) }
        } else { playback?.play(); refresh() }
    }
    func pause() { repeatTask?.cancel(); repeatTask = nil; requestedPlay = false; playback?.pause(); accountTrial.flush(); refresh() }

    func seek(to seconds: Double) async {
        guard seconds.isFinite, let playback, !isLoading else { return }
        pendingSeek = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if let seekTask { await seekTask.value; return }
        let token = mediaGeneration
        renderGeneration &+= 1
        preparingSmooth = false
        let task = Task { @MainActor [weak self, weak playback] in
            guard let self, let playback else { return }
            isSeeking = true
            defer {
                if mediaGeneration == token {
                    isSeeking = false; seekTask = nil
                    if requestedPlay, errorMessage == nil { playback.play() }
                    refresh()
                }
            }
            do {
                while let target = pendingSeek, current(token, playback), !Task.isCancelled {
                    pendingSeek = nil
                    playback.pause()
                    renderer?.close(); renderer = nil
                    try await playback.seek(to: target)
                    guard current(token, playback), !Task.isCancelled else { return }
                    nativeSubtitles?.resetAfterSeek()
                    // A toggle during asynchronous model priming updates the
                    // final choice without publishing a stale post-seek mode.
                    repeat {
                        let choice = requestedSmooth
                        await rebuildRenderer(smoothing: choice, token: token, playback: playback)
                        guard current(token, playback), !Task.isCancelled else { return }
                        if choice == requestedSmooth { break }
                    } while true
                    guard current(token, playback), !Task.isCancelled else { return }
                    refresh()
                }
            } catch {
                guard current(token, playback), !Task.isCancelled else { return }
                requestedPlay = false; errorMessage = Self.message(error)
            }
        }
        seekTask = task
        await task.value
    }

    func setSmooth(_ enabled: Bool) async {
        guard let playback, !isLoading else { return }
        if enabled && !canUseAccountSmooth {
            accountMessage = SPText("10분 체험이 끝났습니다. 계정 화면에서 이용권을 확인하거나 구매해 주세요.")
            return
        }
        requestedSmooth = enabled
        // The seek loop rebuilds once against its final decode generation.
        if isSeeking { return }
        let token = mediaGeneration
        playback.pause()
        let request = renderGeneration &+ 1
        await rebuildRenderer(smoothing: enabled, token: token, playback: playback)
        guard current(token, playback), renderGeneration == request, !isSeeking, !preparingSmooth else { return }
        if requestedPlay { playback.play() }
        refresh()
    }

    func loadSubtitle(_ url: URL) async {
        guard url.isFileURL, let native = nativeSubtitles, let playback else { return }
        let scope = MacFileScope(url)
        defer { scope.close() }
        subtitleGeneration &+= 1
        let selection = subtitleGeneration, token = mediaGeneration
        subtitleMessage = nil
        do {
            let value = try await Task.detached(priority: .userInitiated) { try Self.readSubtitle(url) }.value
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            if let ass = value.ass {
                try await native.loadASS(data: ass, name: url.lastPathComponent)
            } else if native.selectedTrackID != nil || native.externalFilename != nil {
                try await native.selectEmbedded(trackID: nil)
            }
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            externalSubtitle = value.track
            subtitleFilename = url.lastPathComponent
            selectedSubtitleTrackID = nil
            refresh()
        } catch {
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            subtitleMessage = Self.message(error)
        }
    }
    func selectSubtitle(_ id: Int32?) async {
        guard let native = nativeSubtitles, let playback else { return }
        subtitleGeneration &+= 1
        let selection = subtitleGeneration, token = mediaGeneration
        subtitleMessage = nil
        do {
            try await native.selectEmbedded(trackID: id)
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            externalSubtitle = nil; subtitleText = nil
            selectedSubtitleTrackID = id
            subtitleFilename = id.flatMap { id in subtitleTracks.first { $0.id == id }?.label }
            refresh()
        } catch {
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            subtitleMessage = Self.message(error)
        }
    }
    func clearSubtitle() async { await selectSubtitle(nil) }

    private func loadNetworkSubtitle(_ entry: NASEntry, client: NASClient) async {
        guard let native = nativeSubtitles, let playback else { return }
        subtitleGeneration &+= 1
        let selection = subtitleGeneration, token = mediaGeneration
        subtitleMessage = nil
        do {
            guard entry.size <= SubtitleTrack.maximumBytes else { throw SubtitleError.tooLarge }
            let stream = try await client.open(path: entry.path, encodedPath: entry.encodedPath, expectedSize: entry.size)
            let bytes: Data
            do {
                guard stream.size >= 0, stream.size <= SubtitleTrack.maximumBytes else { throw SubtitleError.tooLarge }
                var data = Data()
                while data.count < Int(stream.size) {
                    try Task.checkCancellation()
                    guard current(token, playback), subtitleGeneration == selection else { throw CancellationError() }
                    let chunk = try await stream.read(offset: Int64(data.count), count: min(1_048_576, Int(stream.size) - data.count))
                    guard !chunk.isEmpty else { throw SubtitleError.invalidFormat }
                    data.append(chunk)
                }
                bytes = data
                await stream.close()
            } catch { await stream.close(); throw error }
            let value = try await Task.detached(priority: .userInitiated) { try Self.parseSubtitle(bytes, name: entry.name) }.value
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            if let ass = value.ass {
                try await native.loadASS(data: ass, name: entry.name)
            } else if native.selectedTrackID != nil || native.externalFilename != nil {
                try await native.selectEmbedded(trackID: nil)
            }
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            externalSubtitle = value.track; subtitleFilename = entry.name; selectedSubtitleTrackID = nil
            refresh()
        } catch {
            guard current(token, playback), subtitleGeneration == selection, !Task.isCancelled else { return }
            subtitleMessage = Self.message(error)
        }
    }

    /// Technical counters only, suitable for the root's opt-in synthetic self-test.
    /// No file names, URL, subtitle text, audio samples or decoded images are emitted.
    func diagnostics() async -> [String: Double] {
        guard let playback else { return ["open": 0] }
        var values = await playback.decoder.diagnosticMetrics()
        values.merge(playback.remoteAudioDiagnostics) { _, new in new }
        if let renderer { values.merge(await renderer.generationDiagnostics()) { _, new in new } }
        values["open"] = 1
        values["decodedVideoFrames"] = Double(playback.decodedVideoFrames)
        values["width"] = Double(playback.info?.width ?? 0); values["height"] = Double(playback.info?.height ?? 0)
        values["sourceFPS"] = playback.info?.fps ?? 0
        values["displayMaximumFPS"] = Double(surface?.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        values["targetFPS"] = renderer?.outputFramesPerSecond ?? 0
        values["smoothEnabled"] = smoothEnabled ? 1 : 0
        values["presentedGeneratedFrames"] = Double(renderer?.presentedGeneratedFrames ?? 0)
        values["presentedUniqueFrames"] = Double(renderer?.presentedUniqueFrames ?? 0)
        values["missedPresentationDeadlines"] = Double(renderer?.missedPresentationDeadlines ?? 0)
        values["decodedSourcePeakBytes"] = Double(await playback.frames.peakBufferedByteCount)
        return values
    }

    func closeNetworkPlaylist() {
        if playlist.contains(where: { $0.network != nil }) { close(saveHistory: false) }
    }
    func enforceNetworkPrivacy(_ privacy: FolderPrivacyStore) {
        if playlist.contains(where: { item in
            item.network.map { !privacy.visible(FolderPrivacyStore.networkLocation($0.client.connection, path: $0.entry.path)) } == true
        }) { close() }
    }
    func close(saveHistory: Bool = true) {
        playlistRequest &+= 1
        stopMedia(saveHistory: saveHistory)
        scopes.forEach { $0.close() }; scopes.removeAll()
        playlist = []; currentID = nil; title = "Smooth Player"
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
    }

    private func prepare(_ item: MacPlaylistItem, at start: Double, shouldPlay: Bool, smoothing: Bool) async {
        stopMedia()
        let token = mediaGeneration
        currentID = item.id; title = item.title; isLoading = true; errorMessage = nil
        requestedPlay = shouldPlay; requestedSmooth = smoothing
        let candidate = FFmpegPlayback()
        playback = candidate
            systemPlaybackControls.activate(state: { [weak self] in
                .init(title: self?.title ?? "", position: self?.position ?? 0,
                      duration: self?.duration ?? 0, playing: self?.requestedPlay ?? false)
            }, play: { [weak self] in self?.play() }, pause: { [weak self] in self?.pause() })
        refreshAudioSyncOutput()
        candidate.requestedAudioSyncHundredths = audioSyncHundredths
        candidate.setSoundProfile(sound)
        candidate.soundComparison = soundComparison
        candidate.playbackVolume = Float(volume.isFinite ? min(1, max(0, volume)) : 1)
        candidate.onFailure = { [weak self, weak candidate] message in
            guard let self, let candidate, self.current(token, candidate) else { return }
            self.errorMessage = message; self.pause()
        }
        candidate.onEnded = { [weak self, weak candidate] in
            guard let self, let candidate, self.current(token, candidate) else { return }
            self.playbackEnded(token: token, candidate: candidate)
        }
        do {
            if let network = item.network {
                let stream = try await network.client.open(path: network.entry.path,
                    encodedPath: network.entry.encodedPath, expectedSize: network.entry.size)
                guard current(token, candidate), !Task.isCancelled else { await stream.close(); return }
                try await candidate.open(url: nil, stream: stream, at: start)
            } else { try await candidate.open(url: item.url, stream: nil, at: start) }
            guard current(token, candidate), !Task.isCancelled else { candidate.close(); return }
            let tracks = try await candidate.decoder.subtitleTracks()
            guard current(token, candidate), !Task.isCancelled else { candidate.close(); return }
            if let info = candidate.info {
                let rect = CGRect(x: 0, y: 0, width: info.width, height: info.height).applying(candidate.transform)
                let native = NativeSubtitleController(width: max(1, Int(abs(rect.width).rounded())),
                    height: max(1, Int(abs(rect.height).rounded())), tracks: tracks) { [weak self, weak candidate] id in
                        guard let self, let candidate, self.current(token, candidate) else { throw FFmpegPlaybackError.closed }
                        let time = candidate.currentTimeSeconds
                        try await candidate.decoder.selectSubtitle(id)
                        await self.seek(to: time)
                    }
                native.setStyle(scale: subtitleScale, outline: true)
                nativeSubtitles = native; subtitleTracks = tracks
                candidate.onSubtitlePacket = { [weak native] packet in await native?.receive(packet) }
                let location = item.network == nil ? "" : "FTP · "
                sourceDescription = "\(location)\(info.width) × \(info.height) · \(String(format: "%.2f", info.fps)) fps · \(info.videoCodec.uppercased())"
            }
            await rebuildRenderer(smoothing: smoothing, token: token, playback: candidate)
            guard current(token, candidate), !Task.isCancelled else { return }
            isLoading = false
            scheduleAudioSync()
            startRefresh(token: token)
            if let network = item.network, let sidecar = network.sidecars.first {
                await loadNetworkSubtitle(sidecar, client: network.client)
            } else if let sidecar = item.sidecars.first { await loadSubtitle(sidecar) }
            else if let track = tracks.first(where: { $0.supported && $0.isDefault }) { await selectSubtitle(track.id) }
            guard current(token, candidate), !Task.isCancelled else { return }
            if requestedPlay, renderer != nil { candidate.play() }
            refresh()
        } catch {
            guard current(token, candidate), !Task.isCancelled else { return }
            candidate.close(); playback = nil
            isLoading = false; requestedPlay = false; errorMessage = Self.message(error)
            refresh()
        }
    }

    private func rebuildRenderer(smoothing: Bool, token: UInt, playback: FFmpegPlayback) async {
        let smoothing = smoothing && canUseAccountSmooth
        if !smoothing { requestedSmooth = false }
        renderGeneration &+= 1
        let request = renderGeneration
        preparingSmooth = smoothing
        if smoothing { smoothStatus = SPText("부드러운 재생 준비 중…") }
        defer { if renderGeneration == request { preparingSmooth = false } }
        let displayMaximum = surface?.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        let fps = playback.info?.fps ?? 0
        let target = SmoothOutputPolicy.target(sourceFPS: fps, preferred: 120, displayMaximum: displayMaximum)
        let generates = smoothing && SmoothOutputPolicy.needsGeneration(sourceFPS: fps, target: target)
        var next: SmoothPlaybackCoordinator?
        do {
            if generates {
                guard !playback.containsHDR else { throw FrameGenerationError.unsupportedDynamicRange }
                if interpolator == nil {
                    // Share one outstanding model load across rapid toggles and
                    // seeks. Cancelling a synchronous MLModel initializer does
                    // not stop its work; spawning one per tap would waste memory.
                    let loading: Task<FrameInterpolator, Error>
                    if let existing = modelLoading { loading = existing }
                    else {
                        loading = Task.detached(priority: .userInitiated) { try FrameInterpolator() }
                        modelLoading = loading
                    }
                    let engine = try await loading.value
                    guard current(token, playback), renderGeneration == request, !Task.isCancelled else { return }
                    interpolator = engine; modelLoading = nil
                }
                let source = FFmpegFrameSource(frames: playback.frames, engine: interpolator, transform: playback.transform)
                next = try SmoothPlaybackCoordinator(source: source, outputFramesPerSecond: target, preparationBatchSize: 2,
                    fallbackFrame: { [weak playback] in playback?.frameForPresentation(at: $0) }, ordinaryTransform: playback.transform,
                    currentTime: { [weak playback] in playback?.presentationTimeSeconds ?? 0 },
                    mediaTimeAtHostTime: { [weak playback] in playback?.presentationTime(atHostTime: $0) ?? 0 },
                    isPlaying: { [weak playback] in playback?.isPlaying ?? false })
            } else { next = try ordinaryRenderer(playback, rate: fps > 60 && displayMaximum >= 120 ? 120 : 60) }
            try await next?.prime(at: playback.presentationTimeSeconds)
            guard current(token, playback), renderGeneration == request, !Task.isCancelled else { next?.close(); return }
            renderer?.close(); renderer = next
            next?.onPresentedSmoothInterval = { [weak self] seconds in
                guard let self, self.account.isConfigured else { return }
                self.accountTrial.recordGeneratedPlayback(seconds: seconds, hasPaidAccess: self.account.hasPaidAccess)
                if !self.canUseAccountSmooth && self.smoothEnabled {
                    self.accountMessage = SPText("이용권 또는 남은 체험을 확인해 주세요. 일반 재생을 계속합니다.")
                    Task { await self.setSmooth(false) }
                }
            }
            next?.onFailure = { [weak self, weak playback] _ in
                guard let self, let playback, self.current(token, playback), self.renderGeneration == request else { return }
                Task { @MainActor [weak self] in
                    await self?.setSmooth(false)
                    self?.smoothStatus = SPText("프레임 생성을 계속하지 못해 일반 재생으로 돌아왔습니다.")
                }
            }
            smoothEnabled = smoothing
            smoothStatus = !smoothing ? SPText("부드럽게 끔") : generates ? SPText("부드럽게 켬 · 목표 \(target) fps") : SPText("부드럽게 켬 · 원본 \(Int(fps.rounded())) fps 유지")
            applyVisualSettings()
            if let surface { attach(surface) }
        } catch {
            next?.close()
            guard current(token, playback), renderGeneration == request, !Task.isCancelled else { return }
            requestedSmooth = false; smoothEnabled = false
            smoothStatus = (error as? FrameGenerationError)?.errorDescription ?? SPText("부드러운 재생을 준비하지 못했습니다. 일반 재생을 계속합니다.")
            // A failed model preparation must still leave a real original-frame presenter.
            do {
                let original = try ordinaryRenderer(playback, rate: 60)
                try await original.prime(at: playback.presentationTimeSeconds)
                guard current(token, playback), renderGeneration == request, !Task.isCancelled else { original.close(); return }
                renderer?.close(); renderer = original; applyVisualSettings()
                if let surface { attach(surface) }
            } catch { if current(token, playback) { errorMessage = Self.message(error) } }
        }
    }
    private func ordinaryRenderer(_ playback: FFmpegPlayback, rate: Int) throws -> SmoothPlaybackCoordinator {
        let source = FFmpegFrameSource(frames: playback.frames, engine: nil, transform: playback.transform)
        return try SmoothPlaybackCoordinator(source: source, outputFramesPerSecond: rate, ordinary: true,
            ordinaryFrame: { [weak playback] in playback?.frameForPresentation(at: $0) }, ordinaryTransform: playback.transform,
            currentTime: { [weak playback] in playback?.presentationTimeSeconds ?? 0 },
            mediaTimeAtHostTime: { [weak playback] in playback?.presentationTime(atHostTime: $0) ?? 0 },
            isPlaying: { [weak playback] in playback?.isPlaying ?? false })
    }
    private func applyVisualSettings() {
        renderer?.setUserPaused(!requestedPlay)
        renderer?.videoScaleMode = videoScaleMode
        renderer?.enhancementAutomaticReduction = true
        renderer?.enhancementMode = enhancementMode
        renderer?.edgeUpscaling = edgeUpscaling
        renderer?.lowResolutionEnhancement = lowResolutionEnhancement
        renderer?.lowResolutionSource = playback?.info?.lowResolutionSource
        enhancementStatus = renderer?.enhancementStatus ?? SPText("현재 적용: 끔")
    }
    private func current(_ token: UInt, _ candidate: FFmpegPlayback) -> Bool { mediaGeneration == token && playback === candidate }
    private func startRefresh(token: UInt) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.mediaGeneration == token, self?.playback != nil else { return }
                self?.refresh()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    private func refresh() {
        refreshAudioSyncOutput()
        let time = playback?.currentTimeSeconds ?? 0
        position = time.isFinite ? max(0, time) : 0
        let length = playback?.duration ?? 0
        duration = length.isFinite ? max(0, length) : 0
        isPlaying = playback?.isPlaying ?? false
        renderer?.setUserPaused(!requestedPlay)
        systemPlaybackControls.update()
        if Date.now.timeIntervalSince(lastNASRecord) >= 10 { recordNASPosition(inBackground: true) }
        let presentation = playback?.presentationTimeSeconds ?? position
        subtitleText = externalSubtitle?.text(at: presentation)
        nativeSubtitles?.update(at: presentation)
        enhancementStatus = renderer?.enhancementStatus ?? SPText("현재 적용: 끔")
        if CommandLine.arguments.contains("--window-debug"), Int(position) / 3 != lastDebugSecond {
            lastDebugSecond = Int(position) / 3
            print("MAC_RENDER time=\(position) decoded=\(playback?.decodedVideoFrames ?? 0) presented=\(renderer?.presentedUniqueFrames ?? 0) surface=\(surface.map { String(describing: ObjectIdentifier($0)) } ?? "nil") window=\(surface?.window?.windowNumber ?? -1) paused=\(surface?.isPaused ?? true) delegate=\(surface?.delegate === renderer) drawable=\(surface?.drawableSize ?? .zero)")
            fflush(stdout)
        }
    }
    private func stopMedia(saveHistory: Bool = true) {
        systemPlaybackControls.close()
        if saveHistory { recordNASPosition() }
        accountTrial.flush()
        mediaGeneration &+= 1; renderGeneration &+= 1; subtitleGeneration &+= 1
        audioSyncTask?.cancel(); audioSyncTask = nil
        seekTask?.cancel(); seekTask = nil; pendingSeek = nil
        modelLoading?.cancel(); modelLoading = nil
        audioReloadTask?.cancel(); audioReloadTask = nil
        refreshTask?.cancel(); refreshTask = nil
        renderer?.close(); renderer = nil
        playback?.close(); playback = nil
        nativeSubtitles?.close(); nativeSubtitles = nil
        interpolator = nil; externalSubtitle = nil
        requestedPlay = false; requestedSmooth = false
        isLoading = false; isSeeking = false; preparingSmooth = false; smoothEnabled = false
        smoothStatus = SPText("부드럽게 끔")
        subtitleText = nil; subtitleFilename = nil; subtitleMessage = nil; subtitleTracks = []; selectedSubtitleTrackID = nil
        position = 0; duration = 0; isPlaying = false
    }
    private func recordNASPosition(inBackground: Bool = false) {
        guard let item = playlist.first(where: { $0.id == currentID }), let network = item.network,
              playback != nil, duration > 0 else { return }
        let c = network.client.connection
        _ = nasRecents.record(connectionID: c.id, entry: network.entry, position: position, duration: duration,
            completed: position >= duration - 2, share: c.kind == .smb ? c.share : nil, inBackground: inBackground)
        lastNASRecord = .now
    }

    private func audioConfigurationChanged(_ engine: AVAudioEngine) {
        guard let playback, playback.audioConfigurationNotificationObject === engine,
              !isLoading, let id = currentID, let item = playlist.first(where: { $0.id == id }) else { return }
        // The device may already have reset its sample clock. Use the last
        // published media position and create a fresh graph on the new output.
        let time = position, smoothing = requestedSmooth, token = mediaGeneration
        pause(); isLoading = true
        audioReloadTask?.cancel()
        audioReloadTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, mediaGeneration == token, !Task.isCancelled else { return }
            audioReloadTask = nil // prepare must not cancel its own caller.
            await prepare(item, at: time, shouldPlay: false, smoothing: smoothing)
        }
    }
    private func savePreferences() {
        guard !loadingPreferences, let preferences else { return }
        if let data = try? JSONEncoder().encode(audioSyncOffsets) { preferences.set(data, forKey: "audioSyncOffsets") }
        preferences.set(volume.isFinite ? min(1, max(0, volume)) : 1, forKey: "volume")
        preferences.set(enhancementMode.rawValue, forKey: "enhancement")
        preferences.set(edgeUpscaling, forKey: "edgeUpscaling")
        preferences.set(lowResolutionEnhancement, forKey: "lowResolutionEnhancement")
        preferences.set(videoScaleMode.rawValue, forKey: "scale")
        preferences.set(subtitleScale, forKey: "subtitleScale")
        preferences.set(smoothAtStart, forKey: "smoothAtStart")
        preferences.set(repeatMode.rawValue, forKey: "repeatMode")
        preferences.set(soundTarget.rawValue, forKey: "soundTarget")
        if let data = try? JSONEncoder().encode(sound.sanitized()) { preferences.set(data, forKey: "sound") }
        if let data = try? JSONEncoder().encode(soundPresets) { preferences.set(data, forKey: "soundPresets") }
    }

    private nonisolated static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "mts", "m2ts", "mpeg", "mpg", "wmv"]
    nonisolated static func supportsVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    private nonisolated static func enumerate(_ roots: [URL]) throws -> [MacPlaylistItem] {
        var files: [URL] = []
        for root in roots {
            try Task.checkCancellation()
            guard root.isFileURL else { throw MacPlaybackError.localOnly }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true, values.isPackage != true {
                let children = try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                for child in children {
                    let attributes = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if attributes.isRegularFile == true, attributes.isSymbolicLink != true { files.append(child) }
                    guard files.count <= 5_000 else { throw MacPlaybackError.tooManyFiles }
                }
            } else if values.isRegularFile == true { files.append(root) }
            guard files.count <= 5_000 else { throw MacPlaybackError.tooManyFiles }
        }
        var seen: Set<URL> = []
        files = files.filter { seen.insert($0.standardizedFileURL).inserted }
        let videos = files.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return videos.map { video in
            let siblings = files.filter { $0.deletingLastPathComponent().standardizedFileURL == video.deletingLastPathComponent().standardizedFileURL }
            let names = ExternalSubtitleFormat.matching(videoName: video.lastPathComponent, names: siblings.map(\.lastPathComponent))
            return MacPlaylistItem(id: UUID(), url: video, title: video.lastPathComponent,
                sidecars: names.compactMap { name in siblings.first { $0.lastPathComponent == name } }, network: nil)
        }
    }
    private struct ParsedSubtitle: Sendable { let track: SubtitleTrack?; let ass: Data? }
    private nonisolated static func readSubtitle(_ url: URL) throws -> ParsedSubtitle {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: SubtitleTrack.maximumBytes + 1) ?? Data()
        guard bytes.count <= SubtitleTrack.maximumBytes else { throw SubtitleError.tooLarge }
        return try parseSubtitle(bytes, name: url.lastPathComponent)
    }
    private nonisolated static func parseSubtitle(_ bytes: Data, name: String) throws -> ParsedSubtitle {
        if ["ass", "ssa"].contains((name as NSString).pathExtension.lowercased()) {
            return ParsedSubtitle(track: nil, ass: Data(try ExternalSubtitleFormat.decode(bytes).utf8))
        }
        return ParsedSubtitle(track: try SubtitleTrack.parse(data: bytes, filename: name), ass: nil)
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError { return SPText("재생 준비를 취소했습니다.") }
        if let error = error as? MacPlaybackError { return error.localizedDescription }
        if let error = error as? SubtitleError { return error.localizedDescription }
        if let error = error as? NativeSubtitleError { return error.localizedDescription }
        if let error = error as? FFmpegPlaybackError { return error.localizedDescription }
        if let error = error as? NASError { return error.localizedDescription }
        return SPText("선택한 파일을 열지 못했습니다. 파일 접근 권한과 지원 형식을 확인해 주세요.")
    }
}

private enum MacPlaybackError: LocalizedError {
    case noVideos, localOnly, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .noVideos: SPText("선택한 항목에 재생할 동영상이 없습니다.")
        case .localOnly: SPText("Mac에 있는 동영상 파일이나 폴더를 선택해 주세요.")
        case .tooManyFiles: SPText("한 번에 최대 5,000개 파일이 있는 폴더를 선택해 주세요.")
        }
    }
}

/// Balanced access remains alive for the entire selected playlist, including a
/// parent-folder grant used by its child files. No bookmark persists across runs.
private final class MacFileScope {
    private let url: URL
    private var active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    func close() { if active { active = false; url.stopAccessingSecurityScopedResource() } }
    deinit { close() }
}
