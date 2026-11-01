// Renders every design/icons/*.icon with ictool (Default, Dark, Clear) and lays them out in one PNG.
// Usage: swift design/contact_sheet.swift <output.png>
import AppKit

let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let icons = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("icons"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "icon" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let renditions = ["Default", "Dark", "ClearDark"]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tempra-icons")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let cell: CGFloat = 300, icon: CGFloat = 240, label: CGFloat = 44
let sheet = NSImage(size: NSSize(width: cell * CGFloat(renditions.count) + 220, height: (cell + label) * CGFloat(icons.count)))
var images: [[NSImage]] = []
for doc in icons {
    var row: [NSImage] = []
    for r in renditions {
        let out = tmp.appendingPathComponent("\(doc.deletingPathExtension().lastPathComponent)-\(r).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ictool)
        p.arguments = [doc.path, "--export-image", "--output-file", out.path, "--platform", "macOS",
                       "--rendition", r, "--width", "512", "--height", "512", "--scale", "1"]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        row.append(NSImage(contentsOf: out) ?? NSImage())
    }
    images.append(row)
}

sheet.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill()
NSRect(origin: .zero, size: sheet.size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black]
let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
for (i, doc) in icons.enumerated() {
    let y = sheet.size.height - CGFloat(i + 1) * (cell + label)
    let name = doc.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Tempra-", with: "")
    (name as NSString).draw(at: NSPoint(x: 20, y: y + cell / 2), withAttributes: attrs)
    for (j, image) in images[i].enumerated() {
        let x = 220 + CGFloat(j) * cell
        if renditions[j] != "Default" {
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 10, y: y + 10, width: cell - 20, height: cell - 20), xRadius: 18, yRadius: 18).fill()
        }
        image.draw(in: NSRect(x: x + (cell - icon) / 2, y: y + (cell - icon) / 2, width: icon, height: icon))
        if i == 0 {
            (renditions[j] as NSString).draw(at: NSPoint(x: x + 20, y: y + cell + 10), withAttributes: small)
        }
    }
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])
