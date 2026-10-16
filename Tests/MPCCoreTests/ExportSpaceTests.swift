import Foundation
import XCTest
@testable import MPCCore

final class ExportSpaceTests: XCTestCase {
    func testFATCountsEveryClusterAndEveryPotentialMetadataFile() throws {
        let volume = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: 200_000)
        let estimate = try ExportSpace.estimate(fileSizes: [8193, 4608], volume: volume)
        XCTAssertEqual(estimate.nominalBytes, 12_801)
        XCTAssertEqual(estimate.allocatedBytes, 24_576)
        XCTAssertEqual(estimate.metadataBytes, 16_384)
        XCTAssertEqual(estimate.reserveBytes, 65_536)
        XCTAssertEqual(estimate.requiredBytes, 106_496)
    }

    func testSixtyFourTinySamplesStillNeedSixtyFiveNativeAndMetadataAllocations() throws {
        let volume = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: 1_000_000)
        let estimate = try ExportSpace.estimate(fileSizes: Array(repeating: 2000, count: 64) + [4608], volume: volume)
        XCTAssertEqual(estimate.allocatedBytes, 65 * 8192)
        XCTAssertEqual(estimate.metadataBytes, 65 * 8192)
        XCTAssertGreaterThan(estimate.requiredBytes, volume.availableBytes)
        XCTAssertLessThan(estimate.nominalBytes, volume.availableBytes)
    }

    func testNativeExtendedAttributeFilesystemNeedsNoSidecarReserve() throws {
        let volume = ExportVolumeSpace(allocationUnitBytes: 4096, availableBytes: 1_000_000, reservesAppleDouble: false)
        let estimate = try ExportSpace.estimate(fileSizes: [4096, 4097], volume: volume)
        XCTAssertEqual(estimate.allocatedBytes, 12_288)
        XCTAssertEqual(estimate.metadataBytes, 0)
        XCTAssertEqual(estimate.requiredBytes, 77_824)
    }

    func testInvalidAndOverflowingSizesCannotBecomeAnOptimisticEstimate() {
        for unit in [Int64(0), -1, Int64.max] {
            XCTAssertThrowsError(try ExportSpace.estimate(fileSizes: [1], volume: .init(allocationUnitBytes: unit, availableBytes: 0)))
        }
        XCTAssertThrowsError(try ExportSpace.estimate(fileSizes: [-1], volume: .init(allocationUnitBytes: 8192, availableBytes: 0)))
        XCTAssertThrowsError(try ExportSpace.estimate(fileSizes: [Int.max, Int.max], volume: .init(allocationUnitBytes: 4096, availableBytes: 0)))
    }

    func testVolumeProbeRejectsMissingDirectoryAndInvalidDescriptor() throws {
        XCTAssertThrowsError(try ExportSpace.volume(directoryFD: -1))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ExportSpace.volume(at: missing))
        let volume = try ExportSpace.volume(at: FileManager.default.temporaryDirectory)
        XCTAssertGreaterThan(volume.allocationUnitBytes, 0)
        XCTAssertGreaterThanOrEqual(volume.availableBytes, 0)
    }
}
