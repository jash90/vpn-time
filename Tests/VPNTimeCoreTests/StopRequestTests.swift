import XCTest
@testable import VPNTimeCore

final class StopRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let closed = [Session(start: Date(timeIntervalSince1970: 1_799_990_000), duration: 600)]

    func testTheNamedActiveSessionCountsAsFinishedAtTheRequestedEnd() {
        let stop = StopRequest(sessionStart: start, end: start.addingTimeInterval(3600))
        let settled = StopRequest.settle(sessions: closed, active: (start, "Office_VPN"), stop: stop)

        XCTAssertNil(settled.active)
        XCTAssertEqual(settled.sessions.count, 2)
        XCTAssertEqual(settled.sessions.last?.start, start)
        XCTAssertEqual(settled.sessions.last?.duration, 3600)
    }

    func testARequestForAnotherSessionChangesNothing() {
        let stop = StopRequest(sessionStart: start.addingTimeInterval(-86400), end: start)
        let settled = StopRequest.settle(sessions: closed, active: (start, "Office_VPN"), stop: stop)

        XCTAssertEqual(settled.active?.0, start)
        XCTAssertEqual(settled.sessions.count, 1)
    }

    func testAnEndAtTheStartDropsTheSession() {
        let stop = StopRequest(sessionStart: start, end: start)
        let settled = StopRequest.settle(sessions: closed, active: (start, "Office_VPN"), stop: stop)

        XCTAssertNil(settled.active)
        XCTAssertEqual(settled.sessions.count, 1)
    }

    func testSessionsMatchOnWholeSeconds() {
        XCTAssertTrue(StopRequest(sessionStart: start, end: start).names(start.addingTimeInterval(0.4)))
        XCTAssertFalse(StopRequest(sessionStart: start, end: start).names(start.addingTimeInterval(1)))
    }

    func testStoreWritesReadsAndClearsTheRequest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("sessions.stop").path
        let store = VPNStore(
            csvPath: dir.appendingPathComponent("sessions.csv").path,
            statePath: dir.appendingPathComponent("sessions.state").path,
            stopPath: path
        )
        let request = StopRequest(sessionStart: start, end: start.addingTimeInterval(1800))

        XCTAssertNil(store.stopRequest())
        store.requestStop(request)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "1800000000\t1800001800\n")
        XCTAssertEqual(store.stopRequest(), request)
        store.clearStopRequest()
        XCTAssertNil(store.stopRequest())
    }

    func testStoreReadsAStateFileWithLastSeen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = dir.appendingPathComponent("sessions.state")
        try "1800000000\tOffice_VPN\t1800003600\n".write(to: state, atomically: true, encoding: .utf8)
        let active = VPNStore(csvPath: dir.appendingPathComponent("sessions.csv").path, statePath: state.path)
            .activeSession()

        XCTAssertEqual(active?.0, start)
        XCTAssertEqual(active?.1, "Office_VPN")
    }
}
