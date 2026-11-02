import SwiftUI

struct DatasetListMetadata: Equatable, Sendable {
  let voxelCount: Double
  let physicalVolume: Double?

  init(_ metadata: BORGVRMetaData) {
    voxelCount = Double(metadata.width) * Double(metadata.height) * Double(metadata.depth)
    let spacing = [metadata.voxelSpacingX, metadata.voxelSpacingY, metadata.voxelSpacingZ]
    let volume = voxelCount * spacing.reduce(1) { $0 * Double($1) }
    physicalVolume = spacing.allSatisfy { $0.isFinite && $0 > 0 } && volume.isFinite && volume > 0
      ? volume : nil
  }
}

enum DatasetListSource {
  case local, builtIn
  case remote(address: String, port: Int)

  var identifier: String {
    switch self {
      case .local: return "local"
      case .builtIn: return "builtIn"
      case let .remote(address, port): return "remote:\(address.lowercased()):\(port)"
    }
  }

  var title: String {
    switch self {
      case .local: return String(localized: "Local")
      case .builtIn: return String(localized: "Built-in")
      case let .remote(address, port): return "\(String(localized: "Remote")) - \(address):\(port)"
    }
  }
}

protocol DatasetListEntry {
  var description: String { get }
  var listID: String { get }
  var listSource: DatasetListSource { get }
  var listMetadata: DatasetListMetadata? { get }
}

enum DatasetListSort: String, CaseIterable, Identifiable {
  case description, physicalVolume, voxelCount
  var id: String { rawValue }
  var title: String {
    switch self {
      case .description: return String(localized: "Description")
      case .physicalVolume: return String(localized: "Physical volume")
      case .voxelCount: return String(localized: "Voxel count")
    }
  }
}

enum DatasetListGrouping: String, CaseIterable, Identifiable {
  case none, source
  var id: String { rawValue }
  var title: String {
    switch self {
      case .none: return String(localized: "No grouping")
      case .source: return String(localized: "Data source")
    }
  }
}

struct DatasetListSection<Entry: DatasetListEntry>: Identifiable {
  let id: String
  let title: String?
  var entries: [Entry]
}

enum DatasetListPresentation {
  static func sections<Entry: DatasetListEntry>(
    _ entries: [Entry], sort: DatasetListSort, ascending: Bool, grouping: DatasetListGrouping
  ) -> [DatasetListSection<Entry>] {
    let sorted = entries.sorted { left, right in
      if sort != .description {
        let a = sort == .voxelCount ? left.listMetadata?.voxelCount : left.listMetadata?.physicalVolume
        let b = sort == .voxelCount ? right.listMetadata?.voxelCount : right.listMetadata?.physicalVolume
        if a == nil, b != nil { return false }
        if b == nil, a != nil { return true }
        if let a, let b, a != b { return ascending ? a < b : a > b }
      }
      let byName = left.description.localizedStandardCompare(right.description)
      if byName != .orderedSame {
        return sort == .description && !ascending ? byName == .orderedDescending : byName == .orderedAscending
      }
      return left.listID < right.listID
    }
    guard grouping != .none else {
      return [DatasetListSection(id: "all", title: nil, entries: sorted)]
    }
    var groups: [String: DatasetListSection<Entry>] = [:]
    for entry in sorted {
      let group = group(for: entry, grouping: grouping)
      if groups[group.id] == nil {
        groups[group.id] = DatasetListSection(id: group.id, title: group.title, entries: [])
      }
      groups[group.id]?.entries.append(entry)
    }
    return groups.values.sorted {
      return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
    }
  }

  private static func group<Entry: DatasetListEntry>(
    for entry: Entry, grouping: DatasetListGrouping
  ) -> (id: String, title: String) {
    switch grouping {
      case .source:
        return (entry.listSource.identifier, entry.listSource.title)
      case .none:
        return ("all", "")
    }
  }
}

struct DatasetListSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.title3.weight(.semibold))
      .foregroundStyle(Color.accentColor)
      .textCase(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color.accentColor.opacity(0.14))
      .background(.background)
      .overlay(alignment: .leading) {
        Rectangle().fill(Color.accentColor).frame(width: 4)
      }
      .accessibilityAddTraits(.isHeader)
  }
}

struct DatasetListControls: View {
  @Binding var sort: DatasetListSort
  @Binding var ascending: Bool
  @Binding var grouping: DatasetListGrouping

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 18) {
        sortPicker
        directionPicker
        groupingPicker
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          sortPicker
          Spacer(minLength: 8)
          directionPicker
        }
        groupingPicker
      }
      VStack(alignment: .leading, spacing: 8) {
        sortPicker
        directionPicker
        groupingPicker
      }
    }
    .pickerStyle(.menu)
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var sortPicker: some View {
    Picker("Sort by", selection: $sort) {
      ForEach(DatasetListSort.allCases) { Text($0.title).tag($0) }
    }
  }

  private var directionPicker: some View {
    Picker("Sort direction", selection: $ascending) {
      Text("Ascending").tag(true)
      Text("Descending").tag(false)
    }
    .labelsHidden()
    .accessibilityLabel("Sort direction")
  }

  private var groupingPicker: some View {
    Picker("Group by", selection: $grouping) {
      ForEach(DatasetListGrouping.allCases) { Text($0.title).tag($0) }
    }
  }
}
