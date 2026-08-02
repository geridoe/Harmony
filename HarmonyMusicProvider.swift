//
//  HarmonyMusicProvider.swift
//  Harmony
//
//  Provider-neutral contracts. Concrete MusicKit and Spotify SDK clients can
//  replace the mocks without changing session or queue code.
//

import Foundation
import CryptoKit

struct SpotifyPKCEChallenge: Equatable {
    let verifier: String
    let challenge: String

    static func make() -> SpotifyPKCEChallenge {
        let bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max) }
        let verifier = base64URL(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return SpotifyPKCEChallenge(verifier: verifier, challenge: base64URL(Data(digest)))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum SpotifyAuthorizationRequest {
    static func url(challenge: SpotifyPKCEChallenge, state: String = UUID().uuidString) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: HarmonySupabaseConfiguration.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: HarmonySupabaseConfiguration.spotifyRedirectURI.absoluteString),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "user-read-private user-read-email user-read-playback-state user-modify-playback-state app-remote-control")
        ]
        return components.url!
    }
}

/// The state of a user's provider account on this device.
///
/// This intentionally distinguishes a connected account from a provider that
/// can actually receive playback commands. Spotify App Remote, for example,
/// also needs the Spotify app installed and an active remote connection.
enum ProviderConnectionState: Hashable {
    case disconnected
    case authorizing
    case connected(accountName: String?)
    case requiresSubscription
    case requiresProviderApp
    case unavailable(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .disconnected: return "Not connected"
        case .authorizing: return "Connecting…"
        case let .connected(accountName): return accountName ?? "Connected"
        case .requiresSubscription: return "Subscription required"
        case .requiresProviderApp: return "Provider app required"
        case let .unavailable(reason): return reason
        }
    }
}

enum ProviderPlaybackCapability: Hashable {
    /// The provider can play a Harmony queue item from this device.
    case queuePlayback
    /// Harmony can hand the track off to the provider, but cannot control it.
    case openInProvider
    /// The track or account cannot play through this provider.
    case unavailable(reason: String)

    var availability: ProviderAvailability {
        switch self {
        case .queuePlayback: return .playable
        case .openInProvider: return .openInProvider
        case .unavailable: return .unavailable
        }
    }
}

struct ProviderCapabilities: Hashable {
    let canSearchCatalog: Bool
    let canResolveTracks: Bool
    let canControlPlayback: Bool
    let supportsBackgroundPlayback: Bool
    let requirementsSummary: String

    static let appleMusicMock = ProviderCapabilities(
        canSearchCatalog: true,
        canResolveTracks: true,
        canControlPlayback: true,
        supportsBackgroundPlayback: true,
        requirementsSummary: "Requires MusicKit authorization and an Apple Music subscription for playback."
    )

    static let spotifyMock = ProviderCapabilities(
        canSearchCatalog: true,
        canResolveTracks: true,
        canControlPlayback: true,
        supportsBackgroundPlayback: false,
        requirementsSummary: "Requires Spotify authorization, the Spotify app, and Premium for remote playback control."
    )
}

struct ResolvedProviderTrack: Hashable, Identifiable {
    let provider: MusicProvider
    let providerID: String
    let title: String
    let artist: String
    let playbackCapability: ProviderPlaybackCapability

    var id: String { "\(provider.rawValue):\(providerID)" }
}

enum ProviderPlaybackCommand: Hashable {
    case play(ResolvedProviderTrack)
    case pause
    case resume
    case skip
}

enum ProviderPlaybackResult: Hashable {
    case applied
    case requiresOpenInProvider
    case unavailable(reason: String)
}

enum ProviderAdapterError: LocalizedError, Hashable {
    case notConnected(MusicProvider)
    case trackUnavailable(MusicProvider)
    case unsupportedPlayback(MusicProvider)

    var errorDescription: String? {
        switch self {
        case let .notConnected(provider): return "Connect \(provider.name) before using it."
        case let .trackUnavailable(provider): return "This track is unavailable on \(provider.name)."
        case let .unsupportedPlayback(provider): return "\(provider.name) cannot accept this playback command."
        }
    }
}

