import Cocoa
import FlutterMacOS

/// 无边框透明标题栏窗口与 `acp/window` 平台通道（R9，对齐 windows/runner/acp_window.cpp 与 acp_clipboard.cpp）：
/// - 原生红绿灯（traffic lights）保留在左上角，隐藏系统标题文字与标题栏底色，内容铺满整窗（`.fullSizeContentView`）；
/// - 窗口最小尺寸 960×600，初始内容尺寸 1280×800；
/// - `acp/window` MethodChannel：`minimize` / `toggleMaximize` / `close` / `isMaximized` / `startDragging` / `readClipboardImages`。
class MainFlutterWindow: NSWindow {
  private static let kMinWidth: CGFloat = 960
  private static let kMinHeight: CGFloat = 600
  private static let kDefaultWidth: CGFloat = 1280
  private static let kDefaultHeight: CGFloat = 800
  private static let kDoubleClickSlop: CGFloat = 4
  /// 与 Dart 侧 `clipboardBitmapBytesLimit` 及 Windows runner `kMaxBitmapBytes` 对齐：256 MB。
  private static let kMaxBitmapBytes: Int64 = 256 * 1024 * 1024

  private var channel: FlutterMethodChannel?
  private var lastDragDownTime: TimeInterval = 0
  private var lastDragDownPoint: NSPoint = .zero

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    self.minSize = NSSize(width: Self.kMinWidth, height: Self.kMinHeight)
    self.setContentSize(NSSize(width: Self.kDefaultWidth, height: Self.kDefaultHeight))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    setupWindowChannel(flutterViewController: flutterViewController)

    super.awakeFromNib()
  }

  private func setupWindowChannel(flutterViewController: FlutterViewController) {
    let registrar = flutterViewController.registrar(forPlugin: "AcpWindowChannel")
    let methodChannel = FlutterMethodChannel(
      name: "acp/window",
      binaryMessenger: registrar.messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    self.channel = methodChannel
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "minimize":
      self.miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      self.zoom(nil)
      result(nil)
    case "close":
      self.close()
      result(nil)
    case "isMaximized":
      result(self.isZoomed)
    case "startDragging":
      self.startWindowDrag()
      result(nil)
    case "readClipboardImages":
      var includeBitmap = true
      if let args = call.arguments as? [String: Any],
         let bitmapFlag = args["bitmap"] as? Bool {
        includeBitmap = bitmapFlag
      }
      result(Self.readClipboardImages(includeBitmap: includeBitmap))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 顶栏空白处左键按下：双击触发系统缩放（`performZoom`），单击交由 `performDrag(with:)` 拖动窗口。
  /// 因首击进入系统模态拖拽循环后会吞掉 mouseUp，这里除检查 `event.clickCount >= 2` 外，
  /// 同步按系统双击间隔与 4pt 容差比对连续两次 `startDragging` 的屏幕坐标（与 Windows runner 同口径）。
  private func startWindowDrag() {
    let now = ProcessInfo.processInfo.systemUptime
    let mouseLoc = NSEvent.mouseLocation
    let currentEvent = NSApp.currentEvent

    let isRapidSecondClick =
      lastDragDownTime > 0
      && (now - lastDragDownTime) <= NSEvent.doubleClickInterval
      && abs(mouseLoc.x - lastDragDownPoint.x) <= Self.kDoubleClickSlop
      && abs(mouseLoc.y - lastDragDownPoint.y) <= Self.kDoubleClickSlop

    if (currentEvent?.clickCount ?? 0) >= 2 || isRapidSecondClick {
      lastDragDownTime = 0
      self.performZoom(nil)
      return
    }

    lastDragDownTime = now
    lastDragDownPoint = mouseLoc

    if let event = currentEvent,
       event.type == .leftMouseDown || event.type == .leftMouseDragged {
      self.performDrag(with: event)
      return
    }

    let windowPoint = self.convertPoint(fromScreen: mouseLoc)
    if let synthetic = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: windowPoint,
      modifierFlags: [],
      timestamp: now,
      windowNumber: self.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1.0
    ) {
      self.performDrag(with: synthetic)
    }
  }

  /// 读取剪贴板中的文件/目录 URL 与图片位图（对齐 `windows/runner/acp_clipboard.cpp` 与 `lib/app/clipboard_image.dart`）：
  /// 1. 先读 `NSPasteboard.general` 中的文件/目录 URL（`NSPasteboard.PasteboardType.fileURL`），有则只回 `[{"path": "<UTF-8 路径>"}]`；
  ///    Finder 复制文件时会同时往剪贴板放文件图标的 TIFF 位图，有文件 URL 时必须忽略位图。
  /// 2. 若无文件且 `includeBitmap == true`，读取 PNG / TIFF 位图并转为自上而下、32 位不透明（alpha 置 `0xFF`）的 `bgra` 字节数组；
  ///    超过 `kMaxBitmapBytes`（256 MB）时只回 `width` / `height` 不回 `bgra`。
  private static func readClipboardImages(includeBitmap: Bool) -> [[String: Any]] {
    let pasteboard = NSPasteboard.general
    let filePaths = readFilePaths(from: pasteboard)
    if !filePaths.isEmpty {
      return filePaths.map { ["path": $0] }
    }
    guard includeBitmap else {
      return []
    }
    guard let item = readBitmapItem(from: pasteboard) else {
      return []
    }
    return [item]
  }

  private static func readFilePaths(from pasteboard: NSPasteboard) -> [String] {
    var paths: [String] = []
    var seen = Set<String>()

    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] {
      for url in urls where url.isFileURL {
        let p = url.standardizedFileURL.path
        if !p.isEmpty && seen.insert(p).inserted {
          paths.append(p)
        }
      }
    }

    if paths.isEmpty, let items = pasteboard.pasteboardItems {
      for item in items {
        guard let raw = item.string(forType: .fileURL),
              let url = URL(string: raw),
              url.isFileURL else {
          continue
        }
        let p = url.standardizedFileURL.path
        if !p.isEmpty && seen.insert(p).inserted {
          paths.append(p)
        }
      }
    }
    return paths
  }

  private static func readBitmapItem(from pasteboard: NSPasteboard) -> [String: Any]? {
    let cgImage: CGImage? = {
      if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
         let rep = NSBitmapImageRep(data: data),
         let cg = rep.cgImage {
        return cg
      }
      if let image = NSImage(pasteboard: pasteboard) {
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      }
      return nil
    }()

    guard let image = cgImage else {
      return nil
    }
    let width = image.width
    let height = image.height
    guard width > 0 && height > 0 else {
      return nil
    }

    let totalBytes = Int64(width) * Int64(height) * 4
    if totalBytes > kMaxBitmapBytes {
      return [
        "width": width,
        "height": height,
      ]
    }

    let byteCount = Int(totalBytes)
    let bytesPerRow = width * 4
    var buffer = Data(count: byteCount)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    let drawn = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else {
        return false
      }
      guard let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      ) else {
        return false
      }
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let ptr = rawBuffer.bindMemory(to: UInt8.self)
      var idx = 3
      while idx < byteCount {
        ptr[idx] = 0xFF
        idx += 4
      }
      return true
    }

    guard drawn else {
      return nil
    }

    return [
      "width": width,
      "height": height,
      "bgra": FlutterStandardTypedData(bytes: buffer),
    ]
  }
}
