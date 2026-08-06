// VolumeCellView.swift
// Sidebar row for a mounted volume: icon, name, capacity bar, free space.

import AppKit

final class VolumeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bar = CapacityBarView()
    private let freeLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file          // matches what Finder reports
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        imageView = iconView

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        textField = nameLabel

        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        freeLabel.translatesAutoresizingMaskIntoConstraints = false
        freeLabel.font = .systemFont(ofSize: 10)
        freeLabel.textColor = .secondaryLabelColor
        freeLabel.lineBreakMode = .byTruncatingTail
        // Hug the text, so the label's trailing edge — and with it the bar's —
        // sits at the end of the words rather than at the edge of the sidebar.
        freeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(freeLabel)

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .systemFont(ofSize: 10)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        // Must not be the thing that gives way when the sidebar narrows: it is
        // two or three characters, and the free-space text truncates far more
        // gracefully.
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(percentLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // The bar lines up under the name, not the icon: it describes the
            // volume, and starting it at the icon would make it read as part
            // of the disclosure column.
            bar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            bar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 4),
            // Width follows the line beneath instead of stretching to the
            // edge: a bar wider than its own caption reads as a separate
            // element rather than as a heading for it.
            bar.trailingAnchor.constraint(equalTo: freeLabel.trailingAnchor),

            freeLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            freeLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),

            // Pinned to the row's right edge, on the bar's line. Keeping the
            // number level with the bar lets the eye read fill and figure
            // together, and leaves the caption a clear line of its own.
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            percentLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bar.trailingAnchor,
                                                  constant: 6),
            freeLabel.trailingAnchor.constraint(lessThanOrEqualTo: percentLabel.leadingAnchor,
                                                constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, icon: NSImage?, capacity: VolumeCapacity) {
        nameLabel.stringValue = name
        iconView.image = icon
        bar.fraction = capacity.usedFraction

        // The total is left out on purpose. At the sidebar's usual width there
        // is room for about 144pt of text, and free-plus-total already
        // measures 140pt before the percentage needs anywhere to go. The bar
        // shows the proportion, the percentage puts a number on it, and free
        // space is the figure someone acts on — the total is the one that can
        // go.
        let free = Self.sizeFormatter.string(fromByteCount: capacity.available)
        freeLabel.stringValue = L10n.f("volume.free", "%@ free", free)

        // No localized format: digits and "%" read the same everywhere this
        // ships, and a key would be a translation nobody can get wrong or
        // right.
        percentLabel.stringValue = "\(Int((capacity.usedFraction * 100).rounded()))%"
    }
}
