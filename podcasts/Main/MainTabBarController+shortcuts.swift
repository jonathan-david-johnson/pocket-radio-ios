import Foundation
import PocketCastsUtils

extension MainTabBarController {
    func setupKeyboardShortcuts() {
        // playback
        addKeyCommand(playPauseCommand)

        let skipBackCommand = UIKeyCommand(title: L10n.skipBack, action: #selector(handleSkipBack), input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command])
        addKeyCommand(skipBackCommand)

        let skipForwardCommand = UIKeyCommand(title: L10n.skipForward, action: #selector(handleSkipForward), input: UIKeyCommand.inputRightArrow, modifierFlags: [.command])
        addKeyCommand(skipForwardCommand)

        let openPlayerCommand = UIKeyCommand(title: L10n.keycommandOpenPlayer, action: #selector(handleOpenPlayer), input: UIKeyCommand.inputUpArrow, modifierFlags: [.command])
        addKeyCommand(openPlayerCommand)

        let closePlayerCommand = UIKeyCommand(title: L10n.keycommandClosePlayer, action: #selector(handleClosePlayer), input: UIKeyCommand.inputDownArrow, modifierFlags: [.command])
        addKeyCommand(closePlayerCommand)

        let decreaseSpeedCommand = UIKeyCommand(title: L10n.keycommandDecreaseSpeed, action: #selector(handleDecreaseSpeed), input: "[", modifierFlags: [.command])
        addKeyCommand(decreaseSpeedCommand)

        let increaseSpeedCommand = UIKeyCommand(title: L10n.keycommandIncreaseSpeed, action: #selector(handleIncreaseSpeed), input: "]", modifierFlags: [.command])
        addKeyCommand(increaseSpeedCommand)

        refreshTabKeyboardShortcuts()

        let searchCommand = UIKeyCommand(title: L10n.search, action: #selector(handleSearch), input: "f", modifierFlags: [.command])
        addKeyCommand(searchCommand)
    }

    /// Installs the ⌘1–⌘N tab shortcuts for the bar as it stands, retiring any
    /// previous set.
    ///
    /// Navigation shortcuts are **positional** over the visible slots, titles
    /// read from the slot. A destination that is not promoted has no shortcut,
    /// which is why the old ⌘4 Up Next binding is gone: Up Next is not promoted
    /// by default. Because they are positional, a controlled rebuild has to
    /// re-install them or ⌘N keeps the old title and lands on the old index.
    func refreshTabKeyboardShortcuts() {
        tabKeyCommands.forEach { removeKeyCommand($0) }

        tabKeyCommands = renderedDestinations.prefix(9).enumerated().map { index, destination in
            UIKeyCommand(title: destination.title(),
                         action: #selector(handleTabShortcut(_:)),
                         input: "\(index + 1)",
                         modifierFlags: [.command],
                         propertyList: index)
        }

        tabKeyCommands.forEach { addKeyCommand($0) }
    }

    @objc func handleSearch() {
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.searchRequested, object: nil)
    }

    @objc func handlePlayPauseKey() {
        PlaybackManager.shared.playPause()
    }

    @objc private func handleSkipBack() {
        // Live radio replaces skip with mute/stop (a seek would force a stream reconnect
        // and re-trigger the broadcaster's preroll). Ignore the shortcut for radio.
        if PlaybackManager.shared.shouldUseMuteControls() { return }
        PlaybackManager.shared.skipBack()
    }

    @objc private func handleSkipForward() {
        if PlaybackManager.shared.shouldUseMuteControls() { return }
        PlaybackManager.shared.skipForward()
    }

    @objc private func handleTabShortcut(_ sender: UIKeyCommand) {
        guard let index = sender.propertyList as? Int,
              let destination = renderedDestinations[safe: index] else { return }

        navigate(to: destination)
    }

    @objc private func handleDecreaseSpeed() {
        PlaybackManager.shared.decreasePlaybackSpeed()
    }

    @objc private func handleIncreaseSpeed() {
        PlaybackManager.shared.increasePlaybackSpeed()
    }

    @objc private func handleOpenPlayer() {
        NavigationManager.sharedManager.miniPlayer?.openFullScreenPlayer()
    }

    @objc private func handleClosePlayer() {
        NavigationManager.sharedManager.miniPlayer?.closeFullScreenPlayer()
    }

    @objc func textEditingDidStart() {
        removeKeyCommand(playPauseCommand)
    }

    @objc func textEditingDidEnd() {
        addKeyCommand(playPauseCommand)
    }
}
