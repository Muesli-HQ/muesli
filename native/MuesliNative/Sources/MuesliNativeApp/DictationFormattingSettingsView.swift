import SwiftUI
import MuesliCore

struct DictationFormattingSettingsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var usage: [InsightsUsage] = []
    @State private var loadFailed = false
    @State private var expandedAppIDs: Set<String> = []
    @State private var templateToSave: DictationAppFormattingRule?

    private var visibleRules: [DictationAppFormattingRule] {
        appState.config.dictationAppFormattingRules.filter {
            $0.formatting != .unchanged || expandedAppIDs.contains($0.bundleID)
        }
    }

    private var suggestions: [DictationFormattingSuggestion] {
        Array(DictationFormattingSuggestion.ranked(usage: usage,
            excluding: visibleRules).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set a writing style for each app.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)

            ForEach(visibleRules) { rule in
                DisclosureGroup(isExpanded: expansion(for: rule.bundleID)) {
                    VStack(alignment: .leading, spacing: 12) {
                        control("Template", id: "dictation_format_preset_" + rule.bundleID)
                        Text(templateDescription(rule.formatting))
                            .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preview").font(MuesliTheme.metadata()).foregroundStyle(MuesliTheme.textSecondary)
                            Text(rule.formatting.apply(to: DictationFormattingTemplate.previewText))
                                .font(MuesliTheme.callout())
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                        DisclosureGroup("Customize style") {
                            VStack(alignment: .leading, spacing: 12) {
                                control("Capitalization", id: "dictation_format_case_" + rule.bundleID,
                                    description: "Lowercase includes names, acronyms and links.")
                                control("Final period", id: "dictation_format_period_" + rule.bundleID,
                                    description: "Removing the final period keeps other punctuation.")
                                Button("Save as Template…") { templateToSave = rule }
                                    .disabled(rule.formatting == .unchanged)
                            }
                            .padding(.top, 12)
                        }

                        Button("Remove App", role: .destructive) {
                            controller.removeDictationFormattingApp(bundleID: rule.bundleID)
                        }.accessibilityLabel("Remove formatting for " + rule.appName)
                    }
                    .padding(.top, 12)
                } label: {
                    HStack(spacing: 10) {
                        TargetApplicationIconView(appName: rule.appName, bundleIdentifier: rule.bundleID, size: 28)
                            .accessibilityHidden(true)
                        Text(rule.appName).font(MuesliTheme.body())
                        Spacer()
                        Text(DictationFormattingTemplate.selected(for: rule,
                            saved: appState.config.dictationFormattingTemplates)?.name ?? "Custom")
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                }
                Divider()
            }

            if !suggestions.isEmpty {
                SettingsSectionHeading(title: "Your most-used apps")
                Text("From your last 30 days of dictation on this Mac. Nothing changes until you customize.")
                    .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top) {
                        TargetApplicationIconView(appName: suggestion.appName, bundleIdentifier: suggestion.bundleID, size: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.appName).font(MuesliTheme.font(.body).weight(.medium))
                            Text("\(suggestion.sessions) dictations · " + (suggestion.suggestsLowercaseChat
                                ? "Try lowercase chat, with no final period" : "Keep capitalization or customize punctuation"))
                                .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                        }
                        Spacer()
                        Button("Customize") {
                            beginEditing(bundleID: suggestion.bundleID, name: suggestion.appName)
                        }.accessibilityLabel("Customize dictation in " + suggestion.appName)
                    }
                }
            } else if visibleRules.isEmpty {
                Text(loadFailed ? "App usage couldn't be loaded. You can still choose any installed app."
                    : "Choose an app to get started. Suggestions appear here as you dictate into more apps.")
                    .font(MuesliTheme.font(.callout)).foregroundStyle(MuesliTheme.textSecondary)
            }
            Button("Add App…") { controller.chooseDictationFormattingApp(onChoose: beginEditing) }

            if !appState.config.dictationFormattingTemplates.isEmpty {
                DisclosureGroup("My templates (\(appState.config.dictationFormattingTemplates.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Removing a template keeps the formatting already applied to apps.")
                            .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                        ForEach(appState.config.dictationFormattingTemplates) { template in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.name).font(MuesliTheme.font(.body).weight(.medium))
                                    Text(template.formatting.apply(to: DictationFormattingTemplate.previewText))
                                        .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    controller.removeDictationFormattingTemplate(id: template.id)
                                }.accessibilityLabel("Remove template " + template.name)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
            }

            Text("Formatting changes capitalization and punctuation, not wording or tone. Browser rules apply to every website.")
                .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
            if !DictationAppFormattingRule.activeRules(appState.config.dictationAppFormattingRules).isEmpty {
                Text("Starting dictation in a formatted app delays insertion until you stop, using the receiving app’s rule. Sessions started elsewhere stay live and keep their original formatting, even if you switch apps.")
                    .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
            }
        }
        .task {
            do { usage = try await controller.insightsSnapshot(range: .thirtyDays).appUsage }
            catch { loadFailed = true }
        }
        .sheet(item: $templateToSave) { rule in
            DictationFormattingTemplateSheet(controller: controller, rule: rule)
        }
        .onChange(of: appState.config.dictationAppFormattingRules.map(\.bundleID)) { oldIDs, newIDs in
            let currentIDs = Set(newIDs)
            expandedAppIDs.formIntersection(currentIDs)
            expandedAppIDs.formUnion(currentIDs.subtracting(oldIDs))
        }
    }

    private func beginEditing(bundleID: String, name: String) {
        controller.addDictationFormattingApp(bundleID: bundleID, name: name)
        expandedAppIDs.insert(bundleID)
    }

    private func expansion(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { expandedAppIDs.contains(bundleID) },
            set: { isExpanded in
                if isExpanded { expandedAppIDs.insert(bundleID) }
                else {
                    expandedAppIDs.remove(bundleID)
                    if appState.config.dictationAppFormattingRules.first(where: { $0.bundleID == bundleID })?.formatting == .unchanged {
                        controller.removeDictationFormattingApp(bundleID: bundleID)
                    }
                }
            }
        )
    }

    private func templateDescription(_ formatting: DictationAppFormatting) -> String {
        switch formatting.preset {
        case "unchanged": "Keep the original formatting. Apps using Original do not need a saved rule."
        case "lowercase_chat": "Lowercase messages with no final period. Keeps questions, exclamations and ellipses."
        case "no_final_period": "Keep capitalization and drop the final period for a lighter chat style."
        default: "Use lowercase while keeping punctuation."
        }
    }

    private func control(_ label: String, id: String, description: String? = nil) -> some View {
        SettingsRow(label: label, description: description) {
            MuesliSettingControl(controller: controller, id: id)
        }
    }
}

