import XCTest

/// Shell navigation: tabs 首页 / 通话 / 短信 / 我的, calls segments 拨号 / 最近 / 联系人 / 语音信箱.
/// Labels may carry a count ("短信，3 个未读"), so match on the prefix.
extension XCUIApplication {
    func shell(_ prefix: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func launchFixture(_ environment: [String: String] = [:], arguments: [String] = []) {
        launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        for (key, value) in environment { launchEnvironment[key] = value }
        launch()
        // A fresh install asks for notification permission first; that alert would cover the UI.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow"])).firstMatch
            if allow.exists { allow.tap() } else { alert.buttons.firstMatch.tap() }
        }
    }
}

final class SMSNavigationUITests: XCTestCase {
    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor private func openRecents(_ app: XCUIApplication) {
        XCTAssertTrue(app.shell("通话").waitForExistence(timeout: 10))
        app.shell("通话").tap()
        XCTAssertTrue(app.shell("最近").waitForExistence(timeout: 5))
        app.shell("最近").tap()
    }

    @MainActor func testRecentDetailAndPreferencesReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_RECENTS": "1"])
        defer { app.terminate() }
        openRecents(app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "138 0013 8000")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["通话详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["经由线路"].exists)
        keep(app, "recents-detail")
        app.buttons["关闭"].tap()
        app.shell("我的").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观与偏好")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.waitForExistence(timeout: 5))
        keep(app, "theme-settings")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.shell("我的").waitForExistence(timeout: 5))
    }

    @MainActor func testVerificationCodeHighlightWithoutBackendCode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_CODE_SMS": "1"])
        defer { app.terminate() }
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let codeBody = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(codeBody.waitForExistence(timeout: 5))
        keep(app, "177-verification-code-highlight")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor func testCodeLongPressMenuAndMissingRegion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_CODE_SMS": "1"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        let body = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["复制验证码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["选择文本"].exists)
        XCTAssertTrue(app.buttons["更多…"].exists)
        app.buttons["复制验证码"].firstMatch.tap()
        app.terminate()
        app.launchEnvironment["AIRSIM_UI_CALL"] = "incoming"
        app.launchEnvironment["AIRSIM_UI_REGION_NUMBER"] = "17800159951"
        app.launch()
        XCTAssertTrue(app.staticTexts["北京市"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testAllAndMissedRecentFilter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_RECENTS": "1", "AIRSIM_UI_RECENTS_LONG_REGION": "1"])
        defer { app.terminate() }
        openRecents(app)
        XCTAssertTrue(app.staticTexts["呼出"].waitForExistence(timeout: 5))
        keep(app, "recents-all")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "未接")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["未接"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["呼出"].exists)
        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["呼出"].waitForExistence(timeout: 5))
    }

    @MainActor func testMessageActionsAndUnclutteredThread() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_CODE_SMS": "1"], arguments: ["-airsim.appearance", "light"])
        defer { app.terminate() }
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        XCTAssertTrue(app.buttons["清空全部短信"].waitForExistence(timeout: 5))
        keep(app, "sms-actions")
        app.buttons["清空全部短信"].tap()
        XCTAssertTrue(app.buttons["删除全部"].waitForExistence(timeout: 5))
        // iOS 26 confirmation dialogs may omit a visible cancel button: dismiss by tapping outside.
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        XCTAssertFalse(app.buttons["删除全部"].waitForExistence(timeout: 2))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        let body = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["验证码 (code)"].exists)
        XCTAssertFalse(app.buttons["复制短信"].exists)
        XCTAssertFalse(app.buttons["复制验证码"].exists)
        keep(app, "clean-sms-thread")
        body.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["复制验证码"].waitForExistence(timeout: 5))
        app.buttons["复制验证码"].tap()
    }

    @MainActor func testSMSSearchByNameContentAndNumber() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_SEARCH": "1"])
        defer { app.terminate() }
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Navigation Alice")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Alice")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["清除"].tap(); search.typeText("pickup-token")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Alice")).firstMatch.waitForExistence(timeout: 5))
        keep(app, "177-sms-content-search")
        app.buttons["清除"].tap(); search.typeText("99999999")
        XCTAssertTrue(app.staticTexts["未找到短信"].waitForExistence(timeout: 5))
    }

    @MainActor func testOfflineRegionCStyleInCallAndHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_CALL": "incoming", "AIRSIM_UI_REGION": "1"])
        XCTAssertTrue(app.staticTexts["SIM 2 · 北京市"].waitForExistence(timeout: 10))
        keep(app, "177-region-C-incoming")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "AIRSIM_UI_CALL")
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        openRecents(app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "138 0013 8000")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["北京市"].waitForExistence(timeout: 5))
        keep(app, "177-region-C-history")
    }

    @MainActor func testThemeSwitchAndRecentDelete() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_RECENTS": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.shell("我的").waitForExistence(timeout: 10))
        app.shell("我的").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观与偏好")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.tap()
        app.buttons["墨绿"].tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观、")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        app.buttons["深色"].tap()
        keep(app, "forest-dark-settings")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "墨绿")).firstMatch.waitForExistence(timeout: 5))
        keep(app, "forest-dark-account")
        openRecents(app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "+86 138 0013 8000")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
        // Restore the defaults this test changed so later launches start from 跟随系统 / 暖橙.
        app.shell("我的").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观与偏好")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.tap()
        app.buttons["暖橙"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观、")).firstMatch.tap()
        app.buttons["跟随系统"].tap()
        app.buttons["settings.done"].tap()
    }

    @MainActor
    func testSMSLineMenuSwitchesInThreadAndCompose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_SMS_SIM": "1"])
        defer { app.terminate() }
        let compose = app.buttons["新建短信"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let selector = app.buttons["sms.simSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        XCTAssertTrue(selector.label.contains("SIM 2"))
        selector.tap()
        let firstSIM = app.buttons["SIM 1"]
        XCTAssertTrue(firstSIM.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(firstSIM.frame.width, 240)
        XCTAssertLessThanOrEqual(firstSIM.frame.height, 60)
        keep(app, "176-compact-sim-popover")
        firstSIM.tap()
        XCTAssertTrue(selector.label.contains("SIM 1"))
        app.buttons["取消"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        app.buttons["SIM 1"].tap()
        XCTAssertTrue(selector.label.contains("SIM 1"))
        keep(app, "sms-line-selector-thread")
    }

    @MainActor
    private func dismissMicrophonePrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let description = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        guard description.contains("麦克风") || description.localizedCaseInsensitiveContains("microphone") else { return }
        for label in ["不允许", "Don’t Allow", "Don't Allow"] {
            let deny = alert.buttons[label]
            if deny.exists { deny.tap(); return }
        }
    }

    @MainActor
    func testContactsAndRecentsSurviveTabSwitches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["新建短信"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.shell("通话").tap()
            app.shell("联系人").tap()
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5) || app.buttons["允许访问通讯录"].exists)
            app.shell("最近").tap()
            XCTAssertTrue(app.buttons["全部"].waitForExistence(timeout: 5))
            app.shell("我的").tap()
            app.shell("短信").tap()
            XCTAssertTrue(app.buttons["新建短信"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testConversationReopensAfterSwitchingTabsAndReturning() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture()
        defer { app.terminate() }
        let compose = app.buttons["新建短信"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        for iteration in 0..<3 {
            app.shell("我的").tap()
            app.shell("短信").tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            if iteration == 0 {
                compose.tap()
                let cancel = app.buttons["取消"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 5))
                cancel.tap()
                XCTAssertTrue(compose.waitForExistence(timeout: 5))
            }
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let navigation = app.navigationBars["sms-navigation-fixture"]
            XCTAssertTrue(navigation.waitForExistence(timeout: 5))
            XCTAssertFalse(app.shell("我的").exists && app.shell("我的").isHittable, "a conversation covers the tab bar")
            let systemBack = app.buttons["BackButton"]
            if systemBack.exists { systemBack.tap() } else { navigation.buttons.firstMatch.tap() }
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            XCTAssertTrue(app.shell("短信").isHittable)
        }
    }

    @MainActor
    func testDialPadKeepsNumberAcrossRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.shell("通话").waitForExistence(timeout: 10))
        app.shell("通话").tap()
        app.shell("拨号").tap()
        for label in ["1", "2 ABC", "3 DEF"] { app.buttons[label].tap() }
        let number = app.staticTexts["warm.dial.number"]
        XCTAssertEqual(number.label, "123")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(number.waitForExistence(timeout: 5))
            XCTAssertEqual(number.label, "123")
            keep(app, "dialpad-\(orientation.rawValue)")
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["4 GHI"].waitForExistence(timeout: 5))
        sleep(1) // let the rotation settle before tapping
        app.buttons["4 GHI"].tap()
        let appended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1234"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [appended], timeout: 5), .completed)
        app.buttons["删除一位"].tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "123"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 5), .completed)
    }

    @MainActor
    func testAccessibilityTextDialPadActionsRemainReachable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { app.terminate() }
        XCTAssertTrue(app.shell("通话").waitForExistence(timeout: 10))
        app.shell("通话").tap()
        app.shell("拨号").tap()
        app.buttons["1"].tap()
        let delete = app.buttons["删除一位"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        XCTAssertTrue(app.buttons["#"].isHittable)
        keep(app, "dialpad-accessibility-text-actions")
        delete.tap()
        let number = app.staticTexts["warm.dial.number"]
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "输入号码"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
    }

    @MainActor
    func testMessageDraftSurvivesRotationWithKeyboard() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let reply = app.descendants(matching: .any).matching(identifier: "sms.reply").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        reply.typeText("draft 123")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(reply.waitForExistence(timeout: 5))
            XCTAssertEqual(reply.value as? String, "draft 123")
            XCTAssertTrue(reply.isHittable)
            keep(app, "sms-draft-\(orientation.rawValue)")
        }
    }

    @MainActor
    func testCallControlsAndKeypadRemainReachableInLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for phase in ["incoming", "active"] {
            app.launchEnvironment["AIRSIM_UI_CALL"] = phase
            app.launch()
            dismissMicrophonePrompt()
            XCUIDevice.shared.orientation = .landscapeLeft
            let action = app.buttons[phase == "incoming" ? "接听" : "挂断"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            if !action.isHittable { app.swipeUp() }
            keep(app, "call-\(phase)-before-hit-test")
            if !action.isHittable {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "call-hit-test-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(action.isHittable)
            XCTAssertFalse(app.shell("短信").exists && app.shell("短信").isHittable, "call surface must cover the tab bar")
            keep(app, "call-\(phase)-landscape")
            if phase == "active" {
                app.buttons["拨号键盘"].tap()
                XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
                app.swipeUp()
                XCTAssertTrue(app.buttons["发送 DTMF #"].isHittable)
                app.buttons["取消"].tap()
                XCTAssertTrue(action.waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    /// A call can be collapsed back to the shell and restored from the 返回通话 bar (upstream 0.9.8.26).
    @MainActor func testCallCollapseAndRestoreKeepsSameCall() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_CALL": "active", "AIRSIM_UI_REGION_NUMBER": "10086"])
        defer { app.terminate() }
        let minimize = app.buttons["call.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 10))
        keep(app, "call-active")
        minimize.tap()
        let restore = app.buttons["call.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertFalse(minimize.isHittable)
        XCTAssertTrue(app.shell("短信").isHittable, "collapsed call must hand the shell back")
        app.shell("短信").tap()
        keep(app, "call-collapsed")
        restore.tap()
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        XCTAssertTrue(minimize.isHittable)
    }

    /// Exact service numbers get a logo in the list and thread header; 我的 › 网络诊断 opens.
    @MainActor func testServiceLogosAndNetworkDiagnostics() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_WARM": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.shell("短信").waitForExistence(timeout: 10))
        app.shell("短信").tap()
        let mobile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "中国移动，10086")).firstMatch
        XCTAssertTrue(mobile.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工商银行，95588")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "中国移动，22922")).firstMatch.exists)
        keep(app, "sms-service-logos")
        mobile.tap()
        XCTAssertTrue(app.navigationBars["10086"].waitForExistence(timeout: 5))
        keep(app, "sms-service-thread")
        app.navigationBars.buttons.firstMatch.tap()
        app.shell("我的").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "网络诊断")).firstMatch
        let tabTop = app.shell("我的").frame.minY
        for _ in 0..<6 where !(row.exists && row.frame.maxY < tabTop) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["网络诊断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机网络"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["当前线路"].waitForExistence(timeout: 10))
        keep(app, "network-diagnostics")
        app.swipeUp()
        keep(app, "network-diagnostics-bottom")
    }

    /// The shell's four tabs and the calls segments (首页 / 通话 / 短信 / 我的).
    @MainActor func testShellTabsAndCallSegments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(["AIRSIM_UI_WARM": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.shell("首页").waitForExistence(timeout: 10))
        app.shell("首页").tap()
        XCTAssertTrue(app.staticTexts["还没有线路"].waitForExistence(timeout: 5))
        keep(app, "shell-home")
        app.shell("通话").tap()
        for segment in ["拨号", "最近", "联系人", "语音信箱"] {
            XCTAssertTrue(app.shell(segment).waitForExistence(timeout: 5), segment)
            app.shell(segment).tap()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "555 0591")).firstMatch.waitForExistence(timeout: 5))
        keep(app, "shell-voicemail")
        app.shell("短信").tap()
        XCTAssertTrue(app.buttons["新建短信"].waitForExistence(timeout: 5))
        app.shell("我的").tap()
        XCTAssertTrue(app.staticTexts["连接与设备"].waitForExistence(timeout: 5))
        keep(app, "shell-account")
    }
}

