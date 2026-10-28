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

final class StripTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func window(_ id: Int, _ frame: CGRect?) -> (window: Strip.Window, frame: CGRect?) {
        (Strip.Window(id: id, bundleID: "app\(id)"), frame)
    }

    func ids(_ columns: [Strip.Column]) -> [[Int]] {
        columns.map { $0.windows.map(\.id) }
    }

    func testStackedWindowsShareAColumn() {
        let columns = Strip.columns(of: [
            window(1, CGRect(x: 0, y: 33, width: 756, height: 864)),
            window(2, CGRect(x: 756, y: 33, width: 756, height: 432)),
            window(3, CGRect(x: 756, y: 465, width: 756, height: 432)),
        ], display: display)
        XCTAssertEqual(ids(columns), [[1], [2, 3]])
    }

    func testWindowsPiledOffScreenStaySeparateUnlessStacked() {
        // Off screen, Paneru leaves every column's sliver at the same edge.
        let columns = Strip.columns(of: [
            window(1, CGRect(x: 1507, y: 33, width: 756, height: 864)),
            window(2, CGRect(x: 1507, y: 33, width: 756, height: 864)),
            window(3, CGRect(x: 1507, y: 33, width: 756, height: 432)),
            window(4, CGRect(x: 1507, y: 465, width: 756, height: 432)),
            window(5, CGRect(x: 1507, y: 33, width: 756, height: 864)),
        ], display: display)
        XCTAssertEqual(ids(columns), [[1], [2], [3, 4], [5]])
    }

    func testInViewMeansMostlyShowingOrFillingAThirdOfTheScreen() {
        let columns = Strip.columns(of: [
            window(1, CGRect(x: -751, y: 33, width: 756, height: 864)),
            window(2, CGRect(x: -40, y: 33, width: 750, height: 864)),
            window(3, CGRect(x: 1306, y: 33, width: 756, height: 864)),
            window(4, nil),
        ], display: display)
        XCTAssertEqual(columns.map(\.isInView), [false, true, false, false])
        XCTAssertEqual(ids(columns), [[1], [2], [3], [4]], "a window without a frame gets a column of its own")

        let wide = Strip.columns(of: [window(5, CGRect(x: -864, y: 33, width: 1512, height: 864))], display: display)
        XCTAssertEqual(wide.map(\.isInView), [true], "less than half of it, but 648 points of screen")
    }

    func testMovingAColumnKeepsTheOthersInOrder() {
        func column(_ ids: Int...) -> Strip.Column {
            Strip.Column(windows: ids.map { Strip.Window(id: $0, bundleID: "") }, isInView: false)
        }
        let strip = Strip(columns: [column(1), column(2, 3), column(4), column(5)])
        XCTAssertEqual(strip.column(of: 3), 1)
        XCTAssertNil(strip.column(of: 9))

        let moved = strip.moving(columnOf: 1, to: 2)
        XCTAssertEqual(ids(moved.columns), [[2, 3], [4], [1], [5]])
        XCTAssertEqual(moved.moving(columnOf: 1, to: 2), moved, "already there")
        XCTAssertEqual(ids(strip.moving(columnOf: 3, to: 0).columns), [[2, 3], [1], [4], [5]], "a stack moves whole")
        XCTAssertEqual(ids(strip.moving(columnOf: 4, to: 9).columns), [[1], [2, 3], [5], [4]], "past the end is the end")
        XCTAssertEqual(strip.moving(columnOf: 9, to: 0), strip)
    }
}

final class PaneruStateTests: XCTestCase {
    func testReadsEachDesktopsStrip() throws {
        func window(_ id: Int, _ bundle: String, floating: Bool = false, _ frame: String) -> String {
            #"{"window_id":\#(id),"bundle_id":"\#(bundle)","app_name":"","title":"","focused":false,"floating":\#(floating),"display_id":1,"frame":\#(frame),"visible":true}"#
        }
        let json = """
        {"version":1,"timestamp":1,"active":{"display_id":1,"native_workspace_id":3,"virtual_workspace_number":1},
         "virtual_workspaces":[
          {"number":1,"native_workspace_id":3,"active":true,"windows":[
            \(window(10, "com.mitchellh.ghostty", #"{"x":0,"y":33,"width":756,"height":864}"#)),
            \(window(11, "company.thebrowser.dia", #"{"x":756,"y":33,"width":756,"height":432}"#)),
            \(window(12, "com.spotify.client", #"{"x":756,"y":465,"width":756,"height":432}"#)),
            \(window(13, "dev.zed.Zed", #"{"x":1507,"y":33,"width":756,"height":864}"#)),
            \(window(14, "com.apple.systempreferences", floating: true, #"{"x":200,"y":100,"width":700,"height":500}"#))
          ]},
          {"number":2,"native_workspace_id":3,"active":false,"windows":[]},
          {"number":1,"native_workspace_id":1,"active":false,"windows":[
            \(window(20, "com.apple.mail", "null"))
          ]}
         ]}
        """
        let strips = try PaneruState.strips(from: Data(json.utf8), display: CGRect(x: 0, y: 0, width: 1512, height: 982))

        let here = try XCTUnwrap(strips[3])
        XCTAssertEqual(here.columns.map { $0.windows.map(\.id) }, [[10], [11, 12], [13]], "floating windows aren't in the strip")
        XCTAssertEqual(here.columns.map(\.isInView), [true, true, false])
        XCTAssertEqual(here.columns[1].windows[1].bundleID, "com.spotify.client")
        XCTAssertEqual(strips[1]?.columns.map { $0.windows.map(\.id) }, [[20]])
    }

