import ImogenKit
import SwiftUI

/// The fast way down a very long timeline.
///
/// Fifty thousand photographs is roughly twelve thousand swipes. Nobody is going to find a
/// holiday from 2014 that way, and a scroll indicator that only reports position does not
/// help either — what is needed is a control that says *when* the thumb is, before letting
/// go.
///
/// So dragging shows the month under the thumb and moves the grid as it goes, and the grid
/// fetches nothing while the drag is happening: a flick from top to bottom would otherwise
/// ask the server for four hundred days it passes through and wants none of.
struct Scrubber: View {
    let index: TimelineIndex
    /// Where the grid is now, for drawing the thumb at rest.
    let day: Int
    @Binding var isScrubbing: Bool
    let onSeek: (Int) -> Void

    @State private var dragFraction: Double = 0
    @State private var trackHeight: Double = 1

    private let thumbHeight: Double = 44

    var body: some View {
        if index.isEmpty {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let fraction = isScrubbing ? dragFraction : index.fraction(ofDay: day)
                let travel = max(proxy.size.height - thumbHeight, 1)

                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle())

                    HStack(spacing: 8) {
                        if isScrubbing {
                            Text(monthHeading(index.date(ofDay: index.day(atFraction: fraction))))
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }

                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: thumbHeight)
                            .background(
                                isScrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial),
                                in: Capsule()
                            )
                            .foregroundStyle(isScrubbing ? .white : .secondary)
                    }
                    .padding(.trailing, 4)
                    .offset(y: travel * fraction)
                    .animation(.interactiveSpring, value: isScrubbing)
                }
                .onAppear { trackHeight = travel }
                .onChange(of: proxy.size.height) { _, height in
                    trackHeight = max(height - thumbHeight, 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                            dragFraction = min(
                                max((value.location.y - thumbHeight / 2) / trackHeight, 0), 1
                            )
                            onSeek(index.day(atFraction: dragFraction))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            // The days under the thumb are only fetched once the finger
                            // lifts, which is the moment somebody actually wants to see
                            // what is there.
                            onSeek(index.day(atFraction: dragFraction))
                        }
                )
            }
            .frame(width: 56)
            .accessibilityElement()
            .accessibilityLabel("Scroll through time")
            .accessibilityValue(monthHeading(index.date(ofDay: day)))
            .accessibilityAdjustableAction { direction in
                // A month at a time under VoiceOver: the drag gesture is unusable there,
                // and stepping by day through a decade is not a control either.
                let step = direction == .increment ? 1 : -1
                onSeek(min(max(day + step * 30, 0), index.dayCount - 1))
            }
        }
    }
}
