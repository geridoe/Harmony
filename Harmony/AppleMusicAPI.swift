import Foundation
import MusicKit

enum AppleMusicProviderError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case subscriptionRequired
    case trackUnavailable
    case emptySearch
    case catalogUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow Harmony to access Apple Music in Settings."
        case .permissionRestricted: return "Apple Music access is restricted on this device. Check Screen Time or device-management settings."
        case .subscriptionRequired: return "An active Apple Music subscription is required for catalog playback."
        case .trackUnavailable: return "This track is unavailable in the current Apple Music storefront."
        case .emptySearch: return "Enter a song, artist, or album to search Apple Music."
        case .catalogUnavailable: return "Apple Music could not load the catalog. Check your connection and try again."
        }
    }
}

/// Small, provider-independent evidence record used to associate a song result
/// with the exact album result returned in the same catalog request. Keeping
/// this matching deterministic also makes it testable without MusicKit access.
struct AppleCatalogAlbumEvidence: Equatable {
    let providerID: String
    let title: String
    let artist: String
    let storefront: String?
    let artworkURL: URL?
    let deepLinkURL: URL?
    let upc: String?
    let releaseDate: Date?
    let trackCount: Int
    let isSingle: Bool?
}

func matchingAppleAlbum(
    title: String?,
    artist: String,
    candidates: [AppleCatalogAlbumEvidence]
) -> AppleCatalogAlbumEvidence? {
    guard let title, !title.isEmpty else { return nil }
    let normalizedTitle = normalizedAppleCatalogText(title)
    let normalizedArtist = normalizedAppleCatalogText(artist)
    return candidates.first {
        normalizedAppleCatalogText($0.title) == normalizedTitle
            && normalizedAppleCatalogText($0.artist) == normalizedArtist
    } ?? candidates.first {
        normalizedAppleCatalogText($0.title) == normalizedTitle
    }
}

private func normalizedAppleCatalogText(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            if status == .restricted {
                connectionState = .unavailable(reason: AppleMusicProviderError.permissionRestricted.localizedDescription)
                throw AppleMusicProviderError.permissionRestricted
            }
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
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw AppleMusicProviderError.emptySearch }
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [MusicKit.Song.self, MusicKit.Album.self]
        )
        request.limit = 20
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            throw AppleMusicProviderError.catalogUnavailable
        }
        let albumEvidence = response.albums.map(Self.albumEvidence)
        return response.songs.map { song in
            songsByID[song.id.rawValue] = song
            let album = matchingAppleAlbum(
                title: song.albumTitle,
                artist: song.artistName,
                candidates: albumEvidence
            )
            let mappingStorefront = Self.storefront(from: song.url)
            return HarmonyTrack(
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle ?? "",
                duration: song.duration ?? 0,
                symbol: "music.note",
                artworkURL: song.artwork?.url(width: 300, height: 300),
                isExplicit: song.contentRating == .explicit,
                isrc: song.isrc,
                mappings: [ProviderTrackMapping(
                    provider: .appleMusic,
                    providerID: song.id.rawValue,
                    storefront: mappingStorefront,
                    availability: .playable,
                    deepLinkURL: song.url
                )],
                reviewableAlbum: album.map {
                    ReviewableAlbum(
                        provider: .appleMusic,
                        providerID: $0.providerID,
                        storefront: $0.storefront ?? mappingStorefront,
                        title: $0.title,
                        artist: $0.artist,
                        artworkURL: $0.artworkURL,
                        deepLinkURL: $0.deepLinkURL,
                        upc: $0.upc,
                        releaseDate: $0.releaseDate,
                        totalTracks: $0.trackCount,
                        albumType: $0.isSingle.map { $0 ? "single" : "album" }
                    )
                }
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
        case .seek(let position):
            player.playbackTime = max(0, position)
        }
        return .applied
    }

    func playbackSnapshot() async throws -> ProviderPlaybackSnapshot? {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        return ProviderPlaybackSnapshot(
            providerTrackID: nil,
            position: player.playbackTime,
            isPlaying: player.state.playbackStatus == .playing,
            observedAt: Date()
        )
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

    private static func storefront(from url: URL?) -> String? {
        guard let component = url?.pathComponents.dropFirst().first?.lowercased(),
              component.count == 2,
              component.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return component
    }

    private static func albumEvidence(_ album: MusicKit.Album) -> AppleCatalogAlbumEvidence {
        AppleCatalogAlbumEvidence(
            providerID: album.id.rawValue,
            title: album.title,
            artist: album.artistName,
            storefront: storefront(from: album.url),
            artworkURL: album.artwork?.url(width: 600, height: 600),
            deepLinkURL: album.url,
            upc: album.upc,
            releaseDate: album.releaseDate,
            trackCount: album.trackCount,
            isSingle: album.isSingle
        )
    }
}
