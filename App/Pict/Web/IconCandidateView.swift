import AppKit
import PictKit
import SwiftUI

/// The "is this the one?" step, shown over the browser rather than after it.
///
/// Presented as an overlay on top of the still-open page: closing the browser to
/// ask this question is what made the earlier version's warning useless, since
/// acting on it meant finding the page again. Here, *Choose Another* is a dismissal
/// and the search results are exactly where they were left.
struct IconCandidateView: View {

    let candidate: IconCandidate
    let row: IconTargetRow
    var onUse: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            facts
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 24, y: 6)
    }

    // MARK: The picture

    private var preview: some View {
        ZStack {
            // A chequerboard, because "does this have transparency?" is the question
            // the preview exists to answer and a flat backdrop cannot answer it: a
            // white swatch behind a white-background PNG looks exactly like a
            // free-form icon until it reaches the Dock.
            Chequerboard()
            Image(nsImage: NSImage(cgImage: candidate.image,
                                   size: NSSize(width: candidate.pixelWidth,
                                                height: candidate.pixelHeight)))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 160, height: 160)
                .padding(24)
        }
        .frame(height: 208)
    }

    // MARK: What is wrong with it, if anything

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(candidate.pixelWidth) × \(candidate.pixelHeight)")
                    .font(.callout.monospacedDigit())
                Spacer()
                Text(candidate.shapeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(candidate.notes) { note in
                Label {
                    Text(note.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.level.symbol).foregroundStyle(tint(note.level))
                }
            }

            HStack {
                Button("Choose Another", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // Enabled whatever the notes say. Every one of them is advice about
                // a picture the user picked deliberately, and refusing it would be
                // overruling them about their own icon — the alert this replaced had
                // the same policy, it just arrived too late to be acted on.
                Button("Use for \(row.name)", action: onUse)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    private func tint(_ level: IconCandidate.Note.Level) -> Color {
        switch level {
        case .good: return .green
        case .info: return .secondary
        case .warning: return .orange
        }
    }
}

/// The standard transparency chequer, drawn rather than shipped as an image.
private struct Chequerboard: View {
    var square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let dark = Color(white: 0.86)
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: x, y: y, width: square, height: square)),
                                     with: .color(dark))
                    }
                    x += square
                    column += 1
                }
                y += square
                row += 1
            }
        }
        // Fixed light chequer regardless of appearance: it is a measuring backdrop,
        // not chrome, and a dark-mode version would hide exactly the dark artwork it
        // is meant to reveal.
        .drawingGroup()
    }
}
