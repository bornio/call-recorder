import AppKit
import Combine
import CallRecorderCore
import SwiftUI

@MainActor
final class TranscriptReadingState: ObservableObject {
    @Published var followsAudio = true
    var anchor: (segment: Int, offset: Int, distance: CGFloat)?
    var consumedSearchNavigationID = -1
    var consumedPositionChangeID = 0

    func suspendFollowing() { if followsAudio { followsAudio = false } }
}

/// AppKit owns only native text selection, temporary highlighting, and scrolling.
/// The player owns time; the detail owns the user's follow choice and reading anchor.
struct TranscriptTextView: NSViewRepresentable {
    let document: TranscriptDocument
    let recording: RecordingManifest
    @ObservedObject var player: RecordingAudioPlayerModel
    @ObservedObject var reading: TranscriptReadingState
    let searchText: String
    let activeMatch: TranscriptSearchMatch?
    let searchNavigationID: Int
    let rename: (TranscriptSegment) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        let text = scroll.transcript
        text.delegate = context.coordinator
        context.coordinator.scroll = scroll
        scroll.interaction = { [weak coordinator = context.coordinator] in coordinator?.userInteraction() }
        scroll.willReflow = { [weak coordinator = context.coordinator] in coordinator?.saveAnchor() }
        scroll.didReflow = { [weak coordinator = context.coordinator] in coordinator?.restoreAfterReflow() }
        return scroll
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scroll: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.saveAnchor()
        scroll.interaction = nil
        scroll.willReflow = nil
        scroll.didReflow = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scroll: TranscriptScrollView?
        private var input: TranscriptTextView?
        private var timeline: TranscriptPlaybackTimeline?
        private var bodies: [NSRange] = []
        private var speakers: [NSRange] = []
        private var timestamps: [NSRange] = []
        private var renderedDocument: TranscriptDocument?
        private var renderedNames: [String] = []
        private var renderedSearch = ""
        private var renderedActiveMatch: TranscriptSearchMatch?
        private var currentEntries: [TranscriptPlaybackTimeline.Entry] = []
        private var wasPreview = false
        private var wasFollowing = false
        private var lastFollowStart: Double = -.infinity
        private var updatingText = false
        private var renderedCanSeek = false
        private var searchRanges: [(match: TranscriptSearchMatch, range: NSRange)] = []

        func update(_ value: TranscriptTextView) {
            scroll?.withProgrammaticChanges { updateContent(value) }
        }

        private func updateContent(_ value: TranscriptTextView) {
            guard let scroll else { return }
            input = value
            let names = value.document.segments.map {
                value.recording.speakerDisplayName(channel: $0.channel, speaker: $0.speaker)
            }
            let documentChanged = renderedDocument != value.document
            let changed = documentChanged || names != renderedNames
            if changed {
                saveAnchor()
                if documentChanged { timeline = TranscriptPlaybackTimeline(document: value.document) }
                renderedDocument = value.document
                renderedNames = names
                rebuildText(names: names)
                restoreAnchor()
            }
            let explicitSeek = value.reading.consumedPositionChangeID != value.player.positionChangeID
            value.reading.consumedPositionChangeID = value.player.positionChangeID
            let resumedFollowing = value.reading.followsAudio && !wasFollowing
            wasFollowing = value.reading.followsAudio
            if explicitSeek || resumedFollowing || documentChanged { lastFollowStart = -.infinity }

            let active = value.player.errorMessage == nil && !value.player.isLoading
                ? timeline?.activeEntries(at: value.player.displayTime, duration: value.player.duration) ?? []
                : []
            let preview = value.player.previewTime != nil
            if changed || renderedSearch != value.searchText {
                searchRanges = TranscriptSearchMatch.find(in: value.document, query: value.searchText) {
                    value.recording.speakerDisplayName(channel: $0.channel, speaker: $0.speaker)
                }.compactMap { match in searchRange(match).map { (match, $0) } }
            }
            if changed || active != currentEntries || preview != wasPreview ||
                renderedSearch != value.searchText || renderedActiveMatch != value.activeMatch {
                currentEntries = active
                wasPreview = preview
                renderedSearch = value.searchText
                renderedActiveMatch = value.activeMatch
                updateHighlights()
            }
            if changed || renderedCanSeek != value.player.canSeek {
                renderedCanSeek = value.player.canSeek
                updateTimestampLinks()
            }
            if value.reading.consumedSearchNavigationID != value.searchNavigationID {
                value.reading.consumedSearchNavigationID = value.searchNavigationID
                if let match = value.activeMatch, let range = searchRange(match) {
                    reveal(range, force: true)
                    saveAnchor()
                    return
                }
            }
            guard !preview, scroll.window?.isVisible == true,
                  scroll.window?.isMiniaturized == false, !NSApp.isHidden,
                  !scroll.isHiddenOrHasHiddenAncestor else { return }
            if explicitSeek || resumedFollowing {
                revealPlayback(force: true)
            } else if value.reading.followsAudio {
                revealPlayback(force: false)
            }
        }

