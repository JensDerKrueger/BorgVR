import Foundation

/// Foundation parses Markdown; this only arranges its block-level presentation intents.
struct VoiceAgentMarkdown {
  enum Style: Equatable { case paragraph, heading(Int), code, quote, tableHeader, tableRow }
  struct Block: Identifiable {
    let id: Int
    var cells: [AttributedString]
    var style: Style = .paragraph
    var marker: String?
    var indentation = 0
  }

  let blocks: [Block]

  init(_ source: String) {
    let parsed = (try? AttributedString(markdown: source)) ?? AttributedString(source)
    var blocks: [Block] = []
    var listItems: Set<Int> = []
    for (intent, range) in parsed.runs[\.presentationIntent] {
      var text = AttributedString(parsed[range])
      // Model text must not launch local files, app commands or arbitrary URL schemes.
      for run in text.runs {
        guard let url = run.link else { continue }
        if !["https", "http"].contains(url.scheme?.lowercased() ?? "") ||
          url.host == nil || url.user != nil || url.password != nil {
          text[run.range].link = nil
        }
      }
      let components = intent?.components ?? []
      var block = Block(id: components.first?.identity ?? -(blocks.count + 1), cells: [text])
      var rowID: Int?
      var itemID: Int?
      var ordinal: Int?
      var ordered = false
      for component in components {
        switch component.kind {
          case .header(let level): block.style = .heading(level)
          case .codeBlock: block.style = .code
          case .blockQuote: if block.style == .paragraph { block.style = .quote }
          case .listItem(let number):
            block.indentation += 1
            if itemID == nil { itemID = component.identity; ordinal = number }
          case .orderedList: if rowID == nil, itemID != nil, block.indentation == 1 { ordered = true }
          case .tableHeaderRow: rowID = component.identity; block.style = .tableHeader
          case .tableRow: rowID = component.identity; block.style = .tableRow
          default: break
        }
      }
      if let itemID, listItems.insert(itemID).inserted {
        block.marker = ordered ? "\(ordinal ?? 1)." : "\u{2022}"
      }
      if let rowID {
        if blocks.last?.id == rowID { blocks[blocks.count - 1].cells.append(text); continue }
        block = Block(id: rowID, cells: [text], style: block.style)
      }
      blocks.append(block)
    }
    self.blocks = blocks.isEmpty && !source.isEmpty ? [Block(id: 0, cells: [AttributedString(source)])] : blocks
  }

  var plainText: String {
    blocks.map { $0.cells.map { String($0.characters) }.joined(separator: ", ") }.joined(separator: "\n")
  }
}
