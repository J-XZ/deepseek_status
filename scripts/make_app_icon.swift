#!/usr/bin/env swift
// 生成应用图标：DeepSeek 官方鲸鱼 logo + 紧凑的矢量放大镜徽章。
// 用法：swift scripts/make_app_icon.swift <输入.pdf> <输出.png>
import AppKit

guard CommandLine.arguments.count == 3,
  let source = NSImage(contentsOfFile: CommandLine.arguments[1])
else {
  fputs("用法：swift scripts/make_app_icon.swift <输入.pdf> <输出.png>\n", stderr)
  exit(1)
}

let outputPath = CommandLine.arguments[2]
let canvasSize = NSSize(width: 1024, height: 1024)

let deepSeekBlue = NSColor(
  srgbRed: 77.0 / 255.0,
  green: 107.0 / 255.0,
  blue: 254.0 / 255.0,
  alpha: 1
)

// 给图形保留更均衡的安全边距，避免 Finder、Dock 缩放到小尺寸时视觉拥挤。
let whaleRect = NSRect(x: 232, y: 232, width: 560, height: 560)

let image = NSImage(size: canvasSize, flipped: false) { rect in
  deepSeekBlue.setFill()
  rect.fill()

  // 白色鲸鱼（官方图形，保持宽高比居中缩放）
  let tinted = NSImage(size: whaleRect.size, flipped: false) { whaleArea in
    NSColor.white.setFill()
    whaleArea.fill()
    source.draw(
      in: whaleArea,
      from: .zero,
      operation: .destinationIn,
      fraction: 1
    )
    return true
  }
  tinted.draw(in: whaleRect)

  // 矢量放大镜徽章：尺寸更克制，避免在 16–128px 图标中压住鲸鱼主体。
  let lensRect = NSRect(x: 704, y: 132, width: 204, height: 204)
  let lens = NSBezierPath(ovalIn: lensRect.insetBy(dx: 10, dy: 10))
  let handle = NSBezierPath()
  handle.move(to: CGPoint(x: 856, y: 184))
  handle.line(to: CGPoint(x: 956, y: 84))

  NSColor.white.withAlphaComponent(0.3).setFill()
  lens.fill()
  NSColor.white.setStroke()
  lens.lineWidth = 18
  lens.stroke()
  NSColor.white.setStroke()
  handle.lineWidth = 28
  handle.lineCapStyle = .round
  handle.stroke()
  return true
}

guard let tiff = image.tiffRepresentation,
  let rep = NSBitmapImageRep(data: tiff),
  let png = rep.representation(using: .png, properties: [:])
else {
  fputs("无法编码 PNG\n", stderr)
  exit(1)
}

do {
  try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
  fputs("写入失败：\(error)\n", stderr)
  exit(1)
}
print("已生成 \(outputPath)")
