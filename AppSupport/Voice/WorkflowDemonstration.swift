import Combine
import Foundation

enum WorkflowDemonstrationGoal: String, Codable, CaseIterable {
  case inspectValues = "inspect_values"
  case exposeRegion = "expose_region"
  case unspecified

  var title: String {
    switch self {
      case .inspectValues: return "Demonstrate value exploration"
      case .exposeRegion: return "Demonstrate exposing a region"
      case .unspecified: return "Demonstrate without a specified goal"
    }
  }
}

enum WorkflowDemonstrationAction: String, Codable {
  case transform, clipping, lighting, rendering, annotations, volume
  case transferFunction = "transfer_function"

  var title: String {
    switch self {
      case .transform: return "View transformation"
      case .clipping: return "Clipping"
      case .lighting: return "Lighting"
      case .rendering: return "Rendering"
      case .annotations: return "Annotations"
      case .volume: return "Volume editing"
      case .transferFunction: return "Transfer function"
    }
  }
}

struct WorkflowViewEvidence: Codable, Equatable {
  let clipMinimum: [Float]
  let clipMaximum: [Float]
  let rotation: [Float]

  enum CodingKeys: String, CodingKey {
    case clipMinimum = "clip_minimum", clipMaximum = "clip_maximum", rotation
  }

  init?(clipMinimum: [Float], clipMaximum: [Float], rotation: [Float]) {
    guard clipMinimum.count == 3, clipMaximum.count == 3, rotation.count == 4,
          (clipMinimum + clipMaximum).allSatisfy({ (0...1).contains($0) }),
          zip(clipMinimum, clipMaximum).allSatisfy({ $0.0 <= $0.1 }),
          rotation.allSatisfy({ (-1.001...1.001).contains($0) }),
          (0.99...1.01).contains(rotation.reduce(0) { $0 + $1 * $1 })
    else { return nil }
    self.clipMinimum = clipMinimum
    self.clipMaximum = clipMaximum
    self.rotation = rotation
  }
}

struct WorkflowDemonstration: Codable {
  enum Outcome: String, Codable { case reached, notReached = "not_reached", unknown }
  enum End: String, Codable { case finished, interrupted, limit }
  struct Evidence: Codable { let before: WorkflowViewEvidence; let after: WorkflowViewEvidence }

  let version: Int
  let id: UUID
  let goal: WorkflowDemonstrationGoal
  let actions: [WorkflowDemonstrationAction]
  let outcome: Outcome
  let end: End
  let evidence: Evidence?

  init(version: Int, id: UUID, goal: WorkflowDemonstrationGoal, actions: [WorkflowDemonstrationAction],
       outcome: Outcome, end: End, evidence: Evidence? = nil) {
    self.version = version
    self.id = id
    self.goal = goal
    self.actions = actions
    self.outcome = outcome
    self.end = end
    self.evidence = evidence
  }
}

/// Separate export format. Neither screenshot can enter the upload queue.
struct WorkflowScreenshotExport: Encodable {
  struct Pair: Encodable {
    let before: Data
    let after: Data

    enum CodingKeys: String, CodingKey {
      case before = "before_png_base64", after = "after_png_base64"
    }
  }

  let version = 1
  let demonstration: WorkflowDemonstration
  let screenshots: Pair
}

/// The renderer-opening ID stays on device and is never part of an export.
@MainActor
final class WorkflowDemonstrationRecorder: ObservableObject {
  static let maximumActions = 256
  @Published private(set) var active = false
  @Published private(set) var completed: WorkflowDemonstration?
  @Published private(set) var screenshotExport: WorkflowScreenshotExport?
  private(set) var destination: WorkflowDestination?
  private var context: VoiceAgentContext?
  private var id = UUID()
  private var goal: WorkflowDemonstrationGoal = .unspecified
  private var actions: [WorkflowDemonstrationAction] = []
  private var before: WorkflowViewEvidence?
  private var beforeImage: Data?
  private(set) var requestedScreenshots = false
  var capturingEvidence: Bool { active && before != nil }
  var capturingScreenshots: Bool { capturingEvidence && beforeImage != nil }

  func start(goal: WorkflowDemonstrationGoal, context: VoiceAgentContext, destination: WorkflowDestination? = nil,
             before: WorkflowViewEvidence? = nil, beforeImage: Data? = nil) {
    guard !active, completed == nil else { return }
    self.context = context
    self.destination = destination
    self.goal = goal
    self.before = before
    self.beforeImage = before == nil ? nil : beforeImage
    requestedScreenshots = self.beforeImage != nil
    id = UUID()
    actions = []
    active = true
  }

  func record(_ action: WorkflowDemonstrationAction, context: VoiceAgentContext?) {
    checkContext(context)
    guard active, actions.last != action else { return }
    guard actions.count < Self.maximumActions else { finish(end: .limit); return }
    actions.append(action)
  }

  func checkContext(_ current: VoiceAgentContext?) {
    if active, current != context { finish(end: .interrupted) }
  }

  func checkDestination(_ current: WorkflowDestination?) {
    guard current != destination else { return }
    if active { finish(end: .interrupted) }
    // A captured-for-A draft must not remain exportable from B's profile.
    if destination != nil { discard() }
  }

  func invalidateEvidence() {
    before = nil
    beforeImage = nil
  }

  func finish(outcome: WorkflowDemonstration.Outcome = .unknown, end: WorkflowDemonstration.End = .finished,
              after: WorkflowViewEvidence? = nil, afterImage: Data? = nil) {
    guard active else { return }
    if !actions.isEmpty {
      let evidence = (end == .finished ? before : nil).flatMap { start in
        after.map { WorkflowDemonstration.Evidence(before: start, after: $0) }
      }
      let episode = WorkflowDemonstration(version: evidence == nil ? 1 : 2, id: id, goal: goal, actions: actions,
                                          outcome: outcome, end: end, evidence: evidence)
      if evidence != nil, let beforeImage, let afterImage {
        screenshotExport = .init(demonstration: episode, screenshots: .init(before: beforeImage, after: afterImage))
      }
      completed = episode
    }
    context = nil
    requestedScreenshots = false
    invalidateEvidence()
    actions = []
    active = false
  }

  func discard(id: UUID? = nil) {
    guard !active, id == nil || completed?.id == id else { return }
    destination = nil
    screenshotExport = nil
    completed = nil
  }
}
