import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Readable CUA trace")
struct ReadableComputerUseTraceTests {
    func call(_ name: String, _ args: String, step: Int) -> ComputerUseTraceEvent {
        .init(kind: "tool_call", title: "trycua", body: "[trycua] \(name)\n\(args)", step: step)
    }
    func result(_ json: String, step: Int, status: String? = nil) -> ComputerUseTraceEvent {
        .init(kind: "tool_result", title: "trycua", body: "[trycua] summary\n\(json)", status: status, step: step)
    }
    @Test func resolvesFreshLabelsAndRetainsRawRecords() {
        let events = [call("get_browser_state", #"{"target_id":"t","tab_id":"a"}"#, step: 1),
            result(#"{"target_id":"t","tab_id":"a","refs":[{"ref":"p1:1","name":"Reply"}]}"#, step: 1),
            call("browser_click", #"{"target_id":"t","tab_id":"a","ref":"p1:1"}"#, step: 2),
            result(#"{"effect":"unverifiable"}"#, step: 2)]
        let rows = ComputerUseTraceFormatter.readableRows(events)
        #expect(rows.count == 2)
        #expect(rows[1].title == "Click “Reply”")
        #expect(rows[1].outcome.contains("unverified"))
        #expect(rows.flatMap(\.events) == events)
        let otherTab = events.prefix(2) + [call("browser_click", #"{"target_id":"t","tab_id":"b","ref":"p1:1"}"#, step: 2)]
        #expect(!ComputerUseTraceFormatter.readableRows(Array(otherTab)).last!.title.contains("Reply"))
    }
    @Test func onlyGroupsConsecutiveSuccessfulReads() {
        let args = #"{"target_id":"t","tab_id":"a"}"#
        let events = [call("get_browser_state", args, step: 1), result(#"{"status":"ok"}"#, step: 1),
            call("get_browser_state", args, step: 2), result(#"{"status":"ok"}"#, step: 2),
            call("get_browser_state", args, step: 3), result(#"{"status":"ok"}"#, step: 3, status: "failed"),
            call("get_browser_state", args, step: 4), result(#"{"status":"ok"}"#, step: 4)]
        let rows = ComputerUseTraceFormatter.readableRows(events)
        #expect(rows.count == 3)
        #expect(rows[0].title == "Inspected page ×2")
        #expect(rows[1].outcome.hasPrefix("Error"))
        #expect(rows.flatMap(\.events) == events)
    }
    @Test func incompleteAndMalformedTracesRemainInspectable() {
        let events = [call("browser_click", "not JSON", step: 1),
                      call("browser_click", "{}", step: 2), result(#"{"status":"ok"}"#, step: 1)]
        let rows = ComputerUseTraceFormatter.readableRows(events)
        #expect(rows[0].outcome == "No result recorded")
        #expect(Set(rows.flatMap(\.events).map(\.id)) == Set(events.map(\.id)))
    }
    @Test("Latest successful run has compact rows and complete evidence",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_READABLE_TRACE_FIXTURE"] != nil))
    func savedRun() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MUESLI_READABLE_TRACE_FIXTURE"])
        let events = try JSONDecoder().decode([ComputerUseTraceEvent].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let rows = ComputerUseTraceFormatter.readableRows(events)
        let retained = rows.flatMap(\.events).map(\.id)
        let expected = events.filter { !["transcript", "backend", "context_budget"].contains($0.kind) }.map(\.id)
        #expect(Set(retained) == Set(expected))
        #expect(retained.count == expected.count)
        #expect(rows.count < events.filter { $0.kind == "tool_call" }.count)
        #expect(rows.contains { $0.title.contains("Reply") })
        let preview = rows.map { "\($0.title) | \($0.detail) | \($0.outcome)" }.joined(separator: "\n")
        try preview.write(toFile: "/tmp/cua-readable-trace-preview.txt", atomically: true, encoding: .utf8)
        print("Readable trace: \(events.count) events → \(rows.count) rows; raw evidence retained")
    }
}