private struct DictationFormattingTemplateSheet: View {
    let controller: MuesliController
    let rule: DictationAppFormattingRule
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save a writing template").font(MuesliTheme.font(.title2).bold())
            Text("Reuse this style in other apps. Each app keeps its own copy of the formatting.")
                .font(MuesliTheme.font(.callout)).foregroundStyle(MuesliTheme.textSecondary)
            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Template name")
            Text(rule.formatting.apply(to: DictationFormattingTemplate.previewText))
                .font(MuesliTheme.font(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if let errorMessage {
                SettingsNote(errorMessage, tone: .error)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Template") {
                    do {
                        try controller.saveDictationFormattingTemplate(name: name, from: rule)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// A skippable, one-time invitation for both existing and newly onboarded users.
/// Configuration remains available in Dictation settings after dismissal.
struct DictationFormattingSetupCard: View {
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        if !appState.config.dictationFormattingSetupDismissed,
           appState.config.dictationAppFormattingRules.isEmpty,
           appState.config.resolvedOnboardingUseCase.includesDictation {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your words, formatted for each app").font(MuesliTheme.font(.headline))
                Text("Prefer lowercase messages or fewer final periods? Set up formatting for your most-used apps.")
                    .font(MuesliTheme.font(.callout)).foregroundStyle(MuesliTheme.textSecondary)
                HStack {
                    Button("Set Up App Formatting") { controller.openDictationFormattingSettings() }
                    Button("Skip") { controller.dismissDictationFormattingSetup() }
                        .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, MuesliTheme.pageInset)
            .padding(.bottom, MuesliTheme.spacing12)
        }
    }
}
