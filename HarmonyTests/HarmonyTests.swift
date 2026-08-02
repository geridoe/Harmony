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

    func testTogglePlaybackAlternatesBetweenPlayingAndPaused() {
        let store = HarmonySessionStore()

        XCTAssertEqual(store.playbackState, .playing)

        store.togglePlayback()
        XCTAssertEqual(store.playbackState, .paused)

        store.togglePlayback()
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
}
