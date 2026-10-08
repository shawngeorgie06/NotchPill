import AppKit
import Testing
@testable import NotchPill

@MainActor @Suite("Shelf destination menu lifetime")
struct ShelfDestinationMenuTests {
    @Test("a context-menu handoff holds the notch before launch and until cancellation")
    func deferredCancellation() throws {
        var pending: (@MainActor () -> Void)?
        var delay: TimeInterval?
        var holds: [Bool] = []
        var presentations = 0
        let presenter = ShelfDestinationMenu(schedule: { wait, work in
            delay = wait
            pending = work
        }, showMenu: { _, _ in
            #expect(holds == [true])
            presentations += 1
            return false
        })
        presenter.present(destinations: [], fromContextMenu: true,
                          holdNotchOpen: { holds.append($0) },
                          onPick: { _ in Issue.record("Cancellation selected a folder") })
        #expect(delay == 0.12)
        #expect(holds == [true])
        #expect(presentations == 0)
        let work = try #require(pending)
        work()
        #expect(presentations == 1)
        #expect(holds == [true, false])
    }

    @Test("selection runs while held and repeated clicks cannot release an active menu")
    func selectionAndReentry() throws {
        var pending: (@MainActor () -> Void)?
        var holds: [Bool] = []
        var picked: [URL] = []
        let folder = URL(fileURLWithPath: "/tmp/notchpill-menu-fixture")
        let presenter = ShelfDestinationMenu(schedule: { delay, work in
            #expect(delay == 0)
            pending = work
        }, showMenu: { menu, _ in
            #expect(holds.last == true)
            let index = menu.items.firstIndex { ($0.representedObject as? URL) == folder }!
            menu.performActionForItem(at: index)
            #expect(picked == [folder])
            #expect(holds.last == true)
            return true
        })
        presenter.present(destinations: [.init(url: folder, source: .pinned)],
                          holdNotchOpen: { holds.append($0) }, onPick: { picked.append($0) })
        presenter.present(destinations: [], holdNotchOpen: { _ in
            Issue.record("A second presentation changed the active hold")
        }, onPick: { _ in Issue.record("A second callback replaced the first") })
        let work = try #require(pending)
        work()
        #expect(holds == [true, false])
        #expect(picked == [folder])
        // Once closed, the same presenter can open again with a fresh callback.
        presenter.present(destinations: [], holdNotchOpen: { holds.append($0) }, onPick: { _ in })
        #expect(holds == [true, false, true])
    }
}

@Suite("Overlapping menu holds")
struct NotchInteractionHoldTests {
    @Test("ending the context menu cannot release a deferred destination picker")
    func handoff() {
        var hold = NotchInteractionHold()
        let context = NSObject(), destination = NSObject()
        hold.begin(context)
        hold.begin(context) // duplicate tracking notifications are harmless
        #expect(hold.isHeld)
        hold.manual = true
        hold.end(context)
        #expect(hold.isHeld)
        hold.begin(destination)
        hold.manual = false
        #expect(hold.isHeld)
        hold.end(destination)
        #expect(!hold.isHeld)
    }

    @Test("nested menus release independently, including cancellation")
    func nestedMenus() {
        var hold = NotchInteractionHold()
        let first = NSObject(), second = NSObject(), unknown = NSObject()
        hold.begin(first)
        hold.begin(second)
        hold.end(first)
        hold.end(unknown)
        #expect(hold.isHeld)
        hold.end(second)
        #expect(!hold.isHeld)
    }
}
