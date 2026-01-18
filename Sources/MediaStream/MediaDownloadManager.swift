//
//  MediaDownloadManager.swift
//  MediaStream
//
//  Manages downloading and caching media files locally for background playback.
//  Files are stored UNENCRYPTED because AVPlayer needs direct file access in background.
//

import Foundation
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Progress information for download operations
public struct DownloadProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentItemName: String?
    public let bytesDownloaded: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    public var currentItemProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}

/// State of the download manager
public enum DownloadState: Equatable, Sendable {
    case idle
    case downloading(completed: Int, total: Int)
    case completed
    case cancelled
    case failed(String)

    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.completed, .completed), (.cancelled, .cancelled):
            return true
        case (.downloading(let lhsC, let lhsT), .downloading(let rhsC, let rhsT)):
            return lhsC == rhsC && lhsT == rhsT
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

/// Singleton manager for downloading and caching media files locally.
/// Files are stored UNENCRYPTED for AVPlayer background access.
@MainActor
public final class MediaDownloadManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = MediaDownloadManager()

    // MARK: - Published Properties

    @Published public private(set) var downloadState: DownloadState = .idle
    @Published public private(set) var progress: DownloadProgress?

    // MARK: - Storage

    private let fileManager = FileManager.default
    private let downloadDirectory: URL

    /// Active download task (cancellable)
    private var downloadTask: Task<Void, Never>?

    /// URLSession for downloads
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600 // 10 minutes for large files
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    private init() {
        // Use Caches directory for downloaded media
        // ~/Library/Caches/MediaStream/DownloadedMedia/
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        downloadDirectory = cachesDir
            .appendingPathComponent("MediaStream", isDirectory: true)
            .appendingPathComponent("DownloadedMedia", isDirectory: true)

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Check if a media item is cached locally
    public func isCached(mediaItem: any MediaItem) -> Bool {
        guard let localURL = localURL(for: mediaItem) else { return false }
        return fileManager.fileExists(atPath: localURL.path)
    }

    /// Check if all items in a collection are cached
    public func allCached(_ items: [any MediaItem]) -> Bool {
        let cacheableItems = items.filter { canCache($0) }
        guard !cacheableItems.isEmpty else { return false }
        return cacheableItems.allSatisfy { isCached(mediaItem: $0) }
    }

    /// Check if any items in a collection are cached
    public func anyCached(_ items: [any MediaItem]) -> Bool {
        return items.contains { isCached(mediaItem: $0) }
    }

    /// Get count of cached items
    public func cachedCount(of items: [any MediaItem]) -> Int {
        return items.filter { isCached(mediaItem: $0) }.count
    }

    /// Get the local file URL for a cached media item
    public func localURL(for mediaItem: any MediaItem) -> URL? {
        guard let cacheKey = mediaItem.diskCacheKey else { return nil }

        // Get file extension from sourceURL or diskCacheKey
        let ext = fileExtension(for: mediaItem)
        let filename = "\(cacheKey).\(ext)"

        return downloadDirectory.appendingPathComponent(filename)
    }

    /// Check if a media item can be cached (has diskCacheKey and is video/audio)
    /// Note: sourceURL may be loaded asynchronously, so we only check diskCacheKey here
    public func canCache(_ mediaItem: any MediaItem) -> Bool {
        guard mediaItem.diskCacheKey != nil else { return false }
        // Only cache video and audio for background playback
        return mediaItem.type == .video || mediaItem.type == .audio
    }

    /// Download all media items that support caching
    public func downloadAll(
        _ items: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    ) async {
        // Don't start a new download if one is already in progress
        if case .downloading = downloadState {
            print("[MediaDownloadManager] Download already in progress, ignoring request")
            return
        }

        // Filter to only cacheable items that aren't already cached
        let itemsToDownload = items.filter { canCache($0) && !isCached(mediaItem: $0) }

        guard !itemsToDownload.isEmpty else {
            downloadState = .completed
            return
        }

        downloadState = .downloading(completed: 0, total: itemsToDownload.count)
        progress = DownloadProgress(
            completed: 0,
            total: itemsToDownload.count,
            currentItemName: nil,
            bytesDownloaded: 0,
            totalBytes: 0
        )

        // Create cancellable task
        downloadTask = Task {
            var completedCount = 0

            for item in itemsToDownload {
                // Check for cancellation
                if Task.isCancelled {
                    downloadState = .cancelled
                    progress = nil
                    return
                }

                // Get source URL - try sourceURL first, then load asynchronously
                let sourceURL: URL?
                if let directURL = item.sourceURL {
                    sourceURL = directURL
                } else if item.type == .video {
                    sourceURL = await item.loadVideoURL()
                } else if item.type == .audio {
                    sourceURL = await item.loadAudioURL()
                } else {
                    sourceURL = nil
                }

                guard let sourceURL = sourceURL else {
                    print("[MediaDownloadManager] No URL available for item: \(item.id)")
                    completedCount += 1
                    continue
                }

                // Update progress
                let itemName = sourceURL.lastPathComponent
                progress = DownloadProgress(
                    completed: completedCount,
                    total: itemsToDownload.count,
                    currentItemName: itemName,
                    bytesDownloaded: 0,
                    totalBytes: 0
                )

                // Download the file
                do {
                    try await downloadFile(
                        item: item,
                        sourceURL: sourceURL,
                        headerProvider: headerProvider,
                        progressUpdate: { [weak self] bytesDownloaded, totalBytes in
                            Task { @MainActor in
                                self?.progress = DownloadProgress(
                                    completed: completedCount,
                                    total: itemsToDownload.count,
                                    currentItemName: itemName,
                                    bytesDownloaded: bytesDownloaded,
                                    totalBytes: totalBytes
                                )
                            }
                        }
                    )
                    completedCount += 1
                    downloadState = .downloading(completed: completedCount, total: itemsToDownload.count)
                } catch {
                    if Task.isCancelled {
                        downloadState = .cancelled
                        progress = nil
                        return
                    }
                    print("[MediaDownloadManager] Failed to download \(itemName): \(error)")
                    completedCount += 1  // Continue with next item
                    downloadState = .downloading(completed: completedCount, total: itemsToDownload.count)
                }
            }

            // All done
            if !Task.isCancelled {
                downloadState = .completed
                progress = nil
            }
        }

        // Await the task
        await downloadTask?.value
    }

    /// Cancel any active download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .cancelled
        progress = nil
    }

    /// Clear all downloaded media files
    public func clearAllDownloads() {
        cancelDownload()

        do {
            try fileManager.removeItem(at: downloadDirectory)
            try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            downloadState = .idle
            print("[MediaDownloadManager] Cleared all downloads")
        } catch {
            print("[MediaDownloadManager] Failed to clear downloads: \(error)")
        }
    }

    /// Clear downloads for specific items
    public func clearDownloads(for items: [any MediaItem]) {
        for item in items {
            if let localURL = localURL(for: item) {
                try? fileManager.removeItem(at: localURL)
            }
        }

        // If no downloads remain, reset state
        if let contents = try? fileManager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: nil),
           contents.isEmpty {
            downloadState = .idle
        }
    }

    /// Get current cache statistics
    public var stats: (fileCount: Int, diskMB: Double) {
        var totalSize: Int64 = 0
        var fileCount = 0

        if let enumerator = fileManager.enumerator(
            at: downloadDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                    fileCount += 1
                }
            }
        }

        return (fileCount, Double(totalSize) / 1024.0 / 1024.0)
    }

    // MARK: - Private Helpers

    /// Download a single file
    private func downloadFile(
        item: any MediaItem,
        sourceURL: URL,
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?,
        progressUpdate: @escaping (Int64, Int64) -> Void
    ) async throws {
        guard let destinationURL = localURL(for: item) else {
            throw DownloadError.invalidDestination
        }

        // Skip if already exists
        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }

        // Get headers for authenticated requests
        let headers = await headerProvider(sourceURL)

        var request = URLRequest(url: sourceURL)
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Download with progress tracking
        let (tempURL, response) = try await urlSession.download(for: request)

        // Check response
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw DownloadError.httpError(httpResponse.statusCode)
            }
        }

        // Move to final destination
        // Remove any existing file first
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        print("[MediaDownloadManager] Downloaded: \(destinationURL.lastPathComponent)")
    }

    /// Get file extension for a media item
    private func fileExtension(for mediaItem: any MediaItem) -> String {
        // Try to get extension from sourceURL
        if let sourceURL = mediaItem.sourceURL {
            let ext = sourceURL.pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }

        // Fallback based on media type
        switch mediaItem.type {
        case .video:
            return "mp4"
        case .audio:
            return "mp3"
        case .image:
            return "jpg"
        case .animatedImage:
            return "gif"
        }
    }
}

// MARK: - Errors

enum DownloadError: Error, LocalizedError {
    case invalidDestination
    case httpError(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Invalid download destination"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .cancelled:
            return "Download cancelled"
        }
    }
}
