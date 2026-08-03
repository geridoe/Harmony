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
        XCTAssertTrue(app.buttons["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Diary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reviews"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your music journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Following activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Write a review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Log a listen"].exists)
        app.buttons["Write a review"].tap()
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
        XCTAssertTrue(app.staticTexts["Audience"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Only me"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose different music"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your diary"].exists)
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

    func testJournalComposerCapturesDatedRelistenContext() throws {
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
        let journalShelf = app.buttons["Diary"]
        XCTAssertTrue(journalShelf.waitForExistence(timeout: 5))
        journalShelf.tap()

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

        let reviewsTab = app.tabBars.buttons["Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 5))
        reviewsTab.tap()
        let reviewsNavigation = app.navigationBars["Reviews"]
        if !reviewsNavigation.waitForExistence(timeout: 3) { reviewsTab.tap() }
        XCTAssertTrue(reviewsNavigation.waitForExistence(timeout: 5))
        app.buttons["Diary"].tap()

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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '4.5' AND label CONTAINS 'Afterglow'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Audience"].exists)
        XCTAssertTrue(app.buttons["Save changes"].exists)
        XCTAssertFalse(app.buttons["Choose a different song"].exists, "Editing preserves the logged recording")
    }

    func testJournalBrowsingControlsAndFilteredEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-diary-editor")
        app.launch()

        let reviewsTab = app.tabBars.buttons["Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 5))
        reviewsTab.tap()
        let reviewsNavigation = app.navigationBars["Reviews"]
        if !reviewsNavigation.waitForExistence(timeout: 3) { reviewsTab.tap() }
        XCTAssertTrue(reviewsNavigation.waitForExistence(timeout: 5))
        app.buttons["Diary"].tap()

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

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
