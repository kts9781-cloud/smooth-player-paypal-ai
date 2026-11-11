import Foundation
import MediaPlayer

/// Car/headset/Control Center commands control the complete video transport.
/// Only the current player owns the process-wide command center.
@MainActor
final class SystemPlaybackControls {
    enum Command { case play, pause, stop, toggle }
    struct State {
        var title: String
        var position: Double
        var duration: Double
        var playing: Bool
    }
    private static weak var owner: SystemPlaybackControls?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var state: (() -> State)?
    private var play: (() -> Void)?
    private var pause: (() -> Void)?
    private var published: State?
    var isActive: Bool { Self.owner === self }

    func activate(state: @escaping () -> State, play: @escaping () -> Void, pause: @escaping () -> Void) {
        self.state = state; self.play = play; self.pause = pause
        if !isActive {
            Self.owner?.close()
            Self.owner = self
            let center = MPRemoteCommandCenter.shared()
            for (remote, command) in [(center.playCommand, Command.play), (center.pauseCommand, .pause),
                                      (center.stopCommand, .stop), (center.togglePlayPauseCommand, .toggle)] {
                remote.isEnabled = true
                let token = remote.addTarget { [weak self] _ in
                    // Finish in delivery order before acknowledging the command.
                    if Thread.isMainThread {
                        return MainActor.assumeIsolated { self?.handle(command) ?? .commandFailed }
                    }
                    return DispatchQueue.main.sync { self?.handle(command) ?? .commandFailed }
                }
                targets.append((remote, token))
            }
        }
        update()
    }

    @discardableResult
    func handle(_ command: Command) -> MPRemoteCommandHandlerStatus {
        guard isActive, let state, let play, let pause else { return .commandFailed }
        switch command {
        case .play: play()
        case .pause, .stop: pause()
        case .toggle: if state().playing { pause() } else { play() }
        }
        update()
        return .success
    }

    func update() {
        guard isActive, let value = state?() else { return }
        if let old = published, old.title == value.title, old.playing == value.playing,
           old.duration == value.duration, abs(old.position - value.position) < 1 { return }
        published = value
        var info: [String: Any] = [MPMediaItemPropertyTitle: value.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: value.position.isFinite ? max(0, value.position) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: value.playing ? 1.0 : 0.0]
        if value.duration.isFinite, value.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = value.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = value.playing ? .playing : .paused
        #endif
    }

    func close() {
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        if isActive {
            Self.owner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            #endif
        }
        state = nil; play = nil; pause = nil
        published = nil
    }
}
