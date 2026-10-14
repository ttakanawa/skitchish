struct EditorToolDescriptor {
    let tool: EditorTool
    let title: String
    let shortcut: String

    var toolTip: String { "\(title) (⌥⌘\(shortcut.uppercased()))" }
}

enum EditorToolCatalog {
    static let items: [EditorToolDescriptor] = [
        .init(tool: .select, title: "Select", shortcut: "v"),
        .init(tool: .arrow, title: "Arrow", shortcut: "a"),
        .init(tool: .text, title: "Text", shortcut: "t"),
        .init(tool: .rectangle, title: "Rectangle", shortcut: "r"),
        .init(tool: .roundedRectangle, title: "Rounded Rectangle", shortcut: "u"),
        .init(tool: .ellipse, title: "Ellipse", shortcut: "o"),
        .init(tool: .line, title: "Line", shortcut: "l"),
        .init(tool: .pen, title: "Pen", shortcut: "m"),
        .init(tool: .highlight, title: "Highlighter", shortcut: "i"),
        .init(tool: .pixelate, title: "Pixelate", shortcut: "x"),
        .init(tool: .stamp, title: "Stamp", shortcut: "p"),
        .init(tool: .crop, title: "Crop", shortcut: "k"),
    ]

    static let primaryTools: [EditorTool] = [.arrow, .text, .rectangle, .pen, .stamp, .pixelate, .crop]
    static let shapeTools: [EditorTool] = [.rectangle, .roundedRectangle, .ellipse, .line]
    static let drawingTools: [EditorTool] = [.pen, .highlight]

    static func tools(for primary: EditorTool) -> [EditorTool] {
        switch primary {
        case .rectangle: return shapeTools
        case .pen: return drawingTools
        default: return [primary]
        }
    }
}
