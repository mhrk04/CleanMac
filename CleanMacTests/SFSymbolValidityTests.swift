//
//  SFSymbolValidityTests.swift
//  CleanMacTests
//
//  Guards every module icon against invalid SF Symbol names. A symbol name that
//  does not exist in the running macOS system symbol set makes
//  `NSImage(systemSymbolName:accessibilityDescription:)` return nil, AppKit logs
//  "No symbol named '…' found in system symbol set", and the icon renders as a
//  blank/fallback glyph. Because that failure is a runtime log rather than a
//  compile error, the only thing that catches it is resolving each referenced
//  name through NSImage the same way the app does at render time.
//
//  `SidebarItem` is the single source of truth for the module icons, so these
//  tests read `SidebarItem.systemImage` directly rather than duplicating the
//  string literals.
//

import XCTest
import AppKit
@testable import CleanMac

final class SFSymbolValidityTests: XCTestCase {

    /// The specific bug: the Uninstaller module icon used `app.badge.trash`,
    /// which is not a valid SF Symbol on macOS 14 and resolves to nil.
    func testUninstallerModuleIconIsAValidSymbol() {
        let name = SidebarItem.uninstaller.systemImage
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "SidebarItem.uninstaller.systemImage \"\(name)\" is not a valid system SF Symbol"
        )
    }

    /// The general guard: every module icon exposed by `SidebarItem` must
    /// resolve to a real system symbol, so a future invalid name is caught here
    /// rather than shipping as a blank glyph.
    func testAllSidebarModuleIconsAreValidSymbols() {
        for item in SidebarItem.allCases {
            let name = item.systemImage
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "SidebarItem.\(item.rawValue).systemImage \"\(name)\" is not a valid system SF Symbol"
            )
        }
    }
}
