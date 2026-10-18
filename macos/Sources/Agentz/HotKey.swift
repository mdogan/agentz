// A key that works in every app, like Ghostty's `global:` keybinds. Ghostty
// watches all key presses for them, which needs the Accessibility
// permission; a Carbon hot key needs none.

import AgentzCore
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Nil if no key on this keyboard is `trigger`'s, or macOS refused it.
    init?(_ trigger: KeyTrigger, action: @escaping () -> Void) {
        self.action = action
        guard let code = keyCode(trigger.key) else { return nil }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Carbon calls it on the main thread, for this app's only hot key.
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            guard let me else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(me).takeUnretainedValue().action() }
            return noErr
        }, 1, &pressed, me, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x6167_7A71), id: 1) // "agzq"
        guard RegisterEventHotKey(UInt32(code), carbonModifiers(trigger.modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
        else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    /// What a menu item shows for `trigger`: the character its key types
    /// on this keyboard. Nil for keys like F12 or space, which the menu
    /// does not show as text.
    static func menuKey(_ trigger: KeyTrigger) -> String? {
        guard let code = keyCode(trigger.key), let text = typed(by: code) else { return nil }
        let printable = text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
                && !(0xF700 ... 0xF8FF).contains($0.value)
        }
        return printable ? text : nil
    }
}

private func carbonModifiers(_ m: KeyTrigger.Modifiers) -> UInt32 {
    var flags = 0
    if m.contains(.command) { flags |= cmdKey }
    if m.contains(.shift) { flags |= shiftKey }
    if m.contains(.option) { flags |= optionKey }
    if m.contains(.control) { flags |= controlKey }
    return UInt32(flags)
}

/// The key code of Ghostty's key `name`. A named key is the one in that
/// place on a U.S. keyboard; a character is the key that types it here.
private func keyCode(_ name: String) -> Int? {
    if let code = namedKeys[name] { return code }
    if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1 ... 20).contains(n) { return functionKeys[n - 1] }
    guard name.count == 1, let layout = keyboardLayout() else { return nil }
    return (0 ..< 128).first { typed(by: $0, in: layout) == name }
}

/// What key `code` types without modifiers, lowercased.
private func typed(by code: Int) -> String? {
    keyboardLayout().flatMap { typed(by: code, in: $0) }
}

private func typed(by code: Int, in layout: CFData) -> String? {
    guard let bytes = CFDataGetBytePtr(layout) else { return nil }
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
        UCKeyTranslate(
            $0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars
        )
    }
    guard status == noErr, length > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: length).lowercased()
}

/// The current keyboard layout, or an ASCII one when the current input
/// method has none of its own (e.g. Japanese).
private func keyboardLayout() -> CFData? {
    let layout = { (source: TISInputSource) -> CFData? in
        TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            .map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
    }
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(), let data = layout(source) {
        return data
    }
    guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    return layout(ascii)
}

private let functionKeys = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
]

/// Ghostty's key names, the W3C ones and the older ones, by key code.
private let namedKeys: [String: Int] = {
    var keys: [String: Int] = [
        "backquote": kVK_ANSI_Grave, "grave_accent": kVK_ANSI_Grave,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        "bracket_left": kVK_ANSI_LeftBracket, "left_bracket": kVK_ANSI_LeftBracket,
        "bracket_right": kVK_ANSI_RightBracket, "right_bracket": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon,
        "quote": kVK_ANSI_Quote, "apostrophe": kVK_ANSI_Quote,
        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
        "intl_backslash": kVK_ISO_Section,
        "space": kVK_Space, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "insert": kVK_Help,
        "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "page_down": kVK_PageDown,
        "arrow_up": kVK_UpArrow, "up": kVK_UpArrow, "arrow_down": kVK_DownArrow, "down": kVK_DownArrow,
        "arrow_left": kVK_LeftArrow, "left": kVK_LeftArrow, "arrow_right": kVK_RightArrow, "right": kVK_RightArrow,
    ]
    let letters = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
        kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
        keys["key_\(letter)"] = code
    }
    let digits = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    let pad = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]
    let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    for n in 0 ..< 10 {
        keys["digit_\(n)"] = digits[n]
        keys[words[n]] = digits[n]
        keys["numpad_\(n)"] = pad[n]
        keys["kp_\(n)"] = pad[n]
    }
    let padKeys = [
        ("add", kVK_ANSI_KeypadPlus), ("subtract", kVK_ANSI_KeypadMinus), ("multiply", kVK_ANSI_KeypadMultiply),
        ("divide", kVK_ANSI_KeypadDivide), ("decimal", kVK_ANSI_KeypadDecimal), ("enter", kVK_ANSI_KeypadEnter),
        ("equal", kVK_ANSI_KeypadEquals),
    ]
    for (name, code) in padKeys {
        keys["numpad_\(name)"] = code
        keys["kp_\(name)"] = code
    }
    return keys
}()
