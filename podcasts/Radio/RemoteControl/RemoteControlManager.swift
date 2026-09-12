import Foundation
import Supabase
import UIKit
import PocketCastsServer

extension Notification.Name {
    static let remoteControlPresenceChanged = Notification.Name("remoteControlPresenceChanged")
    static let remoteControlTargetChanged = Notification.Name("remoteControlTargetChanged")
}

class RemoteControlManager {
    static let shared = RemoteControlManager()

    private let deviceIdKey = "pocketradio-device-id"

    private var client: SupabaseClient?
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var loginObserver: NSObjectProtocol?

    // MARK: - Presence & target

    private(set) var presenceList: [String: RemotePresence] = [:]
    private(set) var activeTargetDeviceId: String?

    var activeTargetName: String? {
        guard let id = activeTargetDeviceId else { return nil }
        return presenceList[id]?.deviceName
    }

    func otherDevices() -> [RemotePresence] {
        presenceList.values.filter { $0.deviceId != deviceId }.sorted { $0.deviceName < $1.deviceName }
    }

    func setTarget(_ id: String?) {
        activeTargetDeviceId = id
        NotificationCenter.default.post(name: .remoteControlTargetChanged, object: nil)
        print("🌐 RemoteControl: target set to \(id ?? "nil")")
    }

    func setup() {
        loginObserver = NotificationCenter.default.addObserver(forName: .userSignedIn, object: nil, queue: .main) { [weak self] _ in
            self?.start()
        }
        // Also handle token refresh / re-auth path
        NotificationCenter.default.addObserver(forName: .userLoginDidChange, object: nil, queue: .main) { [weak self] _ in
            if SyncManager.isUserLoggedIn() {
                self?.startOrScheduleRetry()
            } else {
                self?.stop()
            }
        }
        if SyncManager.isUserLoggedIn() {
            startOrScheduleRetry()
        }
    }

