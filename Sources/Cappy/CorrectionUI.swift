import AppKit
import SwiftUI

private final class CorrectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Uses the IMK client's own caret rectangle. No Accessibility APIs or permissions.
/// Panels never become key; invalid/off-screen geometry simply skips presentation.
final class CorrectionOverlayController: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    func show(_ presentation: SessionPresentation, client: any CorrectionClient,
              primary: @escaping () -> Void, secondary: @escaping () -> Void,
              expired: @escaping () -> Void = {}) -> Bool {
        hide()
        guard let rect = client.caretRect(), rect.height > 0, rect.height < 200,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) else { return false }
        let message: String, action: String, dismiss: String, duration: TimeInterval
        switch presentation {
        case .corrected(let correction):
            message = "\(correction.original) → \(correction.replacement)"; action = "Undo"; dismiss = ""; duration = 2
        case .suggestion(let correction):
            message = "\(correction.original) → \(correction.replacement)"; action = "Tab"; dismiss = "×"; duration = 5
        case .manualCorrected(let count):
            message = "Corrected \(count) \(count == 1 ? "mistake" : "mistakes")"; action = "Undo"; dismiss = ""; duration = 5
        case .status(let text):
            message = text; action = "OK"; dismiss = ""; duration = 3
        case .keep(let source):
            message = "Keep “\(source)”\(source.contains(" ") ? " here" : " next time")?"
            action = source.contains(" ") ? "Always Keep Here" : "Always Keep"; dismiss = "Not Now"; duration = 5
        }
        primaryAction = primary; secondaryAction = secondary
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: action, target: self, action: #selector(performPrimary))
        button.bezelStyle = .inline; button.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [label, button]); stack.spacing = 10
        if !dismiss.isEmpty {
            let close = NSButton(title: dismiss, target: self, action: #selector(performSecondary))
            close.bezelStyle = .inline; close.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(close)
        }
        let width = min(520, max(200, stack.fittingSize.width + 24))
        let size = NSSize(width: width, height: 34)
        let frame = screen.visibleFrame
        let origin = NSPoint(x: min(max(rect.minX, frame.minX), frame.maxX - width),
            y: min(max(rect.minY - size.height - 5, frame.minY), frame.maxY - size.height))
        let window = CorrectionPanel(contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu; window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 8
        background.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        window.contentView = background; panel = window; window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.hide(); expired() }
        return true
    }
    func hide() {
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil
        primaryAction = nil; secondaryAction = nil
    }
    @objc private func performPrimary() { let action = primaryAction; hide(); action?() }
    @objc private func performSecondary() { let action = secondaryAction; hide(); action?() }
}

final class PersonalisationSettingsController {
    static let shared = PersonalisationSettingsController()
    private var window: NSWindow?
    func show() {
        if let window {
            ProtectedWords.shared.reload()
            window.contentView = NSHostingView(rootView: PersonalisationSettingsView())
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Cappy Personalisation"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PersonalisationSettingsView())
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PersonalisationSettingsView: View {
    @State private var revision = 0
    @State private var newWord = ""
    @State private var error = ""
    private let protected = ProtectedWords.shared
    private let store = PersonalizationStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cappy Personalisation").font(.title2.bold())
            Text("Learning stays on this Mac. Remove a preference to restore Cappy’s default behaviour.").font(.callout).foregroundColor(.secondary)
            HStack {
                TextField("Word to always keep", text: $newWord).onSubmit(addWord)
                Button("Add", action: addWord)
            }
            if !error.isEmpty { Text(error).foregroundColor(.red).font(.caption) }
            TabView {
                List {
                    ForEach(protected.words.sorted(), id: \.self) { word in
                        HStack {
                            Text(word); Spacer()
                            Button("Remove") {
                                if protected.remove(word) { store.removeVocabulary(word); store.flush(); revision += 1 }
                                else { error = "Could not save protected words." }
                            }
                        }
                    }
                }.tabItem { Text("Protected Words") }
                List {
                    ForEach(store.records.keys.sorted(), id: \.self) { key in
                        if let record = store.records[key] {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(record.source) → \(record.replacement)")
                                    Text("Accepted \(record.automaticAccepted + record.suggestionsAccepted) · Undone \(record.automaticUndone) · Dismissed \(record.suggestionsRejected) · Ignored \(record.suggestionsIgnored)\(record.explicitlySuppressed == true ? " · Suppressed" : record.context.isEmpty ? "" : " · Context-specific")")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Remove") { store.removeRecord(key); store.flush(); revision += 1 }
                            }
                        }
                    }
                }.tabItem { Text("Learned Corrections") }
                List {
                    ForEach(store.vocabulary.keys.sorted(), id: \.self) { word in
                        HStack {
                            Text(word)
                            Text(store.vocabularyState(word, protectedWords: protected).rawValue).foregroundColor(.secondary)
                            Spacer()
                            Button("Always Keep") { newWord = word; addWord() }
                            Button("Remove") { store.removeVocabulary(word); store.flush(); revision += 1 }
                        }
                    }
                }.tabItem { Text("Observed Vocabulary") }
            }
            Text("Correct written text: ⌘⌥⇧C. Select text, or review the paragraph before the caret.").font(.caption).foregroundColor(.secondary)
            Text("Automatic ≥ 0.98 · Suggestion ≥ 0.75 · Weaker candidates stay untouched").font(.caption).foregroundColor(.secondary)
        }.padding(20).id(revision)
    }
    private func addWord() {
        if protected.protect(newWord) { newWord = ""; error = ""; revision += 1 }
        else { error = "Enter one word (up to 32 letters or apostrophes). Check that the file is writable." }
    }
}