        private func rebuildText(names: [String]) {
            guard let value = input, let textView = scroll?.transcript else { return }
            let selection = textView.selectedRange()
            let oldRegions = zip(zip(speakers, timestamps), bodies).flatMap { [$0.0.0, $0.0.1, $0.1] }
            func anchor(for character: Int) -> (Int, Int)? {
                guard let index = oldRegions.lastIndex(where: { $0.location <= character }) else { return nil }
                return (index, character - oldRegions[index].location)
            }
            let selectionStart = anchor(for: selection.location)
            let selectionEnd = anchor(for: NSMaxRange(selection))
            let text = NSMutableAttributedString()
            bodies = []; speakers = []; timestamps = []
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 4
            bodyStyle.paragraphSpacing = 20
            bodyStyle.baseWritingDirection = .natural
            let headingStyle = NSMutableParagraphStyle()
            headingStyle.paragraphSpacing = 6
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            for (index, segment) in value.document.segments.enumerated() {
                let speakerStart = text.length
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: headingStyle,
                ]
                if !(value.recording.effectiveOrigin == .nativeRecording && segment.channel == 1) {
                    attributes[.link] = "speaker:\(index)"
                    attributes[.toolTip] = "Rename this speaker"
                }
                text.append(NSAttributedString(string: names[index], attributes: attributes))
                speakers.append(NSRange(location: speakerStart, length: text.length - speakerStart))
                text.append(NSAttributedString(string: "    ", attributes: attributes.filter { $0.key != .link }))
                let timeStart = text.length
                text.append(NSAttributedString(string: formattedRecordingDuration(segment.start), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: headingStyle,
                ]))
                timestamps.append(NSRange(location: timeStart, length: text.length - timeStart))
                text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: headingStyle]))
                bodies.append(NSRange(location: text.length, length: segment.text.utf16.count))
                text.append(NSAttributedString(string: segment.text + "\n", attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyStyle,
                ]))
            }
            // Highlight changes use layout-manager attributes; only actual document or
            // speaker text changes replace storage. Preserve selection when still valid.
            updatingText = true
            textView.textStorage?.setAttributedString(text)
            let regions = zip(zip(speakers, timestamps), bodies).flatMap { [$0.0.0, $0.0.1, $0.1] }
            if let start = selectionStart, let end = selectionEnd,
               regions.indices.contains(start.0), regions.indices.contains(end.0) {
                let lower = min(text.length, regions[start.0].location + min(start.1, regions[start.0].length))
                let upper = min(text.length, regions[end.0].location + min(end.1, regions[end.0].length))
                textView.setSelectedRange(NSRange(location: lower, length: max(0, upper - lower)))
            } else if selection.location <= text.length, selection.length <= text.length - selection.location {
                textView.setSelectedRange(selection)
            }
            updatingText = false
        }

        private func updateTimestampLinks() {
            guard let value = input, let storage = scroll?.transcript.textStorage else { return }
            for (index, range) in timestamps.enumerated() {
                let segment = value.document.segments[index]
                let valid = segment.start.isFinite && segment.end.isFinite && segment.start >= 0 &&
                    segment.end > segment.start && segment.start < value.player.duration &&
                    segment.end <= value.player.duration + 0.25
                if value.player.canSeek && valid {
                    storage.addAttributes([.link: "seek:\(index)", .toolTip: "Seek without changing play or pause"], range: range)
                } else {
                    storage.removeAttribute(.link, range: range)
                    storage.addAttribute(.toolTip, value: "Audio or timing is unavailable for this passage", range: range)
                }
            }
        }

        private func updateHighlights() {
            guard let value = input, let textView = scroll?.transcript, let layout = textView.layoutManager else { return }
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            for entry in currentEntries {
                guard bodies.indices.contains(entry.segmentIndex) else { continue }
                let range = NSRange(location: bodies[entry.segmentIndex].location + entry.text.range.location,
                                    length: entry.text.range.length)
                layout.addTemporaryAttributes([
                    .backgroundColor: (wasPreview ? NSColor.systemOrange : NSColor.controlAccentColor).withAlphaComponent(0.18),
                    .underlineStyle: wasPreview ? NSUnderlineStyle.patternDash.rawValue | NSUnderlineStyle.single.rawValue
                        : NSUnderlineStyle.single.rawValue,
                ], forCharacterRange: range)
            }
            guard !value.searchText.isEmpty else { return }
            for (match, range) in searchRanges {
                layout.addTemporaryAttribute(.backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(match == value.activeMatch ? 0.65 : 0.3),
                    forCharacterRange: range)
                if match == value.activeMatch {
                    layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.double.rawValue, forCharacterRange: range)
                }
            }
        }

        private func searchRange(_ match: TranscriptSearchMatch) -> NSRange? {
            guard let value = input, bodies.indices.contains(match.segmentIndex), !value.searchText.isEmpty else { return nil }
            let base = match.field == .speaker ? speakers[match.segmentIndex] : bodies[match.segmentIndex]
            guard let string = scroll?.transcript.string as NSString? else { return nil }
            var remaining = base
            for occurrence in 0...match.occurrenceIndex {
                let found = string.range(of: value.searchText, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                guard found.location != NSNotFound else { return nil }
                if occurrence == match.occurrenceIndex { return found }
                remaining = NSRange(location: NSMaxRange(found), length: NSMaxRange(base) - NSMaxRange(found))
            }
            return nil
        }

        private func revealPlayback(force: Bool) {
            guard let value = input, let timeline else { return }
            let candidate = currentEntries.last ?? (force ? timeline.entries.last {
                $0.text.start <= value.player.currentTime && $0.text.start < value.player.duration &&
                    $0.text.end <= value.player.duration + 0.25
            } : nil)
            guard let candidate, bodies.indices.contains(candidate.segmentIndex),
                  force || candidate.text.start >= lastFollowStart else { return }
            lastFollowStart = candidate.text.start
            reveal(NSRange(location: bodies[candidate.segmentIndex].location + candidate.text.range.location,
                           length: candidate.text.range.length), force: force)
        }

        private func reveal(_ range: NSRange, force: Bool) {
            guard let scroll, let layout = scroll.transcript.layoutManager,
                  let container = scroll.transcript.textContainer else { return }
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += scroll.transcript.textContainerOrigin.y
            let visible = scroll.contentView.bounds
            if rect.height > visible.height * 0.7 {
                rect = layout.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: min(1, glyphs.length)), in: container)
                rect.origin.y += scroll.transcript.textContainerOrigin.y
            }
            guard force || rect.minY < visible.minY + 16 || rect.maxY > visible.maxY - 16 else { return }
            let target = max(0, min(rect.minY - visible.height * 0.25, scroll.transcript.bounds.height - visible.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func userInteraction() { input?.reading.suspendFollowing() }

        func textViewDidChangeSelection(_ notification: Notification) {
            if !updatingText, scroll?.transcript.handlingLink != true { userInteraction() }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let value = input, let key = link as? String,
                  let index = Int(key.split(separator: ":").last ?? ""),
                  value.document.segments.indices.contains(index) else { return true }
            let segment = value.document.segments[index]
            if key.hasPrefix("seek:") { value.player.seek(to: segment.start) }
            if key.hasPrefix("speaker:") { userInteraction(); value.rename(segment) }
            return true
        }

        func saveAnchor() {
            guard let value = input, let scroll, let layout = scroll.transcript.layoutManager,
                  let container = scroll.transcript.textContainer, !bodies.isEmpty, layout.numberOfGlyphs > 0 else { return }
            var point = scroll.contentView.bounds.origin
            point.y -= scroll.transcript.textContainerOrigin.y
            let glyph = min(layout.glyphIndex(for: point, in: container), layout.numberOfGlyphs - 1)
            let character = layout.characterIndexForGlyph(at: glyph)
            let segment = bodies.lastIndex(where: { $0.location <= character }) ?? 0
            let offset = max(0, min(character - bodies[segment].location, bodies[segment].length - 1))
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            value.reading.anchor = (segment, offset, scroll.contentView.bounds.minY - rect.minY - scroll.transcript.textContainerOrigin.y)
        }

        private func restoreAnchor() {
            guard let value = input, let anchor = value.reading.anchor, let scroll,
                  !bodies.isEmpty, let layout = scroll.transcript.layoutManager,
                  let container = scroll.transcript.textContainer else { return }
            layout.ensureLayout(for: container)
            let body = bodies[min(anchor.segment, bodies.count - 1)]
            let range = NSRange(location: body.location + min(anchor.offset, max(0, body.length - 1)), length: 1)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let y = max(0, min(rect.minY + scroll.transcript.textContainerOrigin.y + anchor.distance,
                              scroll.transcript.bounds.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func restoreAfterReflow() {
            if input?.reading.followsAudio == true { revealPlayback(force: false) } else { restoreAnchor() }
        }
    }
}

@MainActor
final class TranscriptScrollView: NSScrollView {
    let transcript = ReadingTextView()
    var interaction: (() -> Void)?
    var willReflow: (() -> Void)?
    var didReflow: (() -> Void)?
    private var programmaticDepth = 0
    private var boundsObserver: AnyCancellable?
    private var previousOrigin = NSPoint.zero

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        let scroller = ReadingScroller()
        scroller.interaction = { [weak self] in self?.interaction?() }
        verticalScroller = scroller
        transcript.interaction = { [weak self] in self?.interaction?() }
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainerInset = NSSize(width: 28, height: 18)
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        transcript.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        transcript.setAccessibilityLabel("Transcript")
        transcript.setAccessibilityHelp("Selectable transcript. Timestamp links seek without starting playback. Scrolling or selecting text stops following audio.")
        documentView = transcript
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.publisher(
            for: NSView.boundsDidChangeNotification, object: contentView
        ).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let moved = self.previousOrigin != self.contentView.bounds.origin
                self.previousOrigin = self.contentView.bounds.origin
                // Includes accessibility scroll actions, without mistaking our own
                // reveals, text replacement, or layout reflow for manual reading.
                if moved && self.programmaticDepth == 0 { self.interaction?() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func scrollWheel(with event: NSEvent) { interaction?(); super.scrollWheel(with: event) }

    override func setFrameSize(_ newSize: NSSize) {
        withProgrammaticChanges {
            let reflow = frame.width != newSize.width
            if reflow { willReflow?() }
            super.setFrameSize(newSize)
            if reflow { didReflow?() }
        }
    }

    override func layout() {
        withProgrammaticChanges { super.layout() }
    }

    func withProgrammaticChanges(_ action: () -> Void) {
        programmaticDepth += 1
        defer { programmaticDepth -= 1 }
        action()
    }
}

@MainActor
final class ReadingTextView: NSTextView {
    var interaction: (() -> Void)?
    private(set) var handlingLink = false
    override func mouseDown(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        handlingLink = index < (textStorage?.length ?? 0) && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        if !handlingLink { interaction?() }
        defer { handlingLink = false }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) { interaction?(); super.keyDown(with: event) }
}

@MainActor
private final class ReadingScroller: NSScroller {
    var interaction: (() -> Void)?
    override func mouseDown(with event: NSEvent) { interaction?(); super.mouseDown(with: event) }
}
