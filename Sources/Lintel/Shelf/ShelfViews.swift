import AppKit
import LintelCore
import SwiftUI

// Shelf views: the page in the open island (header, tiles, paging,
// Clear All, drop zone, empty state) and the compact indicator. Geometry on the 345 × 175 pt body.

enum ShelfPageMetrics {
    static let sideInset: CGFloat = 16
    static let contentWidth: CGFloat = 313
    static let headerTop: CGFloat = 14
    static let headerHeight: CGFloat = 20
    static let headerInset: CGFloat = 18
    static let dropZone = CGRect(x: 16, y: 40, width: 313, height: 125)
    static let emptyZone = CGRect(x: 16, y: 42, width: 313, height: 118)
    static let bottomRowTop: CGFloat = 138
    static let bottomRowHeight: CGFloat = 18
}

/// The Shelf page of the open island.
struct ShelfPageView: View {
    let size: CGSize
    let bandHeight: CGFloat

    var body: some View {
        if let feature = ShelfFeature.shared {
            ShelfPage(feature: feature, size: size)
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }
}

private struct ShelfPage: View {
    let feature: ShelfFeature
    let size: CGSize

    var body: some View {
        let items = feature.items
        let paging = ShelfPaging(count: items.count, page: feature.page)
        ZStack(alignment: .topLeading) {
            header(count: items.count)
            if let drop = feature.drop {
                ShelfDropZone(drop: drop)
                    .frame(width: ShelfPageMetrics.dropZone.width, height: ShelfPageMetrics.dropZone.height)
                    .padding(.leading, ShelfPageMetrics.dropZone.minX)
                    .padding(.top, ShelfPageMetrics.dropZone.minY)
                    .transition(.opacity)
            } else if items.isEmpty {
                ShelfEmptyState()
                    .frame(width: ShelfPageMetrics.emptyZone.width, height: ShelfPageMetrics.emptyZone.height)
                    .padding(.leading, ShelfPageMetrics.emptyZone.minX)
                    .padding(.top, ShelfPageMetrics.emptyZone.minY)
                    .transition(.opacity)
            } else {
                HStack(spacing: ShelfTileMetrics.spacing) {
                    ForEach(items[paging.range]) { item in
                        ShelfTileView(item: item, feature: feature)
                    }
                }
                .frame(width: ShelfPageMetrics.contentWidth, height: ShelfTileMetrics.height, alignment: .top)
                .background { ShelfTileMouseArea(itemID: nil, isRow: true) }
                .padding(.leading, ShelfPageMetrics.sideInset)
                .padding(.top, ShelfTileMetrics.rowTop)
                .transition(.opacity)
                bottomRow(paging: paging, count: items.count)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.15), value: feature.drop == nil)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: items.map(\.id))
        .onAppear { feature.pageAppeared() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 0) {
            Text("Shelf")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .overlay { ShelfTileMouseArea(itemID: nil, help: count > 0 ? "Drag to take every item" : "") }
            Spacer(minLength: 0)
            if count > 0 {
                Text(ShelfNaming.itemsLabel(count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, ShelfPageMetrics.headerInset)
        .frame(width: size.width, height: ShelfPageMetrics.headerHeight)
        .padding(.top, ShelfPageMetrics.headerTop)
    }

    private func bottomRow(paging: ShelfPaging, count: Int) -> some View {
        ZStack {
            if paging.pageCount > 1 {
                ShelfPager(paging: paging) { feature.showPage($0) }
            }
            HStack {
                if let problem = feature.problem {
                    Text(problem)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                Spacer(minLength: 0)
                Button { feature.tapClearAll() } label: {
                    Text(feature.clearArmed ? "Clear \(ShelfNaming.itemsLabel(count))?" : "Clear All")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(feature.clearArmed ? Color.black : Brand.copper)
                        .padding(.horizontal, feature.clearArmed ? 8 : 2)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(feature.clearArmed ? Brand.copper : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(feature.clearArmed ? "Confirm Clear All" : "Clear All")
            }
        }
        .frame(width: ShelfPageMetrics.contentWidth, height: ShelfPageMetrics.bottomRowHeight)
        .padding(.leading, ShelfPageMetrics.sideInset)
        .padding(.top, ShelfPageMetrics.bottomRowTop)
        .animation(.easeOut(duration: 0.15), value: feature.clearArmed)
    }
}

/// Chevrons and page dots (more than 5 items).
private struct ShelfPager: View {
    let paging: ShelfPaging
    let show: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button { show(paging.page - 1) } label: { chevron("chevron.left") }
                .buttonStyle(.plain)
                .disabled(!paging.hasPrevious)
                .opacity(paging.hasPrevious ? 1 : 0.3)
            if paging.pageCount <= 7 {
                HStack(spacing: 5) {
                    ForEach(0..<paging.pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == paging.page ? Brand.copper : Color.white.opacity(0.3))
                            .frame(width: 5, height: 5)
                    }
                }
            } else {
                Text("\(paging.page + 1) / \(paging.pageCount)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button { show(paging.page + 1) } label: { chevron("chevron.right") }
                .buttonStyle(.plain)
                .disabled(!paging.hasNext)
                .opacity(paging.hasNext ? 1 : 0.3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(paging.page + 1) of \(paging.pageCount)")
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}

/// One item: thumbnail (or text/link card), state badge, name; hover backdrop and × button.
private struct ShelfTileView: View {
    let item: ShelfItem
    let feature: ShelfFeature

    var body: some View {
        let hovered = feature.hoveredID == item.id
        let usable = item.state.isUsable || item.state == .pending
        VStack(spacing: 4) {
            ShelfThumbnail(item: item, image: feature.thumbnails[item.id])
                .frame(width: ShelfTileMetrics.thumbnail, height: ShelfTileMetrics.thumbnail)
                .opacity(usable ? 1 : 0.35)
                .overlay {
                    if item.state == .pending {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Brand.copper, lineWidth: 2)
                        .padding(-2)
                        .opacity(feature.highlighted.contains(item.id) ? 1 : 0)
                        .animation(.easeOut(duration: 0.6), value: feature.highlighted.contains(item.id))
                }
            // Names wrap at spaces over two lines; a single word stays on one line (scaled a little,
            // then cut in the middle) instead of breaking mid-word.
            let oneWord = !item.name.contains(where: \.isWhitespace)
            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(usable ? 0.92 : 0.45))
                .lineLimit(oneWord ? 1 : 2)
                .minimumScaleFactor(oneWord ? 0.8 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: ShelfTileMetrics.width, height: 26, alignment: .top)
        }
        .frame(width: ShelfTileMetrics.width, height: ShelfTileMetrics.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.10 : 0))
                .padding(-2)
        )
        .overlay(alignment: .topLeading) {
            if hovered {
                ShelfRemoveButton()
                    .position(ShelfTileMetrics.removeCenter)
                    .transition(.opacity)
            }
        }
        .overlay { ShelfTileMouseArea(itemID: item.id, help: help) }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            feature.tileFrames[item.id] = frame
        }
        .onDisappear { feature.tileFrames[item.id] = nil }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.state.label(volume: item.volumeName) ?? item.kind.rawValue)
        .accessibilityAddTraits(.isButton)
    }

    private var help: String {
        var lines = [item.name]
        if let label = item.state.label(volume: item.volumeName) { lines.append(label) }
        switch item.storage {
        case .reference(_, let path): lines.append((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        case .stored(_, let original):
            if let original, item.kind.isFileBased { lines.append("Copy of " + original.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        }
        if item.kind == .link, let url = item.link?.url { lines.append(url) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var badge: some View {
        if let symbol = badgeSymbol {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, item.state == .failed ? Color.orange : Color(white: 0.3))
                .background(Circle().fill(.black).padding(1))
                .offset(x: 3, y: 3)
        }
    }

    private var badgeSymbol: String? {
        switch item.state {
        case .available, .pending: return nil
        case .missing: return "questionmark.circle.fill"
        case .inTrash: return "trash.circle.fill"
        case .unavailable: return "externaldrive.fill.badge.xmark"
        case .noAccess: return "lock.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct ShelfRemoveButton: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.82))
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .overlay {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: ShelfTileMetrics.removeSize, height: ShelfTileMetrics.removeSize)
            .accessibilityLabel("Remove")
    }
}

/// Picture or icon; text clips and links get a drawn card.
struct ShelfThumbnail: View {
    let item: ShelfItem
    let image: NSImage?

    var body: some View {
        switch item.kind {
        case .text:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(alignment: .topLeading) {
                    Text(item.textPreview ?? item.name)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(4)
                        .padding(5)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Brand.copper)
                        .padding(4)
                }
        case .link:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.copper.opacity(0.2))
                .overlay {
                    VStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Brand.copper)
                        Text(item.link.flatMap { ShelfNaming.host(of: $0.url) } ?? "")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                    }
                }
        case .file, .folder, .image:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: item.kind == .folder ? "folder.fill" : (item.kind == .image ? "photo" : "doc.fill"))
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// The copper drop zone.
struct ShelfDropZone: View {
    let drop: ShelfDropState

    var body: some View {
        let targeted = drop.targeted
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .fill(Brand.copper.opacity(targeted ? 0.14 : 0))
            .overlay {
                shape.strokeBorder(targeted ? Brand.copper : Color.white.opacity(0.3),
                                   style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [5, 4]))
            }
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(targeted ? Brand.copper : Color.white.opacity(0.8))
                    Text("Drop to keep on the Shelf")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(ShelfNaming.itemsLabel(drop.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .scaleEffect(targeted ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(targeted ? "Drop zone, ready" : "Drop zone")
    }
}

private struct ShelfEmptyState: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Drop files, images, text or links on the island")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
            }
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Compact indicator

struct ShelfCompactGlyph: View {
    var body: some View {
        Image(systemName: "tray.full.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.copper)
            .accessibilityLabel("Shelf")
    }
}

struct ShelfCompactCount: View {
    let count: Int

    var body: some View {
        Text(ShelfNaming.countLabel(count))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(ShelfNaming.itemsLabel(count))
    }
}
