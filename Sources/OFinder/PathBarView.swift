// PathBarView.swift
// The toolbar's location display: breadcrumbs that navigate, or a text field
// you can select and copy.

import AppKit
import OFinderServices

@MainActor
protocol PathBarViewDelegate: AnyObject {
    /// A crumb was clicked, or a typed path was committed.
    func pathBar(_ bar: PathBarView, didChoose path: String)
}

/// A borderless button that looks like text until the pointer finds it.
private final class CrumbButton: NSButton {
    var targetPath = ""
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        self.title = title
        font = .systemFont(ofSize: 12)
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // An NSButton title wraps by default, and a squeezed crumb turned
        // "afwazan" into four stacked letters instead of shortening it.
        if let cell = cell as? NSButtonCell {
            cell.wraps = false
            cell.lineBreakMode = .byTruncatingTail
        }
        usesSingleLineMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited,
                                                 .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidHide() { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

final class PathBarView: NSView, NSTextFieldDelegate {

    weak var delegate: PathBarViewDelegate?

    private let stack = NSStackView()
    private let field = NSTextField()
    private var path = ""

    /// Set while the field is open so a location arriving from elsewhere — a
    /// background refresh, the other pane — cannot wipe out half-typed text.
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        field.font = .systemFont(ofSize: 12)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = self
        field.isHidden = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            // Centred rather than pinned: if anything ever makes the bar wider
            // than its contents, the trail stays in the middle of the capsule
            // macOS draws around it instead of hugging one edge.
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -Self.horizontalPadding),

            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width follows the content, so the toolbar's flexible spaces can centre
    /// the bar on the crumbs themselves. A fixed minimum width made the trail
    /// sit at the left edge of a wider invisible box, which read as being off
    /// centre even though the box was not.
    override var intrinsicContentSize: NSSize {
        let width: CGFloat
        if isEditing {
            let attributes: [NSAttributedString.Key: Any] = [.font: field.font ?? .systemFont(ofSize: 12)]
            width = (field.stringValue as NSString).size(withAttributes: attributes).width
                + Self.fieldPadding
        } else {
            width = stack.fittingSize.width + Self.horizontalPadding * 2
        }
        // The ceiling follows the window rather than being a fixed number, so
        // a deep path keeps expanding as long as there is room, and only
        // truncates once it would reach the controls on either side.
        let sideControls: CGFloat = 380
        let ceiling = max(280, (window?.frame.width ?? 1000) - sideControls)
        // Showing the trail, the width is the trail: macOS draws a capsule
        // around the item at exactly the size reported here, and any floor
        // above the content leaves the crumbs adrift inside it. Editing keeps
        // a floor, because a field has to have somewhere to type.
        let floor: CGFloat = isEditing ? 220 : 0
        // Height comes from the tallest thing inside rather than a constant,
        // so the crumbs sit on the capsule's own centre line.
        let height = max(stack.fittingSize.height, field.fittingSize.height, 22)
        return NSSize(width: min(max(width, floor), ceiling), height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self,
                                                  name: NSWindow.didResizeNotification,
                                                  object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                               name: NSWindow.didResizeNotification,
                                               object: window)
    }

    /// The ceiling is derived from the window width, so it has to be
    /// recomputed when that changes.
    @objc private func windowResized() {
        invalidateIntrinsicContentSize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Bezel inset plus room for the caret at the end of the text.
    private static let fieldPadding: CGFloat = 22

    /// Space between the crumbs and the edge of the capsule macOS draws around
    /// the item. The capsule is exactly as wide as this view reports, so any
    /// inset has to be built into that width — there is nothing else to pad
    /// against.
    private static let horizontalPadding: CGFloat = 12

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Content
    // ─────────────────────────────────────────────────────────────────────────

    func show(path newPath: String) {
        guard !isEditing else { return }
        path = newPath
        rebuildCrumbs()
        invalidateIntrinsicContentSize()
    }

    private func crumbs(for path: String) -> [PathCrumb] {
        if RecentsService.isRecents(path) {
            return [PathCrumb(title: L10n.t("sidebar.recents", "Recents"), path: path)]
        }
        return PathCrumbs.split(path: path)
    }

    private func rebuildCrumbs() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let parts = crumbs(for: path)
        for (index, crumb) in parts.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "/")
                separator.font = .systemFont(ofSize: 12)
                separator.textColor = .tertiaryLabelColor
                separator.usesSingleLineMode = true
                separator.maximumNumberOfLines = 1
                separator.setContentCompressionResistancePriority(.required,
                                                                  for: .horizontal)
                stack.addArrangedSubview(separator)
            }
            let button = CrumbButton(title: crumb.title)
            button.targetPath = crumb.path
            button.target = self
            button.action = #selector(crumbClicked(_:))
            // The last crumb is where you already are, so clicking it should
            // do nothing rather than reload — but it still reads as part of
            // the trail, so it stays enabled-looking.
            button.isEnabled = index < parts.count - 1
            stack.addArrangedSubview(button)
        }
    }

    @objc private func crumbClicked(_ sender: CrumbButton) {
        delegate?.pathBar(self, didChoose: sender.targetPath)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Editing
    // ─────────────────────────────────────────────────────────────────────────

    /// Clicking the bar anywhere other than on a crumb opens the raw path for
    /// selecting, copying or editing. Crumbs keep their own click, so both
    /// behaviours live on the same control without a modifier key.
    override func mouseDown(with event: NSEvent) {
        guard !RecentsService.isRecents(path) else { return }
        beginEditing()
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        field.stringValue = path
        field.isHidden = false
        stack.isHidden = true
        invalidateIntrinsicContentSize()
        window?.makeFirstResponder(field)
        // Select everything: the reason to open this is usually to copy the
        // path, and a caret sitting in the middle of it helps nobody.
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing(commit: Bool) {
        guard isEditing else { return }
        let typed = field.stringValue
        isEditing = false
        field.isHidden = true
        stack.isHidden = false
        invalidateIntrinsicContentSize()
        window?.makeFirstResponder(nil)

        guard commit, let resolved = Self.resolve(typed), resolved != path else {
            rebuildCrumbs()
            return
        }
        delegate?.pathBar(self, didChoose: resolved)
    }

    /// Resolves typed input to an existing directory, quietly. A path bar that
    /// throws an alert for every mistyped character would be worse than one
    /// that simply declines.
    private static func resolve(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = ((trimmed as NSString).expandingTildeInPath as NSString)
            .resolvingSymlinksInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return expanded
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking away is a dismissal, not a commit: the field is opened to
        // read the path far more often than to change it.
        endEditing(commit: false)
    }
}
