import XCTest

final class BookshelfSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testBookshelfContentAppears() throws {
        XCTAssertTrue(app.staticTexts["档案库"].waitForExistence(timeout: 20),
                      "书架主卡片未出现，App 可能启动失败")
        XCTAssertTrue(app.buttons["新建分组"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["全部"].exists)
    }

    func testTabBarHasThreeTabs() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "未找到 Tab Bar")
        for title in ["书架", "分类", "设置"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "缺少页签：\(title)")
        }
    }

    func testSettingsTabOpens() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "未找到 Tab Bar")
        tabBar.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS / 橘阅"].waitForExistence(timeout: 10),
                      "点击设置后未进入设置页")
    }
}

// 阅读页听书球：轻点、长按都要能打开朗读面板。
final class ReaderListeningBallTests: XCTestCase {
    func testListeningBallTapAndLongPressOpenPanel() throws {
        let app = XCUIApplication()
        app.launch()

        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "紅樓夢")).firstMatch
        guard book.waitForExistence(timeout: 15) else {
            throw XCTSkip("模拟器书架上没有《紅樓夢》，跳过听书球回归")
        }
        book.tap()
        Thread.sleep(forTimeInterval: 4)

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)

        let ball = app.descendants(matching: .any)["reader.listeningBall"]
        XCTAssertTrue(ball.waitForExistence(timeout: 5), "听书球没有出现")
        XCTAssertTrue(ball.isHittable, "听书球不可点")

        let panel = app.staticTexts["朗读"]
        ball.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "轻点听书球没有打开朗读面板")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "点遮罩没有关掉面板")

        ball.press(forDuration: 0.7)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "长按听书球没有打开朗读面板")
    }

    func testListeningBallPausesAndResumesPlayback() throws {
        let app = XCUIApplication()
        app.launch()

        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "紅樓夢")).firstMatch
        guard book.waitForExistence(timeout: 15) else {
            throw XCTSkip("模拟器书架上没有《紅樓夢》，跳过听书球回归")
        }
        book.tap()
        Thread.sleep(forTimeInterval: 4)

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)

        let ball = app.descendants(matching: .any)["reader.listeningBall"]
        XCTAssertTrue(ball.waitForExistence(timeout: 5), "听书球没有出现")

        ball.tap()
        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "从本章开头读")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "朗读面板没有「从本章开头读」")
        start.tap()

        XCTAssertTrue(waitForValue(ball, "正在朗读", timeout: 12),
                      "起读后球状态不是正在朗读：\(ball.value ?? "nil")")
        ball.tap()
        XCTAssertTrue(waitForValue(ball, "已暂停", timeout: 5),
                      "点球没有暂停：\(ball.value ?? "nil")")
        ball.tap()
        XCTAssertTrue(waitForValue(ball, "正在朗读", timeout: 5),
                      "再点球没有恢复：\(ball.value ?? "nil")")
    }

    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
