//
//  make-app-icon.swift
//  Qiyide
//
//  生成应用图标：1024px 主图，采用「Q + 代码折角」的极简结构。
//  用法： swift scripts/design/make-app-icon.swift <输出目录>
//
//  实现要点：
//  - 圆角底板用 `NSBezierPath` 生成，`CGPath(roundedRect:)` 在本环境下会在起始角留下缺口。
//  - 环形用「偶奇填充」而不是描边，笔画用胶囊矩形，避免描边路径被压平。
//  - 尾巴先画、环后画，重叠处被环带覆盖，视觉上没有接缝。
//

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: colorSpace, components: [r, g, b, alpha])!
}

guard let ctx = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("无法创建绘图上下文")
}

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let accentTop = color(0x74E4FF)
let accentBottom = color(0x3D93E6)

// MARK: - 底板

let inset: CGFloat = 100
let radius: CGFloat = 186
let board = CGRect(
    x: inset,
    y: inset,
    width: CGFloat(canvas) - inset * 2,
    height: CGFloat(canvas) - inset * 2
)
/// 手工构造圆角矩形路径。
///
/// 不使用 `CGPath(roundedRect:)` / `NSBezierPath.cgPath`：在本环境下两者的首个圆角会被
/// 一条弦替代，渲染出斜切缺口。这里逐段添加圆弧并显式 `closeSubpath()`。
func roundedRectPath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY

    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addArc(
        center: CGPoint(x: maxX - r, y: minY + r), radius: r,
        startAngle: -CGFloat.pi / 2, endAngle: 0, clockwise: false
    )
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addArc(
        center: CGPoint(x: maxX - r, y: maxY - r), radius: r,
        startAngle: 0, endAngle: CGFloat.pi / 2, clockwise: false
    )
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addArc(
        center: CGPoint(x: minX + r, y: maxY - r), radius: r,
        startAngle: CGFloat.pi / 2, endAngle: CGFloat.pi, clockwise: false
    )
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addArc(
        center: CGPoint(x: minX + r, y: minY + r), radius: r,
        startAngle: CGFloat.pi, endAngle: CGFloat.pi * 1.5, clockwise: false
    )
    path.closeSubpath()
    return path
}

let boardPath = roundedRectPath(board, radius: radius)

ctx.saveGState()
ctx.addPath(boardPath)
ctx.clip()

let boardGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0x2C3C66), color(0x111827)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    boardGradient,
    start: CGPoint(x: 240, y: 900),
    end: CGPoint(x: 830, y: 110),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()

// MARK: - 几何参数

let center = CGPoint(x: 512, y: 556)
let outerRadius: CGFloat = 232
let innerRadius: CGFloat = 156
let strokeWidth: CGFloat = 78

func fillWithAccent(_ path: () -> Void, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    path()
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [accentTop, accentBottom] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - 环形（偶奇填充，得到干净的圆环）

ctx.saveGState()
ctx.addEllipse(in: CGRect(
    x: center.x - outerRadius,
    y: center.y - outerRadius,
    width: outerRadius * 2,
    height: outerRadius * 2
))
ctx.addEllipse(in: CGRect(
    x: center.x - innerRadius,
    y: center.y - innerRadius,
    width: innerRadius * 2,
    height: innerRadius * 2
))
ctx.clip(using: .evenOdd)

let ringGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [accentTop, accentBottom] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    ringGradient,
    start: CGPoint(x: 512, y: 790),
    end: CGPoint(x: 512, y: 320),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()

// MARK: - Q 的尾巴（画在环之上，从碗内起笔，视觉上连续）

let tailAngle = -CGFloat.pi / 4
let tailStart = CGPoint(
    x: center.x + (innerRadius - 66) * cos(tailAngle),
    y: center.y + (innerRadius - 66) * sin(tailAngle)
)
let tailEnd = CGPoint(
    x: center.x + (outerRadius + 96) * cos(tailAngle),
    y: center.y + (outerRadius + 96) * sin(tailAngle)
)
let tailLength = hypot(tailEnd.x - tailStart.x, tailEnd.y - tailStart.y)
let tailMid = CGPoint(x: (tailStart.x + tailEnd.x) / 2, y: (tailStart.y + tailEnd.y) / 2)
var rotation = CGAffineTransform(translationX: tailMid.x, y: tailMid.y).rotated(by: tailAngle)

let tailPath = CGPath(
    roundedRect: CGRect(
        x: -tailLength / 2,
        y: -strokeWidth / 2,
        width: tailLength,
        height: strokeWidth
    ),
    cornerWidth: strokeWidth / 2,
    cornerHeight: strokeWidth / 2,
    transform: &rotation
)

fillWithAccent({
    ctx.addPath(tailPath)
}, from: CGPoint(x: 512, y: 790), to: CGPoint(x: 512, y: 320))

// MARK: - 内部的代码折角

ctx.setLineWidth(36)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(color(0xF3F8FF, 0.96))
ctx.move(to: CGPoint(x: 462, y: 616))
ctx.addLine(to: CGPoint(x: 544, y: 556))
ctx.addLine(to: CGPoint(x: 462, y: 496))
ctx.strokePath()

// MARK: - 导出

guard let image = ctx.makeImage() else { fatalError("无法生成位图") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("无法编码 PNG")
}

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let outputURL = outputDirectory.appendingPathComponent("icon_1024.png")
try data.write(to: outputURL)
print("已生成: \(outputURL.path)")
