import CoreGraphics
import Foundation

/// 屏幕安全区，坐标系与 `NSScreen` 相同：`top` 是菜单栏/刘海一侧。
struct FloatingSafeAreaInsets: Equatable {
  var top: CGFloat
  var left: CGFloat
  var bottom: CGFloat
  var right: CGFloat

  static let zero = FloatingSafeAreaInsets(top: 0, left: 0, bottom: 0, right: 0)
}

/// 截屏识别出的屏幕遮挡/内容块。
/// 仅用于截屏不可用时的窗口列表降级路径。
struct ScreenObstacle: Equatable {
  var rect: CGRect
}

/// 截屏下采样网格：content 标记“内容/遮挡”，colors 记录每格主色。
/// 行 0 对应屏幕顶部（与 AppKit 左下坐标转换后的 rect 一致）。
struct FloatingScreenGrid: Equatable {
  var width: Int
  var height: Int
  var cellSize: CGFloat
  var origin: CGPoint
  var content: [UInt8]
  /// 每个网格单元的 RGB888 打包颜色（r<<16 | g<<8 | b）。
  /// 为空时回退到基于 content 的近似均匀度。
  var colors: [UInt32]

  init(
    width: Int,
    height: Int,
    cellSize: CGFloat,
    origin: CGPoint,
    content: [UInt8],
    colors: [UInt32] = []
  ) {
    self.width = width
    self.height = height
    self.cellSize = cellSize
    self.origin = origin
    self.content = content
    self.colors = colors
  }

  /// 候选框覆盖的网格行/列范围。
  func coveredRange(of frame: CGRect) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
    let minCol = Int(floor((frame.minX - origin.x) / cellSize))
    let maxCol = Int(ceil((frame.maxX - origin.x) / cellSize)) - 1
    // row 0 在屏幕顶部：y 越小 row 越大。
    let minRow = max(0, height - 1 - Int(floor((frame.maxY - origin.y - 0.01) / cellSize)))
    let maxRow = min(height - 1, height - 1 - Int(floor((frame.minY - origin.y) / cellSize)))
    let colStart = max(0, minCol)
    let colEnd = min(width - 1, maxCol)
    guard colStart <= colEnd, minRow <= maxRow else { return nil }
    return (minRow...maxRow, colStart...colEnd)
  }

  func contentCount(in frame: CGRect) -> Int {
    guard let range = coveredRange(of: frame) else { return 0 }
    var count = 0
    for row in range.rows {
      for col in range.cols {
        let index = row * width + col
        if content.indices.contains(index), content[index] == 1 {
          count += 1
        }
      }
    }
    return count
  }

  func coveredCellCount(in frame: CGRect) -> Int {
    guard let range = coveredRange(of: frame) else { return 0 }
    return range.rows.count * range.cols.count
  }

  /// 候选框覆盖区域内“最接近单一颜色”的度量：
  /// 主色出现次数 / 覆盖格子数，值越接近 1 说明颜色越单一。
  /// 有颜色数据时直接统计；没有颜色数据时回退为“非内容格占比”。
  func dominantColorRatio(in frame: CGRect) -> Double {
    guard let range = coveredRange(of: frame) else { return 0 }
    var total = 0
    var counts: [UInt32: Int] = [:]
    for row in range.rows {
      for col in range.cols {
        let index = row * width + col
        total += 1
        if colors.indices.contains(index) {
          counts[colors[index], default: 0] += 1
        }
      }
    }
    guard total > 0 else { return 0 }
    if !colors.isEmpty {
      return Double(counts.values.max() ?? 0) / Double(total)
    }
    let contentCells = contentCount(in: frame)
    return Double(max(0, total - contentCells)) / Double(total)
  }

  /// 候选框覆盖区域的 RGB 颜色方差（三通道方差之和）。
  /// 数值越小说明颜色越接近单一；有颜色数据时精确计算。
  func colorVariance(in frame: CGRect) -> Double {
    guard let range = coveredRange(of: frame) else { return .greatestFiniteMagnitude }
    var values: [(Double, Double, Double)] = []
    for row in range.rows {
      for col in range.cols {
        let index = row * width + col
        if colors.indices.contains(index) {
          let packed = colors[index]
          values.append((
            Double((packed >> 16) & 0xFF),
            Double((packed >> 8) & 0xFF),
            Double(packed & 0xFF)
          ))
        }
      }
    }
    guard !values.isEmpty else { return .greatestFiniteMagnitude }
    let count = Double(values.count)
    let meanR = values.reduce(0) { $0 + $1.0 } / count
    let meanG = values.reduce(0) { $0 + $1.1 } / count
    let meanB = values.reduce(0) { $0 + $1.2 } / count
    let variance = values.reduce(0.0) { partial, value in
      partial
        + pow(value.0 - meanR, 2)
        + pow(value.1 - meanG, 2)
        + pow(value.2 - meanB, 2)
    } / count
    return variance
  }
}

