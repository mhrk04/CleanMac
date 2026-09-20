//
//  SettingsStoreChangeTests.swift
//  CleanMacTests
//
//  Bug 3 (runtime-bugfixes): SwiftUI logs "Publishing changes from within view
//  updates is not allowed" because `SettingsStore` bridges its manual
//  `PassthroughSubject` straight into `objectWillChange` in `init`, so
//  `objectWillChange` fires SYNCHRONOUSLY inside a setter. When a SwiftUI
//  binding writes a setting during a view-update pass (e.g. the
//  `MenuBarExtra(isInserted:)` binding, or the sidebar selection binding), the
//  notification fires mid-render.
//
//  The fix defers the bridged `objectWillChange` delivery to the main run loop
//  (`.receive(on: RunLoop.main)`), so it is coalesced to the next tick instead
//  of firing inside the caller's stack. UserDefaults persistence in the setter
//  stays synchronous, so reads always see the new value immediately.
//
//  This test proves both halves:
//   1. `objectWillChange` does NOT fire synchronously within the mutation
//      window (that is the hazard the warning describes).
//   2. The change IS still delivered — just later, on the run loop.
//   3. The value is readable synchronously right after the setter, proving
//      persistence is not deferred.
//

import XCTest
import Combine
@testable import CleanMac

final class SettingsStoreChangeTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: SettingsStore!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        // A fresh, isolated defaults domain so the test never touches real
        // prefs and starts from registered defaults every run.
        suiteName = "SettingsStoreChangeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = SettingsStore(defaults: defaults)
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        store = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// `objectWillChange` must not be delivered synchronously inside a setter
    /// call — that is exactly the "publishing during view updates" hazard.
    /// It must still be delivered, asynchronously, on the run loop; and the new
    /// value must be readable synchronously the instant the setter returns.
    func testObjectWillChangeIsNotDeliveredSynchronouslyDuringMutation() {
        var firedSynchronously = false
        let asyncDelivery = expectation(description: "objectWillChange delivered asynchronously")

        var duringMutation = false
        store.objectWillChange
            .sink {
                if duringMutation {
                    firedSynchronously = true
                }
                asyncDelivery.fulfill()
            }
            .store(in: &cancellables)

        let before = store.showMenuBarExtra

        // Mutation window: anything the sink observes while this flag is true
        // was delivered synchronously inside the setter's stack — the bug.
        duringMutation = true
        store.showMenuBarExtra.toggle()
        duringMutation = false

        // Reads are synchronous: the setter persisted immediately, only the
        // notification is deferred.
        XCTAssertEqual(store.showMenuBarExtra, !before,
                       "The setter must persist synchronously; the value should be readable immediately.")

        XCTAssertFalse(firedSynchronously,
                       "objectWillChange fired synchronously inside the setter — this is the "
                       + "'Publishing changes from within view updates' hazard. It must be "
                       + "deferred to the run loop.")

        // Prove the notification is not simply lost: it still arrives, later.
        wait(for: [asyncDelivery], timeout: 1.0)
    }
}
