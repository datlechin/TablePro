//
//  StringHexDumpTests.swift
//  TableProTests
//

import XCTest
@testable import TablePro

final class StringHexDumpTests: XCTestCase {

    func testEmptyStringReturnsNil() {
        XCTAssertNil("".formattedAsHexDump())
    }

    func testBasicASCII() {
        let result = "Hello".formattedAsHexDump()
        XCTAssertNotNil(result)
        // "Hello" = 48 65 6C 6C 6F
        XCTAssertTrue(result!.contains("48 65 6C 6C 6F"))
        XCTAssertTrue(result!.contains("|Hello|"))
    }

    func testFullLine() {
        // 16 bytes: "0123456789ABCDEF"
        let input = "0123456789ABCDEF"
        let result = input.formattedAsHexDump()!
        // Should have offset 00000000
        XCTAssertTrue(result.hasPrefix("00000000"))
        // Should contain ASCII representation
        XCTAssertTrue(result.contains("|0123456789ABCDEF|"))
    }

    func testMultipleLines() {
        // 20 bytes = 1 full line (16) + 1 partial line (4)
        let input = "ABCDEFGHIJKLMNOPQRST"
        let result = input.formattedAsHexDump()!
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("00000000"))
        XCTAssertTrue(lines[1].hasPrefix("00000010"))
    }

    func testNonPrintableCharsShowAsDots() {
        // Create string with non-printable characters via isoLatin1
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x41, 0x42, 0x7F, 0xFF]
        let input = String(bytes: bytes, encoding: .isoLatin1)!
        let result = input.formattedAsHexDump()!
        // 0x00, 0x01, 0x02 → dots; 0x41, 0x42 → "AB"; 0x7F, 0xFF → dots
        XCTAssertTrue(result.contains("|...AB..|"))
    }

    func testTruncation() {
        // Create a string larger than maxBytes
        let input = String(repeating: "A", count: 100)
        let result = input.formattedAsHexDump(maxBytes: 32)!
        XCTAssertTrue(result.contains("truncated"))
        XCTAssertTrue(result.contains("100 bytes total"))
        // Should only have 2 full lines (32 bytes / 16) + truncation line
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    func testOffsetFormatting() {
        let input = String(repeating: "X", count: 48)
        let result = input.formattedAsHexDump()!
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("00000000"))
        XCTAssertTrue(lines[1].hasPrefix("00000010"))
        XCTAssertTrue(lines[2].hasPrefix("00000020"))
    }

    func testSingleByte() {
        let result = "A".formattedAsHexDump()!
        XCTAssertTrue(result.contains("41"))
        XCTAssertTrue(result.contains("|A|"))
    }
}