/// 截屏快照：障碍块 + 适合放置的暗色候选区域。
struct ScreenSnapshot: Equatable {
  var obstacles: [ScreenObstacle]
  /// 原始下采样网格：存在时评分使用精确的暗色/内容覆盖。
  var grid: FloatingScreenGrid?
}

/// 智能定位使用的屏幕几何，纯数据输入，便于单元测试。
struct FloatingScreenGeometry: Equatable {
  var visibleFrame: CGRect
  var safeAreaInsets: FloatingSafeAreaInsets

  init(visibleFrame: CGRect, safeAreaInsets: FloatingSafeAreaInsets = .zero) {
    self.visibleFrame = visibleFrame
    self.safeAreaInsets = safeAreaInsets
  }

  /// 安全可用区域：从可见区域扣除刘海/菜单栏、Dock 等安全区。
  var safeFrame: CGRect {
    CGRect(
      x: visibleFrame.minX + safeAreaInsets.left,
      y: visibleFrame.minY + safeAreaInsets.bottom,
      width: max(0, visibleFrame.width - safeAreaInsets.left - safeAreaInsets.right),
      height: max(0, visibleFrame.height - safeAreaInsets.top - safeAreaInsets.bottom)
    )
  }
}

/// 悬浮窗智能定位纯逻辑：候选生成、障碍过滤评分、屏幕选择。
/// AppKit/CGWindow 读取只保留在边界层，这里全部可用纯函数测试。
enum FloatingPlacement {
  static let margin: CGFloat = 8

