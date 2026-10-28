import XCTest
@testable import BetterDockCore

final class DockPlistTests: XCTestCase {
    func url(_ string: String) -> DockPlist.Tile {
        ["_CFURLString": string, "_CFURLStringType": 15]
    }

    func testReadsAppsFoldersAndLinks() {
        let apps: [DockPlist.Tile] = [
            ["tile-type": "file-tile", "tile-data": ["file-label": "Safari", "file-data": url("file:///Applications/Safari.app/")] as DockPlist.Tile],
        ]
        let others: [DockPlist.Tile] = [
            ["tile-type": "directory-tile", "tile-data": ["file-data": url("file:///Users/me/Downloads/")] as DockPlist.Tile],
            ["tile-type": "file-tile", "tile-data": ["file-data": url("file:///Users/me/notes.txt")] as DockPlist.Tile],
            ["tile-type": "url-tile", "tile-data": ["label": "Repo", "url": url("https://github.com")] as DockPlist.Tile],
        ]
        let items = DockPlist.items(apps: apps, others: others)
        XCTAssertEqual(items.map(\.kind), [.app, .folder, .file, .url])
        XCTAssertEqual(items.map(\.location), [
            "/Applications/Safari.app", "/Users/me/Downloads", "/Users/me/notes.txt", "https://github.com",
        ])
        XCTAssertEqual(items[3].label, "Repo")
    }

    func testUnknownTilesAreSkipped() {
        let spacer: DockPlist.Tile = ["tile-type": "spacer-tile", "tile-data": [:] as DockPlist.Tile]
        XCTAssertNil(DockPlist.item(from: spacer, inAppsSection: true))
    }
}

final class SpaceLibraryTests: XCTestCase {
    func testResolvedItemsAppendSharedWithoutDuplicates() {
        let shared = DockItem.folder("/Users/me/Downloads")
        let space = Space(name: "Work", items: [.app("/Applications/Mail.app"), .folder("/Users/me/Downloads")])
        let library = SpaceLibrary(spaces: [space], sharedItems: [shared])

        let resolved = library.resolvedItems(for: space)
        XCTAssertEqual(resolved.map(\.location), ["/Applications/Mail.app", "/Users/me/Downloads"])
    }

    func testAbsorbKeepsLabelsAndDropsShared() {
        var space = Space(name: "Work", items: [.app("/Applications/Mail.app", label: "Inbox")])
        let shared = [DockItem.folder("/Users/me/Downloads")]
        let dock: [DockItem] = [
            .app("/Applications/Slack.app"),
            .app("/Applications/Mail.app"),
            .folder("/Users/me/Downloads"),
        ]

        space.absorb(dockItems: dock, shared: shared)

        XCTAssertEqual(space.items.map(\.location), ["/Applications/Slack.app", "/Applications/Mail.app"])
        XCTAssertEqual(space.items[1].label, "Inbox")
    }

    func testEnsureSpacesAddsOnePerDesktop() {
        var library = SpaceLibrary(spaces: [Space(name: "Work")])
        library.ensureSpaces(count: 3)
        XCTAssertEqual(library.spaces.map(\.name), ["Work", "Desktop 2", "Desktop 3"])
        library.ensureSpaces(count: 1)
        XCTAssertEqual(library.spaces.count, 3, "spaces for removed desktops are kept")
    }

    func testPinsIncludesShared() {
        let work = Space(name: "Work", items: [.app("/Applications/Slack.app")])
        let library = SpaceLibrary(spaces: [work], sharedItems: [.app("/System/Library/CoreServices/Finder.app")])
        XCTAssertTrue(library.pins(appPath: "/Applications/Slack.app", in: work))
        XCTAssertTrue(library.pins(appPath: "/System/Library/CoreServices/Finder.app", in: work))
        XCTAssertFalse(library.pins(appPath: "/Applications/Music.app", in: work))
    }

    func testStorageRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LibraryStorage(fileURL: dir.appendingPathComponent("spaces.json"))

