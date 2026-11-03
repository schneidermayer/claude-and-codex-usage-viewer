import XCTest

@MainActor
final class CodexUsageViewerUITests: XCTestCase {
    private func visibleText(_ element: XCUIElement) -> String {
        // macOS AXStaticText stores its text in value.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
    private func launch(connected: Bool = false, loginCode: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (connected ? ["--ui-testing-connected"] : [])
            + (loginCode ? ["--ui-testing-login-code"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["codexusageviewer.title"].waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    func testClaudeManualCodeUsesSecureFieldAndSubmits() {
        for submitWithReturn in [false, true] {
            let app = launch(loginCode: true)
            defer { app.terminate() }
            let field = app.secureTextFields["codexusageviewer.connection.authenticationCode"]
            let submit = app.buttons["codexusageviewer.connection.submitCode"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["If Claude shows an authentication code, paste it here."].exists)
            XCTAssertFalse(submit.isEnabled)
            field.click()
            field.typeText("synthetic-code#fixture")
            XCTAssertTrue(submit.isEnabled)
            XCTAssertNotEqual(field.value as? String, "synthetic-code#fixture", "The code must remain masked in accessibility output.")
            if submitWithReturn {
                field.typeKey(.return, modifierFlags: [])
            } else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Claude manual authentication code fixture"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                submit.click()
            }
            XCTAssertTrue(field.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["codexusageviewer.connect.account-1"].isEnabled)
        }
    }

    func testOneEmptyAccountAndHonestPreview() {
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["codexusageviewer.connect.account-1"].exists)
        XCTAssertFalse(app.buttons["codexusageviewer.connect.account-2"].exists)
        XCTAssertTrue(app.staticTexts["0 of 1 connected"].exists)

        app.buttons["codexusageviewer.preview"].click()
        let previewBanner = app.descendants(matching: .any).matching(identifier: "codexusageviewer.preview.banner").firstMatch
        XCTAssertTrue(previewBanner.waitForExistence(timeout: 3))
        for name in ["Alex Morgan", "Sam Rivera", "Jordan Lee"] {
            XCTAssertTrue(app.staticTexts[name].exists)
        }
        XCTAssertTrue(previewBanner.label.contains("sample accounts and usage figures"))
        assertBothLimits(app)
        XCTAssertFalse(app.buttons["codexusageviewer.refresh"].isEnabled)

        app.buttons["codexusageviewer.preview"].click()
        XCTAssertTrue(app.staticTexts["0 of 1 connected"].waitForExistence(timeout: 3))
        XCTAssertFalse(previewBanner.exists)
        XCTAssertTrue(app.buttons["codexusageviewer.connect.account-1"].exists)
        XCTAssertFalse(app.buttons["codexusageviewer.connect.account-2"].exists)
    }

    func testAddMixedAccountsAndRemoveDownToOne() {
        let app = launch()
        defer { app.terminate() }
        let add = app.descendants(matching: .any).matching(identifier: "codexusageviewer.addAccount").firstMatch
        add.click()
        app.menuItems["Add Claude account"].click()
        XCTAssertTrue(app.buttons["codexusageviewer.connect.account-2"].waitForExistence(timeout: 3))
        XCTAssertEqual(visibleText(app.staticTexts["codexusageviewer.provider.account-2"]), "Claude")
        add.click()
        app.menuItems["Add Codex account"].click()
        XCTAssertTrue(app.buttons["codexusageviewer.connect.account-3"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 of 3 connected"].exists)
        XCTAssertFalse(add.isEnabled)
        for index in [3, 2] {
            app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-\(index)").firstMatch.click()
            app.menuItems["Remove account…"].click()
            let remove = app.sheets.buttons["Remove account"].firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 3))
            remove.click()
            XCTAssertFalse(app.buttons["codexusageviewer.connect.account-\(index)"].waitForExistence(timeout: 1))
        }
        XCTAssertTrue(app.staticTexts["0 of 1 connected"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-1").firstMatch.exists)
        XCTAssertTrue(add.isEnabled)
    }

    func testChooseProviderBeforeConnecting() {
        let app = launch()
        defer { app.terminate() }
        let picker = app.descendants(matching: .any).matching(identifier: "codexusageviewer.providerPicker.account-1").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.radioButtons["Claude"].click()
        XCTAssertTrue(app.staticTexts["Connect a Claude account"].waitForExistence(timeout: 3))
        XCTAssertEqual(visibleText(app.staticTexts["codexusageviewer.provider.account-1"]), "Claude")
        picker.radioButtons["Codex"].click()
        XCTAssertTrue(app.staticTexts["Connect a Codex account"].waitForExistence(timeout: 3))
    }

    func testSettingsWithPointerAndEscape() {
        let app = launch()
        defer { app.terminate() }

        app.buttons["codexusageviewer.settings"].click()
        let field = app.textFields["codexusageviewer.settings.executable"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["codexusageviewer.settings.claudeExecutable"].exists)
        XCTAssertTrue(app.staticTexts["Background updates"].exists)
        XCTAssertTrue(app.staticTexts["codexusageviewer.settings.backgroundStatus"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "codexusageviewer.settings.loginItems").firstMatch.isHittable)
        let originalValue = field.value as? String ?? ""
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("/tmp/codexusageviewer-ui-test-unused-codex")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["codexusageviewer.settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(field.exists)

        app.buttons["codexusageviewer.settings"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String ?? "", originalValue, "Escape should discard the staged path edit.")
        app.buttons["codexusageviewer.settings.done"].click()
        XCTAssertFalse(field.waitForExistence(timeout: 1))
    }

    func testFullAccountIdentityPlanAndLoggedInBadge() {
        let app = launch(connected: true)
        defer { app.terminate() }

        for (index, name) in ["Alex Morgan", "Sam Rivera", "Jordan Lee"].enumerated() {
            let title = app.staticTexts["codexusageviewer.name.account-\(index + 1)"]
            XCTAssertEqual(visibleText(title), name)
        }
        let plan = app.descendants(matching: .any).matching(identifier: "codexusageviewer.plan.account-1").firstMatch
        let badge = app.descendants(matching: .any).matching(identifier: "codexusageviewer.loggedIn.account-1").firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 3))
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        XCTAssertEqual(visibleText(plan), "Subscription plan: 200")
        let fallbackPlan = app.descendants(matching: .any).matching(identifier: "codexusageviewer.plan.account-2").firstMatch
        XCTAssertEqual(visibleText(fallbackPlan), "Subscription plan: Pro")
        XCTAssertEqual(visibleText(app.staticTexts["codexusageviewer.provider.account-2"]), "Claude")
        XCTAssertEqual(badge.label, "Logged In")
        let claudeBadge = app.descendants(matching: .any).matching(identifier: "codexusageviewer.loggedIn.account-2").firstMatch
        XCTAssertTrue(claudeBadge.waitForExistence(timeout: 3))
        XCTAssertEqual(claudeBadge.label, "Logged In")
        XCTAssertTrue(claudeBadge.isHittable)
        XCTAssertTrue(plan.isHittable)
        XCTAssertTrue(badge.isHittable)
        assertBothLimits(app)

        // Only Codex exposes credits and earned resets. Claude keeps its reported plan.
        for (index, expected) in [("125.5", "2"), ("0", "0"), ("Unlimited", "1")].enumerated() {
            let credits = app.descendants(matching: .any).matching(identifier: "codexusageviewer.credits.account-\(index + 1)").firstMatch
            let resets = app.descendants(matching: .any).matching(identifier: "codexusageviewer.availableResets.account-\(index + 1)").firstMatch
            if index == 1 {
                XCTAssertFalse(credits.exists)
                XCTAssertFalse(resets.exists)
                continue
            }
            XCTAssertTrue(credits.isHittable)
            XCTAssertTrue(resets.isHittable)
            XCTAssertEqual(credits.label, "Available credits: \(expected.0)")
            XCTAssertEqual(resets.label, "Available usage resets: \(expected.1)")
            let expiry = app.descendants(matching: .any).matching(identifier: "codexusageviewer.resetExpiry.account-\(index + 1)").firstMatch
            if expected.1 == "0" {
                XCTAssertFalse(expiry.exists, "No expiry should be shown when no resets are available.")
            } else {
                XCTAssertTrue(expiry.isHittable)
                XCTAssertTrue(expiry.label.hasPrefix("Next usage reset expires: "))
                let expiryValue = String(expiry.label.dropFirst("Next usage reset expires: ".count))
                XCTAssertFalse(expiryValue.isEmpty)
                XCTAssertNotEqual(expiryValue, "Unknown")
            }
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Both usage limits with credits, available resets, and expiry dates"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let options = app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-1").firstMatch
        options.click()
        XCTAssertTrue(app.menuItems["All usage limits"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Rename account"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertBothLimits(_ app: XCUIApplication) {
        for (index, percentages) in [(72, 58), (36, 21), (88, 77)].enumerated() {
            for (duration, label, percent) in [(300, "5-hour", percentages.0), (10_080, "Weekly", percentages.1)] {
                let usage = app.descendants(matching: .any)
                    .matching(identifier: "codexusageviewer.usage.\(duration).account-\(index + 1)").firstMatch
                XCTAssertTrue(usage.isHittable, "Both limits should be visible without opening a sheet")
                XCTAssertEqual(usage.label, "\(label), \(percent) percent remaining")
                let reset = app.descendants(matching: .any)
                    .matching(identifier: "codexusageviewer.reset.\(duration).account-\(index + 1)").firstMatch
                XCTAssertTrue(reset.isHittable)
                XCTAssertEqual(reset.label, "\(label) time until reset")
            }
            XCTAssertTrue(app.staticTexts["codexusageviewer.weeklyResetDate.account-\(index + 1)"].isHittable)
        }
    }

    func testVersionInDashboardAndStandardQuitMenu() {
        let app = launch()
        defer { app.terminate() }
        let version = app.staticTexts["codexusageviewer.version"]
        let versionText = visibleText(version)
        XCTAssertNotNil(versionText.range(of: #"^Version \d+\.\d+(?:\.\d+)?(?:-\d+)?$"#, options: .regularExpression))
        for text in ["CODEX USAGE, IN ONE PLACE", "A little more headspace.", "Three accounts. A clear view of what’s left.", "YOUR ACCOUNTS"] {
            XCTAssertFalse(app.staticTexts[text].exists)
        }
        let appMenu = app.menuBars.menuBarItems["Claude and Codex Usage Viewer"]
        XCTAssertTrue(appMenu.exists)
        appMenu.click()
        let displayedVersion = String(versionText.dropFirst("Version ".count))
        let quit = app.menuItems["Quit Claude and Codex Usage Viewer \(displayedVersion)"]
        XCTAssertTrue(quit.waitForExistence(timeout: 3))
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    func testAllUsageLimitsInPreviewWithPointerAndEscape() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["codexusageviewer.preview"].click()

        let options = app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-1").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        options.click()
        let allLimits = app.menuItems["All usage limits"]
        XCTAssertTrue(allLimits.waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Rename account"].exists)
        XCTAssertFalse(app.menuItems["Reconnect"].isEnabled)
        allLimits.click()

        let title = app.staticTexts["codexusageviewer.limits.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["Sample usage · preview mode"].exists)
        for (window, expected) in [("primary", "72%"), ("secondary", "58%")] {
            let limit = app.descendants(matching: .any).matching(identifier: "codexusageviewer.limit.codex.\(window)").firstMatch
            XCTAssertTrue(limit.label.contains(expected))
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(title.exists)

        options.click()
        allLimits.click()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        app.buttons["codexusageviewer.limits.done"].click()
        XCTAssertFalse(title.exists)
    }

}
