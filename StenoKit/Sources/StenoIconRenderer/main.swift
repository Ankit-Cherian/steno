import Foundation
import StenoKit
import SwiftUI

// Writes the app icon set drawn from `BrandMark`, the one mark definition:
//
//   swift run --package-path StenoKit StenoIconRenderer <output-directory>
//
// The output is the `AppIcon.appiconset` PNGs (icon_16x16.png ... icon_512x512@2x.png, the small
// cut at 16 and 32 pixels) and the quill as Icon Composer layers (`barbs.svg`, `shaft.svg`). It
// writes only to the directory given; copying the PNGs into Steno/Assets.xcassets and the SVGs
// into Design/Steno.icon/Assets is a separate step.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: StenoIconRenderer <output-directory>\n".utf8))
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

/// The tile's continuous-corner outline, as the macOS icon grid draws it.
func tileShape(px: Int) -> CGPath {
    let size = CGFloat(px)
    return RoundedRectangle(cornerRadius: BrandIconArtwork.cornerRadius(px: size), style: .continuous)
        .path(in: BrandIconArtwork.tileRect(px: size)).cgPath
}

func write(_ data: Data?, _ name: String) throws {
    guard let data else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: directory.appendingPathComponent(name))
    print(name)
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try write(BrandIconArtwork.png(px: px, colors: .green, tileShape: tileShape(px: px)), name)
}
try write(Data(BrandIconArtwork.barbsSVG().utf8), "barbs.svg")
try write(Data(BrandIconArtwork.shaftSVG().utf8), "shaft.svg")