        XCTAssertNil(try storage.load())
        let library = SpaceLibrary.starter
        try storage.save(library)
        XCTAssertEqual(try storage.load(), library)
    }
}

final class PinningTests: XCTestCase {
    func testUnpinSharedItemKeepsItOnOtherDesktops() {
        let work = Space(name: "Work")
        let play = Space(name: "Play")
        var library = SpaceLibrary(spaces: [work, play], sharedItems: [.folder("/Users/me/Downloads")])

        library.unpin(.folder("/Users/me/Downloads"), from: work.id)

        XCTAssertTrue(library.sharedItems.isEmpty)
        XCTAssertTrue(library.spaces[0].items.isEmpty)
        XCTAssertEqual(library.spaces[1].items.map(\.location), ["/Users/me/Downloads"])
    }

    func testShareThenUnshareKeepsOneDesktop() {
        let work = Space(name: "Work", items: [.app("/Applications/Slack.app")])
        let play = Space(name: "Play")
        var library = SpaceLibrary(spaces: [work, play])

        library.share(.app("/Applications/Slack.app"))
        XCTAssertEqual(library.sharedItems.count, 1)
        XCTAssertTrue(library.spaces[0].items.isEmpty, "not listed twice")

        library.unshare(.app("/Applications/Slack.app"), keepingIn: play.id)
        XCTAssertTrue(library.sharedItems.isEmpty)
        XCTAssertTrue(library.spaces[0].items.isEmpty)
        XCTAssertEqual(library.spaces[1].items.map(\.location), ["/Applications/Slack.app"])
    }

    func testPinKeepsItemElsewhere() {
        let work = Space(name: "Work", items: [.app("/Applications/Slack.app")])
        let play = Space(name: "Play")
        var library = SpaceLibrary(spaces: [work, play])

        library.pin(.app("/Applications/Slack.app"), in: play.id)
        library.pin(.app("/Applications/Slack.app"), in: play.id)

        XCTAssertEqual(library.spaces[0].items.count, 1)
        XCTAssertEqual(library.spaces[1].items.count, 1)
    }
}

final class DesktopAppsTests: XCTestCase {
    func state(here: Bool = false, any: Bool = false) -> DesktopApps.WindowState {
        DesktopApps.WindowState(hasWindowHere: here, hasAnyWindow: any)
    }

    func testAppWithWindowOnThisDesktopShows() {
        XCTAssertTrue(DesktopApps.showsHere(state(here: true, any: true)))
    }

    func testAppWithWindowsOnlyElsewhereIsLeftOut() {
        XCTAssertFalse(DesktopApps.showsHere(state(any: true)))
    }

    func testAppWithClosedWindowShowsOnlyOnItsDesktop() {
        XCTAssertTrue(DesktopApps.showsHere(DesktopApps.WindowState(hasWindowHere: false, hasClosedWindowHere: true, hasAnyWindow: true)))
        XCTAssertFalse(DesktopApps.showsHere(state(any: true)))
    }

    func testClosedWindowIsIgnoredWhileAnotherIsOpen() {
        // Mail: a kept window on this desktop, its open one on another.
        let mail = DesktopApps.WindowState(
            hasWindowHere: false, hasClosedWindowHere: true, hasOpenWindowAnywhere: true, hasAnyWindow: true
        )
        XCTAssertFalse(DesktopApps.showsHere(mail))
    }

    func testWindowlessAppsShowEverywhere() {
        XCTAssertTrue(DesktopApps.showsHere(state()))
    }
}

final class WindowLayoutTests: XCTestCase {
    // A 1512-wide screen below a 33pt menu bar, above the dock.
    let area = CGRect(x: 0, y: 33, width: 1512, height: 857)