  static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.5
      && abs(lhs.minY - rhs.minY) < 0.5
      && abs(lhs.width - rhs.width) < 0.5
      && abs(lhs.height - rhs.height) < 0.5
  }

  /// 把 CGWindow 的全局坐标（左上原点）转换为 AppKit 坐标（左下原点）。
  /// globalMaxY 是所有屏幕在 AppKit 坐标系中的最高 y，即 CG y=0 对应的点。
  static func appKitRect(fromCG rect: CGRect, globalMaxY: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX,
      y: globalMaxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
      return 0
    }
    return intersection.width * intersection.height
  }

  /// 选择与悬浮窗相交面积最大的屏幕；没有相交屏幕时用窗口中心点所在屏幕；
  /// 仍无法确定时返回传入的 fallback（未传则 nil）。
  static func bestScreenIndex(
    frame: CGRect,
    screens: [FloatingScreenGeometry],
    fallback: Int? = nil
  ) -> Int? {
    guard !screens.isEmpty else { return nil }
    let areas = screens.map { intersectionArea(frame, $0.visibleFrame) }
    if let maxArea = areas.max(), maxArea > 0, let index = areas.firstIndex(of: maxArea) {
      return index
    }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let index = screens.firstIndex(where: { $0.visibleFrame.contains(center) }) {
      return index
    }
    if let fallback, screens.indices.contains(fallback) {
      return fallback
    }
    return nil
  }

  /// 计算遮挡最少的目标位置。返回 nil 表示没有任何候选可完整放入屏幕。
  static func bestOrigin(
    frame: CGRect,
    screen: FloatingScreenGeometry,
    snappedToMenuBar: Bool,
    obstacles: [ScreenObstacle],
    currentOrigin: CGPoint
  ) -> CGPoint? {
    // 旧路径（无 grid）：保留边界/障碍边界候选，去掉距离平局。
    let candidates = candidateOrigins(
      frame: frame,
      screen: screen,
      snappedToMenuBar: snappedToMenuBar,
      obstacles: obstacles,
      currentOrigin: currentOrigin
    )
    let visible = screen.visibleFrame
    let valid = candidates.filter {
      visible.contains(CGRect(origin: $0, size: frame.size))
    }
    guard !valid.isEmpty else { return nil }
    let safeFrame = screen.safeFrame
    return valid.min { lhs, rhs in
      isBetter(
        lhs,
        than: rhs,
        frame: frame,
        safeFrame: safeFrame,
        obstacles: obstacles
      )
    }
  }

  /// 全局最佳位置：使用截屏下采样网格，在全屏候选网格上直接评分。
  /// 完全不考虑“离当前位置近”，只比较候选框的暗色覆盖与内容遮挡。
  static func bestOrigin(
    frame: CGRect,
    screen: FloatingScreenGeometry,
    snappedToMenuBar: Bool,
    snapshot: ScreenSnapshot,
    currentOrigin: CGPoint
  ) -> CGPoint? {
    guard let grid = snapshot.grid else {
      return bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: snappedToMenuBar,
        obstacles: snapshot.obstacles,
        currentOrigin: currentOrigin
      )
    }

    let visible = screen.visibleFrame
    let size = frame.size
    let minX = visible.minX + margin
    let maxX = max(minX, visible.maxX - margin - size.width)
    let minY = visible.minY + margin
    let maxY = max(minY, visible.maxY - margin - size.height)
    let stepX = max(8, floor(size.width / 12))
    let stepY = max(8, floor(size.height / 2))

    var origins: [CGPoint] = []
    if snappedToMenuBar {
      let topY = max(minY, screen.safeFrame.isEmpty ? visible.maxY - size.height : screen.safeFrame.maxY - size.height)
      var x = minX
      while x <= maxX {
        origins.append(CGPoint(x: x, y: topY))
        x += stepX
      }
    } else {
      var y = minY
      while y <= maxY {
        var x = minX
        while x <= maxX {
          origins.append(CGPoint(x: x, y: y))
          x += stepX
        }
        y += stepY
      }
    }

    let valid = deduplicatedOrigins(origins).filter {
      visible.contains(CGRect(origin: $0, size: size))
    }
    guard !valid.isEmpty else { return nil }
    let safeFrame = screen.safeFrame
    return valid.min { lhs, rhs in
      isBetterGrid(
        lhs,
        than: rhs,
        frame: frame,
        safeFrame: safeFrame,
        grid: grid
      )
    }
  }

  // MARK: - Candidate generation

  static func candidateOrigins(
    frame: CGRect,
    screen: FloatingScreenGeometry,
    snappedToMenuBar: Bool,
    obstacles: [ScreenObstacle],
    currentOrigin: CGPoint
  ) -> [CGPoint] {
    let visible = screen.visibleFrame
    let safe = screen.safeFrame.isEmpty ? visible : screen.safeFrame
    let size = frame.size
    let minX = visible.minX + margin
    let maxX = max(minX, visible.maxX - margin - size.width)
    let minY = visible.minY + margin
    let maxY = max(minY, visible.maxY - margin - size.height)

    var xValues: [CGFloat] = [
      minX, maxX,
      visible.midX - size.width / 2,
      safe.minX + margin,
      safe.maxX - margin - size.width,
      currentOrigin.x,
    ]
    var yValues: [CGFloat] = [
      minY, maxY,
      visible.midY - size.height / 2,
      safe.minY + margin,
      safe.maxY - margin - size.height,
      currentOrigin.y,
    ]

    // 只考虑与当前屏幕可见区相交的障碍，其他屏幕/远处窗口不参与评分。
    for obstacle in obstacles where obstacle.rect.intersects(visible) {
      // 候选框左/右边对齐障碍左右边，以及候选框刚好贴在障碍左右。
      xValues.append(obstacle.rect.minX - size.width)
      xValues.append(obstacle.rect.minX)
      xValues.append(obstacle.rect.maxX - size.width)
      xValues.append(obstacle.rect.maxX)
      // 候选框下/上边对齐障碍上下边，以及候选框刚好贴在障碍上下。
      yValues.append(obstacle.rect.minY - size.height)
      yValues.append(obstacle.rect.minY)
      yValues.append(obstacle.rect.maxY - size.height)
      yValues.append(obstacle.rect.maxY)
    }

    xValues = clampedAndDeduplicated(xValues, lower: minX, upper: maxX)
    yValues = clampedAndDeduplicated(yValues, lower: minY, upper: maxY)
    guard !xValues.isEmpty, !yValues.isEmpty else { return [] }

    if snappedToMenuBar {
      // 贴顶模式：y 固定为安全区顶部允许的位置，只评估水平候选。
      let topY = max(minY, safe.maxY - size.height)
      return xValues.map { CGPoint(x: $0, y: topY) }
    }

    var origins: [CGPoint] = []
    for x in xValues {
      for y in yValues {
        origins.append(CGPoint(x: x, y: y))
      }
    }
    return origins
  }

  private static func clampedAndDeduplicated(
    _ values: [CGFloat],
    lower: CGFloat,
    upper: CGFloat
  ) -> [CGFloat] {
    var seen: Set<Int> = []
    var result: [CGFloat] = []
    for raw in values {
      let value = min(max(raw, lower), upper)
      let key = Int((value * 10).rounded())
      if seen.insert(key).inserted {
        result.append(value)
      }
    }
    return result.sorted()
  }

  private static func deduplicatedOrigins(_ origins: [CGPoint]) -> [CGPoint] {
    var seen: Set<Int> = []
    var result: [CGPoint] = []
    for origin in origins {
      let key = Int((origin.x * 10).rounded()) * 100_000 + Int((origin.y * 10).rounded())
      if seen.insert(key).inserted {
        result.append(origin)
      }
    }
    return result
  }

  // MARK: - Scoring

  private static func isBetter(
    _ lhs: CGPoint,
    than rhs: CGPoint,
    frame: CGRect,
    safeFrame: CGRect,
    obstacles: [ScreenObstacle]
  ) -> Bool {
    let lhsScore = score(
      origin: lhs,
      frame: frame,
      safeFrame: safeFrame,
      obstacles: obstacles
    )
    let rhsScore = score(
      origin: rhs,
      frame: frame,
      safeFrame: safeFrame,
      obstacles: obstacles
    )
    if lhsScore.area != rhsScore.area {
      return lhsScore.area < rhsScore.area
    }
    if lhsScore.outsideSafe != rhsScore.outsideSafe {
      return lhsScore.outsideSafe < rhsScore.outsideSafe
    }
    return false
  }

  private static func score(
    origin: CGPoint,
    frame: CGRect,
    safeFrame: CGRect,
    obstacles: [ScreenObstacle]
  ) -> (area: CGFloat, outsideSafe: Int) {
    let candidateFrame = CGRect(origin: origin, size: frame.size)
    var area: CGFloat = 0
    for obstacle in obstacles {
      let intersection = candidateFrame.intersection(obstacle.rect)
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
        continue
      }
      let overlapArea = intersection.width * intersection.height
      area += overlapArea
    }
    let outsideSafe = safeFrame.contains(candidateFrame) ? 0 : 1
    return (area, outsideSafe)
  }

  /// 网格级评分：先比“颜色单一性”（dominantColorRatio 越大越好），
  /// 再比“内容覆盖比例”（越小越好），最后比是否完整落在安全区。
  /// 完全忽略当前位置与深浅，保证选到全局最接近单一颜色的区域。
  private static func isBetterGrid(
    _ lhs: CGPoint,
    than rhs: CGPoint,
    frame: CGRect,
    safeFrame: CGRect,
    grid: FloatingScreenGrid
  ) -> Bool {
    let lhsFrame = CGRect(origin: lhs, size: frame.size)
    let rhsFrame = CGRect(origin: rhs, size: frame.size)
    let lhsCovered = grid.coveredCellCount(in: lhsFrame)
    let rhsCovered = grid.coveredCellCount(in: rhsFrame)
    let lhsContentRatio = lhsCovered > 0 ? Double(grid.contentCount(in: lhsFrame)) / Double(lhsCovered) : 0
    let rhsContentRatio = rhsCovered > 0 ? Double(grid.contentCount(in: rhsFrame)) / Double(rhsCovered) : 0

    let lhsUniformity = grid.dominantColorRatio(in: lhsFrame)
    let rhsUniformity = grid.dominantColorRatio(in: rhsFrame)
    if lhsUniformity != rhsUniformity {
      return lhsUniformity > rhsUniformity
    }
    let lhsVariance = grid.colorVariance(in: lhsFrame)
    let rhsVariance = grid.colorVariance(in: rhsFrame)
    if lhsVariance != rhsVariance {
      return lhsVariance < rhsVariance
    }
    if lhsContentRatio != rhsContentRatio {
      return lhsContentRatio < rhsContentRatio
    }
    let lhsSafe = safeFrame.contains(lhsFrame) ? 0 : 1
    let rhsSafe = safeFrame.contains(rhsFrame) ? 0 : 1
    return lhsSafe < rhsSafe
  }

}
