// Launched only through local_shell's existing OS confinement and process limits.
import Foundation
import AppKit
import PDFKit
import AVFoundation

enum MediaError: Error { case invalidInput, invalidOutput, invalidPage, invalidTime, renderFailed }

@main struct LocalMedia {
  static func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
  }
  static func save(_ image: CGImage, to path: String) throws {
    guard path.lowercased().hasSuffix(".png"), !FileManager.default.fileExists(atPath: path) else { throw MediaError.invalidOutput }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]), data.count < 20_000_000 else { throw MediaError.renderFailed }
    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  static func main() async {
    do {
      let args = CommandLine.arguments
      guard args.count >= 3 else { throw MediaError.invalidInput }
      let command = args[1], source = URL(fileURLWithPath: args[2])
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size <= 512_000_000 else { throw MediaError.invalidInput }
      if command == "pdf-info" || command == "pdf-page" {
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount <= 5000 else { throw MediaError.invalidInput }
        if command == "pdf-info" {
          try emit(["pages": document.pageCount]); return
        }
        guard args.count == 5, let number = Int(args[3]), number >= 1, let page = document.page(at: number - 1) else { throw MediaError.invalidPage }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw MediaError.invalidPage }
        let scale = 1600 / max(bounds.width, bounds.height)
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MediaError.renderFailed }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw MediaError.renderFailed }
        try save(image, to: args[4])
        try emit(["page": number, "pages": document.pageCount, "width": width, "height": height, "text": String((page.string ?? "").prefix(12000))])
      } else if command == "video-info" || command == "video-frame" {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.invalidInput }
        if command == "video-info" { try emit(["duration_seconds": duration]); return }
        guard args.count == 5, let seconds = Double(args[3]), seconds.isFinite, seconds >= 0, seconds < duration else { throw MediaError.invalidTime }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try save(frame.image, to: args[4])
        try emit(["requested_seconds": seconds, "actual_seconds": frame.actualTime.seconds, "duration_seconds": duration, "width": frame.image.width, "height": frame.image.height])
      } else { throw MediaError.invalidInput }
    } catch {
      // Do not expose native exception strings, source paths, or media contents on failure.
      try? emit(["error": "local.media_render_failed", "hint": "Check command, input, page/time and a new PNG output path; use pdf-info/video-info first."])
      exit(2)
    }
  }
}
