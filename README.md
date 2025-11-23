# MediaGallery

A comprehensive SwiftUI package for displaying media galleries with advanced features including zoom, pan, slideshow, video playback, and more.

## Features

✅ **Core Gallery Features**
- Swipe navigation between media items
- Double-tap to zoom in/out (1x to 4x)
- Pan gesture when zoomed
- Fullscreen presentation
- Cross-platform support (iOS & macOS)

✅ **Slideshow**
- Configurable duration (default 5 seconds)
- Automatic playback through images and videos
- Pauses when zoomed in
- Resumes when zoomed out
- Smart duration for animated images

✅ **Media Type Support**
- Static images (JPEG, PNG, etc.)
- Animated images (GIF, APNG, HEIF, WebP) with duration detection
- Videos with automatic playback
- Thumbnail generation

✅ **Advanced Features**
- Share sheet integration
- Collapsible captions for each slide
- Custom action buttons API
- Grid view with thumbnails
- Filter UI (All, Images, Videos, Animated)
- Custom sorting and filtering API
- Video duration display
- Media type indicators
- **Multi-select mode** with selection indicators
- Batch share for multiple items
- Custom multi-select actions (delete, export, etc.)

## Installation

### Adding to Xcode Project

1. In Xcode, go to **File > Add Package Dependencies**
2. Click **Add Local...** button
3. Navigate to `/Users/blainemiller/Documents/mine/Personal/Apps/Ari/Packages/MediaGallery`
4. Select the MediaGallery folder and click **Add Package**
5. Select your target (Ari) and click **Add Package**

## Usage

### Basic Example

```swift
import MediaGallery

// Create media items
let mediaItems: [any MediaItem] = [
    ImageMediaItem(imageLoader: {
        // Load and return your image
        UIImage(named: "photo1")
    }),
    VideoMediaItem(videoURLLoader: {
        // Load and return your video URL
        URL(fileURLWithPath: "/path/to/video.mp4")
    })
]

// Present the gallery
MediaGalleryView(
    mediaItems: mediaItems,
    initialIndex: 0,
    configuration: MediaGalleryConfiguration(
        slideshowDuration: 5.0,
        showControls: true
    ),
    onDismiss: {
        // Handle dismiss
    }
)
```

### Grid View with Filters

```swift
MediaGalleryGridView(
    mediaItems: mediaItems,
    configuration: MediaGalleryConfiguration(),
    filterConfig: MediaGalleryFilterConfig(
        customFilter: { item in
            // Custom filter logic
            return true
        },
        customSort: { item1, item2 in
            // Custom sort logic
            return true
        }
    ),
    onSelect: { index in
        // Handle selection - show full gallery
    },
    onDismiss: {
        // Handle dismiss
    }
)
```

### Custom Action Buttons

```swift
let config = MediaGalleryConfiguration(
    customActions: [
        MediaGalleryAction(icon: "star.fill") { index in
            // Handle favorite action
        },
        MediaGalleryAction(icon: "trash.fill") { index in
            // Handle delete action
        }
    ]
)
```

### Multi-Select with Custom Actions

```swift
MediaGalleryGridView(
    mediaItems: mediaItems,
    multiSelectActions: [
        MediaGalleryMultiSelectAction(
            title: "Export",
            icon: "square.and.arrow.down"
        ) { selectedItems in
            // Export selected items
            exportMedia(selectedItems)
        },
        MediaGalleryMultiSelectAction(
            title: "Delete",
            icon: "trash"
        ) { selectedItems in
            // Delete selected items
            deleteMedia(selectedItems)
        },
        MediaGalleryMultiSelectAction(
            title: "Add to Album",
            icon: "folder.badge.plus"
        ) { selectedItems in
            // Add to album
            addToAlbum(selectedItems)
        }
    ],
    onSelect: { index in
        // Handle single item selection
    },
    onDismiss: {
        // Handle dismiss
    }
)
```

**Multi-Select Features:**
- Tap "Select" in toolbar to enter multi-select mode
- Tap items to select/deselect (blue checkmarks indicate selection)
- "Select All" / "Deselect All" in top-right
- Built-in "Share" button for batch sharing
- Custom action buttons appear in bottom toolbar when items are selected
- Selected items are passed to your custom action handlers

### Implementing Custom MediaItem

```swift
struct CustomMediaItem: MediaItem {
    let id: UUID
    let type: MediaType
    let imageURL: URL

    func loadImage() async -> PlatformImage? {
        // Load image from URL
        ...
    }

    func getCaption() async -> String? {
        return "My custom caption"
    }

    func getShareableItem() async -> Any? {
        return imageURL
    }

    func hasAudioTrack() async -> Bool {
        return false
    }

    // Implement other required methods...
}
```

## Architecture

The package is built with a protocol-based architecture:

- **MediaItem Protocol**: Defines the interface for media items
- **MediaGalleryView**: Main fullscreen gallery view
- **MediaGalleryGridView**: Grid/browsing view with thumbnails
- **ZoomableMediaView**: Individual media view with zoom/pan support
- **AnimatedImageHelper**: Utilities for detecting and handling animated images

## API Reference

### MediaItem Protocol

```swift
protocol MediaItem: Identifiable, Sendable {
    var id: UUID { get }
    var type: MediaType { get }

    func loadImage() async -> PlatformImage?
    func loadVideoURL() async -> URL?
    func getAnimatedImageDuration() async -> TimeInterval?
    func getVideoDuration() async -> TimeInterval?
    func getShareableItem() async -> Any?
    func getCaption() async -> String?
    func hasAudioTrack() async -> Bool
}
```

### MediaGalleryConfiguration

```swift
struct MediaGalleryConfiguration {
    var slideshowDuration: TimeInterval // Default: 5.0
    var showControls: Bool // Default: true
    var backgroundColor: Color // Default: .black
    var customActions: [MediaGalleryAction] // Default: []
}
```

### MediaGalleryFilterConfig

```swift
struct MediaGalleryFilterConfig {
    var customFilter: ((any MediaItem) -> Bool)?
    var customSort: ((any MediaItem, any MediaItem) -> Bool)?
}
```

## Supported Animated Image Formats

- GIF
- APNG/PNG (Animated PNG)
- HEIF/HEIC (Animated HEIF)
- WebP

The package automatically detects animated images and calculates their duration to ensure the animation plays completely before advancing in the slideshow.

## Platform Support

- iOS 17.0+
- macOS 14.0+

## License

This package is part of the Ari project.
