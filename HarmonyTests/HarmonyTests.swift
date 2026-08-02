import XCTest
@testable import Harmony

@MainActor
final class HarmonyTests: XCTestCase {
    func testAddingTrackAdvancesQueueRevision() {
        let store = HarmonySessionStore()
        let initialCount = store.queue.count
        let initialRevision = store.queueRevision

        store.add(store.catalog[3])

        XCTAssertEqual(store.queue.count, initialCount + 1)
        XCTAssertEqual(store.queueRevision, initialRevision + 1)
        XCTAssertEqual(store.queue.last?.track, store.catalog[3])
        XCTAssertEqual(store.queue.last?.addedBy, store.currentMember)
    }

    func testAddingTrackAlreadyInQueueDoesNotChangeQueueOrRevision() {
        let store = HarmonySessionStore()
        let initialQueue = store.queue
        let initialRevision = store.queueRevision

        store.add(store.catalog[0])

        XCTAssertEqual(store.queue, initialQueue)
        XCTAssertEqual(store.queueRevision, initialRevision)
    }

    func testDifferentArtistsWithSameTrackTitleCanBothBeQueued() {
        let store = HarmonySessionStore()
        let track = HarmonyTrack(
            title: store.queue[0].track.title,
            artist: "A Different Artist",
            album: "Another Album",
            duration: 180,
            symbol: "music.note",
            mappings: [ProviderTrackMapping(provider: .spotify, providerID: "spotify:track:different", availability: .playable)]
        )

        store.add(track)

        XCTAssertTrue(store.contains(track))
        XCTAssertEqual(store.queue.last?.track.artist, "A Different Artist")
    }

    func testProviderIDPreventsDuplicateRecordingWithChangedMetadata() {
        let store = HarmonySessionStore()
        let existing = store.queue[0].track
        let duplicate = HarmonyTrack(
            title: "Alternate display title",
            artist: "Alternate display artist",
            album: existing.album,
            duration: existing.duration,
            symbol: existing.symbol,
            mappings: existing.mappings
        )
        let initialCount = store.queue.count

        store.add(duplicate)

        XCTAssertEqual(store.queue.count, initialCount)
    }

    func testSpotifyCatalogErrorsProvideRecoveryGuidance() {
        XCTAssertTrue(SpotifyCatalogError.reconnectRequired.localizedDescription.contains("Reconnect Spotify"))
        XCTAssertTrue(SpotifyCatalogError.rateLimited.localizedDescription.contains("Wait a moment"))
        XCTAssertTrue(SpotifyCatalogError.temporarilyUnavailable.localizedDescription.contains("temporarily unavailable"))
    }

    func testRemoveRemovesSelectedQueueItemAndAdvancesRevision() {
        let store = HarmonySessionStore()
        let itemToRemove = store.queue[1]
        let initialRevision = store.queueRevision

        store.remove(itemToRemove)

        XCTAssertEqual(store.queue.count, 2)
        XCTAssertFalse(store.queue.contains(itemToRemove))
        XCTAssertEqual(store.queueRevision, initialRevision + 1)
    }

