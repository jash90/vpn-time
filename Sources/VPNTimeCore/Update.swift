import Foundation

public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    // Accepts "1.2.0", "v1.2.0" and "1.2"; missing segments count as 0.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }

        let segments = text.split(separator: ".", omittingEmptySubsequences: false)

        guard !segments.isEmpty, segments.count <= 4 else {
            return nil
        }

        var parts: [Int] = []

        for segment in segments {
            guard !segment.isEmpty, segment.allSatisfy(\.isASCII), let value = Int(segment), value >= 0 else {
                return nil
            }

            parts.append(value)
        }

        while parts.count < 3 {
            parts.append(0)
        }

        self.parts = parts
    }

    public var description: String {
        parts.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.padded(to: rhs) == rhs.padded(to: lhs)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.padded(to: rhs).lexicographicallyPrecedes(rhs.padded(to: lhs))
    }

    private func padded(to other: AppVersion) -> [Int] {
        parts + Array(repeating: 0, count: max(0, other.parts.count - parts.count))
    }
}

// The subset of the GitHub "latest release" response the updater reads.
public struct Release: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    public let tagName: String
    public let htmlURL: URL?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
        case assets
    }
}

public struct AvailableUpdate: Equatable {
    public let version: AppVersion
    public let tag: String
    public let downloadURL: URL
    public let size: Int
    public let sha256: String
    public let notes: String
    public let pageURL: URL?
}

public enum Update {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public static func assetName(tag: String) -> String {
        "VPN-Time-\(tag).zip"
    }

    // An update is offered only for a newer, published release whose archive
    // carries a sha256 digest: nothing unverifiable is ever installed.
    public static func evaluate(release: Release, currentVersion: AppVersion) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tagName), version > currentVersion,
              let asset = release.assets.first(where: { $0.name == assetName(tag: release.tagName) }),
              let sha256 = sha256(fromDigest: asset.digest) else {
            return nil
        }

        return AvailableUpdate(
            version: version,
            tag: release.tagName,
            downloadURL: asset.browserDownloadURL,
            size: asset.size,
            sha256: sha256,
            notes: release.body ?? "",
            pageURL: release.htmlURL
        )
    }

    public static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else {
            return nil
        }

        let hex = digest.dropFirst("sha256:".count).lowercased()

        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        return hex
    }

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else {
            return true
        }

        // A clock moved backwards must not block checks for good.
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }
}
