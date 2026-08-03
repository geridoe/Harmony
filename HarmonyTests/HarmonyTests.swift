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

    func testFollowingActivityPayloadsKeepTheirTypedPresentation() {
        let diary = journalEntry(title: "Diary track")
        let review = musicReview(title: "Reviewed track")

        XCTAssertEqual(followingActivityPresentationKind(for: .diary(diary)), .diary)
        XCTAssertEqual(followingActivityPresentationKind(for: .review(review)), .review)
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

    private func musicReview(title: String) -> RemoteMusicReview {
        RemoteMusicReview(
            id: UUID(),
            profileID: UUID(),
            rating: 4.0,
            body: "Fixture review",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            visibility: .followers,
            containsSpoilers: false,
            isLoved: true,
            subjectKind: "track",
            subjectTitle: title,
            subjectArtist: "Test artist",
            subjectArtworkURL: nil,
            subjectDeepLink: nil,
            canonicalTrack: RemoteCatalogTrack(
                id: UUID(),
                title: title,
                artist: "Test artist",
                album: "Test album",
                durationMilliseconds: 180_000,
                artworkURL: nil,
                isExplicit: false,
                providerTracks: nil
            ),
            profile: RemoteProfile(displayName: "Test listener"),
            comments: [],
            reactions: []
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
