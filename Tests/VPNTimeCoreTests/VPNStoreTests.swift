import XCTest
@testable import VPNTimeCore

final class VPNStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(csv: String? = nil, state: String? = nil) throws -> VPNStore {
        let csvURL = dir.appendingPathComponent("sessions.csv")
        let stateURL = dir.appendingPathComponent("sessions.state")

        if let csv {
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        }

        if let state {
            try state.write(to: stateURL, atomically: true, encoding: .utf8)
        }

        return VPNStore(csvPath: csvURL.path, statePath: stateURL.path)
    }

    func testParsesRowsAndSkipsHeader() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
        2026-07-08 07:43:15,2026-07-08 16:26:34,31399,Office_VPN_bartlomiej_zimny
        """
        let sessions = try store(csv: csv).sessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].duration, 839)
        XCTAssertEqual(sessions[1].duration, 31399)
    }

    func testParsesStartInLocalTime() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        2026-07-08 07:27:37,2026-07-08 07:41:36,839,Office_VPN_bartlomiej_zimny
        """
        let sessions = try store(csv: csv).sessions()

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 8
        components.hour = 7
        components.minute = 27
        components.second = 37
        components.timeZone = .current
        let expected = Calendar.vpnTimeISO.date(from: components)

        XCTAssertEqual(sessions[0].start, expected)
    }

    func testSkipsMalformedRows() throws {
        let csv = """
        start_iso,end_iso,duration_s,config
        not-a-date,2026-07-08 07:41:36,839,Office
        2026-07-08 07:43:15,2026-07-08 16:26:34,notanumber,Office
        2026-07-08 07:43:15,2026-07-08 16:26:34,31399,Office
        """
        XCTAssertEqual(try store(csv: csv).sessions().count, 1)
    }

    func testMissingCSVYieldsNoSessions() throws {
        XCTAssertTrue(try store().sessions().isEmpty)
    }

    func testReadsActiveSessionFromStateFile() throws {
        let subject = try store(state: "1789019070\tOffice_VPN_bartlomiej_zimny\n")
        let active = subject.activeSession()

        XCTAssertEqual(active?.0, Date(timeIntervalSince1970: 1789019070))
        XCTAssertEqual(active?.1, "Office_VPN_bartlomiej_zimny")
    }

    func testNoActiveSessionWhenStateFileMissing() throws {
        XCTAssertNil(try store().activeSession())
    }

    func testNoActiveSessionWhenStateFileMalformed() throws {
        XCTAssertNil(try store(state: "garbage\n").activeSession())
    }
}
