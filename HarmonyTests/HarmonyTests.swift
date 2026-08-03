import XCTest
@testable import Harmony

@MainActor
final class HarmonyTests: XCTestCase {
    func testProductionStoreStartsWithoutPrototypeSessionData() {
        let store = HarmonySessionStore(
            spotifyRemote: RecordingSpotifyProvider(),
            appleMusicProvider: RecordingAppleMusicProvider(),
            seedSampleData: false
        )

        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.queueRevision, 0)
        XCTAssertEqual(store.playbackState, .paused)
        XCTAssertEqual(store.members.count, 1)
        XCTAssertEqual(store.currentMember.name, "You")
        XCTAssertEqual(store.sessionName, "My Harmony Session")
        XCTAssertFalse(store.isLiveSession)
    }

    func testSocialHistoryRecordingStartsDisabled() {
        XCTAssertFalse(HarmonySessionStore().recordsHarmonyPlays)
    }

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

    func testCanonicalIdentityOverridesMatchingDisplayMetadata() {
        let store = HarmonySessionStore(seedSampleData: false)
        let firstID = UUID()
        let secondID = UUID()
        let first = identityTrack(canonicalTrackID: firstID, provider: .spotify, providerID: "spotify:track:canonical-one")
        let sameRecording = identityTrack(canonicalTrackID: firstID, title: "Changed title", provider: .appleMusic, providerID: "apple-one")
        let differentRecording = identityTrack(canonicalTrackID: secondID, provider: .appleMusic, providerID: "apple-two")

        store.add(first)
        store.add(sameRecording)
        store.add(differentRecording)

        XCTAssertEqual(store.queue.count, 2)
        XCTAssertEqual(Set(store.queue.compactMap(\.track.canonicalTrackID)), Set([firstID, secondID]))
    }

    func testISRCMergesCrossProviderRecordingWithoutCanonicalID() {
        let store = HarmonySessionStore(seedSampleData: false)
        let spotify = identityTrack(isrc: "QZHAR2600301", provider: .spotify, providerID: "spotify:track:isrc")
        let apple = identityTrack(title: "Compilation display title", isrc: "qzhar2600301", provider: .appleMusic, providerID: "apple-isrc")

        store.add(spotify)
        store.add(apple)

        XCTAssertEqual(store.queue.count, 1)
    }

    func testMetadataFallbackRequiresAlbumAndCloseDuration() {
        let matchingStore = HarmonySessionStore(seedSampleData: false)
        matchingStore.add(identityTrack(duration: 180, provider: .spotify, providerID: "spotify:track:metadata-a"))
        matchingStore.add(identityTrack(title: " identity song ", artist: "identity artist", album: "identity album", duration: 182, provider: .appleMusic, providerID: "apple-metadata-a"))
        XCTAssertEqual(matchingStore.queue.count, 1)

        let variantsStore = HarmonySessionStore(seedSampleData: false)
        variantsStore.add(identityTrack(album: "Studio", duration: 180, provider: .spotify, providerID: "spotify:track:variant-a"))
        variantsStore.add(identityTrack(album: "Live", duration: 180, provider: .appleMusic, providerID: "apple-variant-a"))
        variantsStore.add(identityTrack(album: "Studio", duration: 182.001, provider: .appleMusic, providerID: "apple-variant-b"))
        XCTAssertEqual(variantsStore.queue.count, 3)
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
        XCTAssertTrue((parameters["scope"] ?? nil)?.contains("user-read-recently-played") == true)
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

    func testSessionExpiryChoicesProduceExpectedDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNil(SessionExpiry.never.date(from: now))
        XCTAssertEqual(SessionExpiry.twoHours.date(from: now), now.addingTimeInterval(2 * 60 * 60))
        XCTAssertEqual(SessionExpiry.oneDay.date(from: now), now.addingTimeInterval(24 * 60 * 60))
    }

    func testPlaybackModeRawValuesMatchBackendEnum() {
        XCTAssertEqual(SessionPlaybackMode.conductorPlayback.rawValue, "conductor_playback")
        XCTAssertEqual(SessionPlaybackMode.personalListenAlong.rawValue, "personal_listen_along")
        XCTAssertEqual(SessionPlaybackMode.queueOnly.rawValue, "queue_only")
    }

    func testSessionTitleValidationTrimsWhitespaceAndHonorsDatabaseLimit() {
        let store = HarmonySessionStore()

        store.sessionName = "  Friday Night Finds  "
        XCTAssertTrue(store.canStartLiveSession)

        store.sessionName = " \n "
        XCTAssertFalse(store.canStartLiveSession)

        store.sessionName = String(repeating: "a", count: 121)
        XCTAssertFalse(store.canStartLiveSession)
    }

    func testAppleMusicConnectionEnablesItsCatalogSearch() async {
        let appleMusic = RecordingAppleMusicProvider()
        let store = HarmonySessionStore(
            spotifyRemote: RecordingSpotifyProvider(),
            appleMusicProvider: appleMusic
        )

        await store.connectAppleMusic()
        await store.searchCatalog(query: "Apple")

        XCTAssertEqual(store.providerState(for: .appleMusic), .connected)
        XCTAssertEqual(store.catalogSearchResults?.first?.title, "Apple Catalog Track")
        XCTAssertEqual(store.catalogSearchResults?.first?.availability(for: .appleMusic), .playable)
    }

    func testReviewCatalogSearchDoesNotReplaceAddMusicSearchState() async {
        let store = HarmonySessionStore()

        await store.searchCatalog(query: "Afterglow", purpose: .addMusic)
        let addMusicState = store.catalogSearchState(for: .addMusic)
        await store.searchCatalog(query: "Neon Coast", purpose: .reviews)

        XCTAssertEqual(store.catalogSearchState(for: .addMusic), addMusicState)
        XCTAssertEqual(store.catalogSearchState(for: .reviews).query, "Neon Coast")
        XCTAssertEqual(store.catalogSearchState(for: .reviews).results?.map(\.title), ["Neon Coast"])
        XCTAssertEqual(store.catalogSearchResults?.map(\.title), ["Afterglow"], "The Add music compatibility accessor must stay purpose-scoped")
    }

    func testResettingReviewSearchDoesNotClearAddMusicResults() async {
        let store = HarmonySessionStore()

        await store.searchCatalog(query: "Afterglow", purpose: .addMusic)
        await store.searchCatalog(query: "Neon Coast", purpose: .reviews)
        store.resetCatalogSearch(.reviews)

        XCTAssertEqual(store.catalogSearchState(for: .reviews), .idle)
        XCTAssertEqual(store.catalogSearchState(for: .addMusic).results?.map(\.title), ["Afterglow"])
    }

    func testListCatalogSearchDoesNotReplaceAddMusicOrReviewSearchState() async {
        let store = HarmonySessionStore(seedSampleData: true)

        await store.searchCatalog(query: "Neon Coast", purpose: .addMusic)
        await store.searchCatalog(query: "Midnight", purpose: .reviews)
        await store.searchCatalog(query: "Golden", purpose: .lists)

        XCTAssertEqual(store.catalogSearchState(for: .addMusic).query, "Neon Coast")
        XCTAssertEqual(store.catalogSearchState(for: .reviews).query, "Midnight")
        XCTAssertEqual(store.catalogSearchState(for: .lists).query, "Golden")

        store.resetCatalogSearch(.lists)
        XCTAssertEqual(store.catalogSearchState(for: .lists), .idle)
        XCTAssertEqual(store.catalogSearchState(for: .addMusic).query, "Neon Coast")
        XCTAssertEqual(store.catalogSearchState(for: .reviews).query, "Midnight")
    }

    func testReviewAlbumDeduplicationUsesProviderAndProviderID() {
        let spotifyAlbum = ReviewableAlbum(
            provider: .spotify,
            providerID: "shared-album-id",
            title: "Original title",
            artist: "Original artist",
            artworkURL: nil,
            deepLinkURL: nil
        )
        let changedSpotifyMetadata = ReviewableAlbum(
            provider: .spotify,
            providerID: "shared-album-id",
            title: "Localized title",
            artist: "Localized artist",
            artworkURL: URL(string: "https://i.scdn.co/image/alternate"),
            deepLinkURL: URL(string: "https://open.spotify.com/album/shared-album-id")
        )
        let appleAlbumWithSameID = ReviewableAlbum(
            provider: .appleMusic,
            providerID: "shared-album-id",
            title: "Original title",
            artist: "Original artist",
            artworkURL: nil,
            deepLinkURL: nil
        )
        let tracks = [
            reviewTrack(title: "One", album: spotifyAlbum),
            reviewTrack(title: "Two", album: changedSpotifyMetadata),
            reviewTrack(title: "Three", album: appleAlbumWithSameID)
        ]

        let albums = deduplicatedReviewAlbums(from: tracks)

        XCTAssertEqual(albums, [spotifyAlbum, appleAlbumWithSameID])
    }

    func testReviewableAlbumUsesProviderSpecificDefaultStorefront() {
        let spotifyAlbum = ReviewableAlbum(
            provider: .spotify,
            providerID: "spotify-album",
            title: "Album",
            artist: "Artist",
            artworkURL: nil,
            deepLinkURL: nil
        )
        let appleAlbum = ReviewableAlbum(
            provider: .appleMusic,
            providerID: "apple-album",
            storefront: "gb",
            title: "Album",
            artist: "Artist",
            artworkURL: nil,
            deepLinkURL: nil
        )

        XCTAssertEqual(spotifyAlbum.storefront, "global")
        XCTAssertEqual(appleAlbum.storefront, "gb")
        XCTAssertNil(spotifyAlbum.canonicalAlbumID)
    }

    func testMusicReviewDecodesCanonicalAlbumIdentityAndProviderMappings() throws {
        let reviewID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let albumID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let profileID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let json = """
        {
          "id": "\(reviewID.uuidString)",
          "profile_id": "\(profileID.uuidString)",
          "subject_kind": "album",
          "subject_title": "Canonical Album",
          "subject_artist": "The Artist",
          "subject_artwork_url": "https://example.com/art.jpg",
          "subject_deep_link": "https://open.spotify.com/album/provider-album",
          "canonical_album_id": "\(albumID.uuidString)",
          "rating": 4.5,
          "body": "A review",
          "visibility": "followers",
          "contains_spoilers": false,
          "is_loved": true,
          "created_at": "2026-08-03T12:00:00Z",
          "canonical_tracks": null,
          "canonical_albums": {
            "id": "\(albumID.uuidString)",
            "title": "Canonical Album",
            "artist": "The Artist",
            "release_date": "2026-07-31",
            "upc": "123456789012",
            "album_type": "album",
            "total_tracks": 10,
            "artwork_url": "https://example.com/art.jpg",
            "provider_albums": [{
              "provider": "spotify",
              "provider_album_id": "provider-album",
              "storefront": "global",
              "deep_link": "https://open.spotify.com/album/provider-album",
              "availability": "playable",
              "identity_basis": "provider"
            }]
          },
          "profiles": {"display_name": "Listener"},
          "review_comments": [],
          "review_reactions": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let review = try decoder.decode(RemoteMusicReview.self, from: Data(json.utf8))

        XCTAssertEqual(review.canonicalAlbumID, albumID)
        XCTAssertEqual(review.canonicalAlbum?.id, albumID)
        XCTAssertEqual(review.canonicalAlbum?.releaseDate, "2026-07-31")
        XCTAssertEqual(review.canonicalAlbum?.upc, "123456789012")
        XCTAssertEqual(review.canonicalAlbum?.providerAlbums.first?.storefront, "global")
        XCTAssertEqual(review.canonicalAlbum?.providerAlbums.first?.providerAlbumID, "provider-album")
    }

    func testMusicReviewStillDecodesLegacyPayloadWithoutCanonicalAlbumFields() throws {
        let json = """
        {
          "id": "10000000-0000-0000-0000-000000000001",
          "profile_id": "30000000-0000-0000-0000-000000000003",
          "subject_kind": "album",
          "subject_title": "Legacy Album",
          "subject_artist": "The Artist",
          "subject_artwork_url": null,
          "subject_deep_link": null,
          "rating": 4.0,
          "body": "Legacy review",
          "visibility": "followers",
          "contains_spoilers": false,
          "is_loved": false,
          "created_at": "2026-08-03T12:00:00Z",
          "canonical_tracks": null,
          "profiles": {"display_name": "Listener"},
          "review_comments": [],
          "review_reactions": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let review = try decoder.decode(RemoteMusicReview.self, from: Data(json.utf8))

        XCTAssertNil(review.canonicalAlbumID)
        XCTAssertNil(review.canonicalAlbum)
        XCTAssertEqual(review.subjectTitle, "Legacy Album")
    }

    func testReviewDraftSnapshotsAudienceAndKeepsAllAuthoredFields() {
        var profileDefault = SocialVisibilityOption.followers
        let subject = ReviewDraftSubject.track(reviewTrack(title: "Snapshot song"))
        let draft = ReviewDraft(
            subject: subject,
            rating: 3.5,
            isLoved: true,
            containsSpoilers: true,
            body: "Keep this if publication fails",
            visibility: profileDefault
        )

        profileDefault = .privateOnly

        XCTAssertEqual(draft.subject, subject)
        XCTAssertEqual(draft.rating, 3.5)
        XCTAssertTrue(draft.isLoved)
        XCTAssertTrue(draft.containsSpoilers)
        XCTAssertEqual(draft.body, "Keep this if publication fails")
        XCTAssertEqual(draft.visibility, .followers, "An open draft must not follow later profile-default changes")
    }

    func testMusicListDraftNormalizesAndValidatesAuthoredMetadata() {
        var draft = MusicListDraft(
            title: "  After-hours favorites  ",
            description: "  Sequenced for the ride home.  ",
            tagsText: "Night, party, NIGHT",
            isRanked: true,
            visibility: .followers
        )
        draft.entries = [MusicListDraftEntry(track: reviewTrack(title: "Neon"), note: "  Perfect opener.  ")]

        XCTAssertEqual(draft.normalizedTitle, "After-hours favorites")
        XCTAssertEqual(draft.normalizedDescription, "Sequenced for the ride home.")
        XCTAssertEqual(draft.normalizedTags, ["night", "party"])
        XCTAssertNil(draft.validationMessage)

        draft.title = "   "
        XCTAssertEqual(draft.validationMessage, "List titles must contain 1 to 120 characters.")
    }

    func testMusicListDraftRejectsDuplicateRecordingAndPreservesOrder() {
        let mapping = ProviderTrackMapping(
            provider: .spotify,
            providerID: "spotify:track:list-fixture",
            availability: .playable
        )
        let first = HarmonyTrack(
            title: "Original metadata",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            symbol: "music.note",
            mappings: [mapping]
        )
        let duplicate = HarmonyTrack(
            title: "Changed metadata",
            artist: "Test Artist",
            album: "Deluxe",
            duration: 181,
            symbol: "music.note",
            mappings: [mapping]
        )
        let second = reviewTrack(title: "Second")
        var draft = MusicListDraft(title: "Ordered")

        XCTAssertTrue(draft.addTrack(first))
        XCTAssertFalse(draft.addTrack(duplicate))
        XCTAssertTrue(draft.addTrack(second))
        draft.moveEntries(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(draft.entries.map(\.track.title), ["Second", "Original metadata"])
        XCTAssertEqual(draft.entries.count, 2)
    }

    func testAddToListPickerRecognizesCanonicalDuplicate() {
        let canonicalID = UUID()
        let track = HarmonyTrack(
            canonicalTrackID: canonicalID,
            title: "Same recording",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            symbol: "music.note",
            mappings: []
        )
        let entry = musicListEntry(
            canonicalTrackID: canonicalID,
            canonicalTrack: RemoteCatalogTrack(
                id: canonicalID,
                title: "Older display title",
                artist: "Test Artist",
                album: "Test Album",
                durationMilliseconds: 180_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: nil
            )
        )

        XCTAssertTrue(musicListContainsTrack(track, entries: [entry]))
    }

    func testAddToListPickerRecognizesProviderMappingDuplicateWithoutCanonicalID() {
        let track = HarmonyTrack(
            title: "Provider copy",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            symbol: "music.note",
            mappings: [ProviderTrackMapping(
                provider: .spotify,
                providerID: "spotify:track:list-picker",
                availability: .playable
            )]
        )
        let entry = musicListEntry(
            canonicalTrackID: UUID(),
            canonicalTrack: RemoteCatalogTrack(
                id: UUID(),
                title: "Different metadata",
                artist: "Test Artist",
                album: "Test Album",
                durationMilliseconds: 181_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: [RemoteProviderTrack(
                    provider: "spotify",
                    providerID: "spotify:track:list-picker",
                    storefront: "global",
                    availability: "playable",
                    deepLink: nil
                )]
            )
        )

        XCTAssertTrue(musicListContainsTrack(track, entries: [entry]))
    }

    func testCheckingAddToListAvailabilityHasNoPlaybackQueueOrHistorySideEffects() {
        let store = HarmonySessionStore()
        let track = reviewTrack(title: "Collection only")
        let initialQueue = store.queue
        let initialRevision = store.queueRevision
        let initialPlayback = store.playbackState
        let initialHistory = store.listeningHistory

        XCTAssertFalse(musicListContainsTrack(track, entries: []))

        XCTAssertEqual(store.queue, initialQueue)
        XCTAssertEqual(store.queueRevision, initialRevision)
        XCTAssertEqual(store.playbackState, initialPlayback)
        XCTAssertEqual(store.listeningHistory.map(\.id), initialHistory.map(\.id))
    }

    func testChoosingReviewSubjectHasNoQueueOrHistorySideEffects() {
        let store = HarmonySessionStore()
        let initialQueue = store.queue
        let initialHistory = store.listeningHistory

        _ = ReviewDraft(
            subject: .track(reviewTrack(title: "Opinion only")),
            visibility: .followers
        )

        XCTAssertEqual(store.queue, initialQueue)
        XCTAssertEqual(store.listeningHistory.map(\.id), initialHistory.map(\.id))
        XCTAssertEqual(store.queueRevision, 12)
    }

    func testDiaryDraftNormalizesTagsAndPreservesJournalContext() {
        let listenedOn = Date(timeIntervalSince1970: 1_722_470_400)
        let track = reviewTrack(title: "Midnight reprise")
        let linkedReviewID = UUID()
        let draft = DiaryEntryDraft(
            track: track,
            listenedOn: listenedOn,
            isRelisten: true,
            tagsText: " Party, vinyl, PARTY, , late night ",
            rating: 4.5,
            visibility: .followers,
            linkedReviewID: linkedReviewID
        )

        XCTAssertEqual(draft.track, track)
        XCTAssertEqual(draft.listenedOn, listenedOn)
        XCTAssertTrue(draft.isRelisten)
        XCTAssertEqual(draft.normalizedTags, ["party", "vinyl", "late night"])
        XCTAssertEqual(draft.rating, 4.5)
        XCTAssertEqual(draft.visibility, .followers)
        XCTAssertEqual(draft.linkedReviewID, linkedReviewID)
        XCTAssertNil(draft.tagValidationMessage)
    }

    func testDiaryRatingIsOptionalAndPreservesHalfStarValues() {
        var draft = DiaryEntryDraft()
        XCTAssertNil(draft.rating, "A diary log must not imply a rating without explicit opt-in")

        draft.rating = 3.5
        XCTAssertEqual(draft.rating, 3.5)

        draft.rating = nil
        XCTAssertNil(draft.rating, "Turning rating off removes the historical event rating")
    }

    func testDiaryDraftEnforcesBackendTagLimits() {
        var draft = DiaryEntryDraft(tagsText: (1...11).map { "tag\($0)" }.joined(separator: ","))
        XCTAssertEqual(draft.tagValidationMessage, "Use no more than 10 tags.")

        draft.tagsText = String(repeating: "x", count: 31)
        XCTAssertEqual(draft.tagValidationMessage, "Each tag must be 30 characters or fewer.")

        draft.tagsText = (1...10).map { "tag\($0)" }.joined(separator: ",")
        XCTAssertNil(draft.tagValidationMessage)
    }

    func testDiaryDraftSubmissionPreservesSelectedCalendarDay() {
        let calendar = Calendar.current
        let pastDay = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
        var draft = DiaryEntryDraft(listenedOn: pastDay)

        let pastSubmission = draft.listenedOnForSubmission

        XCTAssertTrue(calendar.isDate(pastSubmission, inSameDayAs: pastDay))
        XCTAssertEqual(calendar.component(.hour, from: pastSubmission), 12, "Past date-only values use local noon to survive UTC conversion")

        draft.listenedOn = calendar.startOfDay(for: Date())
        let beforeSubmission = Date()
        let todaySubmission = draft.listenedOnForSubmission
        XCTAssertTrue(calendar.isDateInToday(todaySubmission))
        XCTAssertGreaterThanOrEqual(todaySubmission, beforeSubmission)
    }

    func testListeningHistoryDecodesOptionalReviewAndCanonicalTrackIdentity() throws {
        let entryID = UUID()
        let profileID = UUID()
        let reviewID = UUID()
        let trackID = UUID()
        let payload = """
        {
          "id": "\(entryID.uuidString)",
          "profile_id": "\(profileID.uuidString)",
          "played_at": "2026-08-02T18:30:00Z",
          "source": "manual",
          "visibility": "followers",
          "is_relisten": true,
          "tags": ["party", "vinyl"],
          "rating": 4.5,
          "review_id": "\(reviewID.uuidString)",
          "canonical_tracks": {
            "id": "\(trackID.uuidString)",
            "title": "Midnight reprise",
            "artist": "Test artist",
            "album": "Test album",
            "duration_ms": 180000,
            "artwork_url": null,
            "is_explicit": false,
            "provider_tracks": null
          },
          "profiles": { "display_name": "Test listener" }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(RemoteListeningHistoryEntry.self, from: Data(payload.utf8))

        XCTAssertEqual(entry.id, entryID)
        XCTAssertEqual(entry.profileID, profileID)
        XCTAssertEqual(entry.reviewID, reviewID)
        XCTAssertEqual(entry.canonicalTrack?.id, trackID)
        XCTAssertTrue(entry.isRelisten)
        XCTAssertEqual(entry.tags, ["party", "vinyl"])
        XCTAssertEqual(entry.rating, 4.5)
    }

    func testJournalSearchMatchesTitleArtistAlbumAndTagsWithoutCaseOrDiacritics() {
        let entry = journalEntry(
            title: "Halo",
            artist: "Beyoncé",
            album: "Café Bleu",
            tags: ["Après party"]
        )

        for query in ["HALO", "beyonce", "cafe bleu", "apres"] {
            let matches = browseJournalEntries([entry], using: JournalBrowseFilter(query: query))
            XCTAssertEqual(matches.map(\.id), [entry.id], "Expected journal search to match \(query)")
        }
        XCTAssertTrue(browseJournalEntries([entry], using: JournalBrowseFilter(query: "midnight" )).isEmpty)
    }

    func testJournalBrowseScopesSelectAllRelistensAndLinkedOpinions() {
        let ordinary = journalEntry(title: "Ordinary")
        let relisten = journalEntry(title: "Again", isRelisten: true)
        let linked = journalEntry(title: "With opinion", reviewID: UUID())
        let entries = [ordinary, relisten, linked]

        XCTAssertEqual(
            browseJournalEntries(entries, using: JournalBrowseFilter(scope: .all)).map(\.id),
            entries.map(\.id)
        )
        XCTAssertEqual(
            browseJournalEntries(entries, using: JournalBrowseFilter(scope: .relistens)).map(\.id),
            [relisten.id]
        )
        XCTAssertEqual(
            browseJournalEntries(entries, using: JournalBrowseFilter(scope: .linkedOpinions)).map(\.id),
            [linked.id]
        )
    }

    func testJournalBrowseSortsNewestAndOldestWithStableTies() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = journalEntry(title: "Oldest", playedAt: baseDate)
        let tiedNewestFirst = journalEntry(title: "First tie", playedAt: baseDate.addingTimeInterval(60))
        let tiedNewestSecond = journalEntry(title: "Second tie", playedAt: baseDate.addingTimeInterval(60))
        let entries = [oldest, tiedNewestFirst, tiedNewestSecond]

        XCTAssertEqual(
            browseJournalEntries(entries, using: JournalBrowseFilter(sort: .newest)).map(\.id),
            [tiedNewestFirst.id, tiedNewestSecond.id, oldest.id]
        )
        XCTAssertEqual(
            browseJournalEntries(entries, using: JournalBrowseFilter(sort: .oldest)).map(\.id),
            [oldest.id, tiedNewestFirst.id, tiedNewestSecond.id]
        )
    }

    func testReviewBrowseSearchesSubjectMetadataAndBody() {
        let review = musicReview(
            title: "Halo",
            artist: "Beyoncé",
            album: "Café Bleu",
            body: "An après-party classic"
        )

        for query in ["HALO", "beyonce", "cafe bleu", "apres-party"] {
            XCTAssertEqual(
                browseMusicReviews([review], using: ReviewBrowseFilter(query: query)).map(\.id),
                [review.id]
            )
        }
        XCTAssertTrue(browseMusicReviews([review], using: ReviewBrowseFilter(query: "midnight")).isEmpty)
    }

    func testReviewBrowseScopesSongsAlbumsAndLoved() {
        let song = musicReview(title: "Song", subjectKind: "track")
        let album = musicReview(title: "Album", subjectKind: "album")
        let loved = musicReview(title: "Loved", isLoved: true)
        let reviews = [song, album, loved]

        XCTAssertEqual(Set(browseMusicReviews(reviews, using: ReviewBrowseFilter(scope: .all)).map(\.id)), Set(reviews.map(\.id)))
        XCTAssertEqual(Set(browseMusicReviews(reviews, using: ReviewBrowseFilter(scope: .songs)).map(\.id)), Set([song.id, loved.id]))
        XCTAssertEqual(browseMusicReviews(reviews, using: ReviewBrowseFilter(scope: .albums)).map(\.id), [album.id])
        XCTAssertEqual(browseMusicReviews(reviews, using: ReviewBrowseFilter(scope: .loved)).map(\.id), [loved.id])
    }

    func testReviewBrowseSortsByRatingWithNewestTieBreak() {
        let oldestHigh = musicReview(title: "Older five", rating: 5, createdAt: Date(timeIntervalSince1970: 100))
        let newestHigh = musicReview(title: "Newer five", rating: 5, createdAt: Date(timeIntervalSince1970: 200))
        let low = musicReview(title: "Low", rating: 1, createdAt: Date(timeIntervalSince1970: 300))
        let reviews = [oldestHigh, newestHigh, low]

        XCTAssertEqual(
            browseMusicReviews(reviews, using: ReviewBrowseFilter(sort: .highestRated)).map(\.id),
            [newestHigh.id, oldestHigh.id, low.id]
        )
        XCTAssertEqual(
            browseMusicReviews(reviews, using: ReviewBrowseFilter(sort: .lowestRated)).map(\.id),
            [low.id, newestHigh.id, oldestHigh.id]
        )
    }

    func testMusicShelfSearchesMetadataAndAppliesEveryScope() {
        let ordinary = trackSubjectState(title: "Ordinary")
        let loved = trackSubjectState(title: "Halo", artist: "Beyoncé", album: "Café Bleu", isLoved: true)
        let wanted = trackSubjectState(title: "Future song", wantToListen: true)
        let rated = trackSubjectState(title: "Rated song", defaultRating: 3.5)
        let listened = trackSubjectState(title: "Heard song", hasListened: true)
        let states = [ordinary, loved, wanted, rated, listened]

        for query in ["HALO", "beyonce", "cafe bleu"] {
            XCTAssertEqual(
                browseTrackSubjectShelf(states, using: MusicShelfFilter(query: query)).map(\.id),
                [loved.id]
            )
        }
        XCTAssertEqual(browseTrackSubjectShelf(states, using: MusicShelfFilter(scope: .loved)).map(\.id), [loved.id])
        XCTAssertEqual(browseTrackSubjectShelf(states, using: MusicShelfFilter(scope: .wantToListen)).map(\.id), [wanted.id])
        XCTAssertEqual(browseTrackSubjectShelf(states, using: MusicShelfFilter(scope: .rated)).map(\.id), [rated.id])
        XCTAssertEqual(browseTrackSubjectShelf(states, using: MusicShelfFilter(scope: .listened)).map(\.id), [listened.id])
    }

    func testMusicShelfUsesStableBackendUpdatedOrder() {
        let older = trackSubjectState(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let tiedLowerID = trackSubjectState(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Tie one",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let tiedHigherID = trackSubjectState(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Tie two",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            browseTrackSubjectShelf([older, tiedLowerID, tiedHigherID], using: MusicShelfFilter()).map(\.id),
            [tiedHigherID.id, tiedLowerID.id, older.id]
        )
    }

    func testTrackSubjectDraftNormalizesOnlyDependentState() {
        let independent = TrackSubjectStateDraft(
            hasListened: false,
            defaultRating: nil,
            isLoved: true,
            wantToListen: true
        ).normalizedForSubmission

        XCTAssertFalse(independent.hasListened)
        XCTAssertTrue(independent.isLoved)
        XCTAssertTrue(independent.wantToListen)
        XCTAssertEqual(independent.activeStatuses, [.loved, .wantToListen])

        let rated = TrackSubjectStateDraft(
            hasListened: false,
            defaultRating: 4.5,
            isLoved: false,
            wantToListen: true
        ).normalizedForSubmission

        XCTAssertTrue(rated.hasListened, "A current rating must establish Listened")
        XCTAssertFalse(rated.wantToListen, "Listened must supersede Want to listen")
        XCTAssertEqual(rated.defaultRating, 4.5)
        XCTAssertEqual(rated.activeStatuses, [.listened, .rated])
    }

    func testTrackSubjectDraftIsAFailureSafeValueSnapshot() {
        let persisted = trackSubjectState(
            title: "Draft source",
            hasListened: true,
            defaultRating: 4,
            isLoved: true
        )
        var draft = TrackSubjectStateDraft(state: persisted)
        draft.defaultRating = nil
        draft.hasListened = false
        draft.wantToListen = true

        XCTAssertTrue(persisted.hasListened)
        XCTAssertEqual(persisted.defaultRating, 4)
        XCTAssertTrue(persisted.isLoved)
        XCTAssertFalse(persisted.wantToListen)
        XCTAssertFalse(draft.hasListened)
        XCTAssertNil(draft.defaultRating)
        XCTAssertTrue(draft.isLoved)
        XCTAssertTrue(draft.wantToListen)
    }

    func testTrackSubjectDraftValidatesHalfStarRatings() {
        XCTAssertTrue(TrackSubjectStateDraft(defaultRating: nil).hasValidRating)
        XCTAssertTrue(TrackSubjectStateDraft(defaultRating: 0.5).hasValidRating)
        XCTAssertTrue(TrackSubjectStateDraft(defaultRating: 5).hasValidRating)
        XCTAssertFalse(TrackSubjectStateDraft(defaultRating: 0).hasValidRating)
        XCTAssertFalse(TrackSubjectStateDraft(defaultRating: 3.7).hasValidRating)
        XCTAssertFalse(TrackSubjectStateDraft(defaultRating: 5.5).hasValidRating)
    }

    func testAlbumSubjectDraftNormalizesIndependentAlbumOpinion() {
        let rated = AlbumSubjectStateDraft(
            hasListened: false,
            defaultRating: 4.5,
            isLoved: true,
            wantToListen: true
        ).normalizedForSubmission

        XCTAssertTrue(rated.hasListened)
        XCTAssertEqual(rated.defaultRating, 4.5)
        XCTAssertTrue(rated.isLoved)
        XCTAssertFalse(rated.wantToListen)
        XCTAssertFalse(rated.isEmpty)
    }

    func testAlbumSubjectDraftValidatesHalfStarsAndEmptyState() {
        XCTAssertTrue(AlbumSubjectStateDraft.empty.isEmpty)
        XCTAssertTrue(AlbumSubjectStateDraft(defaultRating: 0.5).hasValidRating)
        XCTAssertTrue(AlbumSubjectStateDraft(defaultRating: 5).hasValidRating)
        XCTAssertFalse(AlbumSubjectStateDraft(defaultRating: 0).hasValidRating)
        XCTAssertFalse(AlbumSubjectStateDraft(defaultRating: 3.7).hasValidRating)
        XCTAssertFalse(AlbumSubjectStateDraft(defaultRating: 5.5).hasValidRating)
        XCTAssertFalse(AlbumSubjectStateDraft(isLoved: true).isEmpty)
    }

#if DEBUG
    func testFixtureTrackDraftSaveNormalizesAndCommitsOnlyAfterSuccess() async {
        let store = HarmonySessionStore(seedSampleData: false)
        store.seedDiaryEditorUITestFixture()
        let track = try! XCTUnwrap(store.journalEntries.first?.canonicalTrack)
        let original = try! XCTUnwrap(store.trackSubjectState(for: track))
        let rejectedDraft = TrackSubjectStateDraft(
            hasListened: false,
            defaultRating: 3.7,
            isLoved: false,
            wantToListen: true
        )

        let rejected = await store.saveTrackSubjectStateDraft(rejectedDraft, for: track)
        XCTAssertFalse(rejected)
        let stateAfterFailure = try! XCTUnwrap(store.trackSubjectState(for: track))
        XCTAssertEqual(stateAfterFailure.hasListened, original.hasListened)
        XCTAssertEqual(stateAfterFailure.defaultRating, original.defaultRating)
        XCTAssertEqual(stateAfterFailure.isLoved, original.isLoved)
        XCTAssertEqual(stateAfterFailure.wantToListen, original.wantToListen)
        XCTAssertEqual(rejectedDraft.defaultRating, 3.7, "A rejected save must leave the caller's retry draft intact")

        let acceptedDraft = TrackSubjectStateDraft(
            hasListened: false,
            defaultRating: 4.5,
            isLoved: false,
            wantToListen: true
        )
        let accepted = await store.saveTrackSubjectStateDraft(acceptedDraft, for: track)
        XCTAssertTrue(accepted)
        let saved = try! XCTUnwrap(store.trackSubjectState(for: track))
        XCTAssertTrue(saved.hasListened)
        XCTAssertEqual(saved.defaultRating, 4.5)
        XCTAssertFalse(saved.isLoved)
        XCTAssertFalse(saved.wantToListen)
    }

    func testFixtureEmptyTrackDraftRemovesCacheAndShelf() async {
        let store = HarmonySessionStore(seedSampleData: false)
        store.seedDiaryEditorUITestFixture()
        let track = try! XCTUnwrap(store.journalEntries.first?.canonicalTrack)
        let trackID = try! XCTUnwrap(track.id)

        let removed = await store.saveTrackSubjectStateDraft(.empty, for: track)
        XCTAssertTrue(removed)
        XCTAssertNil(store.trackSubjectState(for: track))
        XCTAssertFalse(store.trackSubjectShelf.contains { $0.canonicalTrackID == trackID })
    }
#endif

    func testFollowingActivityPayloadsKeepTheirTypedPresentation() {
        let diary = journalEntry(title: "Diary track")
        let review = musicReview(title: "Reviewed track")
        let list = musicList(title: "Favorite bridges")

        XCTAssertEqual(followingActivityPresentationKind(for: .diary(diary)), .diary)
        XCTAssertEqual(followingActivityPresentationKind(for: .review(review)), .review)
        XCTAssertEqual(followingActivityPresentationKind(for: .musicList(list)), .musicList)
    }

    func testFollowingActivityFiltersTypedPayloadsAndPreservesStableOrder() {
        let firstReview = followingActivityItem(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            payload: .review(musicReview(title: "First review"))
        )
        let diary = followingActivityItem(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            payload: .diary(journalEntry(title: "Diary track"))
        )
        let list = followingActivityItem(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            payload: .musicList(musicList(title: "Favorite bridges"))
        )
        let secondReview = followingActivityItem(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            payload: .review(musicReview(title: "Second review"))
        )
        let raw = [firstReview, diary, list, secondReview]

        XCTAssertEqual(filteredFollowingActivity(raw, using: .all).map(\.id), raw.map(\.id))
        XCTAssertEqual(
            filteredFollowingActivity(raw, using: .reviews).map(\.id),
            [firstReview.id, secondReview.id]
        )
        XCTAssertEqual(filteredFollowingActivity(raw, using: .diary).map(\.id), [diary.id])
        XCTAssertEqual(filteredFollowingActivity(raw, using: .lists).map(\.id), [list.id])
    }

    func testFollowingActivityNoMatchesDoesNotMutateRawFeed() {
        let diary = followingActivityItem(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            payload: .diary(journalEntry(title: "Only diary entry"))
        )
        let raw = [diary]

        let visible = filteredFollowingActivity(raw, using: .reviews)

        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(raw.map(\.id), [diary.id], "Filtering must not consume or reorder the raw paginated feed")
    }

    func testMusicRatingDistributionUsesHalfStarBucketsAndExcludesUnratedTracks() {
        let states = [
            trackSubjectState(title: "Half", defaultRating: 0.5),
            trackSubjectState(title: "Four", defaultRating: 4.0),
            trackSubjectState(title: "Another four", defaultRating: 4.0),
            trackSubjectState(title: "Five", defaultRating: 5.0),
            trackSubjectState(title: "Unrated")
        ]

        let buckets = musicRatingDistribution(states)

        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(buckets.first, MusicRatingDistributionBucket(rating: 0.5, count: 1))
        XCTAssertEqual(buckets.first(where: { $0.rating == 4.0 })?.count, 2)
        XCTAssertEqual(buckets.last, MusicRatingDistributionBucket(rating: 5.0, count: 1))
        XCTAssertEqual(buckets.map(\.count).reduce(0, +), 4)
    }

    func testMusicRatingDistributionCombinesSongAndAlbumRatings() {
        let buckets = musicRatingDistribution(ratings: [1, 4.5, 4.5, 5])

        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(buckets.first(where: { $0.rating == 1 })?.count, 1)
        XCTAssertEqual(buckets.first(where: { $0.rating == 4.5 })?.count, 2)
        XCTAssertEqual(buckets.first(where: { $0.rating == 5 })?.count, 1)
        XCTAssertEqual(buckets.map(\.count).reduce(0, +), 4)
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

    private func reviewTrack(title: String, album: ReviewableAlbum? = nil) -> HarmonyTrack {
        HarmonyTrack(
            title: title,
            artist: "Test artist",
            album: album?.title ?? "Test album",
            duration: 180,
            symbol: "music.note",
            mappings: [ProviderTrackMapping(provider: .spotify, providerID: "spotify:track:\(title)", availability: .playable)],
            reviewableAlbum: album
        )
    }

    private func identityTrack(
        canonicalTrackID: UUID? = nil,
        title: String = "Identity Song",
        artist: String = "Identity Artist",
        album: String = "Identity Album",
        duration: TimeInterval = 180,
        isrc: String? = nil,
        provider: MusicProvider,
        providerID: String
    ) -> HarmonyTrack {
        HarmonyTrack(
            canonicalTrackID: canonicalTrackID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            symbol: "music.note",
            isrc: isrc,
            mappings: [ProviderTrackMapping(
                provider: provider,
                providerID: providerID,
                availability: .playable
            )]
        )
    }

    private func journalEntry(
        title: String,
        artist: String = "Test artist",
        album: String = "Test album",
        playedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isRelisten: Bool = false,
        tags: [String] = [],
        rating: Double? = nil,
        reviewID: UUID? = nil
    ) -> RemoteListeningHistoryEntry {
        RemoteListeningHistoryEntry(
            id: UUID(),
            profileID: UUID(),
            playedAt: playedAt,
            source: "manual",
            visibility: .privateOnly,
            isRelisten: isRelisten,
            tags: tags,
            rating: rating,
            reviewID: reviewID,
            canonicalTrack: RemoteCatalogTrack(
                id: UUID(),
                title: title,
                artist: artist,
                album: album,
                durationMilliseconds: 180_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: nil
            ),
            profile: RemoteProfile(displayName: "Test listener")
        )
    }

    private func trackSubjectState(
        id: UUID = UUID(),
        title: String,
        artist: String = "Test artist",
        album: String = "Test album",
        hasListened: Bool = false,
        defaultRating: Double? = nil,
        isLoved: Bool = false,
        wantToListen: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RemoteTrackSubjectState {
        RemoteTrackSubjectState(
            profileID: UUID(),
            canonicalTrackID: id,
            hasListened: hasListened,
            defaultRating: defaultRating,
            isLoved: isLoved,
            wantToListen: wantToListen,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            canonicalTrack: RemoteCatalogTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                durationMilliseconds: 180_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: nil
            )
        )
    }

    private func musicReview(
        title: String,
        artist: String = "Test artist",
        album: String = "Test album",
        body: String = "Fixture review",
        rating: Double = 4,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        subjectKind: String = "track",
        isLoved: Bool = false
    ) -> RemoteMusicReview {
        RemoteMusicReview(
            id: UUID(),
            profileID: UUID(),
            rating: rating,
            body: body,
            createdAt: createdAt,
            visibility: .followers,
            containsSpoilers: false,
            isLoved: isLoved,
            subjectKind: subjectKind,
            subjectTitle: title,
            subjectArtist: artist,
            subjectArtworkURL: nil,
            subjectDeepLink: nil,
            canonicalAlbumID: nil,
            canonicalTrack: RemoteCatalogTrack(
                id: UUID(),
                title: title,
                artist: artist,
                album: album,
                durationMilliseconds: 180_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: nil
            ),
            canonicalAlbum: nil,
            profile: RemoteProfile(displayName: "Test listener"),
            comments: [],
            reactions: []
        )
    }

    private func musicList(title: String) -> RemoteMusicList {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return RemoteMusicList(
            id: UUID(),
            ownerID: UUID(),
            title: title,
            description: "A test list",
            tags: ["test"],
            isRanked: true,
            visibility: .followers,
            entriesRevision: 2,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now,
            deletedAt: nil,
            owner: RemoteProfile(displayName: "Test listener")
        )
    }

    private func followingActivityItem(
        id: UUID,
        payload: RemoteFollowingActivityPayload
    ) -> RemoteFollowingActivityItem {
        RemoteFollowingActivityItem(
            id: id,
            actorID: UUID(),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            actor: RemoteProfile(displayName: "Following listener"),
            payload: payload
        )
    }

    private func musicListEntry(
        canonicalTrackID: UUID,
        canonicalTrack: RemoteCatalogTrack?
    ) -> RemoteMusicListEntry {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return RemoteMusicListEntry(
            id: UUID(),
            listID: UUID(),
            canonicalTrackID: canonicalTrackID,
            position: 1,
            note: "",
            createdAt: now,
            updatedAt: now,
            canonicalTrack: canonicalTrack
        )
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

@MainActor
private final class RecordingAppleMusicProvider: AppleMusicProviding {
    let provider: MusicProvider = .appleMusic
    var connectionState: ProviderConnectionState = .disconnected
    let capabilities = ProviderCapabilities.appleMusicMock

    func authorize() async throws {
        connectionState = .connected(accountName: "Test Apple Music")
    }

    func search(query: String) async throws -> [HarmonyTrack] {
        [HarmonyTrack(
            title: "Apple Catalog Track",
            artist: "Harmony Test Artist",
            album: "Harmony Test Album",
            duration: 180,
            symbol: "music.note",
            mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: "apple-test-track", availability: .playable)]
        )]
    }

    func resolve(track: HarmonyTrack) async throws -> ResolvedProviderTrack {
        ResolvedProviderTrack(provider: .appleMusic, providerID: "apple-test-track", title: track.title, artist: track.artist, playbackCapability: .queuePlayback)
    }

    func perform(_ command: ProviderPlaybackCommand) async throws -> ProviderPlaybackResult { .applied }
}
