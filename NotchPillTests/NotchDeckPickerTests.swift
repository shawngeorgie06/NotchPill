import Testing
@testable import NotchPill

@Suite("Expanded card picker")
struct NotchDeckPickerTests {
    @Test("every configured card has a named icon entry")
    func everyKindHasPickerMetadata() {
        let kinds = ExpandedActivity.allKinds.map(\.kind)
        let items = NotchDeckPickerItem.items(for: kinds)

        #expect(items.map(\.kind) == kinds)
        #expect(items.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
    }

    @Test("page position is bounded and omitted for a one-card deck")
    func boundedPositionLabel() {
        #expect(NotchDeckPickerItem.positionLabel(page: 0, count: 12) == "1 / 12")
        #expect(NotchDeckPickerItem.positionLabel(page: 6, count: 12) == "7 / 12")
        #expect(NotchDeckPickerItem.positionLabel(page: 40, count: 12) == "12 / 12")
        #expect(NotchDeckPickerItem.positionLabel(page: -4, count: 12) == "1 / 12")
        #expect(NotchDeckPickerItem.positionLabel(page: 0, count: 1) == nil)
    }

    @Test("stored card order removes duplicates and restores missing catalog kinds")
    func cardOrderRepairsStoredValues() {
        #expect(CardOrdering.resolving(["media", "media", "unknown", "clock"],
                                       known: ["media", "clock", "battery"])
                == ["media", "clock", "battery"])
    }
}
