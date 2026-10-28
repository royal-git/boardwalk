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
