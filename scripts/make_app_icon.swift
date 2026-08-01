#!/usr/bin/env swift
// 生成应用图标：DeepSeek 官方鲸鱼 logo + 🔍 放大镜表情符号。
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

let whaleRect = NSRect(x: 212, y: 212, width: 600, height: 600)

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

  // 🔍 放大镜表情符号（右下角徽章）
  guard let emojiFont = NSFont(name: "Apple Color Emoji", size: 340) else {
    return true
  }
  let emoji = NSAttributedString(
    string: "🔍",
    attributes: [.font: emojiFont]
  )
  let emojiSize = emoji.size()
  let emojiRect = NSRect(
    x: 1024 - 64 - emojiSize.width,
    y: 84,
    width: emojiSize.width,
    height: emojiSize.height
  )
  emoji.draw(in: emojiRect)
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
