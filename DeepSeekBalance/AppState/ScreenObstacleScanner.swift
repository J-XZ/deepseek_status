import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore

/// 屏幕遮挡扫描器：双击智能定位时通过短时截屏帧差识别“内容稳定的窗口区域”。
///
/// macOS 的屏幕录制权限不会由代码直接弹窗；应用声明 NSScreenCaptureUsageDescription
/// 后，用户首次调用截屏 API 时系统会弹授权框。未授权时本类返回 nil，
/// 由调用方降级到 CGWindowListCopyWindowInfo 或安全区边界候选。
@MainActor
final class ScreenObstacleScanner: NSObject {
  /// 下采样网格步长（pt）：8pt 一格足以识别窗口遮挡，又不至于逐像素截屏。
  static let sampleStep: CGFloat = 8

  static var hasScreenCaptureAccess: Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// 抓取当前屏幕内容并返回“稳定区域”矩形（AppKit 左下坐标系）。
  /// 采集失败或无权限返回 nil；调用方应降级。
  func captureSnapshot(screen: NSScreen) -> ScreenSnapshot? {
    guard Self.hasScreenCaptureAccess else { return nil }
    guard let displayID = Self.displayID(for: screen) else {
      return nil
    }
    let bounds = screen.frame
    let scale = screen.backingScaleFactor
    let gridWidth = max(1, Int((bounds.width / Self.sampleStep).rounded(.up)))
    let gridHeight = max(1, Int((bounds.height / Self.sampleStep).rounded(.up)))
    // CGDisplayStream 的 outputWidth/outputHeight 单位是像素，不是点。
    let pixelWidth = gridWidth * max(1, Int(scale.rounded()))
    let pixelHeight = gridHeight * max(1, Int(scale.rounded()))

    var capturedFrame: [UInt8]?
    var capturedDark: [UInt8]?
    var capturedColors: [UInt32]?
    let frameLock = NSLock()
    let frameReady = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "screen-obstacle-scanner", qos: .userInitiated)
    let stream = CGDisplayStream(
      dispatchQueueDisplay: displayID,
      outputWidth: pixelWidth,
      outputHeight: pixelHeight,
      pixelFormat: Int32(kCVPixelFormatType_32BGRA),
      properties: nil,
      queue: queue
    ) { _, _, surface, _ in
      guard let surface else { return }
      var pixelBuffer: Unmanaged<CVPixelBuffer>?
      let error = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        surface,
        nil,
        &pixelBuffer
      )
      guard error == kCVReturnSuccess, let pixelBuffer else { return }
      let imageBuffer = pixelBuffer.takeRetainedValue()
      let (content, dark, colors) = Self.downsample(
        imageBuffer,
        gridWidth: gridWidth,
        gridHeight: gridHeight,
        scale: scale
      )
      frameLock.lock()
      if capturedFrame == nil {
        capturedFrame = content
      }
      if capturedDark == nil {
        capturedDark = dark
      }
      if capturedColors == nil {
        capturedColors = colors
      }
      frameLock.unlock()
      frameReady.signal()
    }
    guard let stream else { return nil }
    let started = stream.start()
    guard started == .success else {
      return nil
    }

    // 同步等 1 帧；双击定位是一次性动作，短暂阻塞主线程可接受。
    _ = frameReady.wait(timeout: .now() + 1.0)
    stream.stop()

    frameLock.lock()
    let frame = capturedFrame
    let darkFrame = capturedDark
    let colors = capturedColors
    frameLock.unlock()
    guard let frame else {
      return nil
    }

    let obstacles = Self.stableRegions(
      frame: frame,
      darkFrame: darkFrame,
      width: gridWidth,
      height: gridHeight,
      screenBounds: bounds
    )
    let darkRegions = Self.darkRegions(
      darkFrame: darkFrame,
      width: gridWidth,
      height: gridHeight,
      screenBounds: bounds
    )
    let grid = FloatingScreenGrid(
      width: gridWidth,
      height: gridHeight,
      cellSize: Self.sampleStep,
      origin: bounds.origin,
      content: frame,
      colors: colors ?? []
    )
    return ScreenSnapshot(
      obstacles: obstacles,
      darkRegions: darkRegions,
      grid: grid
    )
  }

  /// 通过 CGDisplayBounds 精确匹配 NSScreen，避免 NSScreenNumber 在有符号
  /// 转换后得到错误的 CGDirectDisplayID（副屏常见）。
  private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success,
      count > 0
    else { return nil }
    let target = screen.frame
    for index in 0..<Int(count) {
      let bounds = CGDisplayBounds(ids[index])
      if abs(bounds.minX - target.minX) < 1,
        abs(bounds.minY - target.minY) < 1,
        abs(bounds.width - target.width) < 1,
        abs(bounds.height - target.height) < 1
      {
        return ids[index]
      }
    }
    // 匹配失败时回退 NSScreenNumber 的位模式。
    if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      return CGDirectDisplayID(number.uint32Value)
    }
    return nil
  }

  /// 把 BGRA 像素缓冲下采样为“是否有内容”网格。
  /// 每个网格单元取左上角像素，按 backingScaleFactor 换算到实际像素坐标。
  private static func downsample(
    _ imageBuffer: CVImageBuffer,
    gridWidth: Int,
    gridHeight: Int,
    scale: CGFloat
  ) -> (content: [UInt8], dark: [UInt8], colors: [UInt32]) {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else {
      return ([], [], [])
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
    let bytesPerPixel = 4
    let bufferHeight = CVPixelBufferGetHeight(imageBuffer)
    let scaleInt = max(1, Int(scale.rounded()))
    var result = [UInt8](repeating: 0, count: gridWidth * gridHeight)
    var dark = [UInt8](repeating: 0, count: gridWidth * gridHeight)
    var colors = [UInt32](repeating: 0, count: gridWidth * gridHeight)
    var luminance = [Double](repeating: 0, count: gridWidth * gridHeight)
    var perCellLuma = [Double](repeating: 0, count: gridWidth * gridHeight)
    let basePtr = base.assumingMemoryBound(to: UInt8.self)

    for row in 0..<gridHeight {
      for col in 0..<gridWidth {
        let srcX = min(col * scaleInt * bytesPerPixel, max(0, bytesPerRow - bytesPerPixel))
        let srcY = min(row * scaleInt, max(0, bufferHeight - 1))
        // 每个网格单元采样 2x2 像素块，取最大亮度，
        // 避免细文字笔画在下采样时被完全吞掉。
        var maxLuma = 0.0
        var cellColorCounts: [UInt32: Int] = [:]
        for dy in 0..<2 {
          for dx in 0..<2 {
            let sx = min(srcX + dx * bytesPerPixel, max(0, bytesPerRow - bytesPerPixel))
            let sy = min(srcY + dy, max(0, bufferHeight - 1))
            let offset = sy * bytesPerRow + sx
            let b = basePtr[offset]
            let g = basePtr[offset + 1]
            let r = basePtr[offset + 2]
            maxLuma = max(maxLuma, 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
            let packed = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            cellColorCounts[packed, default: 0] += 1
          }
        }
        luminance[row * gridWidth + col] = maxLuma
        perCellLuma[row * gridWidth + col] = maxLuma
        colors[row * gridWidth + col] = cellColorCounts.max { $0.value < $1.value }?.key ?? 0
      }
    }
    // 用中位数作为“背景亮度”：整屏相近亮度的壁纸不算内容。
    let sorted = luminance.sorted()
    let median = sorted[sorted.count / 2]
    for index in 0..<result.count {
      let row = index / gridWidth
      let col = index % gridWidth
      // 局部 3x3 邻域最大亮度差：文字笔画通常与紧邻背景有明显反差，
      // 即使整帧中位数接近文字色，也能被识别为内容。
      var localMin = Double.greatestFiniteMagnitude
      var localMax = -Double.greatestFiniteMagnitude
      for dy in -1...1 {
        for dx in -1...1 {
          let ny = row + dy
          let nx = col + dx
          guard ny >= 0, ny < gridHeight, nx >= 0, nx < gridWidth else { continue }
          let neighbor = luminance[ny * gridWidth + nx]
          localMin = min(localMin, neighbor)
          localMax = max(localMax, neighbor)
        }
      }
      let backgroundDiff = abs(luminance[index] - median)
      let localContrast = localMax - localMin
      result[index] = backgroundDiff > 40 || localContrast > 56 ? 1 : 0
      dark[index] = perCellLuma[index] < 32 ? 1 : 0
    }
    return (result, dark, colors)
  }

  /// 多帧取“稳定”单元：至少 2 帧同为内容、且没有大幅来回变化。
  static func stableRegions(
    frame: [UInt8],
    darkFrame: [UInt8]?,
    width: Int,
    height: Int,
    screenBounds: CGRect
  ) -> [ScreenObstacle] {
    var stable = [UInt8](repeating: 0, count: width * height)
    for index in 0..<(width * height) {
      stable[index] = frame.indices.contains(index) ? frame[index] : 0
    }

    // 连通单元合并为矩形：从每个未访问的稳定单元出发做 BFS。
    var visited = [Bool](repeating: false, count: width * height)
    var regions: [ScreenObstacle] = []
    for start in 0..<(width * height) where stable[start] == 1 && !visited[start] {
      var queue = [start]
      visited[start] = true
      var minX = start % width, maxX = minX
      var minY = start / width, maxY = minY
      while !queue.isEmpty {
        let current = queue.removeFirst()
        let cx = current % width
        let cy = current / width
        // 4 连通避免把相邻背景单元斜向连成整屏大块。
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
          let nx = cx + dx
          let ny = cy + dy
          guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
          let neighbor = ny * width + nx
          if stable[neighbor] == 1 && !visited[neighbor] {
            visited[neighbor] = true
            queue.append(neighbor)
            minX = min(minX, nx)
            maxX = max(maxX, nx)
            minY = min(minY, ny)
            maxY = max(maxY, ny)
          }
        }
      }
      let cell = Self.sampleStep
      let minRow = minY
      let maxRow = maxY
      let rect = CGRect(
        x: screenBounds.minX + CGFloat(minX) * cell,
        y: screenBounds.minY + CGFloat(height - 1 - maxRow) * cell,
        width: CGFloat(maxX - minX + 1) * cell,
        height: CGFloat(maxRow - minRow + 1) * cell
      )
      // 忽略几乎覆盖整屏的背景级大块：深色/彩色壁纸渐变会连成整屏，
      // 若作为障碍会让任何位置都被判为遮挡。
      let totalCells = width * height
      let blockCells = (maxX - minX + 1) * (maxRow - minRow + 1)
      if blockCells < Int(Double(totalCells) * 0.6) {
        let blockCellCount = (maxX - minX + 1) * (maxRow - minRow + 1)
        var darkCells = 0
        for row in minY...maxY {
          for col in minX...maxX {
            let index = row * width + col
            if let darkFrame, darkFrame.indices.contains(index), darkFrame[index] == 1 {
              darkCells += 1
            }
          }
        }
      regions.append(
        ScreenObstacle(
          rect: rect,
          darkRatio: Double(darkCells) / Double(blockCellCount),
          isLargeDarkRegion: rect.width >= 200 && rect.height >= 100
        )
      )
      }
    }
    return regions
  }

  /// 测试入口：对外暴露稳定区域合并逻辑。
  static func stableRegionsForTesting(
    frame: [UInt8],
    darkFrame: [UInt8]?,
    width: Int,
    height: Int,
    screenBounds: CGRect
  ) -> [ScreenObstacle] {
    stableRegions(
      frame: frame,
      darkFrame: darkFrame,
      width: width,
      height: height,
      screenBounds: screenBounds
    )
  }

  /// 把暗色网格合并为连通矩形，供候选生成使用。
  private static func darkRegions(
    darkFrame: [UInt8]?,
    width: Int,
    height: Int,
    screenBounds: CGRect
  ) -> [CGRect] {
    guard let darkFrame, !darkFrame.isEmpty else { return [] }
    var visited = [Bool](repeating: false, count: width * height)
    var regions: [CGRect] = []
    let cell = Self.sampleStep
    for start in 0..<(width * height) where darkFrame[start] == 1 && !visited[start] {
      var queue = [start]
      visited[start] = true
      var minX = start % width, maxX = minX
      var minY = start / width, maxY = minY
      while !queue.isEmpty {
        let current = queue.removeFirst()
        let cx = current % width
        let cy = current / width
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
          let nx = cx + dx
          let ny = cy + dy
          guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
          let neighbor = ny * width + nx
          if darkFrame[neighbor] == 1 && !visited[neighbor] {
            visited[neighbor] = true
            queue.append(neighbor)
            minX = min(minX, nx)
            maxX = max(maxX, nx)
            minY = min(minY, ny)
            maxY = max(maxY, ny)
          }
        }
      }
      let rect = CGRect(
        x: screenBounds.minX + CGFloat(minX) * cell,
        y: screenBounds.minY + CGFloat(height - 1 - maxY) * cell,
        width: CGFloat(maxX - minX + 1) * cell,
        height: CGFloat(maxY - minY + 1) * cell
      )
      // 只把足够大的暗色块作为“候选暗色区域”：
      // 浅色背景上小面积暗色文字不是可放置区域，不应进入候选。
      if rect.width >= 200, rect.height >= 100 {
        regions.append(rect)
      }
    }
    return regions
  }

}
