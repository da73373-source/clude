import XCTest
@testable import CrackDetector

@MainActor
final class ScaleTests: XCTestCase {
    func testRulerCalibrationTakesPriority() {
        let vm = DetectionViewModel()
        XCTAssertNil(vm.mmPerPixel)
        vm.addCalibrationPoint(CGPoint(x: 10, y: 10))
        vm.addCalibrationPoint(CGPoint(x: 70, y: 90))   // 距離 100px
        vm.calibrationMM = 50
        XCTAssertEqual(vm.mmPerPixel ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(vm.formatWidth(1), "0.50 mm")
        // 3点目で打ち直し
        vm.addCalibrationPoint(CGPoint(x: 0, y: 0))
        XCTAssertEqual(vm.calibrationPoints.count, 1)
        XCTAssertNil(vm.mmPerPixel)
        vm.clearCalibration()
        XCTAssertNil(vm.calibrationMM)
    }

    func testSeverityUsesScale() {
        let vm = DetectionViewModel()
        let c = Crack(id: 1, bbox: CGRectInt(x: 0, y: 0, width: 10, height: 10), area: 30, lengthPx: 100, meanWidthPx: 3, maxWidthPx: 4)
        XCTAssertEqual(vm.severity(of: c), .unknown)
        vm.addCalibrationPoint(.zero); vm.addCalibrationPoint(CGPoint(x: 100, y: 0))
        vm.calibrationMM = 10     // 0.1 mm/px → 最大幅 0.4mm
        XCTAssertEqual(vm.severity(of: c), .caution)
    }
}
