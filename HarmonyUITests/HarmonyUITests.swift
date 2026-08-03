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
        XCTAssertTrue(app.buttons["Community"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["My journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review music"].waitForExistence(timeout: 5))
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

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
