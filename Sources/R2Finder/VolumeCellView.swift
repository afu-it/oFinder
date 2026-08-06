// VolumeCellView.swift
// Sidebar row for a mounted volume: icon, name, capacity bar, free space.

import AppKit

final class VolumeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bar = CapacityBarView()
    private let freeLabel = NSTextField(labelWithString: "")

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
        addSubview(freeLabel)

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
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 4),

            freeLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            freeLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            freeLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, icon: NSImage?, capacity: VolumeCapacity) {
        nameLabel.stringValue = name
        iconView.image = icon
        bar.fraction = capacity.usedFraction

        let free = Self.sizeFormatter.string(fromByteCount: capacity.available)
        let total = Self.sizeFormatter.string(fromByteCount: capacity.total)
        freeLabel.stringValue = L10n.f("volume.freeOfTotal", "%@ free of %@", free, total)
    }
}
