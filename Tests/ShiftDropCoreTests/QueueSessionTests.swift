import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import AppKit
import PDFKit
@testable import ShiftDropCore

@MainActor final class QueueSessionTests: XCTestCase {
    private func workspace() throws -> URL {
        guard let base=ProcessInfo.processInfo.environment["SHIFTDROP_TEST_ROOT"] else { throw XCTSkip("Task-private test root required") }
        let root=URL(fileURLWithPath:base,isDirectory:true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return root
    }
    private func input(_ root: URL) throws -> URL {
        let file=root.appendingPathComponent("owned.srt")
        try Data("1\n00:00:01,007 --> 00:00:02,999\nSynthetic text\n".utf8).write(to:file)
        return file
    }
    func testConversionCleanupFailurePreservesPublishedOutput() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root), original=try Data(contentsOf:source)
        var attempts=0
        let engine=ConversionEngine(removeStage: { _ in attempts += 1; throw POSIXError(.EACCES) })
        let result=try await engine.convert(input:source,to:.vtt,outputDirectory:root.appendingPathComponent("out"))
        XCTAssertEqual(attempts,1)
        XCTAssertTrue(result.cleanupWarning?.contains(".shiftdrop") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:result.outputURLs[0].path))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    func testActualSubtitlePlanExecuteReopenAndNoOverwrite() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),original=try Data(contentsOf:source),directory=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        var owner: QueueSession?=try QueueSession(directory:directory);let job=try owner!.enqueue(input:source,format:.vtt)
        XCTAssertThrowsError(try QueueSession(directory:directory))
        let result=try await owner!.execute(job.id,destination:dest)
        XCTAssertTrue(try String(contentsOf:result.outputURLs[0],encoding:.utf8).contains("00:00:01.007 --> 00:00:02.999"))
        XCTAssertEqual(try Data(contentsOf:source),original);owner=nil
        let reopened=try QueueSession(directory:directory);XCTAssertEqual(reopened.jobs[0].state,.complete)
        XCTAssertEqual(try reopened.verifiedResult(job.id).outputURLs,result.outputURLs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dest.path).count,1)
    }
    func testCompletedReceiptCountMustMatchVerifiedBytesAfterRestart() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root), folder=root.appendingPathComponent("queue")
        var owner:QueueSession?=try QueueSession(directory:folder)
        let job=try owner!.enqueue(input:source,format:.vtt)
        let result=try await owner!.execute(job.id,destination:root.appendingPathComponent("out"))
        let actual=try Data(contentsOf:result.outputURLs[0]).count
        XCTAssertEqual(try owner!.verifiedResult(job.id).outputBytes,Int64(actual));owner=nil
        let manifest=folder.appendingPathComponent("manifest.json"),original=try Data(contentsOf:manifest)
        for value:Any in [-5,0,actual+1,true,"5"] {
            var body=try JSONSerialization.jsonObject(with:original) as! [String:Any]
            var jobs=body["jobs"] as! [[String:Any]];jobs[0]["outputBytes"]=value;body["jobs"]=jobs
            try JSONSerialization.data(withJSONObject:body).write(to:manifest)
            do { let reopened=try QueueSession(directory:folder);XCTAssertThrowsError(try reopened.verifiedResult(job.id)) }
            catch { /* Invalid JSON types must be refused at admission. */ }
        }
        try original.write(to:manifest)
        let reopened=try QueueSession(directory:folder)
        XCTAssertEqual(try reopened.verifiedResult(job.id).outputBytes,Int64(actual))
        try Data("truncated".utf8).write(to:result.outputURLs[0])
        XCTAssertThrowsError(try reopened.verifiedResult(job.id))
    }
    func testNativeImageUsesCapturedBytesAndDecodes() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let input=root.appendingPathComponent("picture.png")
        let color=CGColorSpaceCreateDeviceRGB()
        let context=try XCTUnwrap(CGContext(data:nil,width:3,height:2,bitsPerComponent:8,bytesPerRow:12,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.6,alpha:1));context.fill(CGRect(x:0,y:0,width:3,height:2))
        let image=try XCTUnwrap(context.makeImage()), encoder=try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(encoder,image,nil);XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let original=try Data(contentsOf:input),owner=try QueueSession(directory:root.appendingPathComponent("queue"))
        let job=try owner.enqueue(input:input,format:.jpeg);let result=try await owner.execute(job.id,destination:root.appendingPathComponent("out"))
        let decoded=try XCTUnwrap(CGImageSourceCreateWithURL(result.outputURLs[0] as CFURL,nil));let output=try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded,0,nil))
        XCTAssertEqual(output.width,3);XCTAssertEqual(output.height,2);XCTAssertEqual(try Data(contentsOf:input),original)
    }
    func testURLOnlyDocumentConversionRetainsSourceAndChecksOutput() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("owned.txt"),bytes=Data("Synthetic PDF text".utf8);try bytes.write(to:source)
        let owner=try QueueSession(directory:root.appendingPathComponent("queue"));let job=try owner.enqueue(input:source,format:.pdf)
        XCTAssertTrue(job.recoverable);let result=try await owner.execute(job.id,destination:root.appendingPathComponent("out"))
        let document=try XCTUnwrap(PDFDocument(url:result.outputURLs[0]));XCTAssertEqual(document.pageCount,1)
        XCTAssertTrue(document.string?.contains("Synthetic PDF text") == true);XCTAssertEqual(try Data(contentsOf:source),bytes)
        try Data("synthetic mutation".utf8).write(to:result.outputURLs[0])
        XCTAssertThrowsError(try owner.verifiedResult(job.id))
    }
    func testMultiPagePDFRemainsOneShotAndIsNotMisrepresentedAsResumable() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let context=try XCTUnwrap(CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.6,alpha:1));context.fill(CGRect(x:0,y:0,width:4,height:4))
        let image=NSImage(cgImage:try XCTUnwrap(context.makeImage()),size:NSSize(width:4,height:4)),document=PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image:image)),at:0);document.insert(try XCTUnwrap(PDFPage(image:image)),at:1)
        let source=root.appendingPathComponent("two-pages.pdf");XCTAssertTrue(document.write(to:source));let original=try Data(contentsOf:source)
        let folder=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        var owner:QueueSession?=try QueueSession(directory:folder);let job=try owner!.enqueue(input:source,format:.png)
        XCTAssertFalse(job.recoverable);XCTAssertTrue(job.message?.contains("One-shot") == true)
        let output=try await owner!.execute(job.id,destination:dest);XCTAssertEqual(output.outputURLs.count,2);XCTAssertEqual(try Data(contentsOf:source),original)
        owner=nil;let reopened=try QueueSession(directory:folder);XCTAssertEqual(reopened.jobs[0].state,.complete)
        XCTAssertThrowsError(try reopened.verifiedResult(job.id));XCTAssertEqual(try reopened.oneShotResult(job.id).outputURLs.count,2)
    }
    func testOneShotInterruptedIsNotAutomaticallyRetried() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("folder",isDirectory:true);try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false)
        let folder=root.appendingPathComponent("queue");var owner:QueueSession?=try QueueSession(directory:folder)
        guard FormatCatalog.formats(for:source).contains(.zip) else { throw XCTSkip("System ZIP unavailable") }
        let job=try owner!.enqueue(input:source,format:.zip);XCTAssertFalse(job.recoverable);owner=nil
        let manifest=folder.appendingPathComponent("manifest.json");var body=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any];var jobs=body["jobs"] as! [[String:Any]];jobs[0]["state"]="running";body["jobs"]=jobs;try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        let reopened=try QueueSession(directory:folder);XCTAssertEqual(reopened.jobs[0].state,.interrupted);XCTAssertThrowsError(try reopened.retry(job.id))
    }
    func testRollbackPreservesReplacementAndReportsRetainedOutput() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let stage=root.appendingPathComponent("stage.txt"),out=root.appendingPathComponent("out");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false);try Data("owned".utf8).write(to:stage)
        let receipt=try OutputTransaction.publish(stage,directory:out,basename:"item",extension:"txt")
        let saved=root.appendingPathComponent("saved-owned.txt");try FileManager.default.moveItem(at:receipt.url,to:saved)
        try Data("foreign synthetic".utf8).write(to:receipt.url)
        let error=OutputTransaction.abort(ConversionError.conversionFailed("synthetic later failure"),[receipt])
        XCTAssertEqual(try Data(contentsOf:receipt.url),Data("foreign synthetic".utf8))
        XCTAssertTrue(error.localizedDescription.contains("could not be safely cleaned"));XCTAssertEqual(try Data(contentsOf:saved),Data("owned".utf8))
    }
    func testRollbackPreservesSameInodeContentChangedAfterPublication() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let stage=root.appendingPathComponent("stage.txt"),out=root.appendingPathComponent("out");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false);try Data("owned".utf8).write(to:stage)
        let receipt=try OutputTransaction.publish(stage,directory:out,basename:"item",extension:"txt")
        let handle=try FileHandle(forWritingTo:receipt.url);try handle.truncate(atOffset:0);try handle.write(contentsOf:Data("edited later".utf8));try handle.close()
        let error=OutputTransaction.abort(ConversionError.conversionFailed("synthetic later failure"),[receipt])
        XCTAssertEqual(try Data(contentsOf:receipt.url),Data("edited later".utf8));XCTAssertTrue(error.localizedDescription.contains("could not be safely cleaned"))
    }
    func testPublishedOutputSurvivesReceiptFailureAndExplicitRecovery() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),owner=try QueueSession(directory:root.appendingPathComponent("queue")),dest=root.appendingPathComponent("out")
        let job=try owner.enqueue(input:source,format:.vtt);var attempts=0
        owner.beforeManifestWrite={ attempts += 1; if attempts==4 { throw POSIXError(.EACCES) } }
        do { _=try await owner.execute(job.id,destination:dest);XCTFail("expected injected receipt failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Output was published"));XCTAssertTrue(error.localizedDescription.contains("receipt")) }
        XCTAssertEqual(attempts,4);XCTAssertEqual(owner.jobs[0].state,.prepared)
        let output=dest.appendingPathComponent("owned.vtt");let bytes=try Data(contentsOf:output)
        owner.beforeManifestWrite=nil;try owner.retry(job.id);let recovered=try await owner.execute(job.id,destination:dest)
        XCTAssertEqual(recovered.outputURLs,[output.standardizedFileURL]);XCTAssertEqual(try Data(contentsOf:output),bytes);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dest.path).count,1)
    }
    func testFailedCaptureCleanupReportsPrimaryAndOwnedPath() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),directory=root.appendingPathComponent("queue"),owner=try QueueSession(directory:directory)
        owner.beforeManifestWrite={ throw POSIXError(.ENOSPC) }
        owner.beforeOwnedCleanup={ _ in throw POSIXError(.EACCES) }
        do { _=try owner.enqueue(input:source,format:.vtt);XCTFail("expected injected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Cannot persist batch manifest"));XCTAssertTrue(error.localizedDescription.contains("Owned staging path retained"));XCTAssertTrue(error.localizedDescription.contains(directory.standardizedFileURL.path)) }
        XCTAssertEqual(owner.jobs.count,0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix("input-") })
    }
    func testRollbackCleanupFailureReportsPrimaryAndRetainedPathOnce() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let stage=root.appendingPathComponent("stage.txt"),out=root.appendingPathComponent("out");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false);try Data("owned".utf8).write(to:stage)
        let receipt=try OutputTransaction.publish(stage,directory:out,basename:"item",extension:"txt");var attempts=0
        let error=OutputTransaction.abort(ConversionError.conversionFailed("synthetic primary"),[receipt],remove:{ _ in attempts += 1;throw POSIXError(.EACCES) })
        XCTAssertEqual(attempts,1);XCTAssertTrue(error.localizedDescription.contains("synthetic primary"));XCTAssertTrue(error.localizedDescription.contains(receipt.url.path));XCTAssertTrue(error.localizedDescription.contains("cleanup failed"));XCTAssertEqual(try Data(contentsOf:receipt.url),Data("owned".utf8))
    }
    func testChangedPrivateSnapshotRefusesPublication() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),bytes=try Data(contentsOf:source),directory=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        let owner=try QueueSession(directory:directory),job=try owner.enqueue(input:source,format:.vtt)
        let snapshot=directory.appendingPathComponent("input-\(job.id.uuidString)").appendingPathComponent(source.lastPathComponent)
        owner.afterStageConversion={ try Data("synthetic snapshot drift".utf8).write(to:snapshot) }
        do { _=try await owner.execute(job.id,destination:dest);XCTFail("snapshot drift accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("snapshot changed")) }
        XCTAssertEqual(try Data(contentsOf:source),bytes);XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("owned.vtt").path))
    }
    func testChangedSourceSpecialFilesAndForeignDestinationRefuse() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),queue=try QueueSession(directory:root.appendingPathComponent("queue")),dest=root.appendingPathComponent("out")
        let job=try queue.enqueue(input:source,format:.vtt);try Data("changed".utf8).write(to:source)
        do { _=try await queue.execute(job.id,destination:dest);XCTFail("changed source accepted") } catch {}
        XCTAssertEqual(queue.jobs[0].state,.failed);XCTAssertFalse(FileManager.default.fileExists(atPath:dest.path))
        let fifo=root.appendingPathComponent("pipe.srt");XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try queue.enqueue(input:fifo,format:.vtt))
        let link=root.appendingPathComponent("link.srt");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try queue.enqueue(input:link,format:.vtt))
        let source2=root.appendingPathComponent("other.srt");try Data("1\n00:00:00,000 --> 00:00:01,000\nA\n".utf8).write(to:source2)
        let j=try queue.enqueue(input:source2,format:.vtt);try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:false)
        let foreign=dest.appendingPathComponent("other.vtt");try Data("KEEP".utf8).write(to:foreign)
        let converted=try await queue.execute(j.id,destination:dest)
        XCTAssertEqual(try Data(contentsOf:foreign),Data("KEEP".utf8));XCTAssertEqual(queue.jobs.last?.state,.complete)
        XCTAssertEqual(converted.outputURLs[0].lastPathComponent,"other (2).vtt")
    }
    func testPreparedLinkReconcilesWithoutDuplicateAfterRestart() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),directory=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        var owner:QueueSession?=try QueueSession(directory:directory);let job=try owner!.enqueue(input:source,format:.vtt)
        let output=try await owner!.execute(job.id,destination:dest).outputURLs[0];let content=try Data(contentsOf:output);owner=nil
        let manifest=directory.appendingPathComponent("manifest.json");var body=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
        var jobs=body["jobs"] as! [[String:Any]];jobs[0]["state"]="prepared";body["jobs"]=jobs
        try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        try Data("source changed after publication".utf8).write(to:source)
        let reopened=try QueueSession(directory:directory);XCTAssertEqual(reopened.jobs[0].state,.prepared);try reopened.retry(job.id)
        let recovered=try await reopened.execute(job.id,destination:dest);XCTAssertEqual(recovered.outputURLs,[output]);XCTAssertEqual(try Data(contentsOf:output),content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dest.path).count,1)
    }
    func testOversizedInputIsExplicitOneShotAndOutputSymlinkIsNeverReplaced() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let large=root.appendingPathComponent("large.srt");FileManager.default.createFile(atPath:large.path,contents:nil)
        let h=try FileHandle(forWritingTo:large);try h.truncate(atOffset:33*1024*1024);try h.close()
        let owner=try QueueSession(directory:root.appendingPathComponent("queue"));let oversized=try owner.enqueue(input:large,format:.vtt)
        XCTAssertFalse(oversized.recoverable);XCTAssertTrue(oversized.message?.contains("One-shot") == true)
        let input=try self.input(root),job=try owner.enqueue(input:input,format:.vtt),dest=root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:false)
        let foreign=root.appendingPathComponent("foreign");try Data("KEEP".utf8).write(to:foreign)
        let link=dest.appendingPathComponent("owned.vtt");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:foreign)
        let converted=try await owner.execute(job.id,destination:dest)
        XCTAssertEqual(converted.outputURLs[0].lastPathComponent,"owned (2).vtt")
        XCTAssertEqual(try Data(contentsOf:foreign),Data("KEEP".utf8));XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:link.path),foreign.path)
    }
    func testPreparedOutputDoesNotAdoptForeignFileWithSameBytes() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),directory=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        var owner:QueueSession?=try QueueSession(directory:directory);let job=try owner!.enqueue(input:source,format:.vtt)
        let output=try await owner!.execute(job.id,destination:dest).outputURLs[0];let bytes=try Data(contentsOf:output);owner=nil
        let manifest=directory.appendingPathComponent("manifest.json");var body=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any];var jobs=body["jobs"] as! [[String:Any]];jobs[0]["state"]="prepared";body["jobs"]=jobs;try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        try FileManager.default.removeItem(at:output);try bytes.write(to:output)
        let reopened=try QueueSession(directory:directory);try reopened.retry(job.id)
        do { _=try await reopened.execute(job.id,destination:dest);XCTFail("foreign same-content file adopted") } catch {}
        XCTAssertEqual(try Data(contentsOf:output),bytes);XCTAssertEqual(reopened.jobs[0].state,.prepared)
    }
    func testInterruptedStageIsRetainedAndExplicitRetryWorks() async throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let source=try input(root),directory=root.appendingPathComponent("queue"),dest=root.appendingPathComponent("out")
        var owner:QueueSession?=try QueueSession(directory:directory);let job=try owner!.enqueue(input:source,format:.vtt);owner=nil
        let manifest=directory.appendingPathComponent("manifest.json");var body=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any];var jobs=body["jobs"] as! [[String:Any]]
        let stale=UUID();jobs[0]["state"]="running";jobs[0]["stageID"]=stale.uuidString;body["jobs"]=jobs;try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        let old=directory.appendingPathComponent("result-\(stale.uuidString)");try FileManager.default.createDirectory(at:old,withIntermediateDirectories:false);try Data("owned partial".utf8).write(to:old.appendingPathComponent("partial"))
        let reopened=try QueueSession(directory:directory);XCTAssertEqual(reopened.jobs[0].state,.interrupted);try reopened.retry(job.id)
        _=try await reopened.execute(job.id,destination:dest);XCTAssertEqual(reopened.jobs[0].state,.complete)
        XCTAssertEqual(try Data(contentsOf:old.appendingPathComponent("partial")),Data("owned partial".utf8))
    }
}
