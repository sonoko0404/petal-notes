import AppKit
import Carbon
import Foundation
import Observation

struct HotKeyChoice: Codable, Hashable, Identifiable {
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String
    var id: String { "\(keyCode)-\(modifiers)" }
    static let optionCommandN = Self(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey | cmdKey), title: "⌥⌘N")
    static let optionCommandM = Self(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | cmdKey), title: "⌥⌘M")
    static let shiftCommandN = Self(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(shiftKey | cmdKey), title: "⇧⌘N")
    static let off = Self(keyCode: 0, modifiers: 0, title: String(localized: "Off"))
    static let allCases = [optionCommandN, optionCommandM, shiftCommandN, off]

    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> Self? {
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        let letter = characters.uppercased()
        guard letter.count == 1, letter.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
        var modifiers: UInt32 = 0
        var title = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); title += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); title += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); title += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); title += "⌘" }
        return Self(keyCode: UInt32(keyCode), modifiers: modifiers, title: title + letter)
    }
}

enum HotKeyRegistrationError: LocalizedError {
    case conflict
    var errorDescription: String? {
        String(localized: "This shortcut is unavailable. Choose another shortcut or turn it off.")
    }
}

@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(_ choice: HotKeyChoice, handler: @escaping @MainActor () -> Void) throws
    func unregister()
}

@MainActor @Observable
final class GlobalHotKeyClient {
    private let registrar: any HotKeyRegistrar
    private let defaults: UserDefaults
    private let key = "quickCaptureHotKey"
    private(set) var selection: HotKeyChoice
    private(set) var errorMessage: String?
    @ObservationIgnored var onPress: (@MainActor () -> Void)?

    init(registrar: any HotKeyRegistrar, defaults: UserDefaults = .standard) {
        self.registrar = registrar
        self.defaults = defaults
        selection = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HotKeyChoice.self, from: $0) } ?? .optionCommandN
    }

    func start() { configure(selection) }

    func beginRecording() {
        registrar.unregister()
        errorMessage = nil
    }

    func cancelRecording() { configure(selection) }

    func configure(_ choice: HotKeyChoice) {
        registrar.unregister()
        selection = choice
        defaults.set(try? JSONEncoder().encode(choice), forKey: key)
        errorMessage = nil
        guard choice != .off else { return }
        do {
            try registrar.register(choice) { [weak self] in self?.onPress?() }
        } catch {
            errorMessage = HotKeyRegistrationError.conflict.localizedDescription
        }
    }
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (@MainActor () -> Void)?

    func register(_ choice: HotKeyChoice, handler: @escaping @MainActor () -> Void) throws {
        unregister()
        callback = handler
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { registrar.callback?() }
            return noErr
        }, 1, &type, context, &eventHandler)
        guard installed == noErr else {
            callback = nil
            throw HotKeyRegistrationError.conflict
        }
        let identifier = EventHotKeyID(signature: 0x5054414C, id: 1)
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            unregister()
            throw HotKeyRegistrationError.conflict
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        callback = nil
    }

    deinit {
        MainActor.assumeIsolated { unregister() }
    }
}
