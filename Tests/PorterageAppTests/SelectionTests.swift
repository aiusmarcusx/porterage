import MTPKit
import Testing

@testable import PorterageApp

/// The click rules, checked without a window and without a phone.
///
/// Shift-click is the second-most-requested thing in the competitor's issue tracker and has been
/// open there for five years, so the rules are worth pinning down rather than eyeballing once.
///
/// What is being copied is the Finder's behaviour, not an invention of this app: a plain click
/// replaces the selection and anchors there, ⌘ toggles one row and re-anchors, ⇧ takes the run
/// between the anchor and the row, and ⌘⇧ adds that run to what is already selected.
@Suite("Selecting rows")
struct SelectionTests {
    /// Ten rows standing in for a listed folder in its current sort order.
    let order: [MTPEntry.ID] = Array(1 ... 10)

    private func click(
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

    // MARK: - Plain click

    @Test("A plain click replaces the selection and anchors there")
    func plainClickReplaces() {
        let result = click(4, from: [1, 2, 3], anchor: 1)
        #expect(result.selection == [4])
        #expect(result.anchor == 4)
    }

    // MARK: - ⌘

    @Test("⌘-click adds a row without disturbing the rest")
    func commandAdds() {
        let result = click(7, from: [2, 3], anchor: 3, command: true)
        #expect(result.selection == [2, 3, 7])
        #expect(result.anchor == 7)
    }

    @Test("⌘-click on an already selected row removes it")
    func commandRemoves() {
        let result = click(3, from: [2, 3, 7], anchor: 7, command: true)
        #expect(result.selection == [2, 7])
        #expect(result.anchor == 3)
    }

    // MARK: - ⇧, the point of the exercise

    @Test("⇧-click takes the whole run from the anchor downwards")
    func shiftSelectsRangeDown() {
        let result = click(6, from: [3], anchor: 3, shift: true)
        #expect(result.selection == [3, 4, 5, 6])
        #expect(result.anchor == 3, "the anchor stays put so the next ⇧-click re-measures from it")
    }

    @Test("⇧-click upwards selects the same run")
    func shiftSelectsRangeUp() {
        let result = click(3, from: [6], anchor: 6, shift: true)
        #expect(result.selection == [3, 4, 5, 6])
        #expect(result.anchor == 6)
    }

    @Test("A second ⇧-click re-measures from the anchor instead of creeping")
    func shiftDoesNotCreep() {
        let first = click(6, from: [3], anchor: 3, shift: true)
        let second = click(4, from: first.selection, anchor: first.anchor, shift: true)
        #expect(second.selection == [3, 4], "shrinking the range must shrink the selection")
        #expect(second.anchor == 3)
    }

    @Test("⇧-click on the anchor itself selects just that row")
    func shiftOnAnchor() {
        let result = click(5, from: [5, 6, 7], anchor: 5, shift: true)
        #expect(result.selection == [5])
    }

    @Test("⇧-click replaces whatever was selected outside the run")
    func shiftReplacesOutsideTheRun() {
        let result = click(4, from: [1, 9], anchor: 3, shift: true)
        #expect(result.selection == [3, 4])
    }

    // MARK: - ⌘⇧

    @Test("⌘⇧-click adds the run to what is already selected")
    func commandShiftUnions() {
        let result = click(5, from: [9, 10], anchor: 3, shift: true, command: true)
        #expect(result.selection == [3, 4, 5, 9, 10])
        #expect(result.anchor == 3, "without moving the anchor")
    }

    // MARK: - The cases that must not select a guess

    @Test("⇧-click with nothing anchored behaves like a plain click")
    func shiftWithoutAnchor() {
        let result = click(6, from: [1, 2], anchor: nil, shift: true)
        #expect(result.selection == [6], "no anchor means no range; never fall back to row zero")
        #expect(result.anchor == 6)
    }

    @Test("⇧-click anchored to a row that is gone behaves like a plain click")
    func shiftWithStaleAnchor() {
        // 99 is not in `order`: the folder was reloaded, or a filter hid the anchored row.
        let result = click(6, from: [1, 2], anchor: 99, shift: true)
        #expect(result.selection == [6])
        #expect(result.anchor == 6)
    }

    @Test("⌘⇧-click with a stale anchor toggles one row rather than selecting a range")
    func commandShiftWithStaleAnchor() {
        let result = click(6, from: [1, 2], anchor: 99, shift: true, command: true)
        #expect(result.selection == [1, 2, 6])
        #expect(result.anchor == 6)
    }

    @Test("Clicking a row that is not listed cannot make a range")
    func clickOutsideTheList() {
        let result = click(42, from: [1], anchor: 1, shift: true)
        #expect(result.selection == [42])
    }

    @Test("A one-row folder is not a special case")
    func singleRow() {
        let result = click(1, anchor: 1, in: [1], shift: true)
        #expect(result.selection == [1])
    }

    // MARK: - Sort order

    @Test("The run follows the order the rows are actually in")
    func runFollowsTheCurrentOrder() {
        // Sorted by size rather than name: the run is whatever lies between them *on screen*.
        let result = click(1, anchor: 3, in: [7, 3, 9, 1, 4], shift: true)
        #expect(result.selection == [3, 9, 1])
    }
}
