// Game art: where a game's art is, the shape it is drawn in, a cache that decodes it once off the main thread, and the view that draws it (or a
// monogram on the stage's indigo until it loads, or when there is none)
import AppKit
import ConverterCore
import ImageIO
import SwiftUI

/// Where a game's art is: the icon the script extracted (GameInfo.icon), the newest extracted icon of a game folder, or an installed app's icon
enum ArtworkSource: Hashable, Sendable {
    case icon(String)
    case gameFolder(URL, titleID: String)
    case app(URL)
}

/// A game's art shows what it is: a game (a rounded square), a Mac app (the macOS squircle), or a screen (the frame it is given, cropped)
enum ArtworkShape: Sendable {
    case game, app, screen

    func radius(for size: CGFloat) -> CGFloat {
        switch self {
        case .game: 0.16 * size
        case .app: 0.2237 * size
        case .screen: 0
        }
    }
}

/// Game art decoded once, off the main thread, at most 256 pixels on its longer side; the newest 300 stay. A miss is not kept: the art can appear
/// later
@MainActor private final class ArtworkCache {
    static let shared = ArtworkCache()
    nonisolated private static let maxPixels = 256
    private var images: [ArtworkSource: CGImage] = [:]
    private var order: [ArtworkSource] = []
    private var loading: [ArtworkSource: Task<CGImage?, Never>] = [:]

    func cached(_ source: ArtworkSource) -> CGImage? { images[source] }

    func image(for source: ArtworkSource) async -> CGImage? {
        if let image = images[source] { return image }
        if let task = loading[source] { return await task.value }
        let task = Task.detached(priority: .utility) { Self.decode(source) }
        loading[source] = task
        let image = await task.value
        loading[source] = nil
        if let image, images[source] == nil {
            images[source] = image
            order.append(source)
            if order.count > 300 { images[order.removeFirst()] = nil }
        }
        return image
    }

    nonisolated private static func decode(_ source: ArtworkSource) -> CGImage? {
        switch source {
        case let .icon(path):
            return thumbnail(URL(fileURLWithPath: path))
        case let .gameFolder(folder, titleID):
            let extract = ConversionCommand.extractFolder(folder: folder, titleID: titleID)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: extract.path)) ?? []
            let newest = versions.compactMap { name in name.hasPrefix("v") ? Int(name.dropFirst()).map { (version: $0, name: name) } : nil }
                .sorted { $0.version > $1.version }
            for version in newest {
                if let image = thumbnail(extract.appendingPathComponent(version.name).appendingPathComponent("icon.jpg")) { return image }
            }
            return nil
        case let .app(url):
            guard let icon = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/AppIcon.icns")) else { return nil }
            var rect = CGRect(x: 0, y: 0, width: maxPixels / 2, height: maxPixels / 2)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(rasterized)
        }
    }

    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let provider = CGDataProvider(filename: url.path), let source = CGImageSourceCreateWithDataProvider(provider, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return rasterized(image)
    }

    // An image decodes when first drawn: drawing it here, at most maxPixels on its longer side, keeps that off the main thread
    nonisolated private static func rasterized(_ image: CGImage) -> CGImage? {
        let scale = min(1, CGFloat(maxPixels) / CGFloat(max(image.width, image.height, 1)))
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1), height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// A game's art at `size` points in the shape of what it is, or with `.screen` filling the frame it is given (`size` then sets the monogram's
/// type). A monogram on the stage's indigo stands in until the art loads, or when there is none
struct GameArtwork: View {
    private let source: ArtworkSource?
    private let name: String
    private let size: CGFloat
    private let shape: ArtworkShape
    @State private var image: CGImage?

    init(_ source: ArtworkSource?, name: String, size: CGFloat, shape: ArtworkShape = .game) {
        self.source = source; self.name = name; self.size = size; self.shape = shape
        _image = State(initialValue: source.flatMap { ArtworkCache.shared.cached($0) })
    }

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: shape.radius(for: size), style: .continuous)
        Group {
            if shape == .screen {
                Color.clear.overlay { art }.clipped()
            } else {
                art.frame(width: size, height: size)
                    .clipShape(tile)
                    .overlay { tile.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
            }
        }
        .task(id: source) {
            // The view keeps its identity when its source changes: the old art goes at once
            guard let source else { image = nil; return }
            image = ArtworkCache.shared.cached(source)
            if image == nil { image = await ArtworkCache.shared.image(for: source) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var art: some View {
        if let image {
            Image(decorative: image, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(LinearGradient(colors: [StagePalette.top, StagePalette.bottom], startPoint: .top, endPoint: .bottom))
                let initials = Self.initials(name)
                if initials.isEmpty {
                    Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.4))
                } else {
                    Text(initials).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !["the", "a", "an", "of"].contains($0.lowercased()) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
