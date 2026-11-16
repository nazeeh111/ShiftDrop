import XCTest
import Foundation
import AppKit
import ShiftDropCore
@testable import ShiftDrop

final class MemoryDefaults: UserDefaults {
    var values: [String: Any]
    init(_ values: [String: Any]) { self.values=values; super.init(suiteName:nil)! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func double(forKey defaultName: String) -> Double { values[defaultName] as? Double ?? 0 }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName]=value }
}

@MainActor final class DurableAppModelTests: XCTestCase {
    func testAppModelPlansRunsAndRestoresPrivateQueue() async throws {
        guard let base=ProcessInfo.processInfo.environment["SHIFTDROP_TEST_ROOT"] else { throw XCTSkip("Task-private test root required") }
        let root=URL(fileURLWithPath:base,isDirectory:true).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("owned.srt"), output=root.appendingPathComponent("output"), queue=root.appendingPathComponent("queue")
        let bytes=Data("1\n00:00:01,007 --> 00:00:02,999\nSynthetic text\n".utf8);try bytes.write(to:source)
        let defaults=MemoryDefaults(["saveBesideOriginals":false,"outputDirectory":output.path])
        var model:AppModel?=AppModel(defaults:defaults,queueDirectory:queue,checkLogin:false)
        model!.addFiles([source],format:.vtt,reveal:false);XCTAssertEqual(model!.items.count,1);XCTAssertEqual(model!.items[0].state,.ready)
        model!.run();for _ in 0..<200 where model!.running { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(model!.running);XCTAssertEqual(model!.items[0].state,.complete)
        let result=try XCTUnwrap(model!.items[0].result);XCTAssertTrue(try String(contentsOf:result.outputURLs[0],encoding:.utf8).contains("00:00:01.007"));XCTAssertEqual(try Data(contentsOf:source),bytes)
        model=nil;try await Task.sleep(nanoseconds:30_000_000)
        let reopened=AppModel(defaults:defaults,queueDirectory:queue,checkLogin:false)
        XCTAssertEqual(reopened.items.count,1);XCTAssertEqual(reopened.items[0].state,.complete)
        XCTAssertEqual(reopened.items[0].result?.outputURLs.first?.path,result.outputURLs.first?.path)
    }
    func testWaitingSelectionUpdatesPersistedDescriptor() async throws {
        guard let base=ProcessInfo.processInfo.environment["SHIFTDROP_TEST_ROOT"] else { throw XCTSkip("Task-private test root required") }
        let root=URL(fileURLWithPath:base,isDirectory:true).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("owned.txt"), output=root.appendingPathComponent("output"), queue=root.appendingPathComponent("queue")
        try Data("Synthetic draft".utf8).write(to:source)
        let defaults=MemoryDefaults(["saveBesideOriginals":false,"outputDirectory":output.path]);let model=AppModel(defaults:defaults,queueDirectory:queue,checkLogin:false)
        model.addFiles([source],format:.html,reveal:false);let id=model.items[0].id
        model.setFormat(id,.rtf);model.run()
        for _ in 0..<200 where model.running { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(model.items[0].state,.complete);let result=try XCTUnwrap(model.items[0].result)
        XCTAssertEqual(result.outputURLs[0].pathExtension,"rtf")
        XCTAssertEqual(try NSAttributedString(url:result.outputURLs[0],options:[:],documentAttributes:nil).string,"Synthetic draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("owned.html").path))
    }

}
