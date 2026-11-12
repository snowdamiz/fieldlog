import Foundation
import XCTest
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid
#if canImport(Darwin)
import Darwin
#endif

final class ReportShareTests: XCTestCase {
    private func directory(_ name: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent("report-" + name)
    }
    @MainActor private func event(_ p: ProjectPresentation, _ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws -> UIEventEnvelope {
        UIEventEnvelope(revision: p.snapshot.document.revision, identity: try XCTUnwrap(p.snapshot.identity(for: id)), event: kind, value: value)
    }
    @MainActor func testRealPublicReportUsesCurrentSavedProjectAndRetainsUnsavedTask() async throws {
        let dir=directory("saved"), repo=try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let saved=try await repo.transact { w in
            let first=try w.createProject(title: "Current Project",site: "Exact site")
            _ = try w.createProject(title: "Other Project",site: "Never share")
            _ = try w.saveTask(projectID:first,title:"Saved task",responsible:"Alex")
        }
        let p=try await ProjectPresentation(repository:repo)
        try p.send(event(p,"task.title",.textChange,.string("Unsaved exact 👩🏽‍🔬")))
        let state=p.state, before=try Data(contentsOf:dir.appendingPathComponent("FieldLog/workspace.json"))
        try p.send(event(p,"workspace.report")); try await p.waitForSave()
        let r=try XCTUnwrap(p.takeReportRequest())
        XCTAssertEqual(r.projectID,saved.projects[0].id); XCTAssertEqual(r.revision,saved.revision)
        let bytes=try Data(contentsOf:r.fileURL)
        XCTAssertEqual(bytes,Data(try saved.report(projectID:r.projectID).utf8)); XCTAssertEqual(bytes.count,r.byteCount)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("Never share"))
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("Unsaved exact"))
        XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("No upload"))
        XCTAssertEqual(p.state,state); XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("FieldLog/workspace.json")),before)
        XCTAssertTrue(p.completeReport(requestID:r.id,result:.opened)); XCTAssertTrue(p.completeReport(requestID:r.id,result:.closed))
        XCTAssertTrue(FileManager.default.fileExists(atPath:r.fileURL.path),"repository export is retained")
        await p.close()
    }
    @MainActor func testSingletonOriginalBatchAdmissionAndDuplicateLateResults() async throws {
        let p=try await ProjectPresentation(directory:directory("singleton"))
        let report=try event(p,"workspace.report"), title=try event(p,"task.title",.textChange,.string("Must not leak"))
        XCTAssertThrowsError(try p.sendBatch([title,report],from:p.snapshot)); XCTAssertEqual(p.state.title,"")
        try p.send(report); try await p.waitForSave()
        let r=try XCTUnwrap(p.takeReportRequest()); XCTAssertNil(p.takeReportRequest())
        XCTAssertThrowsError(try p.send(event(p,"workspace.report")))
        XCTAssertFalse(p.completeReport(requestID:UUID(),result:.opened))
        XCTAssertFalse(p.completeReport(requestID:r.id,result:.closed))
        XCTAssertTrue(p.completeReport(requestID:r.id,result:.opened))
        XCTAssertFalse(p.completeReport(requestID:r.id,result:.opened))
        XCTAssertTrue(p.completeReport(requestID:r.id,result:.closed))
        XCTAssertFalse(p.completeReport(requestID:r.id,result:.unavailable))
        try p.send(event(p,"workspace.report")); try await p.waitForSave()
        let next=try XCTUnwrap(p.takeReportRequest()); XCTAssertNotEqual(next.id,r.id)
        XCTAssertFalse(p.completeReport(requestID:r.id,result:.opened)); XCTAssertTrue(p.reportSharePending)
        XCTAssertTrue(p.completeReport(requestID:next.id,result:.unavailable)); XCTAssertFalse(p.reportSharePending)
        await p.close(); XCTAssertFalse(p.completeReport(requestID:next.id,result:.opened))
    }
    @MainActor func testVerifiedDescriptorSurvivesAtomicPathReplacementAndClosesOnCompletion() async throws {
        let p=try await ProjectPresentation(directory:directory("inode"))
        try p.send(event(p,"workspace.report")); try await p.waitForSave()
        let r=try XCTUnwrap(p.takeReportRequest()), original=try Data(contentsOf:r.fileURL)
        try Data("replacement".utf8).write(to:r.fileURL,options:.atomic)
        #if canImport(Darwin)
        let copy=FileHandle(fileDescriptor:dup(r.descriptor),closeOnDealloc:false)
        XCTAssertEqual(try copy.readToEnd(),original); try copy.close()
        #endif
        XCTAssertTrue(p.completeReport(requestID:r.id,result:.unavailable))
        #if canImport(Darwin)
        XCTAssertEqual(fcntl(r.descriptor,F_GETFD),-1)
        #endif
        await p.close()
    }
    @MainActor func testExportFailureAndCloseDuringPreparationPreserveWorkspaceAndInput() async throws {
        let dir=directory("failure"), p=try await ProjectPresentation(directory:dir)
        try p.send(event(p,"task.title",.textChange,.string("Keep input")))
        let file=dir.appendingPathComponent("FieldLog/workspace.json"), before=try Data(contentsOf:file), state=p.state
        try Data("block exports".utf8).write(to:dir.appendingPathComponent("FieldLog/exports"))
        try p.send(event(p,"workspace.report")); try await p.waitForSave()
        XCTAssertNil(p.takeReportRequest()); XCTAssertFalse(p.reportSharePending)
        XCTAssertEqual(p.state,state); XCTAssertEqual(try Data(contentsOf:file),before)
        try p.send(event(p,"workspace.report")); await p.close(); XCTAssertNil(p.takeReportRequest())
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testBoundDerivedFromActualSnapshotAndValidationCaps() async throws {
        let framing=10000*16+10000*256+4096
        XCTAssertLessThan(32*1024*1024+framing,ProjectPresentation.maximumReportBytes)
        let dir=directory("bound"), repo=try WorkspaceRepository(directory:dir)
        let initial=try await repo.transact { w in _ = try w.createProject(title:"Bound",site:"") }
        let before=try Data(contentsOf:dir.appendingPathComponent("workspace.json"))
        do {
            _ = try await repo.transact { w in
                let project=w.projects[0].id
                for _ in 0..<400 { let draft=EntryDraft(projectID:project,title:"Max note",note:String(repeating:"x",count:100000)); try w.saveDraft(draft); try w.commitDraft(draft.id) }
            }
            XCTFail("actual32MiB storage bound must refuse")
        } catch { }
        let after=await repo.snapshot(); XCTAssertEqual(after,initial)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("workspace.json")),before)
        await repo.close()
    }
}
