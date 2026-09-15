//
//  SizeCalculatorTests.swift
//  CleanMacTests
//
//  Recursive size summation against an in-memory file system, including the
//  symlink-cycle guard, plus ByteCount formatting used across the UI.
//

import XCTest
@testable import CleanMac

final class SizeCalculatorTests: XCTestCase {

    private var fs: MockFileSystem!
    private var calculator: SizeCalculator!

    override func setUp() {
        super.setUp()
        fs = MockFileSystem(home: "/mockhome")
        calculator = SizeCalculator(fileSystem: fs)
    }

    override func tearDown() {
        calculator = nil
        fs = nil
        super.tearDown()
    }

    // MARK: - Single entries

    func testRegularFileReturnsAllocatedSize() {
        fs.addFile("/mockhome/a.txt", size: 4096)
        XCTAssertEqual(calculator.size(of: "/mockhome/a.txt"), 4096)
    }

    func testMissingPathReturnsZero() {
        XCTAssertEqual(calculator.size(of: "/mockhome/nope.txt"), 0)
    }

    func testEmptyDirectoryReturnsZero() {
        fs.addDirectory("/mockhome/empty")
        XCTAssertEqual(calculator.size(of: "/mockhome/empty"), 0)
    }

    // MARK: - Recursion

    func testSumsNestedFiles() {
        fs.addFile("/mockhome/root/a.txt", size: 100)
        fs.addFile("/mockhome/root/b.txt", size: 200)
        fs.addFile("/mockhome/root/deep/c.txt", size: 300)
        fs.addFile("/mockhome/root/deep/deeper/d.txt", size: 400)

        XCTAssertEqual(calculator.size(of: "/mockhome/root"), 1000)
    }

    func testDoesNotIncludeSiblings() {
        fs.addFile("/mockhome/root/a.txt", size: 100)
        fs.addFile("/mockhome/other/b.txt", size: 500)
        XCTAssertEqual(calculator.size(of: "/mockhome/root"), 100)
    }

    func testDeepNestingDoesNotBlowTheStack() {
        var path = "/mockhome/deep"
        for level in 0..<300 {
            path += "/l\(level)"
            fs.addFile("\(path)/file.bin", size: 10)
        }
        XCTAssertEqual(calculator.size(of: "/mockhome/deep"), 3000)
    }

    // MARK: - Symlinks

    func testSymlinksAreCountedOnceAndNeverFollowed() {
        // A classic cycle: the link points back at the directory containing it.
        fs.addFile("/mockhome/loop/payload.bin", size: 1024)
        fs.addSymlink("/mockhome/loop/self", size: 64)

        XCTAssertEqual(calculator.size(of: "/mockhome/loop"), 1024 + 64)
    }

    func testSymlinkToExternalDirectoryIsNotTraversed() {
        fs.addFile("/mockhome/target/big.bin", size: 10_000)
        fs.addDirectory("/mockhome/linker")
        fs.addSymlink("/mockhome/linker/target", size: 64)

        XCTAssertEqual(calculator.size(of: "/mockhome/linker"), 64)
    }

    // MARK: - Batch

    func testSizesOfMultiplePaths() {
        fs.addFile("/mockhome/a.txt", size: 10)
        fs.addFile("/mockhome/b.txt", size: 20)
        fs.addFile("/mockhome/dir/c.txt", size: 30)

        let sizes = calculator.sizes(of: ["/mockhome/a.txt", "/mockhome/b.txt", "/mockhome/dir"])
        XCTAssertEqual(sizes["/mockhome/a.txt"], 10)
        XCTAssertEqual(sizes["/mockhome/b.txt"], 20)
        XCTAssertEqual(sizes["/mockhome/dir"], 30)
    }

    func testSizesOfEmptyList() {
        XCTAssertTrue(calculator.sizes(of: []).isEmpty)
    }

    // MARK: - ByteCount formatting

    func testCompactFormattingPicksTheRightUnit() {
        XCTAssertEqual(ByteCount.compact(0), "0 B")
        XCTAssertEqual(ByteCount.compact(512), "512 B")
        XCTAssertEqual(ByteCount.compact(1024), "1.00 KB")
        XCTAssertEqual(ByteCount.compact(1024 * 1024), "1.00 MB")
        XCTAssertEqual(ByteCount.compact(3 * 1024 * 1024 * 1024), "3.00 GB")
        XCTAssertEqual(ByteCount.compact(2 * 1024 * 1024 * 1024 * 1024), "2.00 TB")
    }

    func testCompactFormattingReducesPrecisionForLargeValues() {
        // >= 10 → one decimal, >= 100 → none.
        XCTAssertEqual(ByteCount.compact(12 * 1024 * 1024), "12.0 MB")
        XCTAssertEqual(ByteCount.compact(150 * 1024 * 1024), "150 MB")
    }

    func testCompactFormattingHandlesNegatives() {
        XCTAssertEqual(ByteCount.compact(-(2 * 1024 * 1024)), "-2.00 MB")
    }

    func testFullFormattingIsNonEmptyAndIncludesUnits() {
        let text = ByteCount.format(1536)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("KB"), "expected a unit in '\(text)'")

        let bare = ByteCount.format(1536, includeUnits: false)
        XCTAssertFalse(bare.contains("KB"))
    }

    func testFullFormattingHandlesZero() {
        let text = ByteCount.format(0)
        XCTAssertFalse(text.isEmpty)
    }
}
