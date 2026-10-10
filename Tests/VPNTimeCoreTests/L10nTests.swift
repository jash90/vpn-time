import Foundation
import XCTest
@testable import VPNTimeCore

// The .strings tables shipped in the app bundle (bundle/Resources/*.lproj).
enum StringsTables {
    static let languages = ["en", "pl"]

    static func url(_ language: String, _ file: String = "Localizable") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bundle/Resources/\(language).lproj/\(file).strings")
    }

    static func load(_ language: String, _ file: String = "Localizable") -> [String: String] {
        (NSDictionary(contentsOf: url(language, file)) as? [String: String]) ?? [:]
    }
}

final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.table = nil
        super.tearDown()
    }

    func testTablesParseAndAreNotEmpty() {
        for language in StringsTables.languages {
            XCTAssertGreaterThan(StringsTables.load(language).count, 50, language)
            XCTAssertFalse(StringsTables.load(language, "InfoPlist").isEmpty, language)
        }
    }

    func testEveryLanguageHasTheSameKeys() {
        let english = Set(StringsTables.load("en").keys)

        for language in StringsTables.languages {
            let keys = Set(StringsTables.load(language).keys)
            XCTAssertEqual(keys.subtracting(english).sorted(), [], "\(language) has extra keys")
            XCTAssertEqual(english.subtracting(keys).sorted(), [], "\(language) is missing keys")
            XCTAssertEqual(
                Set(StringsTables.load(language, "InfoPlist").keys),
                Set(StringsTables.load("en", "InfoPlist").keys),
                "\(language) InfoPlist.strings keys"
            )
        }
    }

    // A translation with a different set of placeholders would crash or
    // print garbage in String(format:).
    func testTranslationsKeepThePlaceholders() throws {
        let pattern = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:@|ld|d)")
        func placeholders(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            let found = pattern.matches(in: text, range: range).map { (text as NSString).substring(with: $0.range) }
            // Positional (%2$@) and plain (%@) forms are equivalent in count and type.
            return found.map { $0.replacingOccurrences(of: "[0-9]+\\$", with: "", options: .regularExpression) }.sorted()
        }

        let english = StringsTables.load("en")

        for language in StringsTables.languages {
            for (key, value) in StringsTables.load(language) {
                XCTAssertEqual(placeholders(value), placeholders(english[key] ?? ""), "\(language): \(key)")
            }
        }
    }

    func testEverySourceKeyExistsInTheTables() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: "\\bL\\(\\s*\"([^\"]+)\"")
        let english = StringsTables.load("en")
        var used = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)

        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }

        XCTAssertGreaterThan(used.count, 50)
        XCTAssertEqual(used.subtracting(english.keys).sorted(), [], "keys used in Sources but missing from en.lproj")
        XCTAssertEqual(Set(english.keys).subtracting(used).sorted(), [], "unused keys in en.lproj")
    }

    func testFormatsArgumentsFromTheTable() {
        L10n.table = StringsTables.load("en")
        XCTAssertEqual(L("menu.connected", "Office", "08:00"), "● Connected (Office) since 08:00")

        L10n.table = StringsTables.load("pl")
        XCTAssertEqual(L("menu.connected", "Office", "08:00"), "● Połączony (Office) od 08:00")
        XCTAssertEqual(L("update.error.status", 404), "GitHub odpowiedział kodem 404.")
    }

    func testMissingKeyFallsBackToTheKey() {
        L10n.table = nil
        XCTAssertEqual(L("no.such.key"), "no.such.key")
    }
}
