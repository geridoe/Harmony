import SwiftUI

enum HarmonyReportTargetKind: String, CaseIterable, Identifiable {
    case profile
    case review
    case musicList = "music_list"
    case reviewComment = "review_comment"
    case musicListComment = "music_list_comment"

    var id: String { rawValue }
}

enum HarmonyReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, hate
    case sexualContent = "sexual_content"
    case violence, impersonation
    case selfHarm = "self_harm"
    case copyright, other

    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct HarmonyReportButton: View {
    let targetKind: HarmonyReportTargetKind
    let targetID: UUID
    @State private var isPresented = false

    var body: some View {
        Button(role: .destructive) { isPresented = true } label: {
            Label("Report", systemImage: "exclamationmark.bubble")
        }
        .accessibilityIdentifier("report-\(targetKind.rawValue)-\(targetID.uuidString)")
        .sheet(isPresented: $isPresented) {
            HarmonyReportSheet(targetKind: targetKind, targetID: targetID)
        }
    }
}

private struct HarmonyReportSheet: View {
    let targetKind: HarmonyReportTargetKind
    let targetID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var reason = HarmonyReportReason.spam
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var failure: String?
    private let repository = HarmonyCollaborationRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(HarmonyReportReason.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Additional details (optional)") {
                    TextEditor(text: $details)
                        .frame(minHeight: 110)
                        .accessibilityIdentifier("report-details")
                    Text("Do not include passwords, access tokens, or private contact information.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Submit report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(isSubmitting || details.count > 1_000)
                        .accessibilityIdentifier("report-submit")
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await repository.submitAbuseReport(
                targetKind: targetKind.rawValue,
                targetID: targetID,
                reason: reason.rawValue,
                details: details
            )
            dismiss()
        } catch {
            failure = "The report could not be submitted. Please try again."
        }
    }
}
