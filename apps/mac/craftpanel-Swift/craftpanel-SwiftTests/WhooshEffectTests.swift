import Testing
import SwiftUI
@testable import craftpanel_Swift

struct WhooshEffectTests {
    private func scale(_ p: CGFloat) -> CGFloat {
        WhooshEffect(travel: 0.014, progress: p).effectValue(size: CGSize(width: 100, height: 40)).m11
    }

    @Test func startsAndEndsAtRestForEveryClick() {
        for n in 0...4 { #expect(abs(scale(CGFloat(n)) - 1) < 0.0001) }
    }

    @Test func onlyGrowsALittleAndNeverMoves() {
        for i in 1..<20 {
            let v = scale(3 + CGFloat(i) / 20)
            #expect(v >= 1 && v <= 1.0141)
        }
        let t = WhooshEffect(travel: 0.014, progress: 3.5).effectValue(size: CGSize(width: 100, height: 40))
        // The centre of the view stays where it was.
        let cx = 50 * t.m11 + t.m31
        #expect(abs(cx - 50) < 0.0001)
    }
}
