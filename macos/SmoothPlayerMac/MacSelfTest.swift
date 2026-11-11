import AppKit
import Foundation
import MetalKit
import CoreAudio

/// Explicit local acceptance harness. Only the bundled, original synthetic video
/// and a generated subtitle are read. Normal launches never enter this path.
@MainActor
enum MacSelfTest {
    private static var started = false
    private enum Failure: Error { case check(String) }

    static func runIfRequested(model: MacPlayerModel, playerWindow: MacWindowController) async {
        guard CommandLine.arguments.contains("--self-test"), !started else { return }
        started = true
        // Presentation acceptance requires a visible surface. Launching the
        // executable from a terminal does not activate its SwiftUI window.
        NSApp.activate(ignoringOtherApps: true)
        playerWindow.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        if CommandLine.arguments.contains("--subtitle-size-test") {
            await runSubtitleSize()
            return
        }
        if CommandLine.arguments.contains("--repeat-test") {
            await runRepeat(model: model)
            return
        }
        if CommandLine.arguments.contains("--tv-seek-test") || CommandLine.arguments.contains("--audio-seek-test") {
            await runAudioSeek(model: model, requireAirPlay: CommandLine.arguments.contains("--tv-seek-test"))
            return
        }
        let clock = ProcessInfo.processInfo.systemUptime
        var rows: [[String: Any]] = []
        var stage = "open", failure: String?
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw Failure.check(message) }
        }
        func record() async {
            var row: [String: Any] = await model.diagnostics().mapValues { $0 as Any }
            row["stage"] = stage
            row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - clock
            row["position"] = model.position
            row["smoothEnabled"] = model.smoothEnabled
            row["playing"] = model.isPlaying
            row["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
            rows.append(row)
            print("MAC_ACCEPTANCE_STAGE \(stage)")
            if stage.hasPrefix("soak_"), let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("MAC_SOAK_METRICS \(text)")
            }
            fflush(stdout)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmoothPlayerMac/Validation", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let subtitle = support.appendingPathComponent("synthetic.srt")
        defer { try? FileManager.default.removeItem(at: subtitle) }
        do {
            stage = "scene_boundary_expiry"
            let boundary = try await MacSceneBoundaryValidation.run()
            rows.append(boundary.mapValues { $0 as Any }.merging(["stage": stage]) { _, new in new })
            print("MAC_ACCEPTANCE_STAGE \(stage)"); fflush(stdout)
            if CommandLine.arguments.contains("--account-fixture-test") {
                stage = "account_fixture_login_purchase_restore"
                try await MacAccountValidation.signInAndPurchase(model)
                await record()
            }
            stage = "open"
            guard let fixture = Bundle.main.url(forResource: "smooth-preview", withExtension: "mp4") else {
                throw Failure.check("missing bundled fixture")
            }
            model.volume = 0
            await model.open(urls: [fixture])
            try check(model.errorMessage == nil, "fixture failed to open")
            try check(model.playback?.info?.width == 1280 && model.playback?.info?.height == 720, "decoded dimensions")
            try check(model.playback?.info?.hasAudio == true, "missing audio stream")
            // Exercise the first renderer before any toggle can restart its timer.
            try await Task.sleep(for: .seconds(1))
            try check((model.renderer?.presentedUniqueFrames ?? 0) > 5, "first-open presentation did not start")
            await model.setSmooth(false)
            if !model.isPlaying { model.togglePlayback() }
            try await Task.sleep(for: .seconds(1.5))
            try check(model.position > 0.5, "ordinary clock did not advance")
            try check((model.playback?.audioRenderedFrames ?? 0) > 24_000, "audio node did not render")
            try check((model.renderer?.presentedUniqueFrames ?? 0) > 10, "no actual ordinary presentation")
            await record()

            stage = "system_media_pause"
            for _ in 0..<3 { model.systemPlaybackControls.handle(.pause) }
            let remotePaused = model.playback?.currentTimeSeconds ?? -1
            try await Task.sleep(for: .milliseconds(250))
            try check(!model.isPlaying && abs((model.playback?.currentTimeSeconds ?? -9) - remotePaused) < 0.025,
                      "remote pause did not stop the video clock")
            model.systemPlaybackControls.handle(.play)
            let remoteSeek = Task { await model.seek(to: 2) }
            await Task.yield()
            model.systemPlaybackControls.handle(.pause)
            await remoteSeek.value
            try await Task.sleep(for: .milliseconds(150))
            try check(!model.isPlaying, "seek restored playback after remote pause")
            model.systemPlaybackControls.handle(.play)
            await record()

            stage = "pause_seek"
            let soundResults = try await MacSoundValidation.run(model)
            rows.append(soundResults.mapValues { $0 as Any }.merging(["stage": "sound_presets_and_comparison"]) { _, new in new })
            print("MAC_ACCEPTANCE_STAGE sound_presets_and_comparison"); fflush(stdout)
            model.togglePlayback()
            let paused = model.playback?.currentTimeSeconds ?? -1
            try await Task.sleep(for: .milliseconds(250))
            try check(abs((model.playback?.currentTimeSeconds ?? -9) - paused) < 0.02, "paused clock advanced")
            await model.seek(to: 5)
            try check(abs((model.playback?.currentTimeSeconds ?? -1) - 5) < 0.15, "seek did not reach target")
            await record()

            stage = "smooth"
            await model.setSmooth(true)
            try check(model.smoothEnabled, "real interpolation did not start")
            if !model.isPlaying { model.togglePlayback() }
            try await Task.sleep(for: .seconds(2))
            try check((model.renderer?.presentedGeneratedFrames ?? 0) >= 5, "generated frames were not presented")
            try check(model.errorMessage == nil, "smooth playback error")
            await record()

            stage = "smooth_display_cadence"
            guard let smoothRenderer = model.renderer else { throw Failure.check("missing smooth renderer") }
            let screenMaximum = playerWindow.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            let expectedTarget = screenMaximum >= 120 ? 120 : 60
            try check(smoothRenderer.outputFramesPerSecond == Double(expectedTarget), "smooth target does not match display capability")
            let sampleStart = ProcessInfo.processInfo.systemUptime
            let firstUnique = smoothRenderer.presentedUniqueFrames
            let firstGenerated = smoothRenderer.presentedGeneratedFrames
            let firstMissed = smoothRenderer.missedPresentationDeadlines
            try await Task.sleep(for: .seconds(3))
            let sampleSeconds = ProcessInfo.processInfo.systemUptime - sampleStart
            let unique = smoothRenderer.presentedUniqueFrames - firstUnique
            let generated = smoothRenderer.presentedGeneratedFrames - firstGenerated
            try check(model.renderer === smoothRenderer && unique > 60 && generated > 20, "smooth presentation stalled")
            rows.append(["stage": stage, "targetFPS": expectedTarget, "displayMaximumFPS": screenMaximum,
                         "sampleSeconds": sampleSeconds, "uniqueFrames": unique, "generatedFrames": generated,
                         "observedUniqueFPS": Double(unique) / sampleSeconds,
                         "missedDeadlineDelta": smoothRenderer.missedPresentationDeadlines - firstMissed])
            print("MAC_ACCEPTANCE_STAGE \(stage)"); fflush(stdout)

            stage = "quality_and_scale"
            model.enhancementMode = .restoreSharp
            model.edgeUpscaling = true
            model.videoScaleMode = .fill
            try await Task.sleep(for: .seconds(0.5))
            try check(model.renderer?.effectiveEnhancementMode != .off, "enhancement shader not applied")
            model.videoScaleMode = .stretch
            try await Task.sleep(for: .seconds(0.5))
            model.videoScaleMode = .fit
            await record()

            if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--sd-fixture=") }) {
                let url = URL(fileURLWithPath: String(option.dropFirst("--sd-fixture=".count)))
                stage = "sd_open"
                await model.open(urls: [url]); model.volume = 0
                try check(model.playback?.info?.width == 640 && model.playback?.info?.height == 360 && model.playback?.info?.enhancementSDR == true, "SD fixture metadata")
                model.enhancementMode = .natural; model.edgeUpscaling = false
                await model.setSmooth(true); model.play()
                guard let renderer = model.renderer, let content = playerWindow.window?.contentView, let surface = metalView(in: content) else { throw Failure.check("SD surface missing") }
                surface.autoResizeDrawable = false; surface.drawableSize = CGSize(width: 1920,height: 1080)
                try await Task.sleep(for: .seconds(2))
                for enabled in [false,true,false,true] {
                    model.enhancementMode = .off; model.enhancementMode = .natural
                    model.lowResolutionEnhancement = enabled
                    try await Task.sleep(for: .seconds(1))
                    let before = renderer.presentedUniqueFrames, generated = renderer.presentedGeneratedFrames
                    let start = ProcessInfo.processInfo.systemUptime
                    try await Task.sleep(for: .seconds(3))
                    let elapsed = ProcessInfo.processInfo.systemUptime-start
                    try check(renderer.presentedUniqueFrames-before > 60, "SD presentation stalled")
                    try check(renderer.presentedGeneratedFrames-generated > 10, "SD interpolation stalled")
                    if enabled { try check(["저해상도 보정 적용 중", "재생 성능을 위해 기본 보정 사용", "부드러운 재생 우선 · 기본 보정"].contains(renderer.lowResolutionStatus), "SD state invalid: " + renderer.lowResolutionStatus) }
                    rows.append(["stage":"sd_cadence","enabled":enabled,"targetFPS":renderer.outputFramesPerSecond,
                        "seconds":elapsed,"uniqueFPS":Double(renderer.presentedUniqueFrames-before)/elapsed,
                        "status":renderer.lowResolutionStatus,"diagnostics":await renderer.generationDiagnostics()])
                }
                surface.autoResizeDrawable = true
                model.lowResolutionEnhancement = false
                await model.open(urls: [fixture]); await model.setSmooth(true); model.play()
            }

            stage = "external_subtitle"
            try "1\n00:00:00,000 --> 00:00:11,900\n스무스 플레이어 자막 검증\n".write(to: subtitle, atomically: true, encoding: .utf8)
            await model.loadSubtitle(subtitle)
            await model.seek(to: 2)
            if !model.isPlaying { model.togglePlayback() }
            try await Task.sleep(for: .milliseconds(500))
            try check(model.subtitleText?.contains("자막 검증") == true, "external subtitle missing")
            await record()
            await model.clearSubtitle()

            stage = "fullscreen_enter"
            await model.seek(to: 1)
            model.play()
            if playerWindow.isFullscreen {
                playerWindow.exitFullscreen()
                try await waitFor { !playerWindow.isFullscreen }
            }
            guard let window = playerWindow.window, let content = window.contentView,
                  let surface = metalView(in: content), let renderer = model.renderer else {
                throw Failure.check("missing actual player window/surface")
            }
            playerWindow.toggleFullscreen()
            try await waitFor { playerWindow.isFullscreen && window.styleMask.contains(.fullScreen) }
            let enteringFrames = renderer.presentedUniqueFrames
            let enteringTime = model.position
            try await Task.sleep(for: .seconds(1))
            let videoRect = surface.convert(surface.bounds, to: content)
            try check(metalView(in: content) === surface && model.renderer === renderer,
                      "fullscreen recreated video surface or renderer")
            try check(videoRect.width >= content.bounds.width - 2 && videoRect.height >= content.bounds.height - 2,
                      "fullscreen left space occupied by app chrome")
            try check(surface.delegate === renderer &&
                      renderer.presentedUniqueFrames > enteringFrames + 5 && model.position > enteringTime + 0.3,
                      "fullscreen presentation stopped")
            await record()
            stage = "fullscreen_exit"
            playerWindow.exitFullscreen()
            try await waitFor { !playerWindow.isFullscreen && !window.styleMask.contains(.fullScreen) }
            try await Task.sleep(for: .seconds(0.5))
            try check(metalView(in: content) === surface && model.renderer === renderer,
                      "fullscreen exit recreated video resources")
            await record()

            stage = "seek_toggle_stability"
            let iterations = CommandLine.arguments.contains("--long-test") ? 30 : 3
            for index in 0..<iterations {
                await model.seek(to: 1)
                await model.setSmooth(index % 3 != 2)
                if !model.isPlaying { model.togglePlayback() }
                try await Task.sleep(for: .seconds(4))
                try check(model.errorMessage == nil && model.position > 3, "playback stalled after seek or mode toggle")
                try check(model.renderer?.lastError == nil && model.playback?.lastError == nil, "render or decoder failure")
                await record()
            }
            if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--ftp-test-port=") }),
               let port = UInt16(option.dropFirst("--ftp-test-port=".count)), port > 0 {
                let storage = support.appendingPathComponent("ftp-fixture-\(UUID().uuidString).json")
                let browser = MacNetworkBrowserModel(storageURL: storage)
                let connection = NASConnection(name: "Synthetic loopback fixture", kind: .ftp,
                    host: "127.0.0.1", port: port, username: "mac-fixture")
                defer {
                    browser.close()
                    try? browser.remove(connection)
                    try? FileManager.default.removeItem(at: storage)
                }
                stage = "ftp_save_connect_list"
                let saved = try browser.save(connection, password: "synthetic-only-read")
                try check(try NASCredentialStore.password(for: saved.id) == "synthetic-only-read", "keychain round-trip")
                let metadata = try String(contentsOf: storage, encoding: .utf8)
                try check(!metadata.contains("synthetic-only-read"), "password was written to metadata")
                let reloaded = MacNetworkBrowserModel(storageURL: storage)
                try check(reloaded.connections.contains(where: { $0.id == saved.id }), "saved server not reloaded")
                reloaded.close()
                try await browser.connect(saved)
                guard let rootMovie = browser.entries.first(where: { $0.name == "synthetic-720p24.mp4" }),
                      let folder = browser.entries.first(where: { $0.isDirectory && $0.name.contains("100%") }) else {
                    throw Failure.check("FTP root entries missing")
                }
                try check(!browser.visibleEntries.contains(where: { $0.name.hasSuffix(".srt") }), "FTP subtitle listed as a movie")
                await record()
                stage = "ftp_mp4_play_seek"
                await model.openNetwork(try browser.selection(for: rootMovie))
                try check(model.errorMessage == nil && model.duration > 230, "FTP MP4 failed to open")
                await model.seek(to: 180)
                model.play()
                try await Task.sleep(for: .seconds(1.5))
                try check(model.errorMessage == nil && model.position >= 180 && model.position < 185, "FTP MP4 seek failed")
                try check(model.subtitleText?.contains("180초") == true, "FTP MP4 sidecar missing")
                try check((model.playback?.audioRenderedFrames ?? 0) > 24_000, "FTP audio did not render")
                await record()

                stage = "ftp_korean_folder_back"
                try await browser.enter(folder)
                try check(browser.canGoBack && browser.currentPath.contains("100%"), "FTP encoded folder entry failed")
                try await browser.goBack()
                try check(browser.currentPath == "/", "FTP back navigation failed")
                try await browser.enter(folder)
                guard let movie = browser.entries.first(where: { $0.name == "한글 영상.mkv" }) else {
                    throw Failure.check("FTP Korean MKV missing")
                }
                let selection = try browser.selection(for: movie)
                browser.close() // Playback must retain its own selected client.
                await model.openNetwork(selection)
                try check(model.errorMessage == nil && model.duration > 230, "FTP MKV failed after browser close")
                await record()

                stage = "ftp_mkv_smooth_seek_subtitle"
                await model.seek(to: 180)
                await model.setSmooth(true)
                model.play()
                try await Task.sleep(for: .seconds(2))
                try check(model.errorMessage == nil && model.position >= 180 && model.position < 186, "FTP MKV smooth seek stalled")
                try check((model.renderer?.presentedGeneratedFrames ?? 0) >= 5, "FTP generated frames missing")
                try check(model.subtitleText?.contains("180초") == true, "FTP MKV sidecar missing")
                await record()
            }
            if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--soak-seconds=") }) {
                guard let seconds = Double(option.dropFirst("--soak-seconds=".count)),
                      seconds.isFinite, seconds >= 60, seconds <= 7200,
                      model.account.hasPaidAccess,
                      CommandLine.arguments.contains("--account-fixture-test"),
                      let fixture = Bundle.main.url(forResource: "smooth-soak", withExtension: "mp4") else {
                    throw Failure.check("Soak requires a synthetic fixture and the isolated account test")
                }
                await model.open(urls: [fixture])
                try check(model.duration > seconds + 20, "soak fixture is too short")
                model.volume = 0
                let soakStart = ProcessInfo.processInfo.systemUptime
                var phase = -1
                while ProcessInfo.processInfo.systemUptime - soakStart < seconds {
                    let elapsed = ProcessInfo.processInfo.systemUptime - soakStart
                    let nextPhase = elapsed < seconds / 6 ? 0 : (elapsed < seconds / 2 ? 1 : 2)
                    if phase != nextPhase {
                        phase = nextPhase
                        model.enhancementMode = phase == 2 ? .restoreSharp : .off
                        model.edgeUpscaling = phase == 2
                        await model.setSmooth(phase != 0)
                        model.play()
                    }
                    stage = ["soak_original", "soak_smooth", "soak_smooth_quality"][phase]
                    let beforePosition = model.position
                    let beforeFrames = model.renderer?.presentedUniqueFrames ?? 0
                    let beforeGenerated = model.renderer?.presentedGeneratedFrames ?? 0
                    try await Task.sleep(for: .seconds(10))
                    try check(model.errorMessage == nil && model.renderer?.lastError == nil && model.playback?.lastError == nil,
                              "soak decoder or renderer error")
                    try check(model.position > beforePosition + 5 && (model.renderer?.presentedUniqueFrames ?? 0) > beforeFrames,
                              "soak presentation stalled")
                    if phase != 0 {
                        try check(model.smoothEnabled && (model.renderer?.presentedGeneratedFrames ?? 0) > beforeGenerated,
                                  "soak interpolation stopped")
                    }
                    await record()
                }
            }
            if CommandLine.arguments.contains("--account-fixture-test") {
                stage = "account_fixture_refund"
                try await MacAccountValidation.refund(model)
                await record()
                stage = "account_fixture_complimentary"
                try await MacAccountValidation.complimentary(model)
                await record()
            }
            stage = "close"
            model.close()
            try check(model.renderer == nil && model.playback == nil, "player retained resources after close")
            await record()
        } catch {
            if case Failure.check(let reason) = error { failure = reason }
            else if case MacSceneBoundaryValidation.Failure.check(let reason) = error { failure = reason }
            else if case MacAccountValidation.Failure.check(let reason) = error { failure = reason }
            else { failure = "test operation failed at \(stage)" }
            await record()
            model.close()
        }
        await model.finishValidationAccount()
        let result: [String: Any] = ["passed": failure == nil, "failure": failure ?? "none",
            "stage": stage, "seconds": ProcessInfo.processInfo.systemUptime - clock,
            "hardware": "Apple Silicon", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "audio": "Muted AVAudioEngine rendering; acoustic continuity is not measured",
            "accountProvider": CommandLine.arguments.contains("--account-fixture-test") ? "loopback synthetic provider; not a live Toss transaction" : "no login or payment tested",
            "scope": "Original synthetic 720p24 SDR fixtures; real Metal display/fullscreen and Core ML-generated frames. FTP only on explicitly selected loopback test port. No private media, TV or YouTube.",
            "stages": rows]
        let destination = support.appendingPathComponent("mac-acceptance.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination, options: .atomic)
        }
        print("MAC_ACCEPTANCE_RESULT \(failure == nil ? "PASS" : "FAIL") \(destination.path)")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// Isolated files in two folders exercise the real EOF/seek path without user history.
    private static func runRepeat(model: MacPlayerModel) async {
        let directory = URL.temporaryDirectory.appending(path: "smooth-repeat-\(UUID())")
        var failure: String?
        var completed: [String] = []
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure.check(message) }
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw Failure.check("Timed out after \(completed.last ?? "open")")
        }
        do {
            guard let fixture = Bundle.main.url(forResource: "smooth-preview", withExtension: "mp4") else { throw Failure.check("fixture missing") }
            let a = directory.appending(path: "A"), b = directory.appending(path: "B")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let first = a.appending(path: "01.mp4"), second = a.appending(path: "02.mp4"), unrelated = b.appending(path: "other.mp4")
            for url in [first, second, unrelated] { try FileManager.default.copyItem(at: fixture, to: url) }
            model.volume = 0; model.smoothAtStart = false
            await model.open(urls: [first, unrelated])
            try check(model.errorMessage == nil, "open failed")
            model.repeatMode = .folder
            await model.seek(to: model.duration - 0.15); model.play()
            try await wait { model.title == "02.mp4" && model.isPlaying }
            try check(model.position < 2, "next video resumed instead of starting at zero")
            try check(model.playlist.allSatisfy { $0.url?.deletingLastPathComponent().standardizedFileURL.path == a.standardizedFileURL.path }, "crossed folder boundary")
            completed.append("folder-next-from-start")
            await model.seek(to: model.duration - 0.15)
            try await wait { model.title == "01.mp4" && model.isPlaying }
            completed.append("folder-wrap")
            model.repeatMode = .one
            let current = model.currentID
            await model.seek(to: model.duration - 0.15)
            try await wait { model.position < 1 && model.isPlaying }
            try check(model.currentID == current, "one changed video")
            completed.append("one-restarts-same-decoder")
            model.repeatMode = .off
            await model.seek(to: model.duration - 0.15)
            try await wait { !model.isPlaying && model.position >= model.duration - 0.2 }
            try check(model.currentID == current, "off advanced")
            completed.append("off-stops")
            model.repeatMode = .one
            model.play(); model.pause()
            try await Task.sleep(for: .milliseconds(400))
            try check(!model.isPlaying, "pause lost to restart")
            completed.append("pause-wins")
        } catch { failure = String(describing: error) }
        model.close(); await model.finishValidationAccount()
        try? FileManager.default.removeItem(at: directory)
        let report: [String: Any] = ["passed": failure == nil, "failure": failure ?? "none", "checks": completed]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) {
            print("MAC_REPEAT_RESULT \(text)"); fflush(stdout)
        }
        NSApp.terminate(nil)
    }

    /// Opt-in physical AirPlay route check using isolated self-test models and the bundled preview.
    private static func runAudioSeek(model: MacPlayerModel, requireAirPlay: Bool) async {
        var rows: [[String: Double]] = []
        var failure: String?
        func outputTransport() throws -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
                throw Failure.check("default audio route unavailable")
            }
            address.mSelector = kAudioDevicePropertyTransportType
            var transport: UInt32 = 0
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
                throw Failure.check("audio transport unavailable")
            }
            return transport
        }
        do {
            let initialTransport = try outputTransport()
            guard !requireAirPlay || initialTransport == kAudioDeviceTransportTypeAirPlay else {
                throw Failure.check("physical AirPlay audio route is required")
            }
            guard let fixture = Bundle.main.url(forResource: "smooth-preview", withExtension: "mp4") else {
                throw Failure.check("missing preview")
            }
            model.volume = 0.25
            await model.open(urls: [fixture]); model.pause()
            guard model.errorMessage == nil, let playback = model.playback else { throw Failure.check("preview open failed") }
            var signalBlocks = 0
            playback.onProcessedAudioPCM = { samples, _ in
                if samples.contains(where: { abs($0) > 0.0001 }) { signalBlocks += 1 }
            }
            defer { playback.onProcessedAudioPCM = nil }
            for (index, target) in [6.0, 1.0, 7.0, 2.0].enumerated() {
                model.pause()
                await model.setSmooth(index >= 2)
                let signalBefore = signalBlocks
                await model.seek(to: target); model.play()
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while model.position < target + 1.5, model.errorMessage == nil,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                var row = await model.diagnostics()
                row["stage"] = Double(index); row["target"] = target
                row["position"] = model.position; row["signalBlocks"] = Double(signalBlocks - signalBefore)
                row["airPlayOutput"] = try outputTransport() == kAudioDeviceTransportTypeAirPlay ? 1 : 0
                rows.append(row)
                print("MAC_AUDIO_SEEK stage=\(index) position=\(model.position) audioFrames=\(playback.audioRenderedFrames) signalBlocks=\(signalBlocks - signalBefore)"); fflush(stdout)
                guard model.errorMessage == nil, model.position > target + 1,
                      playback.audioRenderedFrames > 48_000, signalBlocks - signalBefore > 10,
                      (!requireAirPlay || row["airPlayOutput"] == 1) else { throw Failure.check("audio did not resume on the required output after seek") }
                model.pause()
            }
        } catch { failure = String(describing: error) }
        model.close(); await model.finishValidationAccount()
        let directory = URL.applicationSupportDirectory.appending(path: "SmoothPlayerMac/Validation")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["passed": failure == nil, "failure": failure ?? "none", "stages": rows,
            "requiredAirPlay": requireAirPlay,
            "scope": requireAirPlay
                ? "Physical system AirPlay audio route, synthetic preview, rendered audio and signal counters. TV-speaker acoustics require listening confirmation."
                : "Local synthetic preview, rendered audio and signal counters after repeated seeks. No TV qualification."]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: directory.appending(path: requireAirPlay ? "mac-tv-seek.json" : "mac-local-seek.json"), options: .atomic)
        }
        print("MAC_AUDIO_SEEK_RESULT \(failure == nil ? "PASS" : "FAIL")"); fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func runSubtitleSize() async {
        let namespace = "com.nodelabs.smoothplayer.mac.subtitle-validation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        let subtitle = URL.temporaryDirectory.appending(path: namespace + ".ass")
        let model = MacPlayerModel(preferencesOverride: defaults)
        var failure: String?
        do {
            let ass = """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: 1280
            PlayResY: 720
            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,30,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:00.00,0:00:20.00,Default,,0,0,0,,Shared subtitle size
            """
            try Data(ass.utf8).write(to: subtitle)
            guard let fixture = Bundle.main.url(forResource: "smooth-preview", withExtension: "mp4") else {
                throw Failure.check("missing preview")
            }
            model.volume = 0
            func width() -> Double { Double(model.nativeSubtitles?.images.reduce(CGRect.null) { $0.union($1.rectangle) }.width ?? 0) }
            func waitForWidth(above minimum: Double) async throws -> Double {
                for _ in 0..<200 {
                    if width().isFinite, width() > minimum { return width() }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw Failure.check("subtitle size did not reach renderer")
            }
            await model.open(urls: [fixture]); model.pause()
            await model.loadSubtitle(subtitle)
            let original = try await waitForWidth(above: 0)
            model.setSubtitleScale(1.5)
            let enlarged = try await waitForWidth(above: original * 1.25)
            await model.open(urls: [fixture]); model.pause()
            await model.loadSubtitle(subtitle)
            let next = try await waitForWidth(above: original * 1.25)
            let restored = MacPlayerModel(preferencesOverride: defaults)
            guard restored.subtitleScale == 1.5, defaults.double(forKey: "subtitleScale") == 1.5 else {
                throw Failure.check("subtitle size was not restored")
            }
            restored.close(); await restored.finishValidationAccount()
            print("MAC_SUBTITLE_SIZE widths=\(original),\(enlarged),\(next) restoredScale=1.5")
        } catch { failure = String(describing: error) }
        model.close(); await model.finishValidationAccount()
        defaults.removePersistentDomain(forName: namespace)
        try? FileManager.default.removeItem(at: subtitle)
        print("MAC_SUBTITLE_SIZE_RESULT \(failure == nil ? "PASS" : "FAIL") \(failure ?? "")"); fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func metalView(in view: NSView) -> MTKView? {
        if let metal = view as? MTKView { return metal }
        for child in view.subviews { if let metal = metalView(in: child) { return metal } }
        return nil
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.check("window transition timed out")
    }
}