final class SettingsJourneyUITests: XCTestCase {
    /// Settings open from 我的 › 全部设置 as a sheet whose root is 设置.
    @MainActor private func launchSettings(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchFixture(arguments: arguments)
        XCTAssertTrue(app.shell("我的").waitForExistence(timeout: 15))
        app.shell("我的").tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全部设置")).firstMatch
        // The row must clear the tab bar, not merely exist under it.
        let tabTop = app.shell("我的").frame.minY
        for _ in 0..<6 where !(all.exists && all.frame.maxY < tabTop) { app.swipeUp() }
        all.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-home"; shot.lifetime = .keepAlways; add(shot)
        return app
    }

    @MainActor private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["settings.link.\(id)"]
        for attempt in 0..<24 {
            if row.exists && row.isHittable {
                let frame = app.frame
                var viewport = frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
                for bar in [app.navigationBars.firstMatch] where bar.exists {
                    let bounds = bar.frame
                    if bounds.width > bounds.height, bounds.height < frame.height * 0.4, bounds.midY < frame.midY {
                        let top = max(viewport.minY, bounds.maxY + 8)
                        viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
                    }
                }
                let visible = row.frame.intersection(viewport)
                if !visible.isNull, viewport.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) {
                    row.tap()
                    return
                }
            }
            // Search downwards first, then back up: returning from a page can leave the list below the row.
            let (from, to) = attempt < 12 ? (0.72, 0.35) : (0.35, 0.72)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: from))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: to)))
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "unreachable-\(id)"; shot.lifetime = .keepAlways; add(shot)
        XCTFail("Navigation entry is not reachable: \(id)")
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
        else { app.navigationBars.firstMatch.buttons.firstMatch.tap() }
    }

    @MainActor func testCategoriesAndManualPairingPreserveNavigation() {
        let app = launchSettings(); defer { app.terminate() }
        open("connections", in: app)
        XCTAssertTrue(app.navigationBars["连接与设备"].waitForExistence(timeout: 3))
        open("add", in: app)
        open("pairManual", in: app)
        XCTAssertTrue(app.textFields["manualPairingHost"].waitForExistence(timeout: 3))
        let connect = app.buttons["连接并加密配对"]
        for _ in 0..<6 where !connect.exists {
            let form = app.collectionViews.firstMatch
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)))
        }
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)
        back(app)
        XCTAssertTrue(app.navigationBars["添加设备"].waitForExistence(timeout: 3))
        back(app); back(app)
        open("widgets", in: app)
        open("widgetGuide", in: app)
        XCTAssertTrue(app.staticTexts["添加小组件"].waitForExistence(timeout: 3))
        back(app); back(app)
        open("preferences", in: app)
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-preferences"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testFeedbackDraftSurvivesRangePreviewAndReturn() {
        let app = launchSettings(); defer { app.terminate() }
        open("help", in: app); open("feedback", in: app)
        let text = app.textFields["settings.feedbackDescription"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.tap()
        if let previous = text.value as? String, previous != text.placeholderValue {
            text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        text.typeText("settings draft retained")
        XCTAssertEqual(text.value as? String, "settings draft retained")
        let done = app.toolbars.buttons["完成"]
        if done.exists { done.tap() }
        open("feedbackPreview", in: app)
        XCTAssertTrue(app.navigationBars["上传内容范围"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings draft retained"].waitForExistence(timeout: 3))
        back(app)
        XCTAssertEqual(app.textFields["settings.feedbackDescription"].value as? String, "settings draft retained")
        // This journey deliberately never taps Upload.
    }

    @MainActor func testBluetoothModeAllowsManualCloudSelfTestWithoutRunningIt() {
        let app = launchSettings(); defer { app.terminate() }
        open("help", in: app); open("diagnostics", in: app); open("cloudCheck", in: app)
        let run = app.buttons["运行云端模式自检"]
        XCTAssertTrue(run.waitForExistence(timeout: 3))
        XCTAssertTrue(run.isEnabled)
        // No live Relay request, call, SMS or feedback upload in this test.
    }

    @MainActor func testLargeTypeCategoryNavigationAndScreenshots() {
        let app = launchSettings(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { app.terminate() }
        for (id, title) in [("connections", "连接与设备"), ("calls", "来电与短信"),
                            ("widgets", "灵动岛与小组件"), ("preferences", "外观与偏好"),
                            ("help", "帮助与诊断"), ("about", "关于 AirSIM")] {
            open(id, in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "settings-large-\(id)"; shot.lifetime = .keepAlways; add(shot)
            back(app)
        }
    }

    @MainActor func testLandscapeSettingsCategories() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        testLargeTypeCategoryNavigationAndScreenshots()
    }
}
