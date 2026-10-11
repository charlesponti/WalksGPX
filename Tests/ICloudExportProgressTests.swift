import XCTest
@testable import WalksGPX_iOS

final class ICloudExportProgressTests: XCTestCase {
    func testFractionHandlesEmptyAndClampsBounds() {
        XCTAssertEqual(ICloudExportProgress(completedRoutes: 0, totalRoutes: 0).fraction, 0)
        XCTAssertEqual(ICloudExportProgress(completedRoutes: 25, totalRoutes: 100).fraction, 0.25)
        XCTAssertEqual(ICloudExportProgress(completedRoutes: 150, totalRoutes: 100).fraction, 1)
        XCTAssertEqual(ICloudExportProgress(completedRoutes: -1, totalRoutes: 100).fraction, 0)
    }
}