    func testHalvesAndMaximize() {
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: area), CGRect(x: 0, y: 33, width: 756, height: 857))
        XCTAssertEqual(WindowLayout.rightHalf.frame(in: area), CGRect(x: 756, y: 33, width: 756, height: 857))
        XCTAssertEqual(WindowLayout.maximize.frame(in: area), area)
    }

    func testThirdsMeetWithoutGaps() {
        let thirds = [WindowLayout.leftThird, .centerThird, .rightThird].map { $0.frame(in: area) }
        XCTAssertEqual(thirds[0].maxX, thirds[1].minX)
        XCTAssertEqual(thirds[1].maxX, thirds[2].minX)
        XCTAssertEqual(thirds[2].maxX, area.maxX)
        XCTAssertEqual(WindowLayout.leftTwoThirds.frame(in: area).maxX, thirds[1].maxX)
    }

    func testQuarters() {
        XCTAssertEqual(WindowLayout.bottomRight.frame(in: area), CGRect(x: 756, y: 462, width: 756, height: 428))
        XCTAssertEqual(WindowLayout.topLeft.frame(in: area).maxY, WindowLayout.bottomLeft.frame(in: area).minY)
    }

    func testCenterKeepsSizeButFits() {
        XCTAssertEqual(WindowLayout.centered(CGSize(width: 800, height: 600), in: area),
                       CGRect(x: 356, y: 162, width: 800, height: 600))
        XCTAssertEqual(WindowLayout.centered(CGSize(width: 3000, height: 3000), in: area), area)
    }

    func testTileGivesTheFrontWindowTheMostRoom() {
        XCTAssertEqual(WindowLayout.tile(1, in: area), [area])
        let three = WindowLayout.tile(3, in: area)
        XCTAssertEqual(three[0], WindowLayout.leftHalf.frame(in: area))
        XCTAssertEqual(three[1], WindowLayout.topRight.frame(in: area))
        XCTAssertEqual(three[2], WindowLayout.bottomRight.frame(in: area))
        XCTAssertEqual(WindowLayout.tile(5, in: area).count, 5)
        XCTAssertTrue(WindowLayout.tile(0, in: area).isEmpty)
    }

    func testTileCoversTheWholeArea() {
        for count in 1...9 {
            let frames = WindowLayout.tile(count, in: area)
            let covered = frames.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(covered, area.width * area.height, "\(count) windows")
            XCTAssertTrue(frames.allSatisfy { area.contains($0) })
        }
    }
}

final class ArrowComboTests: XCTestCase {
    func presses(_ arrows: ArrowCombo.Arrow...) -> [WindowLayout] {
        var combo = ArrowCombo()
        return arrows.map { combo.press($0) }
    }

    func testEachPressRefinesTheLast() {
        XCTAssertEqual(presses(.left, .left, .right), [.leftHalf, .leftThird, .leftTwoThirds])
        XCTAssertEqual(presses(.right, .right, .left), [.rightHalf, .rightThird, .rightTwoThirds])
    }

    func testOppositeArrowsMeanTheCenterThird() {
        XCTAssertEqual(presses(.left, .right).last, .centerThird)
        XCTAssertEqual(presses(.right, .left).last, .centerThird)
    }

    func testUpAndDownPickHalvesOfTheColumnsInEitherOrder() {
        XCTAssertEqual(presses(.left, .up).last, .topLeft)
        XCTAssertEqual(presses(.up, .left).last, .topLeft)
        XCTAssertEqual(presses(.right, .down).last, .bottomRight)
        XCTAssertEqual(presses(.up), [.topHalf])
        XCTAssertEqual(presses(.left, .right, .up).last, WindowLayout(columns: .middleThird, rows: .firstHalf))
        XCTAssertEqual(presses(.up, .down).last, .bottomHalf)
    }

    func testMeaninglessSequencesStartOverFromTheLastArrow() {
        XCTAssertEqual(presses(.left, .left, .right, .right).last, .rightHalf)
        XCTAssertEqual(presses(.left, .right, .right).last, .rightHalf)
    }

    func testResetStartsFresh() {
        var combo = ArrowCombo()
        _ = combo.press(.left)
        combo.reset()
        XCTAssertEqual(combo.press(.right), .rightHalf)
    }
}
