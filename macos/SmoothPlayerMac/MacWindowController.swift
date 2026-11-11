import AppKit
import SwiftUI

/// Owns the actual player window, independent of popovers and panels becoming key.
@MainActor
final class MacWindowController: ObservableObject {
    @Published private(set) var isFullscreen = false
    @Published private(set) var controlsVisible = true
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var holds: Set<String> = []
    private var previousMouseEvents = false
    private var transitioning = false
    private let hideDelay = 3.0

    func attach(_ newWindow: NSWindow) {
        trace("attach \(newWindow.windowNumber) type=\(type(of: newWindow)) sheet=\(newWindow.isSheet)")
        guard !(newWindow is NSPanel), !newWindow.isSheet, newWindow.sheetParent == nil else { return }
        guard window !== newWindow else { return }
        detach()
        window = newWindow
        previousMouseEvents = newWindow.acceptsMouseMovedEvents
        newWindow.acceptsMouseMovedEvents = true
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        isFullscreen = newWindow.styleMask.contains(.fullScreen)
        let names: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.willCloseNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self, weak newWindow] note in
                let name = note.name
                Task { @MainActor [weak self, weak newWindow] in
                    guard let self, let newWindow, self.window === newWindow else { return }
                    self.receive(name)
                }
            }
        }
        revealControls()
    }

    func detach() {
        trace("detach \(window?.windowNumber ?? -1)")
        hideTask?.cancel(); hideTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window?.acceptsMouseMovedEvents = previousMouseEvents
        window = nil
        transitioning = false
        isFullscreen = false
        controlsVisible = true
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func toggleFullscreen() {
        trace("toggle window=\(window?.windowNumber ?? -1) transition=\(transitioning) sheet=\(window?.attachedSheet != nil)")
        guard let window, !transitioning, window.attachedSheet == nil else { return }
        revealControls()
        window.toggleFullScreen(nil)
    }

    @discardableResult
    func exitFullscreen() -> Bool {
        guard isFullscreen || window?.styleMask.contains(.fullScreen) == true else { return false }
        toggleFullscreen()
        return true
    }

    func setControlsHeld(_ held: Bool, reason: String) {
        if holds.contains(reason) != held { trace("hold \(reason)=\(held)") }
        if held { holds.insert(reason) } else { holds.remove(reason) }
        revealControls()
    }

    func revealControls() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
        if !controlsVisible { controlsVisible = true }
        NSCursor.setHiddenUntilMouseMoves(false)
        guard isFullscreen, holds.isEmpty, !transitioning,
              window?.isKeyWindow == true, window?.attachedSheet == nil,
              hideTask == nil else { return }
        // One sleeper regardless of mouse event frequency; mouse movement only
        // advances the deadline and never triggers video work or reconstruction.
        hideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { return }
                guard self.isFullscreen, self.holds.isEmpty, !self.transitioning,
                      let window = self.window, window.isKeyWindow, window.attachedSheet == nil else {
                    self.hideTask = nil; return
                }
                let remaining = self.hideDelay - (ProcessInfo.processInfo.systemUptime - self.lastInteraction)
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    continue
                }
                self.controlsVisible = false
                if let content = window.contentView,
                   content.bounds.contains(content.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
                self.hideTask = nil
                return
            }
        }
    }

    private func receive(_ name: Notification.Name) {
        trace("notification \(name.rawValue)")
        switch name {
        case NSWindow.willEnterFullScreenNotification:
            transitioning = true; isFullscreen = true
        case NSWindow.didEnterFullScreenNotification:
            transitioning = false; isFullscreen = true
        case NSWindow.willExitFullScreenNotification:
            transitioning = true
        case NSWindow.didExitFullScreenNotification:
            transitioning = false; isFullscreen = false
            holds.remove("transportHover"); holds.remove("titleHover")
            hideTask?.cancel(); hideTask = nil
        case NSWindow.willCloseNotification:
            // A single SwiftUI Window may be ordered out and reopened by Finder
            // document delivery using the same NSWindow. Keep its observation;
            // a close notification alone does not end that object's lifetime.
            hideTask?.cancel(); hideTask = nil
            transitioning = false; isFullscreen = false; controlsVisible = true
            NSCursor.setHiddenUntilMouseMoves(false)
            return
        default: break
        }
        revealControls()
    }

    private func trace(_ message: String) {
        if CommandLine.arguments.contains("--window-debug") {
            print("MAC_WINDOW \(message)"); fflush(stdout)
        }
    }
}

