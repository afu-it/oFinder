// ProgressWindowController.swift
// Port of ProgressWindowController.m: floating progress window shown while
// rsync / 7zz operations run.

import AppKit
import OFinderServices

final class ProgressWindowController: NSWindowController, NSWindowDelegate {

    /// Set by the caller right after the job starts.
    var cancelHandle: TransferHandle?

    /// Where the window is in the job's life. Kept as one value rather than a
    /// pair of flags because Cancel, the close button, and the completion
    /// callback all have to agree on it, and two flags let them disagree.
    private enum Stage {
        case running        // job is live; Cancel stops it
        case cancelling     // stop requested, waiting for the child to confirm
        case unconfirmed    // no confirmation in time; the user may leave
        case finished       // job reported back; the button is now Close
    }

    private var stage: Stage = .running
    private var confirmWatchdog: DispatchWorkItem?

    /// How long to wait for a cancelled job to report back before letting the
    /// user out. An archive job queued behind another has no child to signal
    /// yet, and a child wedged on an unresponsive mount may never answer.
    private static let confirmTimeout: TimeInterval = 10

    private let refreshCallback: () -> Void
    private let operationTitle: String

    private let progressBar = NSProgressIndicator()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let speedLabel = NSTextField(labelWithString: L10n.t("progress.calculating", "Calculating…"))
    private var cancelButton: NSButton!

    init(title: String, destinationFolder dst: String, refreshCallback: @escaping () -> Void) {
        self.refreshCallback = refreshCallback
        operationTitle = title
        titleLabel = NSTextField(labelWithString: "\(title)…")
        detailLabel = NSTextField(
            labelWithString: L10n.f("progress.destination", "Destination: %@", dst))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(titleLabel)

        // Detail (destination)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(detailLabel)

        // Progress bar
        progressBar.style = .bar
        progressBar.minValue = 0.0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0.0
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.startAnimation(nil)
        cv.addSubview(progressBar)

        // Speed / ETA
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(speedLabel)

        // Cancel
        cancelButton = NSButton(title: L10n.t("button.cancel", "Cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(cancelButton)

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: m),
            titleLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            detailLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            progressBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            progressBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            speedLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),

            cancelButton.centerYAnchor.constraint(equalTo: speedLabel.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
        ])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API (always called on the main thread)
    // ─────────────────────────────────────────────────────────────────────────

    func updateProgress(_ progress: Double, bytesTransferred bytesDone: UInt64,
                        totalBytes total: UInt64, speed bytesPerSec: Double,
                        etaSecs eta: Int64) {
        // Lines still in flight when the child was signalled would otherwise
        // overwrite "Cancelling…" with a live-looking percentage.
        guard case .running = stage else { return }

        // progress > 1.0 signals the sync-to-disk phase (OS write cache flush)
        if progress > 1.0 {
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            let sizeStr = total > 0 ? formattedSize(total) : formattedSize(bytesDone)
            speedLabel.stringValue = L10n.f("progress.syncing", "%@   Syncing…", sizeStr)
            return
        }

        if progressBar.isIndeterminate {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
        }
        // Progress only moves forward — rsync can re-baseline between files,
        // which would otherwise make the bar visibly jump backwards.
        if progress > progressBar.doubleValue { progressBar.doubleValue = progress }

        let pctStr = "\(Int(progressBar.doubleValue * 100))%"
        let sizeStr = formattedSize(bytesDone)
        let speedStr = formattedSpeed(bytesPerSec)
        let etaStr = eta > 0 ? formattedETA(eta) : "—"
        speedLabel.stringValue = "\(pctStr)  •  \(sizeStr)  •  \(speedStr)  •  ETA \(etaStr)"
    }

    func finish(success: Bool, errorMessage msg: String?) {
        let wasCancelling: Bool
        switch stage {
        case .cancelling, .unconfirmed: wasCancelling = true
        case .running, .finished: wasCancelling = false
        }
        stage = .finished
        cancelHandle = nil
        confirmWatchdog?.cancel()
        confirmWatchdog = nil

        // A cancelled job reports failure, but the user asked for it. Show
        // the folder as it now stands instead of an error panel: after a
        // cancelled move, what is where matters more than any message.
        if success || wasCancelling {
            close()
            refreshCallback()
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            titleLabel.stringValue = L10n.t("progress.failedTitle", "Operation failed")
            speedLabel.stringValue = msg ?? L10n.t("progress.unknownError", "Unknown error")
            cancelButton.title = L10n.t("button.close", "Close")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Actions
    // ─────────────────────────────────────────────────────────────────────────

    @IBAction private func cancelClicked(_ sender: Any?) {
        switch stage {
        case .cancelling:
            // Already asked. Closing here would hide a move that is still
            // deleting source files, which is the whole point of the button.
            return

        case .unconfirmed, .finished:
            dismiss()

        case .running:
            guard let handle = cancelHandle else {
                stage = .finished
                close()
                return
            }
            stage = .cancelling
            handle.cancel()

            cancelButton.isEnabled = false
            titleLabel.stringValue = L10n.t("progress.cancelling", "Cancelling…")
            speedLabel.stringValue = ""
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }

            let watchdog = DispatchWorkItem { [weak self] in self?.stopWasNotConfirmed() }
            confirmWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTimeout,
                                          execute: watchdog)
        }
    }

    /// Leaving from `.unconfirmed` means the job never reported back, so
    /// nothing has refreshed the listing — and a cancelled move may already
    /// have emptied part of it.
    private func dismiss() {
        if case .unconfirmed = stage { refreshCallback() }
        close()
    }

    /// Nobody confirmed the stop in time. Never trap the user in a window
    /// that cannot be closed: say what is actually known and let them out.
    private func stopWasNotConfirmed() {
        guard case .cancelling = stage else { return }
        stage = .unconfirmed
        confirmWatchdog = nil

        titleLabel.stringValue = L10n.t("progress.stillStopping", "Still stopping…")
        speedLabel.stringValue = L10n.t(
            "progress.stillStoppingDetail",
            "This is taking longer than expected. Closing this window is safe.")
        cancelButton.title = L10n.t("button.close", "Close")
        cancelButton.isEnabled = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSWindowDelegate
    // ─────────────────────────────────────────────────────────────────────────

    /// The close button is the same decision as Cancel. Letting it through
    /// while a job is live would put the bug back: the window disappears and
    /// the transfer keeps running where nobody can see or stop it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch stage {
        case .running:
            cancelClicked(nil)
            return false
        case .cancelling:
            return false
        case .unconfirmed:
            refreshCallback()
            return true
        case .finished:
            return true
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func formattedSize(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1024 * 1024 { return String(format: "%.1f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / 1024 / 1024) }
        return String(format: "%.2f GB", v / 1024 / 1024 / 1024)
    }

    private func formattedSpeed(_ bps: Double) -> String {
        if bps <= 0 { return "" }
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / 1024 / 1024)
    }

    private func formattedETA(_ secs: Int64) -> String {
        if secs < 0 { return "—" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
