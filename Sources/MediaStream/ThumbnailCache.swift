import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thread-safe LRU cache for thumbnails with memory limit and pressure handling
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    /// Maximum memory limit in bytes (default: 100MB)
    private let maxMemoryBytes: Int

    /// Thumbnail size for grid display
    public static let thumbnailSize: CGFloat = 200

    /// Current estimated memory usage
    private var currentMemoryBytes: Int = 0

    /// Cache storage with access time tracking
    private var cache: [UUID: CacheEntry] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Memory pressure observer
    #if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
    #endif

    private struct CacheEntry {
        let image: PlatformImage
        let sizeBytes: Int
        var lastAccess: Date
    }

    public init(maxMemoryMB: Int = 100) {
        self.maxMemoryBytes = maxMemoryMB * 1024 * 1024
        setupMemoryPressureHandling()
    }

    deinit {
        #if canImport(UIKit)
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    private func setupMemoryPressureHandling() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
        #endif
    }

    /// Handle memory pressure by evicting half the cache
    public func handleMemoryPressure() {
        lock.lock()
        defer { lock.unlock() }

        let targetBytes = maxMemoryBytes / 2
        evictToSize(targetBytes)
        print("🧹 ThumbnailCache: Memory pressure - evicted to \(currentMemoryBytes / 1024 / 1024)MB")
    }

    /// Get a cached thumbnail, or nil if not cached
    public func get(_ id: UUID) -> PlatformImage? {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = cache[id] else { return nil }
        entry.lastAccess = Date()
        cache[id] = entry
        return entry.image
    }

    /// Store a thumbnail in the cache
    public func set(_ id: UUID, image: PlatformImage) {
        let sizeBytes = estimateImageSize(image)

        lock.lock()
        defer { lock.unlock() }

        // Remove existing entry if present
        if let existing = cache[id] {
            currentMemoryBytes -= existing.sizeBytes
        }

        // Evict if necessary to make room
        let targetSize = maxMemoryBytes - sizeBytes
        if currentMemoryBytes > targetSize {
            evictToSize(targetSize)
        }

        // Store the new entry
        cache[id] = CacheEntry(
            image: image,
            sizeBytes: sizeBytes,
            lastAccess: Date()
        )
        currentMemoryBytes += sizeBytes
    }

    /// Check if an item is cached
    public func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[id] != nil
    }

    /// Clear the entire cache
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        currentMemoryBytes = 0
        print("🧹 ThumbnailCache: Cleared all entries")
    }

    /// Get current cache statistics
    public var stats: (count: Int, memoryMB: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (cache.count, Double(currentMemoryBytes) / 1024.0 / 1024.0)
    }

    /// Evict least recently used entries until we're under the target size
    private func evictToSize(_ targetBytes: Int) {
        // Sort by last access time (oldest first)
        let sortedEntries = cache.sorted { $0.value.lastAccess < $1.value.lastAccess }

        for (id, entry) in sortedEntries {
            if currentMemoryBytes <= targetBytes { break }
            cache.removeValue(forKey: id)
            currentMemoryBytes -= entry.sizeBytes
        }
    }

    /// Estimate image memory size in bytes
    private func estimateImageSize(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
        }
        return cgImage.bytesPerRow * cgImage.height
        #elseif canImport(AppKit)
        let size = image.size
        return Int(size.width * size.height * 4)
        #endif
    }
}

// MARK: - Thumbnail Generation

extension ThumbnailCache {
    /// Generate a downsampled thumbnail from an image
    public static func createThumbnail(from image: PlatformImage, targetSize: CGFloat = thumbnailSize) -> PlatformImage {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale

        // Calculate aspect-fit size
        let imageSize = image.size
        let aspectRatio = imageSize.width / imageSize.height

        let thumbnailSize: CGSize
        if aspectRatio > 1 {
            // Landscape
            thumbnailSize = CGSize(width: pixelSize, height: pixelSize / aspectRatio)
        } else {
            // Portrait or square
            thumbnailSize = CGSize(width: pixelSize * aspectRatio, height: pixelSize)
        }

        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
        #elseif canImport(AppKit)
        let imageSize = image.size
        let aspectRatio = imageSize.width / imageSize.height

        let thumbnailSize: NSSize
        if aspectRatio > 1 {
            thumbnailSize = NSSize(width: targetSize, height: targetSize / aspectRatio)
        } else {
            thumbnailSize = NSSize(width: targetSize * aspectRatio, height: targetSize)
        }

        let newImage = NSImage(size: thumbnailSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                   from: NSRect(origin: .zero, size: imageSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }

    /// Load and downsample an image from data for use as a thumbnail
    public static func createThumbnail(from data: Data, targetSize: CGFloat = thumbnailSize) -> PlatformImage? {
        // Use ImageIO for efficient downsampling without loading full image into memory
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return createThumbnail(from: imageSource, targetSize: targetSize)
    }

    /// Load and downsample an image from URL for use as a thumbnail
    public static func createThumbnail(from url: URL, targetSize: CGFloat = thumbnailSize) -> PlatformImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        return createThumbnail(from: imageSource, targetSize: targetSize)
    }

    /// Create a thumbnail from CGImageSource using ImageIO (memory efficient)
    private static func createThumbnail(from imageSource: CGImageSource, targetSize: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale
        #else
        let pixelSize = targetSize * 2.0 // Assume 2x for macOS
        #endif

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
