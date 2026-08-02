import Foundation
import MusicKit

enum AppleMusicProviderError: LocalizedError {
    case permissionDenied
    case subscriptionRequired
    case trackUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow Harmony to access Apple Music in Settings."
        case .subscriptionRequired: return "An active Apple Music subscription is required for catalog playback."
        case .trackUnavailable: return "This track is unavailable in the current Apple Music storefront."
        }
    }
}

@MainActor
protocol AppleMusicProviding: HarmonyMusicProvider {
    func authorize() async throws
}

@MainActor
final class AppleMusicProvider: AppleMusicProviding {
    let provider: MusicProvider = .appleMusic
    private(set) var connectionState: ProviderConnectionState = .disconnected
    let capabilities = ProviderCapabilities.appleMusicMock

    private let player = ApplicationMusicPlayer.shared
    private var songsByID: [String: MusicKit.Song] = [:]

    func authorize() async throws {
        connectionState = .authorizing
        guard await MusicAuthorization.request() == .authorized else {
            connectionState = .unavailable(reason: AppleMusicProviderError.permissionDenied.localizedDescription)
            throw AppleMusicProviderError.permissionDenied
        }
        let subscription = try await MusicSubscription.current
        guard subscription.canPlayCatalogContent else {
            connectionState = .requiresSubscription
            throw AppleMusicProviderError.subscriptionRequired
        }
        connectionState = .connected(accountName: nil)
    }

    func search(query: String) async throws -> [HarmonyTrack] {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        var request = MusicCatalogSearchRequest(term: query, types: [MusicKit.Song.self])
        request.limit = 20
        let response = try await request.response()
        return response.songs.map { song in
            songsByID[song.id.rawValue] = song
            return HarmonyTrack(
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle ?? "",
                duration: song.duration ?? 0,
                symbol: "music.note",
                mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: song.id.rawValue, availability: .playable)]
            )
        }
    }

    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        guard let mapping = track.mappings.first(where: { $0.provider == provider }), !mapping.providerID.isEmpty else {
            throw ProviderAdapterError.trackUnavailable(provider)
        }
        _ = try await song(for: mapping.providerID)
        return ResolvedProviderTrack(
            provider: provider,
            providerID: mapping.providerID,
            title: track.title,
            artist: track.artist,
            playbackCapability: mapping.availability == .playable ? .queuePlayback : .openInProvider
        )
    }

    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        switch command {
        case let .play(track):
            guard track.playbackCapability == .queuePlayback else { return .requiresOpenInProvider }
            let song = try await song(for: track.providerID)
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await player.play()
        case .pause:
            player.pause()
        case .resume:
            try await player.play()
        case .skip:
            try await player.skipToNextEntry()
        }
        return .applied
    }

    private func song(for providerID: String) async throws -> MusicKit.Song {
        if let cached = songsByID[providerID] { return cached }
        let request = MusicCatalogResourceRequest<MusicKit.Song>(
            matching: \.id,
            equalTo: MusicItemID(providerID)
        )
        guard let song = try await request.response().items.first else {
            throw AppleMusicProviderError.trackUnavailable
        }
        songsByID[providerID] = song
        return song
    }
}
