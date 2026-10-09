import AppKit
import CryptoKit
import Security
import VPNTimeCore

struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// Checks GitHub Releases for a newer build and installs it. Nothing is swapped
// in unless the archive matches the published sha256 digest and the unpacked
// bundle is signed by our Developer ID team.
final class Updater {
    static let teamID = "H2X8YGN869"
    static let bundleID = "com.redge.vpntimebar"
    private static let latestURL = URL(string: "https://api.github.com/repos/jash90/vpn-time/releases/latest")!
    private static let appName = "VPN Time.app"

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var currentVersion: AppVersion {
        AppVersion(currentVersionString) ?? AppVersion("0")!
    }

    // Calls back on the main thread with the update, nil when up to date, or an error.
    func check(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VPNTime/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let current = currentVersion

        session.dataTask(with: request) { data, response, error in
            let result: Result<AvailableUpdate?, Error>

            if let error {
                result = .failure(UpdateError("Brak połączenia z GitHubem: \(error.localizedDescription)"))
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(UpdateError("GitHub odpowiedział kodem \(status)."))
            } else if let data, let release = try? JSONDecoder().decode(Release.self, from: data) {
                result = .success(Update.evaluate(release: release, currentVersion: current))
            } else {
                result = .failure(UpdateError("Nie udało się odczytać odpowiedzi GitHuba."))
            }

            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // Downloads, verifies and stages the update, then hands the swap to the
    // helper and quits. Calls back on the main thread only on failure.
    func install(_ update: AvailableUpdate, failure: @escaping (Error) -> Void) {
        appLog("update: downloading \(update.tag) from \(update.downloadURL)")

        session.downloadTask(with: update.downloadURL) { [weak self] location, response, error in
            guard let self else {
                return
            }

            do {
                if let error {
                    throw UpdateError("Pobieranie nie powiodło się: \(error.localizedDescription)")
                }

                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    throw UpdateError("Pobieranie nie powiodło się (kod \(status)).")
                }

                guard let location else {
                    throw UpdateError("Pobieranie nie zwróciło pliku.")
                }

                try self.stage(update, archive: location)
            } catch {
                appLog("update: failed: \(error.localizedDescription)")
                DispatchQueue.main.async { failure(error) }
            }
        }.resume()
    }

    private func stage(_ update: AvailableUpdate, archive location: URL) throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("VPNTime-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        var handedOff = false
        defer {
            if !handedOff {
                try? fileManager.removeItem(at: work)
            }
        }

        let archive = work.appendingPathComponent(Update.assetName(tag: update.tag))
        try fileManager.moveItem(at: location, to: archive)

        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }
            .joined()

        guard digest == update.sha256 else {
            throw UpdateError("Suma kontrolna pobranego pliku się nie zgadza.")
        }

        appLog("update: sha256 ok")

        let unpacked = work.appendingPathComponent("unpacked")
        let ditto = Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        guard ditto.isEmpty else {
            throw UpdateError("Nie udało się rozpakować aktualizacji: \(ditto)")
        }

        let newApp = unpacked.appendingPathComponent(Self.appName)

        guard fileManager.fileExists(atPath: newApp.path) else {
            throw UpdateError("Archiwum nie zawiera \(Self.appName).")
        }

        try Self.verifySignature(of: newApp)
        appLog("update: signature ok (team \(Self.teamID))")

        let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        guard let newVersion, let parsed = AppVersion(newVersion), parsed > currentVersion else {
            throw UpdateError("Pobrana wersja (\(newVersion ?? "?")) nie jest nowsza od \(currentVersionString).")
        }

        let destination = Bundle.main.bundleURL

        guard fileManager.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw UpdateError("Brak uprawnień do zapisu w \(destination.deletingLastPathComponent().path).")
        }

        // The helper comes from the running bundle: an older release being
        // installed may not carry one, and the old bundle is gone after the swap.
        guard let bundledHelper = Bundle.main.url(forResource: "update-helper", withExtension: "sh") else {
            throw UpdateError("W tej kopii aplikacji brakuje update-helper.sh — zainstaluj ręcznie.")
        }

        let helper = work.appendingPathComponent("update-helper.sh")
        try fileManager.copyItem(at: bundledHelper, to: helper)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            helper.path,
            String(ProcessInfo.processInfo.processIdentifier),
            newApp.path,
            destination.path,
            work.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        handedOff = true

        appLog("update: \(currentVersionString) -> \(newVersion) staged, quitting for the swap")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?

        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("Nie udało się odczytać podpisu aktualizacji.")
        }

        let source = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?

        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("Nie udało się zbudować wymagania podpisu.")
        }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)

        guard status == errSecSuccess else {
            throw UpdateError("Aktualizacja nie jest podpisana przez zespół \(teamID) (OSStatus \(status)).")
        }
    }

    // Returns an empty string on success, otherwise the failure to report.
    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }

        let message = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return ""
        }

        return message.isEmpty ? "exit \(process.terminationStatus)" : message
    }
}
