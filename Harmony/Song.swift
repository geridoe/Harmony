//
//  Song.swift
//  Harmony
//
//  Created by Geri Doe on 8/5/22.
//

import Foundation
import SwiftUI

enum MusicProvider: String, CaseIterable, Hashable, Identifiable { case appleMusic, spotify; var id: String { rawValue }; var name: String { self == .appleMusic ? "Apple Music" : "Spotify" } }
enum ProviderAvailability: String, Hashable { case playable, openInProvider, unavailable; var label: String { self == .playable ? "Ready" : self == .openInProvider ? "Open" : "Unavailable" } }
struct ProviderTrackMapping: Hashable { let provider: MusicProvider; let providerID: String; let availability: ProviderAvailability }
struct HarmonyTrack: Identifiable, Hashable {
    let id = UUID(); let title: String; let artist: String; let album: String; let duration: TimeInterval; let symbol: String; let mappings: [ProviderTrackMapping]
    func availability(for provider: MusicProvider) -> ProviderAvailability { mappings.first(where: { $0.provider == provider })?.availability ?? .unavailable }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}
enum SessionRole: Equatable { case conductor, collaborator; var label: String { self == .conductor ? "Conductor" : "Collaborator" } }
struct SessionMember: Identifiable, Hashable { let id = UUID(); let name: String; let initials: String; let role: SessionRole; let providers: Set<MusicProvider> }
struct QueueItem: Identifiable, Hashable { let id = UUID(); let track: HarmonyTrack; let addedBy: SessionMember }
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

final class HarmonySessionStore: ObservableObject {
    @Published var queue: [QueueItem]
    @Published var queueRevision = 12
    @Published var playbackState: PlaybackState = .playing
    @Published var connectedProviders: Set<MusicProvider> = [.appleMusic, .spotify]
    @Published private(set) var events: [QueueEvent] = []
    let sessionName = "Friday Night Finds"
    let inviteCode = "HARMONY-8Q4"
    let currentMember: SessionMember
    let members: [SessionMember]
    let catalog: [HarmonyTrack]
    init() {
        let alex = SessionMember(name: "Alex Morgan", initials: "AM", role: .conductor, providers: [.appleMusic, .spotify])
        let sam = SessionMember(name: "Sam Lee", initials: "SL", role: .collaborator, providers: [.spotify])
        let priya = SessionMember(name: "Priya Shah", initials: "PS", role: .collaborator, providers: [.appleMusic])
        currentMember = alex; members = [alex, sam, priya]; catalog = SampleCatalog.tracks
        queue = [QueueItem(track: catalog[0], addedBy: sam), QueueItem(track: catalog[2], addedBy: priya), QueueItem(track: catalog[1], addedBy: alex)]
    }
    var nowPlaying: QueueItem? { queue.first }
    func add(_ track: HarmonyTrack) {
        guard !queue.contains(where: { $0.track.title == track.title }) else { return }
        queue.append(QueueItem(track: track, addedBy: currentMember))
        record(.add)
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
        record(.remove)
    }

    func move(from: IndexSet, to: Int) {
        guard currentMember.role == .conductor else { return }
        queue.move(fromOffsets: from, toOffset: to)
        record(.move)
    }

    func togglePlayback() {
        guard currentMember.role == .conductor else { return }
        playbackState = playbackState == .playing ? .paused : .playing
        record(playbackState == .playing ? .play : .pause)
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