    func testMoveReordersQueueAndAdvancesRevision() {
        let store = HarmonySessionStore()
        let originalLastItem = store.queue[2]
        let initialRevision = store.queueRevision

        store.move(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(store.queue.first, originalLastItem)
        XCTAssertEqual(store.queueRevision, initialRevision + 1)
    }

    func testTogglePlaybackAlternatesBetweenPlayingAndPaused() async {
        let store = HarmonySessionStore()

        XCTAssertEqual(store.playbackState, .playing)

        await store.togglePlayback()
        XCTAssertEqual(store.playbackState, .paused)

        await store.togglePlayback()
        XCTAssertEqual(store.playbackState, .playing)
    }

    func testTogglePlaybackSendsPauseAndResumeToConnectedSpotify() async {
        let spotify = RecordingSpotifyProvider()
        let store = HarmonySessionStore(spotifyRemote: spotify)

        await store.togglePlayback()
        await store.togglePlayback()

        XCTAssertEqual(spotify.commands, [.pause, .resume])
    }

    func testSkipAdvancesCanonicalQueueAndRevision() async {
        let store = HarmonySessionStore()
        let previousNext = store.queue[1]
        let previousRevision = store.queueRevision

        await store.skipToNext()

        XCTAssertEqual(store.queue.first, previousNext)
        XCTAssertEqual(store.queue.count, 2)
        XCTAssertEqual(store.queueRevision, previousRevision + 1)
        XCTAssertEqual(store.events.last?.type, .skip)
        XCTAssertEqual(store.playbackState, .playing)
    }

    func testSpotifyPKCERequestHasRequiredParameters() {
        let challenge = SpotifyPKCEChallenge.make()
        let redirectURI = URL(string: "harmony://spotify-auth")!
        let request = SpotifyAuthorizationRequest.url(challenge: challenge, state: "expected-state", clientID: "client-id", redirectURI: redirectURI)
        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: request, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value) })

        XCTAssertEqual(request.host, "accounts.spotify.com")
        XCTAssertEqual(parameters["client_id"], "client-id")
        XCTAssertEqual(parameters["redirect_uri"], redirectURI.absoluteString)
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertEqual(parameters["code_challenge"], challenge.challenge)
        XCTAssertEqual(parameters["state"], "expected-state")
        XCTAssertFalse(challenge.verifier.isEmpty)
        XCTAssertFalse(challenge.challenge.isEmpty)
    }

    func testPresenceMembershipTracksJoinsAndLeaves() {
        let store = HarmonySessionStore()
        let memberID = store.members[1].id

        store.applyPresence(joins: [store.currentMember.id, memberID], leaves: [])
        store.applyPresence(joins: [], leaves: [memberID])

        XCTAssertEqual(store.activeMemberIDs, [store.currentMember.id])
    }

    func testInviteURLRoutingAcceptsOnlyValidHarmonyJoinCodes() {
        XCTAssertEqual(
            HarmonySessionStore.inviteCode(from: URL(string: "harmony://join?code=ab12cd34")!),
            "AB12CD34"
        )
        XCTAssertNil(HarmonySessionStore.inviteCode(from: URL(string: "harmony://spotify-auth?code=secret")!))
        XCTAssertNil(HarmonySessionStore.inviteCode(from: URL(string: "https://example.com/join?code=ABC123")!))
        XCTAssertNil(HarmonySessionStore.inviteCode(from: URL(string: "harmony://join?code=bad-code")!))
    }

    func testClearingSessionRemovesRoomStateAndRestoresLocalOwnership() {
        let store = HarmonySessionStore()

        store.clearSessionState(message: "The Conductor ended this session")

        XCTAssertFalse(store.isLiveSession)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.queueRevision, 0)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.playbackState, .paused)
        XCTAssertEqual(store.sessionName, "No active session")
        XCTAssertEqual(store.inviteCode, "")
        XCTAssertEqual(store.members, [store.currentMember])
        XCTAssertEqual(store.currentMember.role, .conductor)
        XCTAssertTrue(store.activeMemberIDs.isEmpty)
        XCTAssertEqual(store.collaborationMessage, "The Conductor ended this session")
    }
}

@MainActor
private final class RecordingSpotifyProvider: SpotifyPlaybackProviding {
    let provider: MusicProvider = .spotify
    var connectionState: ProviderConnectionState = .connected(accountName: "Test Spotify")
    let capabilities = ProviderCapabilities.spotifyMock
    var commands: [ProviderPlaybackCommand] = []

    func authorizeAndConnect() async throws {}
    func disconnect() { connectionState = .disconnected }
    func handleAuthorizationCallback(_ url: URL) -> Bool { false }
    func search(query: String) async throws -> [HarmonyTrack] { [] }
    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        throw ProviderAdapterError.trackUnavailable(.spotify)
    }
    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult {
        commands.append(command)
        return .applied
    }
}
