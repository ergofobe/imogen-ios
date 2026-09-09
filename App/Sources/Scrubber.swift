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
    /// Where the thumb was when the finger took hold of it. The drag is measured from
    /// there, so the thumb moves with the finger rather than snapping under it on touch.
    @State private var startFraction: Double = 0

    private let thumbHeight: Double = 48
    /// The least a finger can be asked to hit. The visible thumb is smaller than this.
    private let touchTarget: Double = 48
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
                    // Sizes the strip and takes no touch; see `thumb`.
                    Color.clear

                    years(marks, travel: travel)
                    bubble(fraction: fraction, travel: travel)
                    thumb(fraction: fraction, travel: travel)
                }
            }
            .frame(width: railWidth)
        }
    }

    /// The years, which appear only while the rail is held.
    ///
    /// Marks drawn over the grid at rest sit on top of the photographs, which are the one
    /// thing this screen is for — and a permanent row of ticks down the edge reads as
    /// chrome rather than as a control. So the rail is a thumb until somebody takes hold
    /// of it, and then it is a ruler.
    ///
    /// Hard against the trailing edge, with nothing after them: a tick would have pointed
    /// at the rail the year is already on. The thumb passes over one now and then, which
    /// costs less than a column of punctuation.
    private func years(_ marks: [YearMark], travel: Double) -> some View {
        ForEach(marks, id: \.year) { mark in
            Text(verbatim: String(mark.year))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .frame(width: railWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .offset(y: mark.fraction * travel + thumbHeight / 2 - 10)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
        .opacity(isScrubbing ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isScrubbing)
    }

    /// The month under the thumb.
    ///
    /// Drawn on its own rather than beside the thumb: measured against the rail's width it
    /// broke "December 2024" across two lines, and measured unbounded inside a row it
    /// pushed the thumb off the screen. So it hangs to the left, from the same offset, and
    /// the rail stays narrow enough not to swallow taps meant for the photographs.
    private func bubble(fraction: Double, travel: Double) -> some View {
        Text(monthHeading(layout.index.date(ofDay: dragDay)))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .frame(width: railWidth - 46, alignment: .trailing)
            .padding(.trailing, 46)
            .offset(y: fraction * travel + 4)
            .opacity(isScrubbing ? 1 : 0)
            .animation(.snappy(duration: 0.18), value: isScrubbing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The thumb, and the whole of what the rail lets a finger take hold of.
    ///
    /// An earlier rail took the drag across its full height and width, which read well as
    /// "the thumb does not have to be hit exactly" and badly as "the last column of
    /// photographs cannot be tapped": the strip sits over the grid, and a touch stops at
    /// the first view that claims it. So the thumb is padded out to a 48pt target and
    /// claims that alone; everything else in the strip falls through to a photograph.
    private func thumb(fraction: Double, travel: Double) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 30, height: thumbHeight - 8)
            .background(
                isScrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .foregroundStyle(isScrubbing ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .shadow(color: .black.opacity(isScrubbing ? 0.2 : 0), radius: 6, y: 2)
            .padding(.trailing, 6)
            .frame(width: touchTarget, height: thumbHeight, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(drag(travel: travel))
            .offset(y: fraction * travel)
            .animation(.snappy(duration: 0.18), value: isScrubbing)
            .accessibilityElement()
            .accessibilityLabel("Scroll through time")
            .accessibilityValue(monthHeading(layout.index.date(ofDay: day)))
            .accessibilityAdjustableAction { direction in
                // A year at a time under VoiceOver: the drag gesture is unusable there,
                // and stepping by day through two decades is not a control either.
                seekByYear(direction == .increment ? 1 : -1)
            }
    }

    private func drag(travel: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    // Taken hold of where it is, not snapped under the finger — and not
                    // sought yet either: a fraction sent back through the day table can
                    // round to the day above, and a touch that moves nothing must not.
                    dragDay = day
                    startFraction = layout.fraction(ofDay: day)
                    dragFraction = startFraction
                    return
                }
                // Measured by translation, which a thumb that moves under the finger
                // cannot disturb; a location in the thumb's own space would chase itself.
                update(to: startFraction + value.translation.height / travel)
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
