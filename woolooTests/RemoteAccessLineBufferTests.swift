import XCTest
import os
@testable import wooloo

final class RemoteAccessLineBufferTests: XCTestCase {
    func testUTF8CodePointsCanSpanEveryReadBoundary() {
        let buffer = RemoteAccessLineBuffer()
        let input = "hé👩‍💻\n汉字\nlasté"
        var lines: [String] = []
        for byte in input.utf8 { lines += buffer.append(Data([byte])) }
        XCTAssertEqual(lines, ["hé👩‍💻", "汉字"])
        XCTAssertEqual(buffer.finish(), ["lasté"])
    }

    func testFragmentedLinesKeepOnlyTheUnterminatedTail() {
        let buffer = RemoteAccessLineBuffer()
        XCTAssertEqual(buffer.append(Data("fir".utf8)), [])
        XCTAssertEqual(buffer.append(Data("st\nsecond\nthi".utf8)), ["first", "second"])
        XCTAssertEqual(buffer.append(Data("rd\nlast".utf8)), ["third"])
        XCTAssertEqual(buffer.finish(), ["last"])
    }

    func testBlankLinesArePreservedWithoutInventingATrailingLine() {
        let buffer = RemoteAccessLineBuffer()
        XCTAssertEqual(buffer.append(Data()), [])
        XCTAssertEqual(buffer.append(Data("\n\none\n\n".utf8)), ["", "", "one", ""])
        XCTAssertEqual(buffer.finish(), [])
        XCTAssertNil(buffer.finish())
    }

    func testCarriageReturnsRemainLiteral() {
        let buffer = RemoteAccessLineBuffer()
        XCTAssertEqual(buffer.append(Data("one\r\ntwo\r".utf8)), ["one\r"])
        XCTAssertEqual(buffer.finish(), ["two\r"])
    }

    func testConcurrentCompleteLineAppendsLoseOrDuplicateNoLines() {
        let buffer = RemoteAccessLineBuffer()
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let output = buffer.append(Data("line-\(index)\n".utf8))
            lines.withLock { $0 += output }
        }
        XCTAssertEqual(lines.withLock { $0.sorted() }, (0..<100).map { "line-\($0)" }.sorted())
        XCTAssertEqual(buffer.finish(), [])
    }

    func testFinishReturnsUnterminatedTailOnlyOnce() {
        let buffer = RemoteAccessLineBuffer()
        XCTAssertEqual(buffer.append(Data("tail".utf8)), [])
        XCTAssertEqual(buffer.finish(), ["tail"])
        XCTAssertNil(buffer.finish())
    }

    func testAppendAfterFinishCannotReviveTheStream() {
        for initial in ["", "tail", "line\n"] {
            let buffer = RemoteAccessLineBuffer()
            _ = buffer.append(Data(initial.utf8))
            _ = buffer.finish()
            XCTAssertEqual(buffer.append(Data("late\nmore".utf8)), [])
            XCTAssertEqual(buffer.append(Data("\n".utf8)), [])
            XCTAssertNil(buffer.finish())
        }
    }

    func testIncompleteUTF8AtEOFUsesReplacementDecoding() {
        let buffer = RemoteAccessLineBuffer()
        XCTAssertEqual(buffer.append(Data([0xf0, 0x9f])), [])
        XCTAssertEqual(buffer.finish(), ["�"])
    }

    func testConcurrentFinishReturnsTailExactlyOnce() {
        let buffer = RemoteAccessLineBuffer()
        _ = buffer.append(Data("tail".utf8))
        let results = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let tail = buffer.finish() { results.withLock { $0.append(tail) } }
        }
        XCTAssertEqual(results.withLock { $0 }, [["tail"]])
    }

    func testConcurrentAppendAndFinishHaveOnlySequentiallyValidOutcomes() {
        for _ in 0..<200 {
            let buffer = RemoteAccessLineBuffer()
            _ = buffer.append(Data("prefix".utf8))
            let results = OSAllocatedUnfairLock<[[String]?]>(initialState: [nil, nil, nil])
            // The append races two EOF callbacks. Exactly one EOF may return a tail.
            DispatchQueue.concurrentPerform(iterations: 3) { operation in
                let output = operation == 0 ? buffer.append(Data("-line\nremaining".utf8)) : buffer.finish()
                results.withLock { $0[operation] = output }
            }
            let outputs = results.withLock { $0 }
            let finishes = outputs.dropFirst().compactMap { $0 }
            XCTAssertEqual(finishes.count, 1)
            if outputs[0] == [] {
                XCTAssertEqual(finishes, [["prefix"]], "EOF won the race")
            } else {
                XCTAssertEqual(outputs[0], ["prefix-line"], "Append won the race")
                XCTAssertEqual(finishes, [["remaining"]])
            }
            XCTAssertEqual(buffer.append(Data("late\n".utf8)), [])
            XCTAssertNil(buffer.finish())
        }
    }
}
