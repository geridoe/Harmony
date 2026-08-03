//
//  HarmonyMusicProvider.swift
//  Harmony
//
//  Provider-neutral contracts. Concrete MusicKit and Spotify SDK clients can
//  replace the mocks without changing session or queue code.
//

import Foundation
import CryptoKit
import AuthenticationServices
import UIKit
@preconcurrency import SpotifyiOS

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
        url(challenge: challenge, state: state, clientID: HarmonySupabaseConfiguration.spotifyClientID, redirectURI: HarmonySupabaseConfiguration.spotifyRedirectURI)
    }

    static func url(challenge: SpotifyPKCEChallenge, state: String, clientID: String, redirectURI: URL) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "user-read-private user-read-email user-read-playback-state user-read-recently-played user-modify-playback-state app-remote-control")
        ]
        return components.url!
    }
}

struct SpotifyAuthorizationResponse: Equatable {
    let code: String
    let codeVerifier: String
}

enum SpotifyAuthorizationError: LocalizedError {
    case invalidCallback, stateMismatch, denied

    var errorDescription: String? {
        switch self {
        case .invalidCallback: return "Spotify returned an invalid authorization response."
        case .stateMismatch: return "Spotify authorization could not be verified. Please try again."
        case .denied: return "Spotify authorization was cancelled."
        }
    }
}

