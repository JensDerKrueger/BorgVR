import Foundation

// Only the header fields used by the list; no volume data or networking is needed.
struct BORGVRMetaData {
  var width: Int = 10
  var height: Int = 10
  var depth: Int = 10
  var voxelSpacingX: Float = 1
  var voxelSpacingY: Float = 1
  var voxelSpacingZ: Float = 1
}

private struct Entry: DatasetListEntry {
  let listID: String
  let description: String
  let listSource: DatasetListSource
  var listMetadata: DatasetListMetadata?
}

@main
struct DatasetListPresentationTests {
  static func main() {
    let small = DatasetListMetadata(BORGVRMetaData(width: 100, height: 100, depth: 100,
      voxelSpacingX: 0.0001, voxelSpacingY: 0.0001, voxelSpacingZ: 0.0001))
    let large = DatasetListMetadata(BORGVRMetaData())
    let invalid = DatasetListMetadata(BORGVRMetaData(voxelSpacingX: .nan))
    precondition(invalid.physicalVolume == nil)
    precondition(DatasetListMetadata(BORGVRMetaData(voxelSpacingX: 0)).physicalVolume == nil)
    let entries = [
      Entry(listID: "small", description: "B", listSource: .local, listMetadata: small),
      Entry(listID: "unknown", description: "C", listSource: .remote(address: "server", port: 1234)),
      Entry(listID: "large", description: "A", listSource: .builtIn, listMetadata: large),
      Entry(listID: "invalid", description: "D", listSource: .remote(address: "server", port: 5678), listMetadata: invalid)
    ]
    func ids(_ sort: DatasetListSort, _ ascending: Bool) -> [String] {
      DatasetListPresentation.sections(entries, sort: sort, ascending: ascending, grouping: .none)
        .flatMap(\.entries).map(\.listID)
    }
    precondition(ids(.description, true) == ["large", "small", "unknown", "invalid"])
    precondition(ids(.description, false) == ["invalid", "unknown", "small", "large"])
    precondition(ids(.physicalVolume, true) == ["small", "large", "unknown", "invalid"])
    precondition(ids(.physicalVolume, false) == ["large", "small", "unknown", "invalid"])
    precondition(ids(.voxelCount, true) == ["large", "invalid", "small", "unknown"])
    precondition(ids(.voxelCount, false) == ["small", "large", "invalid", "unknown"])

    let grouped = DatasetListPresentation.sections(entries, sort: .voxelCount, ascending: false, grouping: .source)
    precondition(grouped.count == 4, "Different server ports must not be merged")
    let remoteGroup = grouped.first { $0.id == "remote:server:1234" }
    precondition(remoteGroup?.title == "Remote - server:1234", "Remote group headings must include the source type and endpoint")
    precondition(Set(grouped.flatMap(\.entries).map(\.listID)) == Set(entries.map(\.listID)))
    precondition(grouped.allSatisfy { $0.title != nil })
    let multiple = [entries[0], Entry(listID: "local2", description: "E", listSource: .local, listMetadata: large)]
    let localGroup = DatasetListPresentation.sections(multiple, sort: .voxelCount, ascending: true, grouping: .source)
    precondition(localGroup.count == 1 && localGroup[0].entries.map(\.listID) == ["local2", "small"])
    let duplicates = [entries[0], Entry(listID: "remote-copy", description: "B", listSource: .remote(address: "server", port: 1234), listMetadata: small)]
    precondition(DatasetListPresentation.sections(duplicates, sort: .description, ascending: true, grouping: .none)[0].entries.count == 2)
    let natural = [Entry(listID: "10", description: "Scan 10", listSource: .local),
                   Entry(listID: "2", description: "Scan 2", listSource: .local)]
    precondition(DatasetListPresentation.sections(natural, sort: .description, ascending: true, grouping: .none)[0].entries.map(\.listID) == ["2", "10"])
    precondition(entries.map(\.listID) == ["small", "unknown", "large", "invalid"], "Presentation must not reorder the underlying catalog")
    print("Dataset list sorting and source grouping tests passed")
  }
}
