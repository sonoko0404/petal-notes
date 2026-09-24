import XCTest
import AppKit
import Carbon
@testable import PetalChecklist

@MainActor
final class GlobalHotKeyClientTests: XCTestCase {
    private final class Registrar: HotKeyRegistrar {
        var active: HotKeyChoice?
        var registrations: [HotKeyChoice] = []
        var shouldFail = false
        func register(_ choice: HotKeyChoice, handler: @escaping @MainActor () -> Void) throws {
            registrations.append(choice)
            if shouldFail { throw HotKeyRegistrationError.conflict }
            active = choice
        }
        func unregister() { active = nil }
    }

    func testReconfigurationUnregistersOldShortcutAndSurfacesConflict() {
        let registrar = Registrar()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = GlobalHotKeyClient(registrar: registrar, defaults: defaults)
        client.configure(.optionCommandN)
        XCTAssertEqual(registrar.active, .optionCommandN)
        registrar.shouldFail = true
        client.configure(.optionCommandM)
        XCTAssertNil(registrar.active)
        XCTAssertNotNil(client.errorMessage)
        XCTAssertEqual(client.selection, .optionCommandM)
        client.configure(.off)
        XCTAssertNil(client.errorMessage)
        XCTAssertNil(registrar.active)
    }

    func testCustomShortcutCanBeRegisteredAndRestoredFromSettings() {
        let registrar = Registrar()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = GlobalHotKeyClient(registrar: registrar, defaults: defaults)
        let custom = HotKeyChoice(keyCode: 40, modifiers: 0x1100, title: "⌃⌘K")
        client.configure(custom)
        XCTAssertEqual(registrar.active, custom)
        let restored = GlobalHotKeyClient(registrar: Registrar(), defaults: defaults)
        XCTAssertEqual(restored.selection, custom)
    }

    func testRecordingTemporarilyReleasesShortcutAndCancelRestoresIt() {
        let registrar = Registrar()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = GlobalHotKeyClient(registrar: registrar, defaults: defaults)
        client.start()
        client.beginRecording()
        XCTAssertNil(registrar.active)
        client.cancelRecording()
        XCTAssertEqual(registrar.active, .optionCommandN)
    }

    func testRecordedKeyUsesCarbonModifiersAndRequiresARealModifier() {
        let recorded = HotKeyChoice.recorded(keyCode: 40, flags: [.option, .command], characters: "k")
        XCTAssertEqual(recorded, HotKeyChoice(keyCode: 40, modifiers: 0x900, title: "⌥⌘K"))
        XCTAssertNil(HotKeyChoice.recorded(keyCode: 40, flags: [.shift], characters: "k"))
    }

    func testPersistedOffIgnoresOldLocalizedTitleAndNeverRegisters() throws {
        let registrar = Registrar()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try XCTUnwrap("{\"keyCode\":0,\"modifiers\":0,\"title\":\"Off in another locale\"}".data(using: .utf8)),
                     forKey: "quickCaptureHotKey")
        let client = GlobalHotKeyClient(registrar: registrar, defaults: defaults)
        client.start()
        XCTAssertEqual(client.selection, .off)
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertEqual(HotKeyChoice(keyCode: 40, modifiers: 0x900, title: "⌥⌘K"),
                       HotKeyChoice(keyCode: 40, modifiers: 0x900, title: "Old label"))
    }

    func testCarbonHandlerIgnoresUnrelatedHotKeyIdentifiers() {
        var callbacks = 0
        let wrongSignature = EventHotKeyID(signature: 0x12345678, id: 1)
        let wrongID = EventHotKeyID(signature: 0x5054414C, id: 9)
        let matching = EventHotKeyID(signature: 0x5054414C, id: 1)
        XCTAssertEqual(CarbonHotKeyRegistrar.dispatch(wrongSignature) { callbacks += 1 }, OSStatus(eventNotHandledErr))
        XCTAssertEqual(CarbonHotKeyRegistrar.dispatch(wrongID) { callbacks += 1 }, OSStatus(eventNotHandledErr))
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(CarbonHotKeyRegistrar.dispatch(matching) { callbacks += 1 }, noErr)
        XCTAssertEqual(callbacks, 1)
    }
}
