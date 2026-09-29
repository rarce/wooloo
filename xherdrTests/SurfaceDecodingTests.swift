import XCTest
@testable import xherdr

/// The decoder must reproduce every cell, color, attribute and cursor position Herdr sends.
final class SurfaceDecodingTests: XCTestCase {
    func testCompleteSurfaceRoundTrips() throws {
        let workload = TerminalWorkload.colorScroll(width: 80, height: 24, frames: 1)
        var decoder = HerdrSurfaceDecoder()
        let surface = try XCTUnwrap(decoder.apply(frame: workload.frames[0]))
        let expected = workload.final.surface
        XCTAssertEqual(surface.cells, expected.cells)
        XCTAssertEqual(surface.cursor, expected.cursor)
        XCTAssertEqual(surface.paneRects, expected.paneRects)
        XCTAssertEqual(surface.paneInnerRects, expected.paneInnerRects)
        XCTAssertEqual(surface.contentDigest, workload.digests[0])
    }

    /// After every frame of every workload the app's decoder and the reference decoder show
    /// the expected screen.
    func testEveryFrameMatchesExpectedScreen() throws {
        for workload in TerminalWorkload.all(width: 100, height: 30, frames: 40) {
            var decoder = HerdrSurfaceDecoder()
            var reference = ReferenceSurfaceDecoder()
            for (index, frame) in workload.frames.enumerated() {
                let surface = try XCTUnwrap(decoder.apply(frame: frame), "\(workload.name) frame \(index)")
                let expected = try XCTUnwrap(reference.apply(frame))
                XCTAssertEqual(expected.contentDigest, workload.digests[index],
                               "reference decoder disagrees with the fixture: \(workload.name) frame \(index)")
                XCTAssertEqual(surface.contentDigest, workload.digests[index], "\(workload.name) frame \(index)")
            }
            XCTAssertEqual(decoder.surface?.cells, workload.final.cells, workload.name)
            XCTAssertEqual(decoder.surface?.cursor, workload.final.cursor, workload.name)
        }
    }

    /// A patch must never land on a revision other than its base; that would silently corrupt
    /// the screen instead of forcing a reconnect.
    func testPatchOnWrongBaseIsRejected() throws {
        let workload = TerminalWorkload.typing(width: 40, height: 10, frames: 3)
        var decoder = HerdrSurfaceDecoder()
        _ = try decoder.apply(frame: workload.frames[0])
        XCTAssertThrowsError(try decoder.apply(frame: workload.frames[2]))
    }

    func testPatchWithoutSurfaceIsRejected() {
        let workload = TerminalWorkload.typing(width: 40, height: 10, frames: 2)
        var decoder = HerdrSurfaceDecoder()
        XCTAssertThrowsError(try decoder.apply(frame: workload.frames[1]))
    }

    func testDigestNoticesSingleCellChanges() {
        var model = SurfaceModel(width: 10, height: 2)
        let original = model.surface.contentDigest
        model.cells[13] = HerdrCell(symbol: " ", foreground: 0, background: 0, modifier: 1, skip: false)
        XCTAssertNotEqual(model.surface.contentDigest, original)
        model.cells[13] = SurfaceModel.blank
        model.cursor = HerdrCursor(x: 1, y: 0, visible: true, shape: 0)
        XCTAssertNotEqual(model.surface.contentDigest, original)
    }
}

/// Replays a trace recorded from a live session (`XHERDR_SURFACE_TRACE`) and, when given the
/// same run's metrics (`XHERDR_METRICS_FILE`), checks that every drawn revision showed exactly
/// what Herdr sent and that the last frame received was drawn. `scripts/terminal-e2e.sh` runs
/// it; without those variables it is skipped.
final class SurfaceTraceReplayTests: XCTestCase {
    func testRecordedTraceMatchesReferenceAndDrawnScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let tracePath = environment["XHERDR_REPLAY_TRACE"], !tracePath.isEmpty else {
            throw XCTSkip("Set XHERDR_REPLAY_TRACE to replay a recorded surface trace")
        }
        let frames = try TerminalSurfaceTraceRecorder.frames(in: Data(contentsOf: URL(fileURLWithPath: tracePath)))
        XCTAssertFalse(frames.isEmpty, "the trace holds no surface frames")

        var decoder = HerdrSurfaceDecoder()
        var reference = ReferenceSurfaceDecoder()
        var digests: [String: UInt64] = [:]
        var lastKey: String?
        var mismatches = 0
        func key(_ boot: String, _ projection: UInt64, _ revision: UInt64) -> String { "\(boot)#\(projection)#\(revision)" }
        for (index, frame) in frames.enumerated() {
            // A reconnect starts over with a complete surface, which both decoders accept.
            let expected = try reference.apply(frame.payload)
            let actual = try decoder.apply(frame: frame.payload)
            guard let expected, let actual else { continue }
            if expected.contentDigest != actual.contentDigest {
                mismatches += 1
                if mismatches <= 5 { XCTFail("frame \(index) revision \(expected.revision) decodes differently") }
            }
            lastKey = key(expected.bootID, expected.projectionRevision, expected.revision)
            digests[lastKey!] = expected.contentDigest
        }
        XCTAssertEqual(mismatches, 0, "frames the app decoded differently from the reference")

        guard let metricsPath = environment["XHERDR_REPLAY_METRICS"], !metricsPath.isEmpty else { return }
        let lines = try String(contentsOfFile: metricsPath, encoding: .utf8).split(separator: "\n")
        var checked = 0
        var drawn = Set<String>()
        for line in lines {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["e"] as? String == "draw",
                  let boot = object["boot"] as? String,
                  let projection = (object["proj"] as? NSNumber)?.uint64Value,
                  let revision = (object["rev"] as? NSNumber)?.uint64Value else { continue }
            let drawnKey = key(boot, projection, revision)
            drawn.insert(drawnKey)
            guard let digest = object["digest"] as? String else { continue }
            guard let expected = digests[drawnKey] else {
                XCTFail("drew revision \(drawnKey), which the trace never received")
                continue
            }
            XCTAssertEqual(digest, String(expected, radix: 16), "revision \(drawnKey) was drawn with different content")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "the metrics file holds no drawn digests")
        if let lastKey { XCTAssertTrue(drawn.contains(lastKey), "the last revision received, \(lastKey), was never drawn") }
    }
}
