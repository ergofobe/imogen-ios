import AVKit
import ImogenKit
import ImogenSDK
import SwiftUI

enum ViewerMode { case library, trash }

/// One photograph, full screen, with the rest of them a swipe away.
///
/// Black, and the chrome hides on a tap. A photograph shown inside a frame of interface is
/// a photograph you are looking at; a photograph filling the screen is one you are looking
/// into, and that is the difference this screen exists to make.
struct ViewerView: View {
    let session: Session
    let assets: [Asset]
    let initial: Asset
    let mode: ViewerMode
    var onFavorite: (Asset, Bool) -> Void
    var onArchive: (Asset) -> Void
    var onTrash: (Asset) -> Void
    var onRestore: (Asset) -> Void
    var onDetails: (Asset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: String = ""
    @State private var chromeVisible = true

    private var asset: Asset? {
        assets.first { $0.id == current } ?? assets.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(assets) { asset in
                    Group {
                        if asset.type == .video {
                            VideoPage(session: session, asset: asset, active: current == asset.id)
                        } else {
                            ZoomablePhoto(session: session, asset: asset) {
                                withAnimation { chromeVisible.toggle() }
                            }
                        }
                    }
                    .tag(asset.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible, let asset {
                VStack {
                    top(asset)
                    Spacer()
                    bottom(asset)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .onAppear { current = initial.id }
        // Every photograph deleted from underneath the pager shortens the list. Closing
        // when it empties is the only sensible end to that.
        .onChange(of: assets.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private func top(_ asset: Asset) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.headline)
            }
            Text(asset.originalFilename)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Button { onDetails(asset) } label: {
                Image(systemName: "info.circle").font(.headline)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45))
    }

    private func bottom(_ asset: Asset) -> some View {
        HStack(spacing: 44) {
            if mode == .trash {
                Button { onRestore(asset) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Put back")
            } else {
                Button { onFavorite(asset, !asset.favorite) } label: {
                    Image(systemName: asset.favorite ? "heart.fill" : "heart")
                }
                .accessibilityLabel("Favourite")

                Button { onArchive(asset) } label: {
                    Image(systemName: "archivebox")
                }
                .accessibilityLabel("Archive")

                Button { onTrash(asset) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Move to trash")
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.45))
    }
}

/// Pinch to zoom, drag to pan, double-tap to do both at once.
///
/// The pan is clamped so the photograph cannot be dragged off the screen and abandoned
/// there, which is the failure mode of every zoom implementation that forgets to.
private struct ZoomablePhoto: View {
    let session: Session
    let asset: Asset
    let onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            AssetImage(session: session, asset: asset, variant: "preview", contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(settledScale * value, 1), 6)
                        }
                        .onEnded { _ in
                            settledScale = scale
                            if scale <= 1 { reset() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            let limitX = proxy.size.width * (scale - 1) / 2
                            let limitY = proxy.size.height * (scale - 1) / 2
                            offset = CGSize(
                                width: min(max(settledOffset.width + value.translation.width, -limitX), limitX),
                                height: min(max(settledOffset.height + value.translation.height, -limitY), limitY)
                            )
                        }
                        .onEnded { _ in settledOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.25)) {
                        if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                    }
                }
                .onTapGesture(perform: onTap)
        }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}

/// A video, played from the server rather than downloaded first.
///
/// `AVPlayer` streams it, which for a phone-shot 4K clip is the difference between playing
/// in a second and playing in a minute. The bearer token goes on the request the same way
/// it does for a thumbnail: the media endpoints are ordinary API routes and want ordinary
/// authentication, and `AVURLAsset` takes the header as an option.
private struct VideoPage: View {
    let session: Session
    let asset: Asset
    let active: Bool

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: asset.id) {
                guard let url = session.assetURL(asset.id, variant: "original") else { return }
                let headers = await session.authorizationHeaders()
                let item = AVURLAsset(
                    url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
                )
                player = AVPlayer(playerItem: AVPlayerItem(asset: item))
            }
            // Only the page in front plays. Without this, swiping through a folder of
            // videos starts every one it passes and leaves them all running.
            .onChange(of: active) { _, isActive in
                isActive ? player?.play() : player?.pause()
            }
            .onDisappear { player?.pause() }
    }
}
