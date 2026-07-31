// 生成 DeepSeekBalance 占位菜单栏图标（矢量 PDF）。
// 用法：swift scripts/generate_deepseek_icon.swift
// 图标为单色鲸鱼剪影，配合 template rendering 在浅色/深色菜单栏下均可用。
import AppKit
import Foundation

let canvas: CGFloat = 64

let path = NSBezierPath()

// 吻部（面向左侧），向上经过头顶
path.move(to: NSPoint(x: 10, y: 33))
path.curve(
  to: NSPoint(x: 30, y: 45),
  controlPoint1: NSPoint(x: 8, y: 42),
  controlPoint2: NSPoint(x: 18, y: 46)
)
// 背鳍
path.line(to: NSPoint(x: 35, y: 51))
path.line(to: NSPoint(x: 40, y: 43))
// 背部到尾部交汇点
path.curve(
  to: NSPoint(x: 47, y: 38),
  controlPoint1: NSPoint(x: 42, y: 43),
  controlPoint2: NSPoint(x: 45, y: 40)
)
// 尾鳍上叶
path.curve(
  to: NSPoint(x: 61, y: 46),
  controlPoint1: NSPoint(x: 52, y: 43),
  controlPoint2: NSPoint(x: 58, y: 46)
)
// 尾鳍缺口
path.curve(
  to: NSPoint(x: 55, y: 36),
  controlPoint1: NSPoint(x: 60, y: 42),
  controlPoint2: NSPoint(x: 58, y: 38)
)
// 尾鳍下叶
path.curve(
  to: NSPoint(x: 61, y: 26),
  controlPoint1: NSPoint(x: 57, y: 33),
  controlPoint2: NSPoint(x: 60, y: 28)
)
// 回到尾部交汇点下方
path.curve(
  to: NSPoint(x: 47, y: 30),
  controlPoint1: NSPoint(x: 57, y: 24),
  controlPoint2: NSPoint(x: 52, y: 27)
)
// 腹部
path.curve(
  to: NSPoint(x: 18, y: 25),
  controlPoint1: NSPoint(x: 38, y: 22),
  controlPoint2: NSPoint(x: 26, y: 21)
)
// 下颌回到吻部
path.curve(
  to: NSPoint(x: 10, y: 33),
  controlPoint1: NSPoint(x: 12, y: 27),
  controlPoint2: NSPoint(x: 9, y: 29)
)
path.close()

// 眼睛：使用 even-odd 规则挖出透明圆孔
let eye = NSBezierPath(ovalIn: NSRect(x: 19, y: 35, width: 5, height: 5))
path.append(eye)
path.windingRule = .evenOdd

let data = NSMutableData()
guard let consumer = CGDataConsumer(data: data) else {
  fatalError("无法创建 CGDataConsumer")
}
var mediaBox = CGRect(x: 0, y: 0, width: canvas, height: canvas)
guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
  fatalError("无法创建 CGContext")
}

context.beginPDFPage(nil)
let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputURL =
  scriptDirectory
  .deletingLastPathComponent()
  .appendingPathComponent("DeepSeekBalance/Assets.xcassets/DeepSeekIcon.imageset/deepseek_icon.pdf")

try data.write(to: outputURL)
print("已生成：\(outputURL.path)")
