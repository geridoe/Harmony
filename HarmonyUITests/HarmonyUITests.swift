//
//  HarmonyUITests.swift
//  HarmonyUITests
//
//  Created by Geri Doe on 7/25/22.
//

import XCTest

class HarmonyUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testProductionLaunchHasNoPrototypeSession() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Harmony"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Build a queue, then start or join a live session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Friday Night Finds"].exists)
    }

    func testConnectionsTabLoadsWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launch()

        let connectionsTab = app.tabBars.buttons["Connections"]
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 5))
        connectionsTab.tap()

        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Harmony profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Social privacy"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Your listening services"].waitForExistence(timeout: 5))
    }

    func testConnectionsExposesMusicShelfPrivacy() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Connections"].tap()
        let privacy = app.descendants(matching: .any)["music-shelf-privacy"]
        for _ in 0..<4 where !privacy.exists { app.swipeUp() }
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Music shelf"].exists || app.buttons["Music shelf"].exists)
    }

    func testListenTabLoadsSocialSections() throws {
        let app = XCUIApplication()
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()

        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["People"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Eavesdrop"].waitForExistence(timeout: 5))
        let listeningHistory = app.staticTexts["Listening history"]
        for _ in 0..<4 where !listeningHistory.exists { app.swipeUp() }
        XCTAssertTrue(listeningHistory.waitForExistence(timeout: 5))
    }

    func testReviewNotificationOpensExactReviewEvenWhenAlreadyRead() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-social-activity")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))

        let notification = app.descendants(matching: .any)[
            "notification-review-30000000-0000-0000-0000-000000000003"
        ]
        XCTAssertTrue(notification.waitForExistence(timeout: 5))
        notification.tap()

        XCTAssertTrue(app.navigationBars["Afterglow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A fixture opinion."].exists)
    }

    func testEndedBroadcastNotificationReopensSnapshotConversation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-social-activity")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))

        let notification = app.descendants(matching: .any)[
            "notification-broadcast-72000000-0000-0000-0000-000000000007"
        ]
        XCTAssertTrue(notification.waitForExistence(timeout: 5))
        notification.tap()

        XCTAssertTrue(app.descendants(matching: .any)[
            "eavesdrop-detail-72000000-0000-0000-0000-000000000007"
        ].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[
            "eavesdrop-ended-72000000-0000-0000-0000-000000000007"
        ].exists)
        XCTAssertTrue(app.staticTexts["Afterglow"].exists)
        XCTAssertTrue(app.staticTexts["That bridge was incredible."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["notification-destination-unavailable"].exists)
    }

    func testReviewsTabIsAFirstClassDestination() throws {
        let app = XCUIApplication()
        app.launch()

        let reviewsTab = app.tabBars.buttons["Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 5))
        reviewsTab.tap()

        let reviewsNavigation = app.navigationBars["Reviews"]
        if !reviewsNavigation.waitForExistence(timeout: 3) {
            reviewsTab.tap()
        }
        XCTAssertTrue(reviewsNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reviews"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ratings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Activity"].exists)
        XCTAssertFalse(app.buttons["Diary"].exists)
        XCTAssertTrue(app.buttons["Write review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'Listening events stay in Diary under Listen'"
        )).firstMatch.exists)
        app.buttons["Write review"].tap()
        XCTAssertTrue(app.navigationBars["Write a review"].waitForExistence(timeout: 5))
        let chooseMusic = app.buttons["Choose a song or album"]
        XCTAssertTrue(chooseMusic.waitForExistence(timeout: 5))
        chooseMusic.tap()
        XCTAssertTrue(app.navigationBars["Choose music"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Albums"].waitForExistence(timeout: 5))
        app.buttons["Albums"].tap()
        XCTAssertTrue(app.staticTexts["No albums found for this search."].waitForExistence(timeout: 5))
        app.buttons["Songs"].tap()
        let reviewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review song '")).firstMatch
        XCTAssertTrue(reviewSong.waitForExistence(timeout: 5))
        reviewSong.tap()
        XCTAssertTrue(app.switches["Contains spoilers"].waitForExistence(timeout: 5))
        let optionalReviewRating = app.switches["review-composer-rating-toggle"]
        XCTAssertTrue(optionalReviewRating.waitForExistence(timeout: 5))
        XCTAssertEqual(optionalReviewRating.value as? String, "0")
        XCTAssertTrue(app.descendants(matching: .any)["review-composer-no-rating"].exists)
        XCTAssertTrue(app.staticTexts["Audience"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Only me"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose different music"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your diary"].exists)

        let addToDiary = app.switches["review-add-to-diary"]
        XCTAssertTrue(addToDiary.exists)
        for _ in 0..<3 where !addToDiary.isHittable { app.swipeUp() }
        XCTAssertTrue(addToDiary.isHittable)
        addToDiary.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(addToDiary.value as? String, "1")
        for _ in 0..<2 where !app.staticTexts["Listened on"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Listened on"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Relisten"].exists)
        for _ in 0..<4 where !app.textFields["review-diary-tags"].exists { app.swipeUp() }
        XCTAssertTrue(app.textFields["review-diary-tags"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Publish review and log listen"].exists)
    }

    func testReviewFeedKeepsConversationControlsOffTheSummary() throws {
        let app = XCUIApplication()
        app.launch()

        let reviewsTab = app.tabBars.buttons["Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 5))
        reviewsTab.tap()

        let reviewsNavigation = app.navigationBars["Reviews"]
        if !reviewsNavigation.waitForExistence(timeout: 3) {
            reviewsTab.tap()
        }
        XCTAssertTrue(reviewsNavigation.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Add a comment"].exists)
        XCTAssertFalse(app.buttons["Post comment"].exists)
    }

    func testMusicShelfIsDedicatedSearchableDestination() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))

        let musicShelf = app.buttons["Music shelf"]
        XCTAssertTrue(musicShelf.waitForExistence(timeout: 5))
        musicShelf.tap()

        XCTAssertTrue(app.navigationBars["Music shelf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["music-shelf-search"].exists)
        XCTAssertTrue(app.segmentedControls["music-shelf-scope"].exists)
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Loved"].exists)
        XCTAssertTrue(app.buttons["Want to listen"].exists)
        XCTAssertTrue(app.buttons["Rated"].exists)
        XCTAssertTrue(app.buttons["Listened"].exists)
    }

    func testMusicShelfTrackDetailEditsIndependentStatusAndShowsHistory() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))

        let musicShelf = app.buttons["Music shelf"]
        XCTAssertTrue(musicShelf.waitForExistence(timeout: 5))
        musicShelf.tap()
        XCTAssertTrue(app.navigationBars["Music shelf"].waitForExistence(timeout: 5))

        let trackID = "20000000-0000-0000-0000-000000000002"
        let track = app.descendants(matching: .any)["music-shelf-open-\(trackID)"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()

        XCTAssertTrue(app.navigationBars["Afterglow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["owner-track-detail-header"].exists)
        XCTAssertTrue(app.staticTexts["Wolves at Noon"].exists)
        XCTAssertTrue(app.staticTexts["Northern Lights"].exists)

        let listened = app.switches["owner-track-listened"]
        let loved = app.switches["owner-track-loved"]
        let want = app.switches["owner-track-want"]
        let ratingToggle = app.switches["owner-track-rating-toggle"]
        XCTAssertEqual(listened.value as? String, "1")
        XCTAssertEqual(loved.value as? String, "1")
        XCTAssertEqual(want.value as? String, "0")
        XCTAssertEqual(ratingToggle.value as? String, "1")
        XCTAssertEqual(app.descendants(matching: .any)["owner-track-rating"].value as? String, "4.0 out of 5")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'Diary entries are historical snapshots'"
        )).firstMatch.exists)

        for _ in 0..<3 where !ratingToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(ratingToggle.isHittable)
        ratingToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let ratingCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '0'"),
            object: ratingToggle
        )
        wait(for: [ratingCleared], timeout: 3)
        XCTAssertEqual(ratingToggle.value as? String, "0")
        for _ in 0..<2 where !want.isHittable { app.swipeDown() }
        XCTAssertTrue(want.isHittable)
        want.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let wantEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: want
        )
        wait(for: [wantEnabled], timeout: 3)
        XCTAssertEqual(want.value as? String, "1")
        XCTAssertEqual(listened.value as? String, "0", "Want to listen clears Listened and its overall rating")

        let save = app.buttons["owner-track-save"]
        for _ in 0..<3 where !save.exists { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "An unchanged status cannot be submitted twice")

        let diary = app.descendants(matching: .any)["owner-track-diary-40000000-0000-0000-0000-000000000004"]
        for _ in 0..<4 where !diary.exists { app.swipeUp() }
        XCTAssertTrue(diary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '#party' AND label CONTAINS '#vinyl' ")).firstMatch.exists)

        let review = app.descendants(matching: .any)["owner-track-review-30000000-0000-0000-0000-000000000003"]
        for _ in 0..<3 where !review.exists { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.navigationBars["Afterglow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A fixture opinion."].exists)
    }

    func testTypedFollowingActivityNavigatesToMemberShelves() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-social-activity")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        app.buttons["Following activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.descendants(matching: .any)["following-activity-card-review-50000000-0000-0000-0000-000000000005"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["following-activity-card-diary-60000000-0000-0000-0000-000000000006"].exists)
        XCTAssertTrue(app.staticTexts["Shared with followers"].exists)

        let actor = app.staticTexts["UI Test Listener"].firstMatch
        XCTAssertTrue(actor.waitForExistence(timeout: 5))
        actor.tap()

        // A fast Simulator can finish the profile push under the synthesized
        // touch and activate its first review row. Return to the profile if so.
        if !app.navigationBars["UI Test Listener"].waitForExistence(timeout: 1),
           app.navigationBars["Afterglow"].exists {
            app.navigationBars["Afterglow"].buttons["UI Test Listener"].tap()
        }
        XCTAssertTrue(app.navigationBars["UI Test Listener"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["member-profile-privacy"].exists)
        let shelves = app.segmentedControls["member-profile-shelf-picker"]
        XCTAssertTrue(shelves.exists)
        XCTAssertTrue(app.staticTexts["Afterglow"].exists)

        shelves.buttons["Diary"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'member-profile-diary-'")).firstMatch.waitForExistence(timeout: 5))

        let linkedReview = app.descendants(matching: .any)["member-profile-diary-review-30000000-0000-0000-0000-000000000003"]
        XCTAssertTrue(linkedReview.waitForExistence(timeout: 5))
        linkedReview.tap()
        XCTAssertTrue(app.navigationBars["Afterglow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A fixture opinion."].exists)
        app.navigationBars["Afterglow"].buttons["UI Test Listener"].tap()
        XCTAssertTrue(app.navigationBars["UI Test Listener"].waitForExistence(timeout: 5))

        shelves.buttons["Loved"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["member-profile-loved-20000000-0000-0000-0000-000000000002"].waitForExistence(timeout: 5))
    }

    func testJournalComposerCapturesDatedRelistenContext() throws {
        let app = XCUIApplication()
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        let diary = app.buttons["Diary"]
        XCTAssertTrue(diary.waitForExistence(timeout: 5))
        diary.tap()
        XCTAssertTrue(app.navigationBars["Diary"].waitForExistence(timeout: 5))

        let logListen = app.buttons["Log a listen"]
        for _ in 0..<3 where !logListen.exists { app.swipeUp() }
        XCTAssertTrue(logListen.waitForExistence(timeout: 5))
        logListen.tap()

        XCTAssertTrue(app.navigationBars["Log a listen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose a song"].exists)
        XCTAssertTrue(app.staticTexts["Listened on"].exists)
        XCTAssertTrue(app.switches["Relisten"].exists)
        XCTAssertTrue(app.textFields["Tags, separated by commas"].exists)
        XCTAssertTrue(app.staticTexts["Audience"].exists)
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertFalse(app.staticTexts["Linked opinion"].exists, "Opinion linkage belongs to editing an existing manual diary entry")

        let ratingToggle = app.switches["diary-create-rating-toggle"]
        let ratingPicker = app.descendants(matching: .any)["diary-create-rating"]
        XCTAssertTrue(ratingToggle.exists)
        XCTAssertEqual(ratingToggle.value as? String, "0")
        XCTAssertTrue(ratingPicker.exists)
        XCTAssertFalse(ratingPicker.isEnabled, "An unrated listen keeps the rating picker inactive")

        app.buttons["Choose a song"].tap()
        XCTAssertTrue(app.navigationBars["Choose music"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Albums"].exists, "A diary log selects one track, not an album review subject")
        let reviewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review song '")).firstMatch
        XCTAssertTrue(reviewSong.waitForExistence(timeout: 5))
        reviewSong.tap()
        XCTAssertTrue(app.buttons["Choose a different song"].waitForExistence(timeout: 5))
    }

    func testManualJournalEntryEditorPrefillsContextAndCompatibleOpinion() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        app.buttons["Diary"].tap()
        XCTAssertTrue(app.navigationBars["Diary"].waitForExistence(timeout: 5))

        let edit = app.buttons["Edit journal entry for Afterglow"]
        for _ in 0..<3 where !edit.exists { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        XCTAssertTrue(app.navigationBars["Edit journal entry"].waitForExistence(timeout: 5))
        let fixtureEntry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Afterglow'")).firstMatch
        XCTAssertTrue(fixtureEntry.exists)
        XCTAssertTrue(app.staticTexts["Wolves at Noon"].exists)
        XCTAssertTrue(app.staticTexts["Listened on"].exists)
        XCTAssertEqual(app.switches["Relisten"].value as? String, "1")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '#party' AND label CONTAINS '#vinyl'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Linked opinion"].exists)
        let linkedOpinion = app.descendants(matching: .any)["diary-edit-linked-opinion"]
        XCTAssertTrue(linkedOpinion.exists)
        let linkedOpinionValue = linkedOpinion.value as? String ?? linkedOpinion.label
        XCTAssertNotEqual(linkedOpinionValue, "No linked opinion")
        XCTAssertTrue(app.buttons["Save changes"].exists)
        XCTAssertFalse(app.buttons["Choose a different song"].exists, "Editing preserves the logged recording")

        let ratingToggle = app.switches["diary-edit-rating-toggle"]
        let ratingPicker = app.descendants(matching: .any)["diary-edit-rating"]
        XCTAssertTrue(ratingToggle.exists)
        XCTAssertEqual(ratingToggle.value as? String, "1")
        XCTAssertTrue(ratingPicker.exists)
        XCTAssertTrue(ratingPicker.isEnabled)
        XCTAssertEqual(ratingPicker.value as? String, "4.5 out of 5")
    }

    func testJournalBrowsingControlsAndFilteredEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5))
        listenTab.tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        app.buttons["Diary"].tap()
        XCTAssertTrue(app.navigationBars["Diary"].waitForExistence(timeout: 5))

        let search = app.textFields["Search journal"]
        for _ in 0..<3 where !search.exists { app.swipeUp() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Relistens"].exists)
        XCTAssertTrue(app.buttons["Linked opinions"].exists)
        let fixtureEntry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Afterglow'")).firstMatch
        XCTAssertTrue(fixtureEntry.exists)

        search.tap()
        search.typeText("no such recording")

        XCTAssertTrue(app.staticTexts["No matching listens"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Try another search, scope, or sort option. Your journal entries have not been removed."].exists)
        XCTAssertFalse(fixtureEntry.exists)
    }

    func testCanonicalAlbumIsFirstClassFromRatings() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let reviewsTab = app.tabBars.buttons["Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 5))
        reviewsTab.tap()
        let reviewsNavigation = app.navigationBars["Reviews"]
        if !reviewsNavigation.waitForExistence(timeout: 3) {
            reviewsTab.tap()
        }
        XCTAssertTrue(reviewsNavigation.waitForExistence(timeout: 5))
        app.buttons["Ratings"].tap()
        app.buttons["Albums"].tap()

        let albumID = "70000000-0000-0000-0000-000000000007"
        let albumRow = app.descendants(matching: .any)["rating-open-album-\(albumID)"]
        XCTAssertTrue(albumRow.waitForExistence(timeout: 5))
        albumRow.tap()

        XCTAssertTrue(app.navigationBars["Northern Lights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["canonical-album-header"].exists)
        XCTAssertTrue(app.staticTexts["Wolves at Noon"].exists)
        XCTAssertEqual(app.switches["canonical-album-listened"].value as? String, "1")
        XCTAssertEqual(app.switches["canonical-album-loved"].value as? String, "1")
        XCTAssertEqual(app.switches["canonical-album-want"].value as? String, "0")
        XCTAssertEqual(
            app.descendants(matching: .any)["canonical-album-rating"].value as? String,
            "4.5 out of 5"
        )
        for _ in 0..<3 where !app.staticTexts["Average across reviews visible to you"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Average across reviews visible to you"].exists)
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
