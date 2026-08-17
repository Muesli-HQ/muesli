import AppKit
import Contacts
import ContactsUI
import SwiftUI

struct MeetingContactPicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onSelect: (CNContact) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard isPresented else { return }
        context.coordinator.presentIfNeeded(relativeTo: nsView)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: MeetingContactPicker
        private var picker: CNContactPicker?

        init(parent: MeetingContactPicker) {
            self.parent = parent
        }

        func presentIfNeeded(relativeTo view: NSView) {
            // A live picker owns the presentation state. `updateNSView` re-runs on any
            // SwiftUI re-render, so clearing the binding here would dismiss the popover
            // the user is still using.
            guard picker == nil else { return }

            // No window means no anchor, so bail out without leaving `isPresented` stuck
            // true. It is already true here, so a stale flag would make every later click
            // a no-op change — no updateNSView, no presentation, and a dead button.
            guard view.window != nil else {
                resetPresentation()
                return
            }

            // Deliberately no `displayedKeys`: per CNContactPicker.h, providing keys
            // switches the picker to selecting values rather than whole contacts.
            let picker = CNContactPicker()
            picker.delegate = self
            self.picker = picker

            // Present after the current SwiftUI update pass. Showing the popover
            // inline reads uncommitted layout for the anchor rect, and a synchronous
            // delegate callback would mutate state during view update.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.window != nil else {
                    self?.picker = nil
                    self?.resetPresentation()
                    return
                }
                guard self.picker === picker else { return }
                picker.showRelative(to: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
            parent.onSelect(contact)
            finish()
        }

        func contactPickerDidClose(_ picker: CNContactPicker) {
            finish()
        }

        private func finish() {
            picker = nil
            resetPresentation()
        }

        /// Always deferred: `presentIfNeeded` runs inside `updateNSView`, and clearing
        /// the binding synchronously there mutates state during a view update.
        private func resetPresentation() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isPresented else { return }
                self.parent.isPresented = false
            }
        }
    }
}
