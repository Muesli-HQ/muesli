import AppKit
import Contacts
import ContactsUI
import SwiftUI

@MainActor
protocol MeetingContactPresenting: AnyObject {
    func present(
        relativeTo view: NSView,
        rect: NSRect,
        preferredEdge: NSRectEdge,
        onSelect: @escaping (CNContact) -> Void,
        onClose: @escaping () -> Void
    )
    func close()
}

/// Owns the out-of-process whole-contact picker for both notification cards and SwiftUI.
@MainActor
final class MeetingContactPickerPresenter: NSObject, CNContactPickerDelegate, MeetingContactPresenting {
    private var picker: CNContactPicker?
    private var onSelect: ((CNContact) -> Void)?
    private var onClose: (() -> Void)?

    func present(
        relativeTo view: NSView,
        rect: NSRect,
        preferredEdge: NSRectEdge,
        onSelect: @escaping (CNContact) -> Void,
        onClose: @escaping () -> Void
    ) {
        guard picker == nil else { return }
        self.onSelect = onSelect
        self.onClose = onClose
        guard view.window != nil else {
            finish()
            return
        }

        // Providing displayedKeys switches ContactsUI to selecting values, not contacts.
        let picker = CNContactPicker()
        picker.delegate = self
        self.picker = picker
        // Wait for SwiftUI/AppKit to commit the anchor's layout.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.picker === picker else { return }
            guard let view, view.window != nil else {
                self.finish()
                return
            }
            picker.showRelative(to: rect, of: view, preferredEdge: preferredEdge)
        }
    }

    func close() {
        let currentPicker = picker
        // Clear ownership before ContactsUI can call its delegate during close().
        finish()
        currentPicker?.close()
    }

    func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
        guard self.picker === picker else { return }
        let select = onSelect
        select?(contact)
        // Selection can synchronously replace/close the presentation.
        guard self.picker === picker else { return }
        close()
    }

    func contactPickerDidClose(_ picker: CNContactPicker) {
        guard self.picker === picker else { return }
        finish()
    }

    private func finish() {
        let callback = onClose
        picker = nil
        onSelect = nil
        onClose = nil
        callback?()
    }
}

struct MeetingContactPicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onSelect: (CNContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if isPresented {
            context.coordinator.presentIfNeeded(relativeTo: nsView)
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator {
        var parent: MeetingContactPicker
        private let presenter: any MeetingContactPresenting = MeetingContactPickerPresenter()
        private var presentationID: UUID?

        init(parent: MeetingContactPicker) { self.parent = parent }

        func presentIfNeeded(relativeTo view: NSView) {
            guard presentationID == nil else { return }
            let id = UUID()
            presentationID = id
            presenter.present(relativeTo: view, rect: view.bounds, preferredEdge: .maxY, onSelect: { [weak self] contact in
                guard let self, self.presentationID == id else { return }
                self.parent.onSelect(contact)
            }, onClose: { [weak self] in
                // Delegate callbacks may arrive inside updateNSView. Keep binding writes deferred,
                // and don't let a stale reset dismiss a newer presentation.
                DispatchQueue.main.async {
                    guard let self, self.presentationID == id else { return }
                    self.presentationID = nil
                    if self.parent.isPresented { self.parent.isPresented = false }
                }
            })
        }

        func close() {
            presentationID = nil
            presenter.close()
        }
    }
}
