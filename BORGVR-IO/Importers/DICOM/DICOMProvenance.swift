import Foundation

/// Original DICOM history values, kept separate from import-time processing events.
struct DicomProvenanceMetadata: Sendable {
  struct Event: Hashable, Sendable {
    let date: Date?
    let text: String
    let category: String
    let details: String?
    let dateOnly: Bool
  }

  struct Contribution: Sendable {
    let dateTime: String?
    let description: String?
    let softwareVersions: String?
  }

  let acquisitionDateTime: String?
  let acquisitionDate: String?
  let acquisitionTime: String?
  let studyDate: String?
  let studyTime: String?
  let seriesDate: String?
  let seriesTime: String?
  let contentDate: String?
  let contentTime: String?
  let instanceCreationDate: String?
  let instanceCreationTime: String?
  let instanceCoercionDateTime: String?
  let timezoneOffsetFromUTC: String?
  let derivationDescription: String?
  let contributions: [Contribution]

  init(readString: (DicomTag) -> String? = { _ in nil }, contributions: [Contribution] = []) {
    acquisitionDateTime = readString(.acquisitionDateTime)
    acquisitionDate = readString(.acquisitionDate)
    acquisitionTime = readString(.acquisitionTime)
    studyDate = readString(.studyDate)
    studyTime = readString(.studyTime)
    seriesDate = readString(.seriesDate)
    seriesTime = readString(.seriesTime)
    contentDate = readString(.contentDate)
    contentTime = readString(.contentTime)
    instanceCreationDate = readString(.instanceCreationDate)
    instanceCreationTime = readString(.instanceCreationTime)
    instanceCoercionDateTime = readString(.instanceCoercionDateTime)
    timezoneOffsetFromUTC = readString(.timezoneOffsetFromUTC)
    derivationDescription = readString(.derivationDescription)
    self.contributions = contributions
  }

  var events: [Event] {
    var result: [Event] = []
    func append(_ label: String, dateTime: String? = nil, date: String? = nil,
                time: String? = nil, details: String? = nil) {
      let raw = dateTime ?? date.map { $0 + (time ?? "") }
      guard raw != nil || details != nil else { return }
      let parsed = raw.map { Self.timestamp($0, offset: timezoneOffsetFromUTC) }
      var text = "DICOM \(label)"
      if let raw { text += "; source timestamp: \(raw)" }
      if let note = parsed?.note { text += "; \(note)" }
      if let details { text += "; \(details)" }
      result.append(Event(date: parsed?.date, text: text, category: label, details: details,
        dateOnly: parsed?.note?.hasPrefix("date only:") == true))
    }
    append("study", date: studyDate, time: studyTime)
    append("series", date: seriesDate, time: seriesTime)
    append("acquisition", dateTime: acquisitionDateTime, date: acquisitionDate, time: acquisitionTime)
    append("content creation", date: contentDate, time: contentTime,
      details: derivationDescription.map { "derivation: \($0)" })
    append("instance creation", date: instanceCreationDate, time: instanceCreationTime)
    append("instance coercion/correction/conversion", dateTime: instanceCoercionDateTime)
    for (index, contribution) in contributions.enumerated() {
      let details = [contribution.description, contribution.softwareVersions.map { "software: \($0)" }]
        .compactMap { $0 }.joined(separator: "; ")
      append("equipment contribution #\(index + 1)", dateTime: contribution.dateTime,
        details: details.isEmpty ? nil : details)
    }
    return result
  }

  /// Slice timestamps describe one series event, not one processing step per slice.
  static func seriesEvents(from slices: [Self]) -> [Event] {
    struct Key: Hashable {
      let category: String
      let details: String?
    }
    var groups: [Key: [Event]] = [:]
    var order: [Key] = []
    for slice in slices {
      for event in slice.events {
        let key = Key(category: event.category, details: event.details)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(event)
      }
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return order.map { key in
      let events = groups[key]!
      let dated = events.filter { $0.date != nil }
      guard dated.count > 1 else { return dated.first ?? events[0] }
      let origin = dated[0].date!
      // Average relative offsets to retain sub-second precision for long series.
      var mean = origin.addingTimeInterval(dated.reduce(0) { $0 + $1.date!.timeIntervalSince(origin) } / Double(dated.count))
      let dateOnly = dated.allSatisfy(\.dateOnly)
      let timestamp: String
      if dateOnly {
        mean = calendar.startOfDay(for: mean)
        let parts = calendar.dateComponents([.year, .month, .day], from: mean)
        timestamp = String(format: "date only: %04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
      } else {
        timestamp = "mean source timestamp: \(formatter.string(from: mean))"
      }
      var text = "DICOM \(key.category); \(timestamp); averaged over \(dated.count) slices"
      if dated.count != events.count { text += " (\(events.count) slices with this event in total)" }
      if let details = key.details { text += "; \(details)" }
      return Event(date: mean, text: text, category: key.category, details: key.details, dateOnly: dateOnly)
    }
  }

  // PS3.5 section 6.2 (DA/TM/DT), PS3.3 C.12.1.1.8 (UTC offsets).
  // A missing offset must never be replaced by the importing device's time zone.
  private static func timestamp(_ raw: String, offset: String?) -> (date: Date?, note: String?) {
    var value = raw
    var zone = offset
    if let sign = value.firstIndex(where: { $0 == "+" || $0 == "-" }) {
      zone = String(value[sign...])
      value = String(value[..<sign])
    }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let digits = Array(parts[0].utf8)
    let allowedLengths = [8, 10, 12, 14]
    guard allowedLengths.contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }),
          parts.count <= 2 else { return (nil, "invalid or incomplete source timestamp; recorded at import time") }
    func number(_ start: Int, _ count: Int) -> Int {
      digits[start..<start + count].reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    let year = number(0, 4), month = number(4, 2), day = number(6, 2)
    let hour = digits.count >= 10 ? number(8, 2) : 0
    let minute = digits.count >= 12 ? number(10, 2) : 0
    let second = digits.count == 14 ? number(12, 2) : 0
    var fraction = 0.0
    if parts.count == 2 {
      guard digits.count == 14, (1...6).contains(parts[1].utf8.count),
            parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
            let parsed = Double("0." + parts[1]) else {
        return (nil, "invalid source timestamp; recorded at import time")
      }
      fraction = parsed
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard year > 0, (1...12).contains(month), (1...31).contains(day),
          hour < 24, minute < 60, second <= 60,
          let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
            hour: hour, minute: minute, second: min(second, 59))),
          calendar.component(.month, from: date) == month,
          calendar.component(.day, from: date) == day else {
      return (nil, "invalid source timestamp; recorded at import time")
    }
    if digits.count == 8 {
      return (date, String(format: "date only: %04d-%02d-%02d", year, month, day))
    }
    guard let zone else { return (nil, "timezone unspecified; recorded at import time") }
    let bytes = Array(zone.utf8)
    guard bytes.count == 5, bytes[0] == 43 || bytes[0] == 45,
          bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) else {
      return (nil, "invalid UTC offset; recorded at import time")
    }
    let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
    let minutes = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
    let offsetMinutes = (bytes[0] == 43 ? 1 : -1) * (hours * 60 + minutes)
    guard minutes < 60, (-720...840).contains(offsetMinutes), zone != "-0000" else {
      return (nil, "invalid UTC offset; recorded at import time")
    }
    return (date.addingTimeInterval(fraction + (second == 60 ? 1 : 0) - Double(offsetMinutes * 60)),
      "UTC offset: \(zone)")
  }
}
