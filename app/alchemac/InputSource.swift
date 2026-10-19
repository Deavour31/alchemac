import Carbon.HIToolbox
import Foundation

// Some .NET programs run with globalization-invariant mode. When Wine reports a
// non-English keyboard layout (the Mac's 2-Set Korean becomes 0x0412), WinForms
// builds a CultureInfo for it and the program stops with an unhandled exception.
// Add-ons for such programs ask for an English input source before starting.
enum EnglishInput {
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
    }

    private static func isEnglish(_ source: TISInputSource) -> Bool { languages(source).first == "en" }

    /// Returns the name of the source selected, or nil when nothing changed.
    static func ensure() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if isEnglish(current) { return nil }
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        let english = list.filter(isEnglish)
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        let choice = preferred.lazy.compactMap { id in english.first { string($0, kTISPropertyInputSourceID) == id } }.first
            ?? english.first
        guard let choice, TISSelectInputSource(choice) == noErr else { return nil }
        return string(choice, kTISPropertyLocalizedName) ?? "영문"
    }
}
