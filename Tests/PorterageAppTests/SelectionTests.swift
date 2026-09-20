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
        cursor: MTPEntry.ID? = nil,
        in rows: [MTPEntry.ID]? = nil,
        shift: Bool = false,
        command: Bool = false
    ) -> PhoneBrowser.RowSelection {
        PhoneBrowser.clicking(
            id, in: rows ?? order, extending: shift, togglingOne: command,
            from: .init(ids: current, anchor: anchor, cursor: cursor)
        )
    }

    private func arrow(
        _ step: Int,
        from current: Set<MTPEntry.ID> = [],
        anchor: MTPEntry.ID? = nil,
        cursor: MTPEntry.ID? = nil,
        in rows: [MTPEntry.ID]? = nil,
        shift: Bool = false
    ) -> PhoneBrowser.RowSelection {
        PhoneBrowser.moving(
            step, in: rows ?? order, extending: shift,
            from: .init(ids: current, anchor: anchor, cursor: cursor)
        )
    }

    // MARK: - Plain click

    @Test("A plain click replaces the selection and anchors there")
    func plainClickReplaces() {
        let result = click(4, from: [1, 2, 3], anchor: 1)
        #expect(result.ids == [4])
        #expect(result.anchor == 4)
        #expect(result.cursor == 4, "and the keyboard follows the mouse")
    }

    // MARK: - ⌘

    @Test("⌘-click adds a row without disturbing the rest")
    func commandAdds() {
        let result = click(7, from: [2, 3], anchor: 3, command: true)
        #expect(result.ids == [2, 3, 7])
        #expect(result.anchor == 7)
    }

    @Test("⌘-click on an already selected row removes it")
    func commandRemoves() {
        let result = click(3, from: [2, 3, 7], anchor: 7, command: true)
        #expect(result.ids == [2, 7])
        #expect(result.anchor == 3)
    }

    // MARK: - ⇧, the point of the exercise

    @Test("⇧-click takes the whole run from the anchor downwards")
    func shiftSelectsRangeDown() {
        let result = click(6, from: [3], anchor: 3, shift: true)
        #expect(result.ids == [3, 4, 5, 6])
        #expect(result.anchor == 3, "the anchor stays put so the next ⇧-click re-measures from it")
        #expect(result.cursor == 6, "but the cursor moves to the row clicked")
    }

    @Test("⇧-click upwards selects the same run")
    func shiftSelectsRangeUp() {
        let result = click(3, from: [6], anchor: 6, shift: true)
        #expect(result.ids == [3, 4, 5, 6])
        #expect(result.anchor == 6)
    }

    @Test("A second ⇧-click re-measures from the anchor instead of creeping")
    func shiftDoesNotCreep() {
        let first = click(6, from: [3], anchor: 3, shift: true)
        let second = click(4, from: first.ids, anchor: first.anchor, shift: true)
        #expect(second.ids == [3, 4], "shrinking the range must shrink the selection")
        #expect(second.anchor == 3)
    }

    @Test("⇧-click on the anchor itself selects just that row")
    func shiftOnAnchor() {
        let result = click(5, from: [5, 6, 7], anchor: 5, shift: true)
        #expect(result.ids == [5])
    }

    @Test("⇧-click replaces whatever was selected outside the run")
    func shiftReplacesOutsideTheRun() {
        let result = click(4, from: [1, 9], anchor: 3, shift: true)
        #expect(result.ids == [3, 4])
    }

    // MARK: - ⌘⇧

    @Test("⌘⇧-click adds the run to what is already selected")
    func commandShiftUnions() {
        let result = click(5, from: [9, 10], anchor: 3, shift: true, command: true)
        #expect(result.ids == [3, 4, 5, 9, 10])
        #expect(result.anchor == 3, "without moving the anchor")
    }

    // MARK: - The cases that must not select a guess

    @Test("⇧-click with nothing anchored behaves like a plain click")
    func shiftWithoutAnchor() {
        let result = click(6, from: [1, 2], anchor: nil, shift: true)
        #expect(result.ids == [6], "no anchor means no range; never fall back to row zero")
        #expect(result.anchor == 6)
    }

    @Test("⇧-click anchored to a row that is gone behaves like a plain click")
    func shiftWithStaleAnchor() {
        // 99 is not in `order`: the folder was reloaded, or a filter hid the anchored row.
        let result = click(6, from: [1, 2], anchor: 99, shift: true)
        #expect(result.ids == [6])
        #expect(result.anchor == 6)
    }

    @Test("⌘⇧-click with a stale anchor toggles one row rather than selecting a range")
    func commandShiftWithStaleAnchor() {
        let result = click(6, from: [1, 2], anchor: 99, shift: true, command: true)
        #expect(result.ids == [1, 2, 6])
        #expect(result.anchor == 6)
    }

    @Test("Clicking a row that is not listed cannot make a range")
    func clickOutsideTheList() {
        let result = click(42, from: [1], anchor: 1, shift: true)
        #expect(result.ids == [42])
    }

    @Test("A one-row folder is not a special case")
    func singleRow() {
        let result = click(1, anchor: 1, in: [1], shift: true)
        #expect(result.ids == [1])
    }

    // MARK: - Sort order

    @Test("The run follows the order the rows are actually in")
    func runFollowsTheCurrentOrder() {
        // Sorted by size rather than name: the run is whatever lies between them *on screen*.
        let result = click(1, anchor: 3, in: [7, 3, 9, 1, 4], shift: true)
        #expect(result.ids == [3, 9, 1])
    }

    // MARK: - Arrow keys

    @Test("↓ with nothing selected lands on the first row")
    func downFromNothing() {
        let result = arrow(1)
        #expect(result.ids == [1])
        #expect(result.cursor == 1)
        #expect(result.anchor == 1)
    }

    @Test("↑ with nothing selected lands on the last row")
    func upFromNothing() {
        let result = arrow(-1)
        #expect(result.ids == [10])
        #expect(result.cursor == 10)
    }

    @Test("↓ moves one row down and takes the selection with it")
    func downMovesOne() {
        let result = arrow(1, from: [3], anchor: 3, cursor: 3)
        #expect(result.ids == [4])
        #expect(result.anchor == 4, "a plain arrow re-anchors, like a plain click")
        #expect(result.cursor == 4)
    }

    @Test("↑ moves one row up")
    func upMovesOne() {
        let result = arrow(-1, from: [3], anchor: 3, cursor: 3)
        #expect(result.ids == [2])
    }

    @Test("↓ at the last row stays there rather than wrapping")
    func downStopsAtTheEnd() {
        let result = arrow(1, from: [10], anchor: 10, cursor: 10)
        #expect(result.ids == [10], "wrapping in a file list means one keypress jumps a thousand rows")
    }

    @Test("↑ at the first row stays there")
    func upStopsAtTheStart() {
        let result = arrow(-1, from: [1], anchor: 1, cursor: 1)
        #expect(result.ids == [1])
    }

    @Test("⇧↓ drags the range behind the cursor")
    func shiftDownExtends() {
        let result = arrow(1, from: [3], anchor: 3, cursor: 3, shift: true)
        #expect(result.ids == [3, 4])
        #expect(result.anchor == 3)
        #expect(result.cursor == 4)
    }

    @Test("⇧↓ three times takes four rows")
    func shiftDownRepeats() {
        var state = PhoneBrowser.RowSelection(ids: [3], anchor: 3, cursor: 3)
        for _ in 0 ..< 3 {
            state = PhoneBrowser.moving(1, in: order, extending: true, from: state)
        }
        #expect(state.ids == [3, 4, 5, 6])
        #expect(state.anchor == 3)
    }

    @Test("⇧↑ after ⇧↓ shrinks the range back instead of leaving rows behind")
    func shiftReverses() {
        let down = arrow(1, from: [3], anchor: 3, cursor: 3, shift: true)
        let back = arrow(-1, from: down.ids, anchor: down.anchor, cursor: down.cursor, shift: true)
        #expect(back.ids == [3], "this is the whole reason the anchor and the cursor are separate")
    }

    @Test("⇧↓ with nothing anchored measures from where the cursor already is")
    func shiftDownWithoutAnchor() {
        let result = arrow(1, from: [5], anchor: nil, cursor: 5, shift: true)
        #expect(result.ids == [5, 6])
        #expect(result.anchor == 5)
    }

    @Test("⇧↓ after a ⇧-click continues from the row clicked, not from the anchor")
    func arrowContinuesFromTheClick() {
        let clicked = click(6, from: [3], anchor: 3, cursor: 3, shift: true)
        let result = arrow(1, from: clicked.ids, anchor: clicked.anchor, cursor: clicked.cursor, shift: true)
        #expect(result.ids == [3, 4, 5, 6, 7])
    }

    @Test("An arrow in an empty folder changes nothing")
    func arrowInEmptyFolder() {
        let result = arrow(1, in: [])
        #expect(result.ids == [])
        #expect(result.cursor == nil)
    }

    @Test("An arrow steps through the order on screen, not the phone's order")
    func arrowFollowsTheCurrentOrder() {
        let bySize: [MTPEntry.ID] = [7, 3, 9, 1, 4]
        let result = arrow(1, from: [3], anchor: 3, cursor: 3, in: bySize)
        #expect(result.ids == [9], "3 is followed by 9 in this order, not by 4")
    }

    @Test("An arrow with a cursor on a row that is gone lands on an end")
    func arrowWithStaleCursor() {
        let result = arrow(1, from: [1], anchor: 1, cursor: 99)
        #expect(result.ids == [1], "the first row, because down came from nowhere")
    }
}