/// A provider-specific implementation boundary. Do not place OAuth secrets or
/// developer tokens in implementations of this protocol on the device.
protocol HarmonyMusicProvider: AnyObject {
    var provider: MusicProvider { get }
    var connectionState: ProviderConnectionState { get }
    var capabilities: ProviderCapabilities { get }

    func search(query: String) async throws -> [HarmonyTrack]
    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack
    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult
}

/// Simulator-safe Apple Music behavior. Replace with a MusicKit-backed client
/// after the App ID has MusicKit enabled and the user grants authorization.
final class MockAppleMusicProvider: HarmonyMusicProvider {
    let provider: MusicProvider = .appleMusic
    var connectionState: ProviderConnectionState
    let capabilities = ProviderCapabilities.appleMusicMock
    private let catalog: [HarmonyTrack]

    init(catalog: [HarmonyTrack] = SampleCatalog.tracks, connectionState: ProviderConnectionState = .connected(accountName: "Mock Apple Music")) {
        self.catalog = catalog
        self.connectionState = connectionState
    }

    func search(query: String) async throws -> [HarmonyTrack] {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return catalog.filter { $0.availability(for: provider) != .unavailable } }
        return catalog.filter {
            $0.availability(for: provider) != .unavailable &&
                "\($0.title) \($0.artist) \($0.album)".lowercased().contains(term)
        }
    }

    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        try resolvedTrack(for: track)
    }

    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        if case let .play(track) = command, track.playbackCapability == .openInProvider { return .requiresOpenInProvider }
        return .applied
    }

    private func resolvedTrack(for track: HarmonyTrack) throws -> ResolvedProviderTrack {
        guard let mapping = track.mappings.first(where: { $0.provider == provider }), !mapping.providerID.isEmpty else {
            throw ProviderAdapterError.trackUnavailable(provider)
        }
        let capability: ProviderPlaybackCapability = mapping.availability == .playable ? .queuePlayback : .openInProvider
        return ResolvedProviderTrack(provider: provider, providerID: mapping.providerID, title: track.title, artist: track.artist, playbackCapability: capability)
    }
}

/// Simulator-safe Spotify behavior. A production implementation will use PKCE
/// OAuth plus the Spotify iOS App Remote; it must not include a client secret.
final class MockSpotifyProvider: HarmonyMusicProvider {
    let provider: MusicProvider = .spotify
    var connectionState: ProviderConnectionState
    let capabilities = ProviderCapabilities.spotifyMock
    private let catalog: [HarmonyTrack]

    init(catalog: [HarmonyTrack] = SampleCatalog.tracks, connectionState: ProviderConnectionState = .connected(accountName: "Mock Spotify")) {
        self.catalog = catalog
        self.connectionState = connectionState
    }

    func search(query: String) async throws -> [HarmonyTrack] {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return catalog.filter { $0.availability(for: provider) != .unavailable } }
        return catalog.filter {
            $0.availability(for: provider) != .unavailable &&
                "\($0.title) \($0.artist) \($0.album)".lowercased().contains(term)
        }
    }

    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        guard let mapping = track.mappings.first(where: { $0.provider == provider }), !mapping.providerID.isEmpty else {
            throw ProviderAdapterError.trackUnavailable(provider)
        }
        let capability: ProviderPlaybackCapability = mapping.availability == .playable ? .queuePlayback : .openInProvider
        return ResolvedProviderTrack(provider: provider, providerID: mapping.providerID, title: track.title, artist: track.artist, playbackCapability: capability)
    }

    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult {
        guard connectionState.isConnected else { throw ProviderAdapterError.notConnected(provider) }
        if case let .play(track) = command {
            switch track.playbackCapability {
            case .queuePlayback: return .applied
            case .openInProvider: return .requiresOpenInProvider
            case let .unavailable(reason): return .unavailable(reason: reason)
            }
        }
        return .applied
    }
}

/// One injection point for feature code. It makes the local prototype and
/// future production adapters interchangeable.
final class MusicProviderRegistry {
    private let adapters: [MusicProvider: HarmonyMusicProvider]

    init(adapters: [HarmonyMusicProvider] = [MockAppleMusicProvider(), MockSpotifyProvider()]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
    }

    func adapter(for provider: MusicProvider) -> HarmonyMusicProvider? {
        adapters[provider]
    }
}
