import AppKit
import Carbon

extension NSEvent {
    /// The characters a shortcut names, whatever the input source.
    ///
    /// A non-Latin source reports a key as its own letter even with ⌘ held: under
    /// 두벌식 the T key arrives as "ㅅ", so a `"t"` shortcut never matches and the key
    /// falls through to the terminal. Such a key is read again through the source's
    /// ASCII-capable layout, which is where ⌃⌘T is T.
    var shortcutCharacters: String? {
        guard let characters = charactersIgnoringModifiers else { return nil }
        guard !characters.allSatisfy(\.isASCII) else { return characters }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return characters }

        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var translated = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return OSStatus(paramErr) }

            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                translated.count,
                &length,
                &translated)
        }

        guard status == noErr, length > 0 else { return characters }

        return String(utf16CodeUnits: translated, count: length)
    }
}
