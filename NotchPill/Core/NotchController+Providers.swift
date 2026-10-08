import AppKit
import Combine

@MainActor
extension NotchController {
    func wireProviders() {
        devCommands.onUpdate = { [weak self] commands in self?.state.devCommands = commands }
        nowPlaying.onUpdate = { [weak self] np in self?.state.notifyMediaChanged(np) }
        calendar.onUpdate = { [weak self] event in self?.state.nextEvent = event }
        airDrop.onUpdate = { [weak self] status in self?.state.airDrop = status }
        appSwitch.onFrontmostApp = { [weak self] name, icon in self?.state.setFrontmostApp(name, icon: icon) }
        appSwitch.onSwitch = { [weak self] name, icon in self?.state.notifyAppSwitched(name, icon: icon) }
        systemStats.onUpdate = { [weak self] stats in self?.state.updateSystemStats(stats) }
        battery.onUpdate = { [weak self] status in self?.state.updateBattery(status) }

        AppSettings.shared.$showExpandedCommands
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.devCommands.start() } else {
                    self.devCommands.stop()
                    self.state.devCommands = []
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$showExpandedMedia
            .combineLatest(AppSettings.shared.$showCollapsedMedia)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.nowPlaying.start() } else { self.nowPlaying.stop() }
            }
            .store(in: &cancellables)

        AppSettings.shared.$showExpandedActiveApp
            .combineLatest(AppSettings.shared.$showCollapsedAppSwitch)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.appSwitch.start() } else { self.appSwitch.stop() }
            }
            .store(in: &cancellables)
        volume.start()
        AudioOutputStore.shared.start()
        if let level = volume.currentVolume() { state.refreshSystemVolume(level) }
        volume.onVolumeChanged = { [weak self] level in self?.state.showVolume(level) }
        brightness.onBrightnessChanged = { [weak self] level in self?.state.showBrightness(level) }
        microphone.onMuteChanged = { [weak self] muted in self?.state.showMicrophoneMuted(muted) }
        brightness.start()
        microphone.start()
        devReady.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "signal") }
        // Murmur's opt-in caption mirror. Nothing appears unless that app is
        // installed and the user switched it on, so there is no cost to
        // everyone else: the file simply never exists.
        dictation.onCaption = { [weak self] caption in
            guard let self else { return }
            let scale = AppSettings.shared.captionScale
            let width = NotchContentLayout.peekWidthCeiling(metrics: self.metrics,
                                                            wrapping: true, scale: scale)
            self.presentDevReady(
                Self.alert(for: caption, width: width,
                           maxLines: NotchContentLayout.titleMaxLines(scale: scale)),
                origin: "dictation")
        }
        // Hookless finished peeks. Emits the same title/subtitle/sessionId as the
        // hooks, so DevReadyDedup collapses the pair when both are active.
        transcripts.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "transcript") }
        cursorActivity.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "cursordb") }
        agentSessions.onUpdate = { [weak self] sessions in
            self?.state.agentSessions = sessions
            self?.refreshCI(for: sessions)
        }
        agentSessions.onOpenCodeUsageUpdate = { [weak self] usage in
            self?.state.openCodeUsage = usage
        }
        agentSessions.onCodexQuotaUpdate = { [weak self] quota in
            self?.state.codexQuota = quota
        }
        agentSessions.onClaudeQuotaUpdate = { [weak self] quota in
            self?.state.claudeQuota = quota
        }
        agentSessions.onCursorQuotaUpdate = { [weak self] quota in
            self?.state.cursorQuota = quota
        }
        AppSettings.shared.$showClaudeUsage
            .combineLatest(AppSettings.shared.$showCursorUsage)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] claudeEnabled, cursorEnabled in
                self?.agentSessions.clearDisabledUsage(claudeEnabled: claudeEnabled,
                                                       cursorEnabled: cursorEnabled)
            }
            .store(in: &cancellables)
        AppSettings.shared.$showExpandedAgents
            .combineLatest(AppSettings.shared.$showClaudeUsage,
                           AppSettings.shared.$showCursorUsage,
                           AppSettings.shared.$showExpandedCI)
            .map { $0 || $1 || $2 || $3 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.agentSessions.start() } else {
                    self.agentSessions.stop()
                    self.state.agentSessions = []
                    self.state.openCodeUsage = nil
                    self.state.codexQuota = nil
                    self.state.claudeQuota = nil
                    self.state.cursorQuota = nil
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$showDevReadyPings
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.dictation.start()
                    self.transcripts.start()
                    self.cursorActivity.start()
                } else {
                    self.dictation.stop()
                    self.transcripts.stop()
                    self.cursorActivity.stop()
                }
            }
            .store(in: &cancellables)
        AppSettings.shared.$showDevReadyPings
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.devReady.start() } else { self.devReady.stop() }
            }
            .store(in: &cancellables)

        // The clipboard is only watched while the setting is on, and turning it
        // off clears what was already remembered rather than merely hiding it.
        if AppSettings.shared.showClipboard { ClipboardStore.shared.start() }
        AppSettings.shared.$showClipboard
            .removeDuplicates()
            .sink { on in
                if on { ClipboardStore.shared.start() } else { ClipboardStore.shared.stop() }
            }
            .store(in: &cancellables)

        // The shell is not started here even when the card is on: it costs a
        // process and a profile read, and the card is one of seventeen that
        // may never come up. `TerminalStore` starts it the first time someone
        // clicks into it. Turning the setting off does kill it, so switching
        // the card away never leaves a shell running invisibly.
        AppSettings.shared.$showTerminal
            .removeDuplicates()
            .sink { on in if !on { TerminalStore.shared.stop() } }
            .store(in: &cancellables)

        AppSettings.shared.$showCalendar
            .combineLatest(AppSettings.shared.$showExpandedCalendar,
                           AppSettings.shared.$showCollapsedActivity)
            .map { ($0 && $2) || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.calendar.start() } else { self.calendar.stop() }
            }
            .store(in: &cancellables)

        AppSettings.shared.$showCollapsedSystemStats
            .combineLatest(AppSettings.shared.$showExpandedSystemStats)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.systemStats.start()
                } else {
                    self.systemStats.stop()
                    self.state.updateSystemStats(nil)
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$showCollapsedBattery
            .combineLatest(AppSettings.shared.$showExpandedBattery)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.battery.start()
                } else {
                    self.battery.stop()
                    self.state.updateBattery(nil)
                }
            }
            .store(in: &cancellables)

        // Providers with visible controls are enabled only while their cards
        // are configured to appear.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.airDrop.start()
        }

        state.$isExpanded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, let level = self.volume.currentVolume() else { return }
                self.state.refreshSystemVolume(level)
            }
            .store(in: &cancellables)
    }
}