    func testReadsEvents() {
        func event(_ json: String) -> PaneruEvent { PaneruState.event(from: Data(json.utf8)) }
        XCTAssertEqual(event(#"{"event":"window_title_changed","window_id":3,"title":"x"}"#), .titleChanged)
        XCTAssertEqual(event(#"{"event":"windows_changed","virtual_workspace_number":1}"#), .other)
        XCTAssertEqual(event(#"{"event":"window_tit"#), .other, "half a line might be anything")
        let slid = event("""
            {"active":{"display_id":1,"native_workspace_id":3,"virtual_workspace_number":1},"event":"on_screen_changed",
             "windows":[{"app_name":"Ghostty","bundle_id":"com.mitchellh.ghostty","display_id":1,"floating":false,"focused":true,
                         "frame":{"height":864,"width":756,"x":-40,"y":33},"title":"","visible":true,"window_id":10}]}
            """)
        XCTAssertEqual(slid, .onScreen(desktop: 3, frames: [10: CGRect(x: -40, y: 33, width: 756, height: 864)]))
    }

    func testSlidingUpdatesWhatsInView() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func column(_ ids: Int...) -> Strip.Column {
            Strip.Column(windows: ids.map { Strip.Window(id: $0, bundleID: "") }, isInView: false)
        }
        var strip = Strip(columns: [column(1), column(2, 3), column(4)])
        strip.updateInView(onScreen: [
            2: CGRect(x: 0, y: 33, width: 756, height: 432),
            3: CGRect(x: 0, y: 465, width: 756, height: 432),
            4: CGRect(x: 756, y: 33, width: 756, height: 864),
        ], display: display)
        XCTAssertEqual(strip.columns.map(\.isInView), [false, true, true], "windows missing from the list aren't on screen")
    }
}

final class ReorderTests: XCTestCase {
    func testMovesWithinADesktopsOwnItemsAndWithinSharedOnes() {
        let a = DockItem.app("/Applications/A.app"), b = DockItem.app("/Applications/B.app")
        let c = DockItem.app("/Applications/C.app"), finder = DockItem.app("/System/Finder.app")
        let mail = DockItem.app("/Applications/Mail.app")
        var space = Space(name: "Work", items: [a, b, c])
        var library = SpaceLibrary(spaces: [space], sharedItems: [finder, mail])

        library.move(c, to: a, in: space.id)
        XCTAssertEqual(library.spaces[0].items, [c, a, b], "dragged left, it takes the target's place")
        library.move(c, to: b, in: space.id)
        XCTAssertEqual(library.spaces[0].items, [a, b, c], "dragged right too")

        library.move(mail, to: finder, in: space.id)
        XCTAssertEqual(library.sharedItems, [mail, finder])

        library.move(a, to: finder, in: space.id)
        XCTAssertEqual(library.sharedItems, [mail, finder], "a desktop's item can't go among the shared ones")
        XCTAssertEqual(library.spaces[0].items, [a, b, c])
        space = library.spaces[0]
        _ = space
    }
}

final class RowDragTests: XCTestCase {
    /// A tile, a two-tile stack, then two more tiles, 6 points apart.
    let frames = [
        CGRect(x: 0, y: 0, width: 48, height: 48),
        CGRect(x: 54, y: 0, width: 96, height: 48),
        CGRect(x: 156, y: 0, width: 48, height: 48),
        CGRect(x: 210, y: 0, width: 48, height: 48),
    ]

    func drag(_ index: Int, by offset: CGFloat) -> RowDrag {
        RowDrag(frames: frames, dragged: index, offset: offset, spacing: 6)
    }

    func testLandsOncePastTheMiddleOfTheNextItem() {
        XCTAssertEqual(drag(0, by: 0).destination, 0)
        XCTAssertEqual(drag(0, by: 70).destination, 0, "the stack's middle is at 102")
        XCTAssertEqual(drag(0, by: 80).destination, 1)
        XCTAssertEqual(drag(0, by: 500).destination, 3)
        XCTAssertEqual(drag(3, by: -60).destination, 2)
        XCTAssertEqual(drag(3, by: -500).destination, 0)
    }

    func testPassedItemsMakeRoomTheWayItCame() {
        let right = drag(0, by: 160)
        XCTAssertEqual(right.destination, 2)
        XCTAssertEqual((0..<4).map(right.shift(of:)), [160, -54, -54, 0])

        let left = drag(2, by: -160)
        XCTAssertEqual(left.destination, 0)
        XCTAssertEqual((0..<4).map(left.shift(of:)), [54, 54, -160, 0])
    }
}
