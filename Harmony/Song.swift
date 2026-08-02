//
//  Song.swift
//  Harmony
//
//  Created by Geri Doe on 8/5/22.
//

import Foundation
import SwiftUI

enum MusicProvider: String, CaseIterable, Hashable, Identifiable { case appleMusic, spotify; var id: String { rawValue }; var name: String { self == .appleMusic ? "Apple Music" : "Spotify" } }
enum ProviderAccountStatus: Equatable {
    case setupRequired, notConnected, connected

    var label: String {
        switch self {
        case .setupRequired: return "Setup required"
        case .notConnected: return "Not connected"
        case .connected: return "Connected"
        }
    }
}
enum ProviderAvailability: String, Hashable { case playable, openInProvider, unavailable; var label: String { self == .playable ? "Ready" : self == .openInProvider ? "Open" : "Unavailable" } }
struct ProviderTrackMapping: Hashable { let provider: MusicProvider; let providerID: String; let availability: ProviderAvailability }
struct HarmonyTrack: Identifiable, Hashable {
    let id = UUID(); let title: String; let artist: String; let album: String; let duration: TimeInterval; let symbol: String; let mappings: [ProviderTrackMapping]
    func availability(for provider: MusicProvider) -> ProviderAvailability { mappings.first(where: { $0.provider == provider })?.availability ?? .unavailable }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}
enum SessionRole: Equatable { case conductor, collaborator; var label: String { self == .conductor ? "Conductor" : "Collaborator" } }
struct SessionMember: Identifiable, Hashable { let id: UUID; let name: String; let initials: String; let role: SessionRole; let providers: Set<MusicProvider>; init(id: UUID = UUID(), name: String, initials: String, role: SessionRole, providers: Set<MusicProvider>) { self.id = id; self.name = name; self.initials = initials; self.role = role; self.providers = providers } }
struct QueueItem: Identifiable, Hashable { let id: UUID; let track: HarmonyTrack; let addedBy: SessionMember; init(id: UUID = UUID(), track: HarmonyTrack, addedBy: SessionMember) { self.id = id; self.track = track; self.addedBy = addedBy } }
enum PlaybackState { case playing, paused }

enum QueueCommandType: String, Codable {
    case add, move, remove, play, pause
}

struct QueueEvent: Identifiable, Hashable {
    let id: UUID
    let revision: Int
    let actorID: UUID
    let type: QueueCommandType
    let createdAt: Date

    init(revision: Int, actorID: UUID, type: QueueCommandType) {
        self.id = UUID()
        self.revision = revision
        self.actorID = actorID
        self.type = type
        self.createdAt = Date()
    }
}

@MainActor
final class HarmonySessionStore: ObservableObject {
    @Published var queue: [QueueItem]
    @Published var queueRevision = 12
    @Published var playbackState: PlaybackState = .playing
    @Published private(set) var providerStates: [MusicProvider: ProviderAccountStatus] = [.appleMusic: .setupRequired, .spotify: .setupRequired]
    @Published private(set) var events: [QueueEvent] = []
    @Published var sessionName = "Friday Night Finds"
    @Published var inviteCode = "HARMONY-8Q4"
    @Published var collaborationMessage = "Local prototype"
    @Published private(set) var isConnectingSpotify = false
    @Published private(set) var activeMemberIDs: Set<UUID> = []
    private var remoteSessionID: UUID?
    private var liveQueueSubscription: LiveQueueSubscription?
    private var livePresenceSubscription: LivePresenceSubscription?
    private let collaborationRepository = HarmonyCollaborationRepository()
    @Published private(set) var currentMember: SessionMember
    @Published private(set) var members: [SessionMember]
    let catalog: [HarmonyTrack]
    init() {
        let alex = SessionMember(name: "Alex Morgan", initials: "AM", role: .conductor, providers: [.appleMusic, .spotify])
        let sam = SessionMember(name: "Sam Lee", initials: "SL", role: .collaborator, providers: [.spotify])
        let priya = SessionMember(name: "Priya Shah", initials: "PS", role: .collaborator, providers: [.appleMusic])
        currentMember = alex; members = [alex, sam, priya]; catalog = SampleCatalog.tracks
        queue = [QueueItem(track: catalog[0], addedBy: sam), QueueItem(track: catalog[2], addedBy: priya), QueueItem(track: catalog[1], addedBy: alex)]
    }
    var nowPlaying: QueueItem? { queue.first }
    var isLiveSession: Bool { remoteSessionID != nil }
    func providerState(for provider: MusicProvider) -> ProviderAccountStatus { providerStates[provider] ?? .notConnected }

