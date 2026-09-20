import Foundation
import MTPKit

// The click rules, checked without a phone and without a window.
//
// This Mac has the command line tools only, so neither XCTest nor swift-testing is installable and
// `swift test` cannot run at all. Rather than leave the one piece of logic that needs no hardware
// unchecked, the checks live in the app and run from a flag:
//
//     swift run PorterageApp --check
//
// It exits non-zero on the first failing rule, so it works in a script the same way a test suite
// would. `mtpcheck selftest` already uses this shape for the parts that do need a phone.
//
// What is being copied is the Finder's behaviour, not an invention of this app: a plain click
// replaces the selection and anchors there, ⌘ toggles one row and re-anchors, ⇧ takes the run
// between the anchor and the row, and ⌘⇧ adds that run to what is already selected.

enum SelectionChecks {
    private static var failures = 0

    private static func expect(
        _ got: Set<MTPEntry.ID>, _ want: Set<MTPEntry.ID>, _ label: String
    ) {
        let passed = got == want
        if !passed { failures += 1 }
        print("  \(passed ? "✅" : "❌") \(label)")
        if !passed {
            print("       wanted \(want.sorted()), got \(got.sorted())")
        }
    }

    private static func expect(_ got: MTPEntry.ID?, _ want: MTPEntry.ID?, _ label: String) {
        let passed = got == want
        if !passed { failures += 1 }
        print("  \(passed ? "✅" : "❌") \(label)")
        if !passed {
            print("       wanted \(want.map(String.init) ?? "none"), got \(got.map(String.init) ?? "none")")
        }
    }

    /// Ten rows standing in for a listed folder in its current sort order.
    private static let order: [MTPEntry.ID] = Array(1 ... 10)

    private static func click(
        _ id: MTPEntry.ID,
        from current: Set<MTPEntry.ID> = [],
        anchor: MTPEntry.ID? = nil,
        in rows: [MTPEntry.ID]? = nil,
        shift: Bool = false,
        command: Bool = false
    ) -> (selection: Set<MTPEntry.ID>, anchor: MTPEntry.ID?) {
        PhoneBrowser.selection(
            from: current, anchor: anchor, clicking: id, in: rows ?? order,
            extending: shift, togglingOne: command
        )
    }

    static func run() -> Never {
        print("Selection rules\n")

        print(" Plain click")
        var r = click(4, from: [1, 2, 3], anchor: 1)
        expect(r.selection, [4], "replaces the selection")
        expect(r.anchor, 4, "and anchors there")

        print("\n ⌘-click")
        r = click(7, from: [2, 3], anchor: 3, command: true)
        expect(r.selection, [2, 3, 7], "adds a row without disturbing the rest")
        expect(r.anchor, 7, "re-anchors on the row just clicked")
        r = click(3, from: [2, 3, 7], anchor: 7, command: true)
        expect(r.selection, [2, 7], "clicking a selected row removes it")

        print("\n ⇧-click — the point of the exercise")
        r = click(6, from: [3], anchor: 3, shift: true)
        expect(r.selection, [3, 4, 5, 6], "takes the whole run from the anchor downwards")
        expect(r.anchor, 3, "the anchor stays put")
        r = click(3, from: [6], anchor: 6, shift: true)
        expect(r.selection, [3, 4, 5, 6], "and upwards, the same run")
        let first = click(6, from: [3], anchor: 3, shift: true)
        r = click(4, from: first.selection, anchor: first.anchor, shift: true)
        expect(r.selection, [3, 4], "a second ⇧-click re-measures instead of creeping")
        r = click(5, from: [5, 6, 7], anchor: 5, shift: true)
        expect(r.selection, [5], "⇧-clicking the anchor selects just that row")
        r = click(4, from: [1, 9], anchor: 3, shift: true)
        expect(r.selection, [3, 4], "replaces whatever was selected outside the run")

        print("\n ⌘⇧-click")
        r = click(5, from: [9, 10], anchor: 3, shift: true, command: true)
        expect(r.selection, [3, 4, 5, 9, 10], "adds the run to what is already selected")
        expect(r.anchor, 3, "without moving the anchor")

        print("\n Cases that must not select a guess")
        r = click(6, from: [1, 2], anchor: nil, shift: true)
        expect(r.selection, [6], "⇧ with nothing anchored is a plain click, never a range from row 0")
        expect(r.anchor, 6, "and anchors where it was clicked")
        // 99 is not in `order`: the folder was reloaded, or a filter hid the anchored row.
        r = click(6, from: [1, 2], anchor: 99, shift: true)
        expect(r.selection, [6], "⇧ with an anchor that is gone is a plain click")
        r = click(6, from: [1, 2], anchor: 99, shift: true, command: true)
        expect(r.selection, [1, 2, 6], "⌘⇧ with an anchor that is gone toggles one row")
        r = click(42, from: [1], anchor: 1, shift: true)
        expect(r.selection, [42], "clicking a row that is not listed cannot make a range")
        r = click(1, anchor: 1, in: [1], shift: true)
        expect(r.selection, [1], "a one-row folder is not a special case")

        print("\n Sort order")
        // Sorted by size rather than name: the run is whatever lies between them *on screen*.
        r = click(1, anchor: 3, in: [7, 3, 9, 1, 4], shift: true)
        expect(r.selection, [3, 9, 1], "the run follows the order the rows are actually in")

        print(failures == 0 ? "\nALL PASSED." : "\n\(failures) CHECK(S) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
