//
//  AppQuitterTests.swift
//  CleanMacTests
//
//  Spec §7: uninstalling a running app must first send it a `kAEQuitApplication`
//  Apple Event so it can save state before it goes away. These tests assert on
//  the *constructed* event only. Nothing is ever sent — sending one would
//  terminate a real process on whatever machine runs the suite.
//

import XCTest
import Carbon
@testable import CleanMac

final class AppQuitterTests: XCTestCase {

    func testQuitEventIsACoreQuitAppleEvent() {
        let event = AppQuitter.makeQuitEvent(pid: 4242)

        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEQuitApplication),
                       "Must be a Quit event; anything else leaves the app running and the uninstall half-done.")
    }

    func testProcessDescriptorUsesTheKernelSubprocessType() throws {
        let descriptor = try XCTUnwrap(AppQuitter.makeProcessDescriptor(pid: 4242))
        XCTAssertEqual(descriptor.descriptorType, AppQuitter.kernelSubprocessDescType)
    }

    func testKernelSubprocessTypeIsTheKpidFourCharCode() {
        // The Carbon overlay does not export `typeKernelSubprocess`, so the
        // constant is spelled out as a literal. Recomputing it from the 'kpid'
        // characters is what stops that literal from drifting: a wrong
        // descriptor type means the event is never delivered, and the
        // `terminate()` fallback would mask the failure by killing the app
        // ungracefully instead.
        let expected = "kpid".unicodeScalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1.value) }
        XCTAssertEqual(AppQuitter.kernelSubprocessDescType, expected)
    }

    func testProcessDescriptorCarriesTheRawPIDBytes() throws {
        let pid: Int32 = 0x0102_0304
        let descriptor = try XCTUnwrap(AppQuitter.makeProcessDescriptor(pid: pid))

        var expected = pid
        let bytes = Data(bytes: &expected, count: MemoryLayout<pid_t>.size)
        XCTAssertEqual(descriptor.data, bytes)
    }

    func testDistinctPIDsProduceDistinctDescriptors() throws {
        // Quitting the wrong process would be worse than not quitting at all,
        // so the pid must actually reach the descriptor rather than be dropped.
        let first = try XCTUnwrap(AppQuitter.makeProcessDescriptor(pid: 111))
        let second = try XCTUnwrap(AppQuitter.makeProcessDescriptor(pid: 222))
        XCTAssertNotEqual(first.data, second.data)
    }
}