    private func startOrScheduleRetry() {
        if ServerSettings.userId != nil {
            start()
        } else {
            print("🌐 RemoteControl: userId nil at launch, retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startOrScheduleRetry()
            }
        }
    }

    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }

    func start() {
        guard channel == nil else { return }
        guard let userId = ServerSettings.userId, !userId.isEmpty else { return }
        guard let urlString = Bundle.main.infoDictionary?["SUPABASE_URL"] as? String,
              let url = URL(string: urlString) else { return }
        let anonKey = Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String ?? ""

        let supabase = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                global: .init(headers: ["x-user-uuid": userId])
            )
        )
        client = supabase

        let ch = supabase.channel("remote:\(userId)") { config in
            config.broadcast.receiveOwnBroadcasts = false
            config.presence.key = deviceId
        }
        channel = ch

        listenTask = Task { [weak self] in
            guard let self else { return }
            for await msg in ch.broadcastStream(event: "command") {
                self.handleIncomingBroadcast(msg)
            }
        }

        presenceTask = Task { [weak self] in
            guard let self else { return }
            for await action in ch.presenceChange() {
                for (key, presenceV2) in action.joins {
                    if let data = try? JSONEncoder().encode(presenceV2.state),
                       let presence = try? JSONDecoder().decode(RemotePresence.self, from: data) {
                        self.presenceList[key] = presence
                        print("🌐 RemoteControl:   join device=\(key) name=\(presence.deviceName)")
                    }
                }
                for key in action.leaves.keys {
                    self.presenceList.removeValue(forKey: key)
                    if self.activeTargetDeviceId == key {
                        self.setTarget(nil)
                    }
                    print("🌐 RemoteControl:   leave device=\(key)")
                }
                print("🌐 RemoteControl: presence_diff joins=\(action.joins.count) leaves=\(action.leaves.count) total=\(self.presenceList.count)")
                NotificationCenter.default.post(name: .remoteControlPresenceChanged, object: nil)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await ch.subscribe()
            print("🌐 RemoteControl: subscribed channel=remote:\(userId) device=\(deviceId)")
            await self.trackPresence(channel: ch)
        }

        observePlaybackNotifications()
    }

    func stop() {
        listenTask?.cancel()
        presenceTask?.cancel()
        listenTask = nil
        presenceTask = nil
        Task { [weak self] in
            guard let ch = self?.channel else { return }
            await ch.unsubscribe()
        }
        channel = nil
        client = nil
        removePlaybackObservers()
    }

    func updatePresence() {
        guard let ch = channel else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.trackPresence(channel: ch)
        }
    }

    /// Send a command to a specific device. Provide nil targetDeviceId to broadcast to all.
    func send(command: String, to targetDeviceId: String, payload: RemoteCommandPayload? = nil) {
        guard let ch = channel, let userId = ServerSettings.userId else { return }
        let cmd = RemoteCommand(
            commandId: UUID().uuidString,
            fromDeviceId: deviceId,
            targetDeviceId: targetDeviceId,
            command: command,
            payload: payload,
            sentAt: ISO8601DateFormatter().string(from: Date())
        )
        Task {
            do {
                try await ch.broadcast(event: "command", message: cmd)
                print("🌐 RemoteControl: sent command=\(command) to=\(targetDeviceId) from=\(userId)")
            } catch {
                print("🌐 RemoteControl: broadcast failed: \(error)")
            }
        }
    }

    // MARK: - Private

    private func trackPresence(channel: RealtimeChannelV2) async {
        let pm = PlaybackManager.shared
        let episode = pm.currentEpisode
        let playing = pm.isPlaying

        let playbackState: String
        if episode == nil {
            playbackState = "idle"
        } else if playing {
            playbackState = "playing"
        } else {
            playbackState = "paused"
        }

        let station = episode as? RadioStation
        let presence = RemotePresence(
            deviceId: deviceId,
            deviceType: "ios",
            deviceName: UIDevice.current.name,
            role: "sender",
            playback: RemotePlaybackState(
                state: playbackState,
                stationId: station?.stationId,
                stationName: station?.title,
                artworkUrl: nil
            ),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await channel.track(presence)
            print("🌐 RemoteControl: tracked presence state=\(playbackState)")
        } catch {
            print("🌐 RemoteControl: presence track failed: \(error)")
        }
    }

    private func handleIncomingBroadcast(_ msg: JSONObject) {
        guard let data = try? JSONEncoder().encode(msg),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else {
            print("🌐 RemoteControl: failed to decode incoming command")
            return
        }
        guard cmd.targetDeviceId == deviceId else { return }
        print("🌐 RemoteControl: received command=\(cmd.command) from=\(cmd.fromDeviceId) id=\(cmd.commandId)")
    }

    // MARK: - Remote routing

    func sendLoadStationNow() {
        sendLoadStationIfTargeted()
    }

    private func sendLoadStationIfTargeted() {
        guard let targetId = activeTargetDeviceId else { return }
        guard let station = PlaybackManager.shared.currentEpisode as? RadioStation else { return }
        send(command: "load_station", to: targetId, payload: RemoteCommandPayload(
            stationId: station.uuid,
            stationUrl: station.streamUrl,
            stationName: station.title
        ))
    }

    private func sendPlayPauseIfTargeted(playing: Bool) {
        guard let targetId = activeTargetDeviceId else { return }
        guard PlaybackManager.shared.currentEpisode is RadioStation else { return }
        send(command: playing ? "play" : "pause", to: targetId)
    }

    // MARK: - Playback observers

    private var playbackObservers: [NSObjectProtocol] = []

    private func observePlaybackNotifications() {
        let center = NotificationCenter.default
        let add: (Notification.Name, @escaping () -> Void) -> NSObjectProtocol = { name, block in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updatePresence()
                block()
            }
        }
        playbackObservers = [
            add(Constants.Notifications.playbackStarted) { [weak self] in
                self?.sendLoadStationIfTargeted()
            },
            add(Constants.Notifications.playbackPaused) { [weak self] in
                self?.sendPlayPauseIfTargeted(playing: false)
            },
            add(Constants.Notifications.playbackTrackChanged) { [weak self] in
                self?.sendLoadStationIfTargeted()
            }
        ]
    }

    private func removePlaybackObservers() {
        playbackObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playbackObservers = []
    }
}