/// Owns the short-lived web authentication session used for Spotify's PKCE flow.
/// It returns only an authorization code and verifier; refresh tokens stay server-side.
@MainActor
final class SpotifyAuthorizationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    func authorize() async throws -> SpotifyAuthorizationResponse {
        let challenge = SpotifyPKCEChallenge.make()
        let state = UUID().uuidString
        let request = SpotifyAuthorizationRequest.url(challenge: challenge, state: state)

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: request, callbackURLScheme: HarmonySupabaseConfiguration.spotifyRedirectURI.scheme) { [weak self] callbackURL, error in
                self?.webSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: SpotifyAuthorizationError.denied)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
                      returnedState == state else {
                    continuation.resume(throwing: SpotifyAuthorizationError.stateMismatch)
                    return
                }
                if components.queryItems?.contains(where: { $0.name == "error" }) == true {
                    continuation.resume(throwing: SpotifyAuthorizationError.denied)
                    return
                }
                guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    continuation.resume(throwing: SpotifyAuthorizationError.invalidCallback)
                    return
                }
                continuation.resume(returning: SpotifyAuthorizationResponse(code: code, codeVerifier: challenge.verifier))
            }
            session.presentationContextProvider = self
            webSession = session
            guard session.start() else {
                webSession = nil
                continuation.resume(throwing: SpotifyAuthorizationError.invalidCallback)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
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
@MainActor
protocol HarmonyMusicProvider: AnyObject {
    var provider: MusicProvider { get }
    var connectionState: ProviderConnectionState { get }
    var capabilities: ProviderCapabilities { get }

    func search(query: String) async throws -> [HarmonyTrack]
    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack
    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult
}

@MainActor
protocol SpotifyPlaybackProviding: HarmonyMusicProvider {
    func authorizeAndConnect() async throws
    func disconnect()
    @discardableResult func handleAuthorizationCallback(_ url: URL) -> Bool
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

@MainActor
final class SpotifyAppRemoteProvider: NSObject, SpotifyPlaybackProviding, @preconcurrency SPTAppRemoteDelegate, @preconcurrency SPTAppRemotePlayerStateDelegate {
    let provider: MusicProvider = .spotify
    private(set) var connectionState: ProviderConnectionState = .disconnected
    let capabilities = ProviderCapabilities.spotifyMock
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeoutTask: Task<Void, Never>?

    private lazy var configuration = SPTConfiguration(
        clientID: HarmonySupabaseConfiguration.spotifyClientID,
        redirectURL: HarmonySupabaseConfiguration.spotifyRedirectURI
    )

    private lazy var appRemote: SPTAppRemote = {
        let remote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        remote.delegate = self
        return remote
    }()

    func connect(accessToken: String) async throws {
        appRemote.connectionParameters.accessToken = accessToken
        if appRemote.isConnected {
            connectionState = .connected(accountName: nil)
            return
        }
        guard connectionContinuation == nil else { return }
        connectionState = .authorizing
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            appRemote.connect()
            connectionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishConnection(with: .failure(SpotifyAppRemoteError.connectionFailed))
            }
        }
    }

    func authorizeAndConnect() async throws {
        if appRemote.isConnected {
            connectionState = .connected(accountName: nil)
            return
        }
        guard connectionContinuation == nil else { return }
        connectionState = .authorizing
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            appRemote.authorizeAndPlayURI("") { [weak self] spotifyInstalled in
                guard spotifyInstalled else {
                    Task { @MainActor [weak self] in
                        self?.finishConnection(with: .failure(SpotifyAppRemoteError.spotifyNotInstalled))
                    }
                    return
                }
            }
            connectionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishConnection(with: .failure(SpotifyAppRemoteError.authorizationTimedOut))
            }
        }
    }

    @discardableResult
    func handleAuthorizationCallback(_ url: URL) -> Bool {
        guard let parameters = appRemote.authorizationParameters(from: url) else { return false }
        if let accessToken = parameters[SPTAppRemoteAccessTokenKey], !accessToken.isEmpty {
            appRemote.connectionParameters.accessToken = accessToken
            appRemote.connect()
        } else {
            let reason = parameters[SPTAppRemoteErrorDescriptionKey] ?? "Spotify did not return an App Remote access token."
            finishConnection(with: .failure(SpotifyAppRemoteError.authorizationFailed(reason)))
        }
        return true
    }

    func disconnect() {
        if appRemote.isConnected { appRemote.disconnect() }
        connectionState = .disconnected
    }

    func search(query: String) async throws -> [HarmonyTrack] {
        throw ProviderAdapterError.unsupportedPlayback(provider)
    }

    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        guard let mapping = track.mappings.first(where: { $0.provider == provider }), !mapping.providerID.isEmpty else {
            throw ProviderAdapterError.trackUnavailable(provider)
        }
        return ResolvedProviderTrack(
            provider: provider,
            providerID: mapping.providerID,
            title: track.title,
            artist: track.artist,
            playbackCapability: mapping.availability == .playable ? .queuePlayback : .openInProvider
        )
    }

    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult {
        guard appRemote.isConnected, let playerAPI = appRemote.playerAPI else {
            throw ProviderAdapterError.notConnected(provider)
        }
        switch command {
        case let .play(track):
            guard track.playbackCapability == .queuePlayback else { return .requiresOpenInProvider }
            try await invoke { callback in playerAPI.play(track.providerID, callback: callback) }
        case .pause:
            try await invoke { callback in playerAPI.pause(callback) }
        case .resume:
            try await invoke { callback in playerAPI.resume(callback) }
        case .skip:
            try await invoke { callback in playerAPI.skip(toNext: callback) }
        }
        return .applied
    }

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        connectionState = .connected(accountName: nil)
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: nil)
        finishConnection(with: .success(()))
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let failure = error ?? SpotifyAppRemoteError.connectionFailed
        connectionState = .unavailable(reason: failure.localizedDescription)
        finishConnection(with: .failure(failure))
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        connectionState = .disconnected
        if let error { finishConnection(with: .failure(error)) }
    }

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {}

    private func finishConnection(with result: Result<Void, Error>) {
        guard let continuation = connectionContinuation else { return }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionContinuation = nil
        continuation.resume(with: result)
    }

    private func invoke(_ operation: (@escaping SPTAppRemoteCallback) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

enum SpotifyAppRemoteError: LocalizedError {
    case connectionFailed
    case missingAppRemoteScope
    case spotifyNotInstalled
    case authorizationTimedOut
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not connect to the Spotify app. Open Spotify and try again."
        case .missingAppRemoteScope:
            return "Reconnect your Spotify account so Harmony can request playback-control permission."
        case .spotifyNotInstalled:
            return "Install the Spotify app to enable playback."
        case .authorizationTimedOut:
            return "Spotify did not return to Harmony. Open Spotify, confirm playback, and try again."
        case let .authorizationFailed(reason):
            return reason
        }
    }
}

/// One injection point for feature code. It makes the local prototype and
/// future production adapters interchangeable.
@MainActor
final class MusicProviderRegistry {
    private let adapters: [MusicProvider: HarmonyMusicProvider]

    convenience init() {
        self.init(adapters: [MockAppleMusicProvider(), MockSpotifyProvider()])
    }

    init(adapters: [HarmonyMusicProvider]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
    }

    func adapter(for provider: MusicProvider) -> HarmonyMusicProvider? {
        adapters[provider]
    }
}
