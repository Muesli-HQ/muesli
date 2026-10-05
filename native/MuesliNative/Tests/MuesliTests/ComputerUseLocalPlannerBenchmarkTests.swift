import Foundation
import Testing
@testable import MuesliNativeApp

/// Opt-in inference benchmark. Never executes generated OS actions or writes settings.
/// MUESLI_CUA_BENCHMARK=1 [MUESLI_CUA_BENCHMARK_MODEL=<planner ID>] swift test --filter ComputerUseLocalPlannerBenchmarkTests
@Suite(.serialized)
@MainActor
struct ComputerUseLocalPlannerBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK"] == "1"))
    func settingsRoundTripWithoutChatGPT() async throws {
        let selected = ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK_MODEL"]
        guard let model = ComputerUseLocalPlanner.models.first(where: { $0.available && (selected == nil || selected == $0.id) }) else {
            Issue.record("Download a supported local model first")
            return
        }
        var config = AppConfig()
        config.computerUsePlannerModel = model.id
        config.soundEnabled = true
        var saved = config
        let setting = MuesliSetting(id: "sound", label: "Sound effects",
            choices: [.init(id: "on", label: "On"), .init(id: "off", label: "Off")],
            read: { $0.soundEnabled ? "on" : "off" }, unavailable: { _ in nil },
            apply: { config.soundEnabled = $0 == "on"; saved = config })
        let result = await ComputerUseSettings.run(command: "Turn sound effects off", settings: [setting],
            config: { config }, persistedConfig: { saved })
        #expect(result?.status == .done)
        #expect(!saved.soundEnabled)
        print("CUA_BENCHMARK settings-round-trip status=\(String(describing: result?.status)) saved=\(saved.soundEnabled) message=\(result?.message ?? "no settings result")")
        if #available(macOS 15, *) { await Gemma4LiteRTTranscriber.shared.shutdown() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK"] == "1"))
    func fixedPlannerPrompts() async throws {
        let selected = ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK_MODEL"]
        let models = ComputerUseLocalPlanner.models.filter { $0.available && (selected == nil || selected == $0.id) }
        #expect(!models.isEmpty, "Download a supported local model before benchmarking.")
        for model in models {
            let cases: [(String, String, String, [[String: Any]], String)] = [
                ("settings-discovery", ComputerUseSettings.instructions,
                 #"{"command":"Turn sound effects off","availableSettings":[{"id":"sound","label":"Sound effects"}],"settings":[],"answers":[]}"#,
                 ComputerUseSettings.tools, "inspect_muesli_setting"),
                ("settings-mutation", ComputerUseSettings.instructions,
                 #"{"command":"Turn sound effects off","availableSettings":[{"id":"sound","label":"Sound effects"}],"settings":[{"id":"sound","label":"Sound effects","current":"on","choices":[{"id":"on","label":"On"},{"id":"off","label":"Off"}],"unavailable":{}}],"answers":[]}"#,
                 ComputerUseSettings.tools, "set_muesli_setting"),
                ("launch-app", ComputerUsePlannerClient.instructions,
                 #"{"command":"Open Calculator","latest_window_state":{"app_name":"Finder","elements":[]},"prior_steps":[]}"#,
                 ComputerUseToolRegistry.nativeToolDefinitions(), "launch_app"),
                ("move-cursor", ComputerUsePlannerClient.instructions,
                 #"{"command":"Move the cursor to screenshot coordinate x=120, y=80 without clicking","latest_window_state":{"app_name":"Finder","screenshot":{"screenshot_id":"bench-screen","width":800,"height":600},"elements":[]},"prior_steps":[]}"#,
                 ComputerUseToolRegistry.nativeToolDefinitions(), "move_cursor")
            ]
            for (name, system, prompt, tools, expected) in cases {
                let start = Date()
                do {
                    let call = try await ComputerUseLocalPlanner.callTool(systemPrompt: system, userPrompt: prompt, model: model.id, tools: tools) { system, prompt in
                        guard #available(macOS 15, *) else { throw ComputerUsePlannerError.invalidResponse("Requires macOS 15") }
                        let output = try await model.backend.generate(systemPrompt: system, userPrompt: prompt)
                        print("CUA_BENCHMARK_RAW \(name): \(output)")
                        return output
                    }
                    print("CUA_BENCHMARK model=\(model.id) case=\(name) seconds=\(Date().timeIntervalSince(start)) tool=\(call.name) arguments=\(call.arguments)")
                    #expect(call.name == expected)
                    let args = try #require(try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any])
                    if name.hasPrefix("settings-") { #expect(args["setting"] as? String == "sound") }
                    if name == "settings-mutation" { #expect(args["value"] as? String == "off") }
                    if name == "launch-app" { #expect(args["app_name"] as? String == "Calculator") }
                    if name == "move-cursor" {
                        #expect(args["screenshot_id"] as? String == "bench-screen")
                        #expect(args["x"] as? Int == 120)
                        #expect(args["y"] as? Int == 80)
                    }
                } catch {
                    print("CUA_BENCHMARK model=\(model.id) case=\(name) seconds=\(Date().timeIntervalSince(start)) error=\(error)")
                    Issue.record(error)
                }
            }
            if #available(macOS 15, *) { await Gemma4LiteRTTranscriber.shared.shutdown() }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK"] == "1"))
    func writingDelegationWithGemma() async throws {
        let selected = ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK_MODEL"]
        let model = try #require(ComputerUseLocalPlanner.models.first { $0.available && (selected == nil || selected == $0.id) })
        let call = try await ComputerUseLocalPlanner.callTool(systemPrompt: ComputerUsePlannerClient.instructions,
            userPrompt: #"{"command":"Rewrite the entire text field to be shorter","latest_window_state":{"app_name":"TextEdit","elements":[{"element_id":"e1","element_index":1,"role":"AXTextArea","value":"Please send the report when you have time."}]},"prior_steps":[]}"#,
            model: model.id, tools: ComputerUseToolRegistry.nativeToolDefinitions()) { system, prompt in
                let output = try await model.backend.generate(systemPrompt: system, userPrompt: prompt)
                print("CUA_WRITING_RAW \(output)")
                return output
            }
        print("CUA_WRITING_BENCHMARK tool=\(call.name) args=\(call.arguments)")
        #expect(call.name == "edit_text")
        let decoded = try ComputerUsePlannerResponse.decodeNativeToolCall(name: call.name, arguments: call.arguments).toolCall
        #expect(decoded.scope == "field")
        #expect(decoded.elementID == "e1" || decoded.elementIndex == 1)
        if #available(macOS 15, *) { await Gemma4LiteRTTranscriber.shared.shutdown() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK"] == "1"))
    func writingGenerationWithGemma() async throws {
        let selected = ProcessInfo.processInfo.environment["MUESLI_CUA_BENCHMARK_MODEL"]
        let model = try #require(ComputerUseLocalPlanner.models.first { $0.available && (selected == nil || selected == $0.id) })
        var config = AppConfig()
        config.quilBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
        config.quilModel = String(model.id.dropFirst("local:gemma4-litert:".count))
        let original = "Please send the report when you have time."
        var output = original
        let target = ComputerUseTextEditing.Target(text: original, isCurrent: { output == original }, write: { output = $0; return .executed("verified test target") })
        let edit = try await ComputerUseTextEditing.prepare(target: target, instruction: "Make this shorter, preserving the request to send the report.") { text, instruction in
            try await WritingService.generate(selectedText: text, instruction: instruction, config: config,
                coordinator: TranscriptionCoordinator(), localOnly: true)
        }
        #expect(edit.apply().status == .executed)
        #expect(!output.isEmpty)
        #expect(output.count < original.count)
        #expect(output.lowercased().contains("report"))
        print("CUA_WRITING_BENCHMARK output=\(output)")
        if #available(macOS 15, *) { await Gemma4LiteRTTranscriber.shared.shutdown() }
    }
}
