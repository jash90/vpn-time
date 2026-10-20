import Foundation

// UI strings. The tables live in bundle/Resources/<language>.lproj and are
// copied into the app bundle by build.sh. English is the development region
// and the fallback; Polish is used when it is the user's preferred language.
public enum L10n {
    // Overrides the bundle lookup; tests set it to a parsed .strings table.
    public static var table: [String: String]?

    public static var bundle: Bundle = .main

    public static func string(_ key: String, _ args: [CVarArg]) -> String {
        let format = table?[key] ?? bundle.localizedString(forKey: key, value: nil, table: nil)

        guard !args.isEmpty else {
            return format
        }

        return String(format: format, locale: Locale.current, arguments: args)
    }
}

// Shorthand: L("menu.version", version).
public func L(_ key: String, _ args: CVarArg...) -> String {
    L10n.string(key, args)
}
