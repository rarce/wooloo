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

/// Surfaces that arrive while the main thread is busy collapse into the newest one, and the
/// newest one always reaches the view.
@MainActor
final class SurfaceDeliveryTests: XCTestCase {
    private func surface(_ revision: UInt64) -> HerdrSurface {
        var model = SurfaceModel(width: 4, height: 2)
        model.revision = revision
        return model.surface
    }

    func testMailboxWakesOnceAndKeepsNewest() {
        let mailbox = HerdrSurfaceMailbox()
        XCTAssertTrue(mailbox.put(surface(1)), "the first surface wakes the main thread")
        XCTAssertFalse(mailbox.put(surface(2)), "a pending wake-up already covers later surfaces")
        XCTAssertFalse(mailbox.put(surface(3)))
        XCTAssertEqual(mailbox.take()?.revision, 3)
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.put(surface(4)), "a surface after the take wakes the main thread again")
    }

    func testFeedDeliversToLiveObserverOnly() {
        let feed = HerdrSurfaceFeed()
        var received: [UInt64] = []
        var owner: NSObject? = NSObject()
        feed.observe(owner!) { received.append($0?.revision ?? 0) }
        feed.publish(surface(1))
        owner = nil
        feed.publish(surface(2))
        XCTAssertEqual(received, [1])
        XCTAssertEqual(feed.surface?.revision, 2)
    }
}

/// OSC 8 hyperlinks survive decoding and patches, and links are found for Command-click.
final class TerminalLinkTests: XCTestCase {
    private func model(_ rows: [RowBuilder], width: Int) -> SurfaceModel {
        var model = SurfaceModel(width: width, height: rows.count)
        for (y, row) in rows.enumerated() { model.setRow(y, row.cells) }
        return model
    }

    func testHyperlinksDecodeAndSurvivePatches() throws {
        var row = RowBuilder(width: 20)
        row.put("see ")
        row.put("docs", hyperlink: 0)
        var model = model([row, RowBuilder(width: 20)], width: 20)
        model.hyperlinks = ["https://herdr.dev/docs"]
        var decoder = HerdrSurfaceDecoder()
        var reference = ReferenceSurfaceDecoder()
        let full = model.surfaceFrame()
        let surface = try XCTUnwrap(decoder.apply(frame: full))
        XCTAssertEqual(surface, model.surface)
        XCTAssertEqual(try reference.apply(full), model.surface)

        var typed = RowBuilder(width: 20)
        typed.put("$ ls")
        model.setRow(1, typed.cells)
        model.revision = 2
        let patched = try XCTUnwrap(decoder.apply(frame: model.patchFrame(baseRevision: 1, rows: [1])))
        XCTAssertEqual(patched.hyperlinks, ["https://herdr.dev/docs"])
        XCTAssertEqual(patched.cells[4].hyperlink, 0)
    }

    func testExplicitLinksCoverTheirCellsAcrossRows() throws {
        var first = RowBuilder(width: 10)
        first.put("go ")
        first.put("somewhere", hyperlink: 1)
        var second = RowBuilder(width: 10)
        second.put("else", hyperlink: 1)
        second.put(" ok")
        var model = model([first, second], width: 10)
        model.hyperlinks = ["https://a.example", "https://b.example/path"]
        let link = try XCTUnwrap(TerminalLinks.link(atColumn: 1, row: 1, in: model.surface))
        XCTAssertEqual(link.url.absoluteString, "https://b.example/path")
        XCTAssertEqual(link.spans, [.init(row: 0, columns: 3..<10), .init(row: 1, columns: 0..<4)])
        XCTAssertNil(TerminalLinks.link(atColumn: 1, row: 0, in: model.surface))
    }

    func testOnlyWebHyperlinksOpen() {
        var row = RowBuilder(width: 20)
        row.put("run me", hyperlink: 0)
        var model = model([row], width: 20)
        model.hyperlinks = ["file:///Applications/Calculator.app"]
        XCTAssertNil(TerminalLinks.link(atColumn: 2, row: 0, in: model.surface))
    }

    func testPlainURLsAreFoundWithoutTrailingPunctuation() throws {
        var row = RowBuilder(width: 60)
        row.put("Read (https://en.wikipedia.org/wiki/Foo_(bar)), then.")
        let surface = model([row], width: 60).surface
        let link = try XCTUnwrap(TerminalLinks.link(atColumn: 10, row: 0, in: surface))
        XCTAssertEqual(link.url.absoluteString, "https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(link.spans, [.init(row: 0, columns: 6..<45)])
        XCTAssertNil(TerminalLinks.link(atColumn: 2, row: 0, in: surface))
        XCTAssertNil(TerminalLinks.link(atColumn: 46, row: 0, in: surface))
    }

    func testWrappedPlainURLsAreFoundWhole() throws {
        var first = RowBuilder(width: 12)
        first.put("x https://ex")
        var second = RowBuilder(width: 12)
        second.put("ample.com/a b")
        let surface = model([first, second], width: 12).surface
        let link = try XCTUnwrap(TerminalLinks.link(atColumn: 3, row: 1, in: surface))
        XCTAssertEqual(link.url.absoluteString, "https://example.com/a")
        XCTAssertEqual(link.spans, [.init(row: 0, columns: 2..<12), .init(row: 1, columns: 0..<11)])
    }
}
