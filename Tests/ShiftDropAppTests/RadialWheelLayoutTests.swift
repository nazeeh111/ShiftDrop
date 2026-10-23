import XCTest
@testable import ShiftDrop

final class RadialWheelLayoutTests: XCTestCase {
    func testEveryOfferedOperationHasOneReachableSector() {
        for count in 1...24 {
            let layout = RadialWheelLayout(count: count)
            XCTAssertEqual(layout.sectors.count, count)
            for sector in layout.sectors {
                XCTAssertEqual(layout.index(at: sector.center), sector.index, "count \(count), operation \(sector.index)")
                XCTAssertEqual(layout.sectors.filter { $0.contains(sector.center) }.count, 1)
            }
        }
    }
    func testCenterAndOutsideNeverPerformAnOperation() {
        for count in [0, 6, 12, 19, 23] {
            let layout = RadialWheelLayout(count: count)
            for point in [CGPoint(x: 240, y: 240), CGPoint(x: 240, y: 280), .zero, CGPoint(x: 480, y: 480)] {
                XCTAssertNil(layout.index(at: point))
            }
        }
    }
}
