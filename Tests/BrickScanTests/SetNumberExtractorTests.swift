import XCTest
@testable import BrickScan

final class SetNumberExtractorTests: XCTestCase {

    func testSetNoLabel() {
        let result = SetNumberExtractor.extractFromOCR(["Set No. 42143"])
        XCTAssertTrue(result.contains("42143"))
    }

    func testNumberWithSuffix() {
        let result = SetNumberExtractor.extractFromOCR(["75192-1"])
        XCTAssertTrue(result.contains("75192-1"))
    }

    func testArtNrLabel() {
        let result = SetNumberExtractor.extractFromOCR(["Art.Nr. 21325"])
        XCTAssertTrue(result.contains("21325"))
    }

    func testCopyrightPrefixedNumber() {
        let result = SetNumberExtractor.extractFromOCR(["© LEGO 2022 10300"])
        XCTAssertTrue(result.contains("10300"))
    }

    func testPhoneNumberExcluded() {
        let result = SetNumberExtractor.extractFromOCR(["1-800-422-5346"])
        XCTAssertTrue(result.isEmpty)
    }

    func testYearExcluded() {
        let result = SetNumberExtractor.extractFromOCR(["2024"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFullEAN13Excluded() {
        let result = SetNumberExtractor.extractFromOCR(["5702016617756"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFourDigitSet() {
        let result = SetNumberExtractor.extractFromOCR(["42143"])
        XCTAssertEqual(result, ["42143"])
    }

    func testFiveDigitSet() {
        let result = SetNumberExtractor.extractFromOCR(["75192"])
        XCTAssertEqual(result, ["75192"])
    }

    func testSixDigitSet() {
        let result = SetNumberExtractor.extractFromOCR(["910001"])
        XCTAssertTrue(result.contains("910001"))
    }

    func testMultipleCandidates() {
        let result = SetNumberExtractor.extractFromOCR(["42143", "Set No. 10300"])
        XCTAssertEqual(result, ["42143", "10300"])
    }

    func testDeduplication() {
        let result = SetNumberExtractor.extractFromOCR(["42143", "42143"])
        XCTAssertEqual(result, ["42143"])
    }

    func testNearbyYearRangeExcluded() {
        let result = SetNumberExtractor.extractFromOCR(["1990"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFutureYearExcluded() {
        let result = SetNumberExtractor.extractFromOCR(["2035"])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyString() {
        let result = SetNumberExtractor.extractFromOCR([""])
        XCTAssertTrue(result.isEmpty)
    }

    func testNoDigits() {
        let result = SetNumberExtractor.extractFromOCR(["LEGO Technic"])
        XCTAssertTrue(result.isEmpty)
    }

    func testSuffixWithTwoDigits() {
        let result = SetNumberExtractor.extractFromOCR(["10300-12"])
        XCTAssertTrue(result.contains("10300-12"))
    }

    func testLabeledNumberWithoutDash() {
        let result = SetNumberExtractor.extractFromOCR(["SetNo 60380"])
        XCTAssertFalse(result.isEmpty)
    }

    func testBarcodePassthrough() {
        let result = SetNumberExtractor.extractFromBarcode("5702016617756")
        XCTAssertEqual(result, "5702016617756")
    }

    func testThreeDigitNumberExcluded() {
        let result = SetNumberExtractor.extractFromOCR(["123"])
        XCTAssertTrue(result.isEmpty)
    }
}
