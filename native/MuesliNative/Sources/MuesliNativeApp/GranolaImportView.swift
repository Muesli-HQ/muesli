import SwiftUI
import UniformTypeIdentifiers
import MuesliCore

struct GranolaImportView: View {
    let controller: MuesliController
    @Environment(\.dismiss) private var dismiss
    @State private var showsExportGuide = true
    @State private var showsLargeGuide = false
    @State private var choosingFiles = false
    @State private var records: [GranolaImportRecord] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var report: GranolaImportReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import from Granola").font(MuesliTheme.title2())
                Spacer()
                Button(report == nil ? "Cancel" : "Done") { dismiss() }.disabled(busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report {
                        Label(report.imported > 0 ? "Your meetings have been imported." : "These meetings are already in muesli.", systemImage: "checkmark.circle")
                            .font(MuesliTheme.font(.headline))
                    } else {
                        if showsExportGuide {
                            Button { showsLargeGuide = true } label: {
                                GranolaExportGuideImage()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand illustrated Granola export guide")
                        }
                        Button(records.isEmpty ? "Choose ZIP or CSV…" : "Choose different files…") { choosingFiles = true }
                            .disabled(busy)
                        if !records.isEmpty {
                            ForEach(Array(records.prefix(50).enumerated()), id: \.offset) { _, record in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title.isEmpty ? "Untitled document" : record.title).fontWeight(.medium)
                                    Text("Created \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.workspace)")
                                        .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textSecondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                            if records.count > 50 { Text("Previewing the first 50 meetings").font(MuesliTheme.font(.caption)) }
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Processing export…") }
                Spacer()
                if report == nil && !records.isEmpty {
                    Button("Import \(records.count) meetings") { importRecords() }
                        .buttonStyle(.borderedProminent)
                        .disabled(records.isEmpty || busy)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: report != nil ? 160 : (records.isEmpty ? 360 : 620))
        .foregroundStyle(MuesliTheme.textPrimary)
        .background(MuesliTheme.backgroundBase)
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $showsLargeGuide) { GranolaExportGuideView() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.commaSeparatedText, .zip], allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let error): errorMessage = error.localizedDescription
            case .success(let urls):
                busy = true; errorMessage = nil; records = []
                Task { @MainActor in
                    defer { busy = false }
                    do {
                        records = try await Task.detached(priority: .userInitiated) { try GranolaImport.read(files: urls) }.value
                        showsExportGuide = false
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func importRecords() {
        busy = true; errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do { report = try await controller.importGranolaMeetings(records) }
            catch { errorMessage = "Nothing was imported. \(error.localizedDescription)" }
        }
    }
}

private struct GranolaExportGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GranolaExportGuideImage()
            .padding(16)
            .frame(width: 1048)
            .background(MuesliTheme.backgroundBase)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close guide")
                .keyboardShortcut(.cancelAction)
                .padding(8)
            }
    }
}

private struct GranolaExportGuideImage: View {
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "granola-export-guide", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel("Illustrated guide: open Granola’s workspace menu, choose Settings, then Profile. Under Export historical data, choose Generate CSV, select your workspaces, and confirm.")
        } else {
            Text("In Granola: Settings → Profile → Export historical data → Generate CSV.")
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }
}
