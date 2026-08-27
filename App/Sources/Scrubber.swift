import ImogenKit
import SwiftUI

/// The fast way down a very long timeline.
///
/// Fifty thousand photographs is roughly twelve thousand swipes. Nobody is going to find a
/// holiday from 2014 that way, and a scroll indicator that only reports position does not
/// help either — what is needed is a control that says *when* the thumb is, before letting
/// go, and that shows what is above and below without being dragged at all.
///
/// So the rail is labelled with years, positioned by how much of the library each one
/// holds rather than by how long ago it was: a year of nine thousand frames takes more
/// rail than a year of two hundred, because that is where its photographs are.
///
/// The thumb is driven by the segment table, not by a photograph's position in the list.
/// Those are different measurements — a day holding one photograph and a day holding
/// twenty-five are adjacent in the list and nine rows apart on screen — and using the
/// wrong one is what makes a scrubber jump while the content scrolls smoothly.
struct Scrubber: View {
    let layout: TimelineLayout
    /// Where the grid is now, as a day, for drawing the thumb at rest.
    let day: Int
    @Binding var isScrubbing: Bool
    let onSeek: (Int) -> Void

    @State private var dragFraction: Double = 0
    /// What the label says while dragging. Held separately so it does not flicker back to
    /// the settled day between the drag ending and the grid arriving.
    @State private var dragDay: Int = 0

    private let thumbHeight: Double = 48
    private let railWidth: Double = 96

    var body: some View {
        if layout.index.isEmpty {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let travel = max(proxy.size.height - thumbHeight, 1)
                let fraction = isScrubbing ? dragFraction : layout.fraction(ofDay: day)
                let marks = layout.yearMarks(spacedBy: 34, railHeight: travel)

                ZStack(alignment: .topTrailing) {
                    // The whole strip takes the gesture, so the thumb does not have to be
                    // hit exactly — it is a small target on a moving list.
                    Color.clear.contentShape(Rectangle())

                    years(marks, travel: travel)
                    thumb(fraction: fraction, travel: travel)
                }
                .gesture(drag(travel: travel))
            }
            .frame(width: railWidth)
            .accessibilityElement()
            .accessibilityLabel("Scroll through time")
            .accessibilityValue(monthHeading(layout.index.date(ofDay: day)))
            .accessibilityAdjustableAction { direction in
                // A year at a time under VoiceOver: the drag gesture is unusable there,
                // and stepping by day through two decades is not a control either.
                seekByYear(direction == .increment ? 1 : -1)
            }
        }
    }

    /// The years, which appear only while the rail is held.
    ///
    /// Marks drawn over the grid at rest sit on top of the photographs, which are the one
    /// thing this screen is for — and a permanent row of ticks down the edge reads as
    /// chrome rather than as a control. So the rail is a thumb until somebody takes hold
    /// of it, and then it is a ruler.
    private func years(_ marks: [YearMark], travel: Double) -> some View {
        ForEach(marks, id: \.year) { mark in
            HStack(spacing: 5) {
                Spacer(minLength: 0)

                Text(verbatim: String(mark.year))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())

                Capsule()
                    .fill(.secondary)
                    .frame(width: 10, height: 1.5)
                    .opacity(0.9)
            }
            .frame(width: railWidth - 40, height: 16, alignment: .trailing)
            .padding(.trailing, 40)
            .offset(y: mark.fraction * travel + thumbHeight / 2 - 8)
            .allowsHitTesting(false)
        }
        .opacity(isScrubbing ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isScrubbing)
    }

    private func thumb(fraction: Double, travel: Double) -> some View {
        HStack(spacing: 8) {
            if isScrubbing {
                Text(monthHeading(layout.index.date(ofDay: dragDay)))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: thumbHeight - 8)
                .background(
                    isScrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                    in: Capsule()
                )
                .foregroundStyle(isScrubbing ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .shadow(color: .black.opacity(isScrubbing ? 0.2 : 0), radius: 6, y: 2)
        }
        .padding(.trailing, 6)
        .offset(y: fraction * travel + 4)
        .animation(.snappy(duration: 0.18), value: isScrubbing)
        .allowsHitTesting(false)
    }

    private func drag(travel: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                update(to: (value.location.y - thumbHeight / 2) / travel)
            }
            .onEnded { _ in
                isScrubbing = false
                // Seek once more on release: the grid only fetches days when the drag
                // stops, so this is the request that actually matters.
                onSeek(dragDay)
            }
    }

    private func update(to fraction: Double) {
        dragFraction = min(max(fraction, 0), 1)
        let landing = layout.day(atFraction: dragFraction)
        if landing != dragDay {
            dragDay = landing
            // One tick per day crossed would buzz continuously across a decade; per
            // month is enough to feel the rail moving under a thumb.
            if monthHeading(layout.index.date(ofDay: landing))
                != monthHeading(layout.index.date(ofDay: day)) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        onSeek(landing)
    }

    private func seekByYear(_ step: Int) {
        let marks = layout.yearMarks()
        guard let current = marks.lastIndex(where: {
            layout.index.date(ofDay: day).prefix(4) <= String($0.year).prefix(4)
        }) else { return }
        let next = min(max(current + step, 0), marks.count - 1)
        onSeek(layout.day(atFraction: marks[next].fraction))
    }
}
