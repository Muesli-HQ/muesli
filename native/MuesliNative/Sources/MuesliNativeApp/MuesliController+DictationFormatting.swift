import AppKit
import UniformTypeIdentifiers

@MainActor
extension MuesliController {
    func updateDictationFormatting(bundleID: String, _ mutate: (inout DictationAppFormatting) -> Void) {
        updateConfig {
            guard let index = $0.dictationAppFormattingRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
            mutate(&$0.dictationAppFormattingRules[index].formatting)
            $0.dictationAppFormattingRules[index].templateID = nil
            if $0.dictationAppFormattingRules[index].formatting == .unchanged {
                $0.dictationAppFormattingRules.remove(at: index)
            }
        }
    }

    func applyDictationFormattingTemplate(bundleID: String, templateID: String) {
        guard let template = (DictationFormattingTemplate.builtIns + config.dictationFormattingTemplates)
            .first(where: { $0.id == templateID }) else { return }
        updateConfig {
            guard let index = $0.dictationAppFormattingRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
            if template.formatting == .unchanged {
                $0.dictationAppFormattingRules.remove(at: index)
            } else {
                $0.dictationAppFormattingRules[index].formatting = template.formatting
                $0.dictationAppFormattingRules[index].templateID = template.id
            }
        }
    }

    func saveDictationFormattingTemplate(name: String, from rule: DictationAppFormattingRule) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MuesliSettings.Failure.rejected("Give this template a name.") }
        let templates = DictationFormattingTemplate.builtIns + config.dictationFormattingTemplates
        guard !templates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MuesliSettings.Failure.rejected("A template with that name already exists.")
        }
        guard rule.formatting != .unchanged,
              config.dictationAppFormattingRules.first(where: { $0.bundleID == rule.bundleID })?.formatting == rule.formatting else {
            throw MuesliSettings.Failure.rejected("This app's formatting changed. Close this window and try again.")
        }
        let template = DictationFormattingTemplate(id: "saved_" + UUID().uuidString, name: name, formatting: rule.formatting)
        updateConfig {
            $0.dictationFormattingTemplates.append(template)
            if let index = $0.dictationAppFormattingRules.firstIndex(where: { $0.bundleID == rule.bundleID }) {
                $0.dictationAppFormattingRules[index].templateID = template.id
            }
        }
        try verifySavedDictationFormattingTemplate(template)
    }

    func removeDictationFormattingTemplate(id: String) {
        updateConfig {
            $0.dictationFormattingTemplates.removeAll { $0.id == id }
            for index in $0.dictationAppFormattingRules.indices where $0.dictationAppFormattingRules[index].templateID == id {
                $0.dictationAppFormattingRules[index].templateID = nil
            }
        }
    }

    func addDictationFormattingApp(bundleID: String, name: String) {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.dictationAppFormattingRules.contains(where: { $0.bundleID == bundleID }) else { return }
        updateConfig {
            $0.dictationAppFormattingRules.append(.init(bundleID: bundleID, appName: name))
            $0.dictationFormattingSetupDismissed = true
        }
    }

    func removeDictationFormattingApp(bundleID: String) {
        updateConfig { $0.dictationAppFormattingRules.removeAll { $0.bundleID == bundleID } }
    }

    func chooseDictationFormattingApp(onChoose: @escaping (String, String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose an app for dictation formatting"
        panel.prompt = "Add App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            onChoose(bundleID,
                (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension)
        }
    }

    func dismissDictationFormattingSetup() {
        updateConfig { $0.dictationFormattingSetupDismissed = true }
    }

    func openDictationFormattingSettings() {
        dismissDictationFormattingSetup()
        appState.selectedSettingsPane = .dictation
        openSettingsTab()
    }
}
