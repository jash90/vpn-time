import XCTest
@testable import VPNTimeCore

final class UpdateTests: XCTestCase {
    private let digest = "sha256:0661f25ced3393f3be783490f19aa04ebd4aa79b37b672693cb6d875741af569"

    private func release(
        tag: String = "v1.3.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = nil,
        digest: String?? = nil
    ) throws -> Release {
        let name = assetName ?? "VPN-Time-\(tag).zip"
        let digestValue = digest ?? self.digest
        let digestJSON = digestValue.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/jash90/vpn-time/releases/tag/\(tag)",
          "body": "notes",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "assets": [{
            "name": "\(name)",
            "browser_download_url": "https://github.com/jash90/vpn-time/releases/download/\(tag)/\(name)",
            "size": 243332,
            "digest": \(digestJSON)
          }]
        }
        """
        return try JSONDecoder().decode(Release.self, from: Data(json.utf8))
    }

    private let current = AppVersion("1.2.0")!

    func testParsesVersions() {
        XCTAssertEqual(AppVersion("v1.2.0")?.description, "1.2.0")
        XCTAssertEqual(AppVersion("1.2")?.description, "1.2.0")
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("1.x.0"))
        XCTAssertNil(AppVersion("1..0"))
        XCTAssertNil(AppVersion("1.2.0-beta"))
    }

    func testComparesVersionsNumerically() {
        XCTAssertGreaterThan(AppVersion("1.10.0")!, AppVersion("1.9.0")!)
        XCTAssertGreaterThan(AppVersion("2.0")!, AppVersion("1.99.99")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("v1.2.0")!)
        XCTAssertEqual(AppVersion("1.2.0.0")!, AppVersion("1.2.0")!)
        XCTAssertGreaterThan(AppVersion("1.2.0.1")!, AppVersion("1.2.0")!)
    }

    func testOffersANewerRelease() throws {
        let update = try XCTUnwrap(Update.evaluate(release: release(), currentVersion: current))

        XCTAssertEqual(update.version, AppVersion("1.3.0"))
        XCTAssertEqual(update.tag, "v1.3.0")
        XCTAssertEqual(update.sha256, "0661f25ced3393f3be783490f19aa04ebd4aa79b37b672693cb6d875741af569")
        XCTAssertEqual(update.downloadURL.lastPathComponent, "VPN-Time-v1.3.0.zip")
        XCTAssertEqual(update.notes, "notes")
    }

    func testIgnoresTheSameOrAnOlderRelease() throws {
        XCTAssertNil(Update.evaluate(release: try release(tag: "v1.2.0"), currentVersion: current))
        XCTAssertNil(Update.evaluate(release: try release(tag: "v1.1.1"), currentVersion: current))
    }

    func testIgnoresDraftsAndPrereleases() throws {
        XCTAssertNil(Update.evaluate(release: try release(draft: true), currentVersion: current))
        XCTAssertNil(Update.evaluate(release: try release(prerelease: true), currentVersion: current))
    }

    func testIgnoresAReleaseWithoutTheAppArchive() throws {
        XCTAssertNil(Update.evaluate(release: try release(assetName: "Source.zip"), currentVersion: current))
    }

    func testIgnoresAnArchiveWithoutAUsableDigest() throws {
        XCTAssertNil(Update.evaluate(release: try release(digest: .some(nil)), currentVersion: current))
        XCTAssertNil(Update.evaluate(release: try release(digest: "md5:abc"), currentVersion: current))
        XCTAssertNil(Update.evaluate(release: try release(digest: "sha256:1234"), currentVersion: current))
    }

    func testIgnoresAnUnparseableTag() throws {
        XCTAssertNil(Update.evaluate(release: try release(tag: "latest"), currentVersion: current))
    }

    func testCheckIsDueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(Update.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(Update.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(Update.isDue(lastCheck: now.addingTimeInterval(-Update.checkInterval), now: now))
        XCTAssertTrue(Update.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