    func refreshProviderConnections() async {
        do {
            let connections = try await collaborationRepository.providerConnections()
            let connected = Set(connections.compactMap { connection -> MusicProvider? in
                switch connection.provider {
                case "apple_music": return .appleMusic
                case "spotify": return .spotify
                default: return nil
                }
            })
            providerStates = Dictionary(uniqueKeysWithValues: MusicProvider.allCases.map {
                ($0, connected.contains($0) ? .connected : .notConnected)
            })
        } catch {
            collaborationMessage = "Could not load connection status: \(error.localizedDescription)"
        }
    }

    func connectSpotify() async {
        guard !isConnectingSpotify else { return }
        isConnectingSpotify = true
        defer { isConnectingSpotify = false }
        do {
            let response = try await SpotifyAuthorizationCoordinator().authorize()
            try await collaborationRepository.exchangeSpotifyAuthorization(response)
            await refreshProviderConnections()
            collaborationMessage = "Spotify connected"
        } catch {
            collaborationMessage = "Spotify connection failed: \(error.localizedDescription)"
        }
    }

    func applyPresence(joins: Set<UUID>, leaves: Set<UUID>) {
        activeMemberIDs.formUnion(joins)
        activeMemberIDs.subtract(leaves)
    }
    func add(_ track: HarmonyTrack) {
        guard !queue.contains(where: { $0.track.title == track.title }) else { return }
        queue.append(QueueItem(track: track, addedBy: currentMember))
        record(.add)
        guard let remoteSessionID else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteAdd(track, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
        record(.remove)
        guard let remoteSessionID else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteRemove(item.id, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func move(from: IndexSet, to: Int) {
        guard currentMember.role == .conductor else { return }
        guard let movedItemID = from.first.map({ queue[$0].id }) else { return }
        queue.move(fromOffsets: from, toOffset: to)
        record(.move)
        guard let remoteSessionID else { return }
        guard let destination = queue.firstIndex(where: { $0.id == movedItemID }) else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteMove(movedItemID, position: Double(destination + 1) * 1024, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func togglePlayback() {
        guard currentMember.role == .conductor else { return }
        playbackState = playbackState == .playing ? .paused : .playing
        record(playbackState == .playing ? .play : .pause)
        guard let remoteSessionID else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemotePlayback(sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func createLiveSession() async {
        collaborationMessage = "Connecting…"
        do {
            let remoteSession = try await collaborationRepository.createSession(title: sessionName)
            sessionName = remoteSession.title
            inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            remoteSessionID = remoteSession.id
            collaborationMessage = "Live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
        } catch {
            collaborationMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func joinLiveSession(inviteCode: String) async {
        collaborationMessage = "Joining…"
        do {
            let remoteSession = try await collaborationRepository.joinSession(inviteCode: inviteCode)
            sessionName = remoteSession.title
            self.inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            remoteSessionID = remoteSession.id
            collaborationMessage = "Joined live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
        } catch {
            collaborationMessage = "Join failed: \(error.localizedDescription)"
        }
    }

    private func applyRemoteAdd(_ track: HarmonyTrack, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.add(track: track, to: sessionID, expectedRevision: expectedRevision)
            collaborationMessage = "Live Supabase session"
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func refreshRemoteQueue() async {
        guard let remoteSessionID else { return }
        do {
            async let remoteSession = collaborationRepository.session(id: remoteSessionID)
            async let remoteQueue = collaborationRepository.queue(for: remoteSessionID)
            async let remoteMembers = collaborationRepository.members(for: remoteSessionID)
            async let currentUserID = collaborationRepository.currentUserID()
            let (session, snapshot, remoteMemberRecords, userID) = try await (remoteSession, remoteQueue, remoteMembers, currentUserID)
            sessionName = session.title
            inviteCode = session.inviteCode
            queueRevision = session.queueRevision
            if session.playbackState?.status == "playing" { playbackState = .playing }
            if session.playbackState?.status == "paused" { playbackState = .paused }
            members = remoteMemberRecords.map { member in
                let name = member.profile.displayName
                return SessionMember(id: member.profileID, name: name, initials: String(name.prefix(2)).uppercased(), role: member.role == "conductor" ? .conductor : .collaborator, providers: [])
            }
            if let me = members.first(where: { $0.id == userID }) { currentMember = me }
            queue = snapshot.map { remote in
                let track = catalog.first(where: { $0.title == remote.canonicalTrack.title && $0.artist == remote.canonicalTrack.artist })
                    ?? HarmonyTrack(title: remote.canonicalTrack.title, artist: remote.canonicalTrack.artist, album: remote.canonicalTrack.album ?? "", duration: TimeInterval(remote.canonicalTrack.durationMilliseconds ?? 0) / 1000, symbol: "music.note", mappings: [])
                return QueueItem(id: remote.id, track: track, addedBy: members.first(where: { $0.id == remote.addedBy }) ?? currentMember)
            }
        } catch {
            collaborationMessage = "Could not refresh queue: \(error.localizedDescription)"
        }
    }

    private func applyRemoteRemove(_ queueItemID: UUID, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.remove(queueItemID: queueItemID, from: sessionID, expectedRevision: expectedRevision)
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func applyRemoteMove(_ queueItemID: UUID, position: Double, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.move(queueItemID: queueItemID, to: position, in: sessionID, expectedRevision: expectedRevision)
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func applyRemotePlayback(sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.setPlayback(state: playbackState, in: sessionID, expectedRevision: expectedRevision)
        } catch {
            collaborationMessage = "Playback sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func subscribeToRemoteQueue(_ sessionID: UUID) async {
        do {
            liveQueueSubscription = try await collaborationRepository.observeQueue(sessionID: sessionID) { [weak self] in
                Task { @MainActor in await self?.refreshRemoteQueue() }
            }
        } catch {
            collaborationMessage = "Live session connected, but updates are delayed."
        }
    }

    private func subscribeToPresence(_ sessionID: UUID) async {
        do {
            let profileID = try await collaborationRepository.currentUserID()
            activeMemberIDs.insert(profileID)
            livePresenceSubscription = try await collaborationRepository.observePresence(sessionID: sessionID, profileID: profileID) { [weak self] joins, leaves in
                Task { @MainActor in
                    self?.applyPresence(joins: joins, leaves: leaves)
                }
            }
        } catch {
            // Presence is an enhancement; room membership and queue sync remain usable.
            collaborationMessage = "Live session connected, but member activity is delayed."
        }
    }

    private func record(_ type: QueueCommandType) {
        queueRevision += 1
        events.append(QueueEvent(revision: queueRevision, actorID: currentMember.id, type: type))
    }
}

enum SampleCatalog {
    static func mappings(_ apple: String, _ spotify: String) -> [ProviderTrackMapping] { [ProviderTrackMapping(provider: .appleMusic, providerID: apple, availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: spotify, availability: .playable)] }
    static let tracks = [
        HarmonyTrack(title: "Afterglow", artist: "Wolves at Noon", album: "Motion Blur", duration: 221, symbol: "sun.max.fill", mappings: mappings("am.afterglow", "spotify:track:afterglow")),
        HarmonyTrack(title: "Neon Coast", artist: "Daya Rose", album: "Neon Coast", duration: 194, symbol: "sparkles", mappings: mappings("am.neon", "spotify:track:neon")),
        HarmonyTrack(title: "Seventeen", artist: "The Ferns", album: "Paper Rooms", duration: 248, symbol: "leaf.fill", mappings: mappings("am.seventeen", "spotify:track:seventeen")),
        HarmonyTrack(title: "Switchback", artist: "KITE CLUB", album: "Switchback", duration: 203, symbol: "bolt.fill", mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: "am.switch", availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: "spotify:track:switch", availability: .openInProvider)]),
        HarmonyTrack(title: "Blue Hour", artist: "Eloise Harbor", album: "Slow Light", duration: 216, symbol: "moon.stars.fill", mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: "am.blue", availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: "", availability: .unavailable)])
    ]
}
