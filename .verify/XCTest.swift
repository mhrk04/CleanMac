// Functional XCTest stand-in used by the no-Xcode verification harness.
//
// The Command Line Tools toolchain ships no XCTest.framework, so this module
// re-implements exactly the slice the CleanMac test target uses, with real
// behaviour: assertions record failures instead of being no-ops, XCTUnwrap
// throws, XCTSkipUnless throws XCTSkip, and a recorder collects the results so
// a generated runner can execute the suite from the command line.
//
// Signatures match Apple's XCTest so that code which type-checks and runs here
// also compiles against the real framework under Xcode.
@_exported import Foundation

// MARK: - Failure recording

public final class XCTFailureRecorder: @unchecked Sendable {
    public static let shared = XCTFailureRecorder()

    private let lock = NSLock()
    private var _failures: [String] = []

    private init() {}

    public func reset() {
        lock.lock(); _failures = []; lock.unlock()
    }

    public func record(_ message: String, file: StaticString, line: UInt) {
        let loc = "\(URL(fileURLWithPath: file.description).lastPathComponent):\(line)"
        lock.lock(); _failures.append("\(loc): \(message)"); lock.unlock()
    }

    public var failures: [String] {
        lock.lock(); defer { lock.unlock() }
        return _failures
    }

    public var hasFailed: Bool { !failures.isEmpty }
}

// MARK: - Case

open class XCTestCase {
    public init() {}
    open func setUp() {}
    open func tearDown() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    public var continueAfterFailure: Bool { get { true } set {} }
}

public struct XCTSkip: Error, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String = "") { self.reason = reason }
    public var description: String { reason }
}

/// Thrown by XCTUnwrap when the value is nil — mirrors XCTest, which aborts the
/// current test method rather than continuing with a bogus value.
public struct XCTUnwrapError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

// MARK: - Assertions

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTFailureRecorder.shared.record("XCTFail: \(message)", file: file, line: line)
}

public func XCTAssertEqual<T: Equatable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1()
    let b = try e2()
    if a != b {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record(
            "XCTAssertEqual failed: (\(a)) is not equal to (\(b))\(extra)",
            file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1()
    let b = try e2()
    if a == b {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record(
            "XCTAssertNotEqual failed: (\(a)) is equal to (\(b))\(extra)",
            file: file, line: line)
    }
}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    if !(try expression()) {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record("XCTAssertTrue failed\(extra)", file: file, line: line)
    }
}

public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try expression() {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record("XCTAssertFalse failed\(extra)", file: file, line: line)
    }
}

public func XCTAssertNil(
    _ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    if let value = try expression() {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record(
            "XCTAssertNil failed: (\(value)) is not nil\(extra)", file: file, line: line)
    }
}

public func XCTAssertNotNil(
    _ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try expression() == nil {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record("XCTAssertNotNil failed\(extra)", file: file, line: line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1(); let b = try e2()
    if !(a > b) {
        XCTFailureRecorder.shared.record(
            "XCTAssertGreaterThan failed: (\(a)) is not greater than (\(b))",
            file: file, line: line)
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1(); let b = try e2()
    if !(a >= b) {
        XCTFailureRecorder.shared.record(
            "XCTAssertGreaterThanOrEqual failed: (\(a)) is less than (\(b))",
            file: file, line: line)
    }
}

public func XCTAssertLessThan<T: Comparable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1(); let b = try e2()
    if !(a < b) {
        XCTFailureRecorder.shared.record(
            "XCTAssertLessThan failed: (\(a)) is not less than (\(b))", file: file, line: line)
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ e1: @autoclosure () throws -> T, _ e2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try e1(); let b = try e2()
    if !(a <= b) {
        XCTFailureRecorder.shared.record(
            "XCTAssertLessThanOrEqual failed: (\(a)) is greater than (\(b))",
            file: file, line: line)
    }
}

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        let value = try expression()
        XCTFailureRecorder.shared.record(
            "XCTAssertThrowsError failed: no error thrown, got (\(value))",
            file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

public func XCTAssertNoThrow<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) rethrows {
    do {
        _ = try expression()
    } catch {
        XCTFailureRecorder.shared.record(
            "XCTAssertNoThrow failed: threw (\(error))", file: file, line: line)
    }
}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        let extra = message().isEmpty ? "" : " — \(message())"
        XCTFailureRecorder.shared.record("XCTUnwrap failed: nil value\(extra)", file: file, line: line)
        throw XCTUnwrapError(message: "XCTUnwrap of nil value\(extra)")
    }
    return value
}

public func XCTSkipUnless(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String? = nil,
    file: StaticString = #filePath, line: UInt = #line) throws {
    if !(try expression()) { throw XCTSkip(message() ?? "") }
}

public func XCTSkipIf(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String? = nil,
    file: StaticString = #filePath, line: UInt = #line) throws {
    if try expression() { throw XCTSkip(message() ?? "") }
}
