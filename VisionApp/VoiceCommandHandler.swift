import Foundation

@MainActor
final class VoiceCommandHandler {

  // MARK: - Dependencies

  let runtimeAppModel: RuntimeAppModel
  let sharedAppModel: SharedAppModel
  let voice: VoiceCommandService
  let speak: (String) -> Void
  let openSelectedEditor: () -> Void

  init(runtimeAppModel: RuntimeAppModel,
       sharedAppModel: SharedAppModel,
       voice: VoiceCommandService,
       speak: @escaping (String) -> Void,
       openSelectedEditor: @escaping () -> Void) {
    self.runtimeAppModel = runtimeAppModel
    self.sharedAppModel = sharedAppModel
    self.voice = voice
    self.speak = speak
    self.openSelectedEditor = openSelectedEditor
  }

  // MARK: - Overview model

  struct CommandOverview {
    struct Section: Identifiable {
      struct Group: Identifiable {
        struct Item: Identifiable {
          let id = UUID()
          let patterns: [String]
          let description: String
        }

        let id = UUID()
        let title: String
        let description: String
        let commands: [Item]
      }

      let id = UUID()
      let title: String
      let description: String
      let groups: [Group]
    }

    let title: String
    let subtitle: String
    let generalDescription: String
    let sections: [Section]
  }

  // MARK: - Command description

  struct Command {

    enum Phase {
      case passiveGate   // checked when voice.isPassive == true
      case main          // checked when voice.isPassive == false
    }

    enum GroupKey: CaseIterable {
      case passive          // wake from standby
      case voiceState       // standby / voice off
      case isoMode          // iso-specific commands
      case transferGlobal   // TF: all colors
      case transferOpacity  // TF: opacity
      case transferChannels // TF: individual channels
      case transferReset    // TF: reset
      case interaction      // interaction / clipping / model / editor
      case global           // reset everything
      case datasetInfo      // dataset description

      var title: String {
        switch self {
          case .passive:
            return NSLocalizedString(
              "voice_group_passive_title",
              comment: "Voice commands group: wake-up"
            )
          case .voiceState:
            return NSLocalizedString(
              "voice_group_voiceState_title",
              comment: "Voice commands group: voice state"
            )
          case .isoMode:
            return NSLocalizedString(
              "voice_group_isoMode_title",
              comment: "Voice commands group: iso rendering"
            )
          case .transferGlobal:
            return NSLocalizedString(
              "voice_group_transferGlobal_title",
              comment: "Voice commands group: transfer function global"
            )
          case .transferOpacity:
            return NSLocalizedString(
              "voice_group_transferOpacity_title",
              comment: "Voice commands group: transfer function opacity"
            )
          case .transferChannels:
            return NSLocalizedString(
              "voice_group_transferChannels_title",
              comment: "Voice commands group: transfer function channels"
            )
          case .transferReset:
            return NSLocalizedString(
              "voice_group_transferReset_title",
              comment: "Voice commands group: transfer function reset"
            )
          case .interaction:
            return NSLocalizedString(
              "voice_group_interaction_title",
              comment: "Voice commands group: interaction and clipping"
            )
          case .global:
            return NSLocalizedString(
              "voice_group_global_title",
              comment: "Voice commands group: global reset"
            )
          case .datasetInfo:
            return NSLocalizedString(
              "voice_group_datasetInfo_title",
              comment: "Voice commands group: dataset info"
            )
        }
      }

      var description: String {
        switch self {
          case .passive:
            return NSLocalizedString(
              "voice_group_passive_description",
              comment: "Description for wake-up commands"
            )
          case .voiceState:
            return NSLocalizedString(
              "voice_group_voiceState_description",
              comment: "Description for voice state commands"
            )
          case .isoMode:
            return NSLocalizedString(
              "voice_group_isoMode_description",
              comment: "Description for iso rendering commands"
            )
          case .transferGlobal:
            return NSLocalizedString(
              "voice_group_transferGlobal_description",
              comment: "Description for global transfer function commands"
            )
          case .transferOpacity:
            return NSLocalizedString(
              "voice_group_transferOpacity_description",
              comment: "Description for opacity transfer function commands"
            )
          case .transferChannels:
            return NSLocalizedString(
              "voice_group_transferChannels_description",
              comment: "Description for per-channel transfer function commands"
            )
          case .transferReset:
            return NSLocalizedString(
              "voice_group_transferReset_description",
              comment: "Description for transfer function reset commands"
            )
          case .interaction:
            return NSLocalizedString(
              "voice_group_interaction_description",
              comment: "Description for interaction and clipping commands"
            )
          case .global:
            return NSLocalizedString(
              "voice_group_global_description",
              comment: "Description for global reset commands"
            )
          case .datasetInfo:
            return NSLocalizedString(
              "voice_group_datasetInfo_description",
              comment: "Description for dataset info commands"
            )
        }
      }
    }

    typealias Condition = (VoiceCommandHandler) -> Bool
    typealias Handler = (VoiceCommandHandler) -> Void

    let phase: Phase
    let group: GroupKey

    /// Canonical phrases that are shown in the UI.
    let patterns: [String]

    /// Additional phrases that are recognized but not shown in the UI.
    let patternAliases: [String]

    let condition: Condition
    let handler: Handler
    let description: String

    func matches(_ handler: VoiceCommandHandler, text: String, phase: Phase) -> Bool {
      guard self.phase == phase else { return false }
      guard condition(handler) else { return false }

      let allPatterns = patterns + patternAliases
      return allPatterns.contains { text.hasSuffix($0) }
    }

    init(
      phase: Phase,
      group: GroupKey,
      patterns: [String],
      patternAliases: [String],
      condition: @escaping Condition,
      handler: @escaping Handler,
      description: String
    ) {
      self.phase = phase
      self.group = group
      self.patterns = patterns
      self.patternAliases = patternAliases
      self.condition = condition
      self.handler = handler
      self.description = description
    }
  }

  // MARK: - Common conditions

  static let always: Command.Condition = { _ in true }

  static let inIsoMode: Command.Condition = {
    $0.sharedAppModel.renderMode == .isoValue
  }

  static let inTransferMode: Command.Condition = {
    $0.sharedAppModel.renderMode != .isoValue
  }

  static let hasActiveDataset: Command.Condition = {
    $0.runtimeAppModel.activeDatasetInfo != nil
  }

  static let isPassive: Command.Condition = {
    $0.voice.isPassive
  }

  // MARK: - Central command table

  private lazy var commands: [Command] = [

    // Passive gate: only commands allowed while passive

    Command(
      phase: .passiveGate,
      group: .passive,
      patterns: LP("voice_patterns_passive_wakeup"),
      patternAliases: LP("voice_patterns_aliases_passive_wakeup"),
      condition: VoiceCommandHandler.isPassive,
      handler: { h in
        h.voice.exitPassiveMode()
        h.speak(L("voice_speak_wakeup", comment: "Voice: woke from standby"))
      },
      description: L(
        "voice_cmd_passive_wakeup_description",
        comment: "Description: wake assistant from standby"
      )
    ),

    // Main: enter passive mode

    Command(
      phase: .main,
      group: .voiceState,
      patterns: LP("voice_patterns_voice_standby"),
      patternAliases: LP("voice_patterns_aliases_voice_standby"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.voice.enterPassiveMode()
        h.speak(L("voice_speak_standby", comment: "Voice: entering standby"))
      },
      description: L(
        "voice_cmd_voice_standby_description",
        comment: "Description: put assistant into standby"
      )
    ),

    // Iso mode specific

    Command(
      phase: .main,
      group: .isoMode,
      patterns: LP("voice_patterns_iso_reset_iso"),
      patternAliases: LP("voice_patterns_aliases_iso_reset_iso"),
      condition: VoiceCommandHandler.inIsoMode,
      handler: { h in
        h.sharedAppModel.resetIsoValue()
        h.sharedAppModel.synchronize(kind: .full)
      },
      description: L(
        "voice_cmd_iso_reset_iso_description",
        comment: "Description: reset iso value in iso mode"
      )
    ),

    // Transfer function – global color (non-iso mode)

    Command(
      phase: .main,
      group: .transferGlobal,
      patterns: LP("voice_patterns_tf_color_off"),
      patternAliases: LP("voice_patterns_aliases_tf_color_off"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setColorChannels(red: false, green: false, blue: false)
        h.openSelectedEditor()
        let state = L("voice_state_off", comment: "State: off")
        let phrase = String(
          format: L("voice_speak_colour_state", comment: "Voice: colour on/off"),
          state
        )
        h.speak(phrase)
      },
      description: L(
        "voice_cmd_tf_color_off_description",
        comment: "Description: disable all color channels"
      )
    ),

    Command(
      phase: .main,
      group: .transferGlobal,
      patterns: LP("voice_patterns_tf_color_on"),
      patternAliases: LP("voice_patterns_aliases_tf_color_on"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setColorChannels(red: true, green: true, blue: true)
        h.openSelectedEditor()
        let state = L("voice_state_on", comment: "State: on")
        let phrase = String(
          format: L("voice_speak_colour_state", comment: "Voice: colour on/off"),
          state
        )
        h.speak(phrase)
      },
      description: L(
        "voice_cmd_tf_color_on_description",
        comment: "Description: enable all color channels"
      )
    ),

    Command(
      phase: .main,
      group: .transferGlobal,
      patterns: LP("voice_patterns_tf_color_toggle"),
      patternAliases: LP("voice_patterns_aliases_tf_color_toggle"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.toggleAllColorChannels()
        h.openSelectedEditor()
        h.speakColorToggleSummary()
      },
      description: L(
        "voice_cmd_tf_color_toggle_description",
        comment: "Description: toggle all color channels"
      )
    ),

    // Transfer function – opacity / alpha (non-iso mode)

    Command(
      phase: .main,
      group: .transferOpacity,
      patterns: LP("voice_patterns_tf_opacity_off"),
      patternAliases: LP("voice_patterns_aliases_tf_opacity_off"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setOpacity(false)
      },
      description: L(
        "voice_cmd_tf_opacity_off_description",
        comment: "Description: disable opacity editing"
      )
    ),

    Command(
      phase: .main,
      group: .transferOpacity,
      patterns: LP("voice_patterns_tf_opacity_on"),
      patternAliases: LP("voice_patterns_aliases_tf_opacity_on"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setOpacity(true)
      },
      description: L(
        "voice_cmd_tf_opacity_on_description",
        comment: "Description: enable opacity editing"
      )
    ),

    Command(
      phase: .main,
      group: .transferOpacity,
      patterns: LP("voice_patterns_tf_opacity_toggle"),
      patternAliases: LP("voice_patterns_aliases_tf_opacity_toggle"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.toggleOpacity()
      },
      description: L(
        "voice_cmd_tf_opacity_toggle_description",
        comment: "Description: toggle opacity editing"
      )
    ),

    // Transfer function – per-channel (non-iso mode)

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_red_off"),
      patternAliases: LP("voice_patterns_aliases_tf_red_off"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.red, value: false)
      },
      description: L(
        "voice_cmd_tf_red_off_description",
        comment: "Description: disable red channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_green_off"),
      patternAliases: LP("voice_patterns_aliases_tf_green_off"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.green, value: false)
      },
      description: L(
        "voice_cmd_tf_green_off_description",
        comment: "Description: disable green channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_blue_off"),
      patternAliases: LP("voice_patterns_aliases_tf_blue_off"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.blue, value: false)
      },
      description: L(
        "voice_cmd_tf_blue_off_description",
        comment: "Description: disable blue channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_red_on"),
      patternAliases: LP("voice_patterns_aliases_tf_red_on"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.red, value: true)
      },
      description: L(
        "voice_cmd_tf_red_on_description",
        comment: "Description: enable red channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_green_on"),
      patternAliases: LP("voice_patterns_aliases_tf_green_on"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.green, value: true)
      },
      description: L(
        "voice_cmd_tf_green_on_description",
        comment: "Description: enable green channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_blue_on"),
      patternAliases: LP("voice_patterns_aliases_tf_blue_on"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.setSingleChannel(.blue, value: true)
      },
      description: L(
        "voice_cmd_tf_blue_on_description",
        comment: "Description: enable blue channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_toggle_red"),
      patternAliases: LP("voice_patterns_aliases_toggle_red"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.toggleSingleChannel(.red)
      },
      description: L(
        "voice_cmd_tf_toggle_red_description",
        comment: "Description: toggle red channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_toggle_green"),
      patternAliases: LP("voice_patterns_aliases_toggle_green"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.toggleSingleChannel(.green)
      },
      description: L(
        "voice_cmd_tf_toggle_green_description",
        comment: "Description: toggle green channel"
      )
    ),

    Command(
      phase: .main,
      group: .transferChannels,
      patterns: LP("voice_patterns_tf_toggle_blue"),
      patternAliases: LP("voice_patterns_aliases_toggle_blue"),
      condition: VoiceCommandHandler.inTransferMode,
      handler: { h in
        h.toggleSingleChannel(.blue)
      },
      description: L(
        "voice_cmd_tf_toggle_blue_description",
        comment: "Description: toggle blue channel"
      )
    ),

    // Transfer function – reset (any mode)

    Command(
      phase: .main,
      group: .transferReset,
      patterns: LP("voice_patterns_tf_reset"),
      patternAliases: LP("voice_patterns_aliases_tf_reset"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.sharedAppModel.transferFunction.reset()
        h.sharedAppModel.synchronize(kind: .full)
      },
      description: L(
        "voice_cmd_tf_reset_description",
        comment: "Description: reset transfer function"
      )
    ),

    // Interaction / clipping / model / editor

    Command(
      phase: .main,
      group: .interaction,
      patterns: LP("voice_patterns_interaction_activate_clipping"),
      patternAliases: LP("voice_patterns_aliases_interaction_activate_clipping"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.runtimeAppModel.interactionMode = .clipping
        h.speak(L("voice_speak_clipping", comment: "Voice: clipping mode"))
      },
      description: L(
        "voice_cmd_interaction_activate_clipping_description",
        comment: "Description: switch interaction mode to clipping"
      )
    ),

    Command(
      phase: .main,
      group: .interaction,
      patterns: LP("voice_patterns_interaction_reset_clipping"),
      patternAliases: LP("voice_patterns_aliases_interaction_reset_clipping"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.sharedAppModel.resetClipBoundsToVolume()
        h.sharedAppModel.synchronize(kind: .full)
      },
      description: L(
        "voice_cmd_interaction_reset_clipping_description",
        comment: "Description: reset clipping bounds"
      )
    ),

    Command(
      phase: .main,
      group: .interaction,
      patterns: LP("voice_patterns_interaction_open_editor"),
      patternAliases: LP("voice_patterns_aliases_interaction_open_editor"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.openSelectedEditor()
      },
      description: L(
        "voice_cmd_interaction_open_editor_description",
        comment: "Description: open selected editor"
      )
    ),

    Command(
      phase: .main,
      group: .interaction,
      patterns: LP("voice_patterns_interaction_activate_model"),
      patternAliases: LP("voice_patterns_aliases_interaction_activate_model"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.runtimeAppModel.interactionMode = .model
        h.speak(L("voice_speak_model", comment: "Voice: model mode"))
      },
      description: L(
        "voice_cmd_interaction_activate_model_description",
        comment: "Description: switch interaction mode to model"
      )
    ),

    // Voice off / reset everything / dataset description

    Command(
      phase: .main,
      group: .voiceState,
      patterns: LP("voice_patterns_voice_disable"),
      patternAliases: LP("voice_patterns_aliases_voice_disable"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.voice.stopListening()
        h.speak(L("voice_speak_voice_off", comment: "Voice: voice off"))
      },
      description: L(
        "voice_cmd_voice_disable_description",
        comment: "Description: disable voice control"
      )
    ),

    Command(
      phase: .main,
      group: .global,
      patterns: LP("voice_patterns_global_reset_all"),
      patternAliases: LP("voice_patterns_aliases_global_reset_all"),
      condition: VoiceCommandHandler.always,
      handler: { h in
        h.sharedAppModel.reset()
        h.sharedAppModel.synchronize(kind: .full)
        h.speak(L("voice_speak_reset_all", comment: "Voice: reset everything"))
      },
      description: L(
        "voice_cmd_global_reset_all_description",
        comment: "Description: reset entire application"
      )
    ),

    Command(
      phase: .main,
      group: .datasetInfo,
      patterns: LP("voice_patterns_dataset_info"),
      patternAliases: LP("voice_patterns_aliases_dataset_info"),
      condition: VoiceCommandHandler.hasActiveDataset,
      handler: { h in
        h.describeCurrentDataset()
      },
      description: L(
        "voice_cmd_dataset_info_description",
        comment: "Description: describe current dataset"
      )
    )
  ]

  // MARK: - Public entry point

  func handle(rawText: String, isFinal: Bool) {
    let text = normalize(rawText)

    if voice.isPassive {
      if runFirstMatching(phase: .passiveGate, text: text) {
        return
      } else {
        return
      }
    }

    if !runFirstMatching(phase: .main, text: text) {
      print(text)
    }
  }

  // MARK: - Public overview builder

  func commandsOverview() -> CommandOverview {
    let passiveCommands = commands.filter { $0.phase == .passiveGate }
    let mainCommands = commands.filter { $0.phase == .main }

    var sections: [CommandOverview.Section] = []

    // Passive section
    if !passiveCommands.isEmpty {
      let group = makeGroup(
        title: Command.GroupKey.passive.title,
        description: Command.GroupKey.passive.description,
        commands: passiveCommands
      )

      let section = CommandOverview.Section(
        title: L(
          "voice_overview_passive_title",
          comment: "Section title: passive mode"
        ),
        description: L(
          "voice_overview_passive_description",
          comment: "Section description: passive mode"
        ),
        groups: [group]
      )
      sections.append(section)
    }

    // Main section with alphabetically sorted groups
    if !mainCommands.isEmpty {
      let grouped = Dictionary(grouping: mainCommands, by: { $0.group })

      let sortedKeys = grouped.keys.sorted { $0.title < $1.title }

      var groups: [CommandOverview.Section.Group] = []

      for key in sortedKeys {
        guard let cmds = grouped[key] else { continue }
        let group = makeGroup(
          title: key.title,
          description: key.description,
          commands: cmds
        )
        groups.append(group)
      }

      let section = CommandOverview.Section(
        title: L(
          "voice_overview_main_title",
          comment: "Section title: main commands"
        ),
        description: L(
          "voice_overview_main_description",
          comment: "Section description: main commands"
        ),
        groups: groups
      )
      sections.append(section)
    }

    return CommandOverview(
      title: L(
        "voice_overview_title",
        comment: "Voice commands overview title"
      ),
      subtitle: L(
        "voice_overview_subtitle",
        comment: "Voice commands overview subtitle"
      ),
      generalDescription: L(
        "voice_overview_generalDescription",
        comment: "Voice commands general description"
      ),
      sections: sections
    )
  }

  private func makeGroup(
    title: String,
    description: String,
    commands: [Command]
  ) -> CommandOverview.Section.Group {
    let items = commands.map { cmd in
      CommandOverview.Section.Group.Item(
        patterns: cmd.patterns,      // aliases are intentionally not shown
        description: cmd.description
      )
    }

    return CommandOverview.Section.Group(
      title: title,
      description: description,
      commands: items
    )
  }

  // MARK: - Execution helpers

  private func runFirstMatching(phase: Command.Phase, text: String) -> Bool {
    for command in commands {
      if command.matches(self, text: text, phase: phase) {
        command.handler(self)
        return true
      }
    }
    return false
  }

  private func normalize(_ text: String) -> String {
    text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  // MARK: - Helpers

  private enum ColorChannel {
    case red, green, blue
  }

  private func setColorChannels(red: Bool, green: Bool, blue: Bool) {
    runtimeAppModel.transferEditState.red = red
    runtimeAppModel.transferEditState.green = green
    runtimeAppModel.transferEditState.blue = blue
  }

  private func toggleAllColorChannels() {
    let s = runtimeAppModel.transferEditState
    runtimeAppModel.transferEditState.red = !s.red
    runtimeAppModel.transferEditState.green = !s.green
    runtimeAppModel.transferEditState.blue = !s.blue
  }

  private func speakColorToggleSummary() {
    let s = runtimeAppModel.transferEditState
    if s.red == s.green && s.green == s.blue {
      let stateKey = s.red ? "voice_state_on" : "voice_state_off"
      let state = L(stateKey, comment: "State: on/off")
      let phrase = String(
        format: L("voice_speak_colour_state", comment: "Voice: colour on/off"),
        state
      )
      speak(phrase)
    } else {
      speak(
        L(
          "voice_speak_colour_toggled",
          comment: "Voice: colour toggled"
        )
      )
    }
  }

  private func setSingleChannel(_ channel: ColorChannel, value: Bool) {
    let stateKey = value ? "voice_state_on" : "voice_state_off"
    let state = L(stateKey, comment: "State: on/off")

    switch channel {
      case .red:
        runtimeAppModel.transferEditState.red = value
        speak(
          String(
            format: L("voice_speak_red_state", comment: "Voice: red on/off"),
            state
          )
        )
      case .green:
        runtimeAppModel.transferEditState.green = value
        speak(
          String(
            format: L("voice_speak_green_state", comment: "Voice: green on/off"),
            state
          )
        )
      case .blue:
        runtimeAppModel.transferEditState.blue = value
        speak(
          String(
            format: L("voice_speak_blue_state", comment: "Voice: blue on/off"),
            state
          )
        )
    }
    openSelectedEditor()
  }

  private func toggleSingleChannel(_ channel: ColorChannel) {
    switch channel {
      case .red:
        runtimeAppModel.transferEditState.red.toggle()
        let stateKey = runtimeAppModel.transferEditState.red
        ? "voice_state_on" : "voice_state_off"
        let state = L(stateKey, comment: "State: on/off")
        speak(
          String(
            format: L("voice_speak_red_state", comment: "Voice: red on/off"),
            state
          )
        )
      case .green:
        runtimeAppModel.transferEditState.green.toggle()
        let stateKey = runtimeAppModel.transferEditState.green
        ? "voice_state_on" : "voice_state_off"
        let state = L(stateKey, comment: "State: on/off")
        speak(
          String(
            format: L("voice_speak_green_state", comment: "Voice: green on/off"),
            state
          )
        )
      case .blue:
        runtimeAppModel.transferEditState.blue.toggle()
        let stateKey = runtimeAppModel.transferEditState.blue
        ? "voice_state_on" : "voice_state_off"
        let state = L(stateKey, comment: "State: on/off")
        speak(
          String(
            format: L("voice_speak_blue_state", comment: "Voice: blue on/off"),
            state
          )
        )
    }
    openSelectedEditor()
  }

  private func setOpacity(_ value: Bool) {
    runtimeAppModel.transferEditState.opacity = value
    openSelectedEditor()
    let stateKey = value ? "voice_state_on" : "voice_state_off"
    let state = L(stateKey, comment: "State: on/off")
    speak(
      String(
        format: L("voice_speak_opacity_state", comment: "Voice: opacity on/off"),
        state
      )
    )
  }

  private func toggleOpacity() {
    runtimeAppModel.transferEditState.opacity.toggle()
    openSelectedEditor()
    let stateKey = runtimeAppModel.transferEditState.opacity
    ? "voice_state_on" : "voice_state_off"
    let state = L(stateKey, comment: "State: on/off")
    speak(
      String(
        format: L("voice_speak_opacity_state", comment: "Voice: opacity on/off"),
        state
      )
    )
  }

  private func describeCurrentDataset() {
    guard let info = runtimeAppModel.activeDatasetInfo else { return }

    let componentWordKey = (info.componentCount == 1)
    ? "voice_dataset_component_singular"
    : "voice_dataset_component_plural"
    let componentWord = L(
      componentWordKey,
      comment: "Component / components"
    )

    let byteWordKey = (info.bytesPerComponent == 1)
    ? "voice_dataset_byte_singular"
    : "voice_dataset_byte_plural"
    let byteWord = L(
      byteWordKey,
      comment: "Byte / bytes"
    )

    let sizeText: String
    if info.width == info.height && info.height == info.depth {
      sizeText = String(
        format: L(
          "voice_dataset_size_cube",
          comment: "Cubic dataset size: %d³"
        ),
        info.width
      )
    } else if info.width == info.height {
      sizeText = String(
        format: L(
          "voice_dataset_size_square_depth",
          comment: "Square by depth size: %d² by %d"
        ),
        info.width, info.depth
      )
    } else {
      sizeText = String(
        format: L(
          "voice_dataset_size_generic",
          comment: "Generic size: w by h by d"
        ),
        info.width, info.height, info.depth
      )
    }

    let text = String(
      format: L(
        "voice_dataset_full_sentence",
        comment: "Full spoken description of dataset"
      ),
      info.description,
      sizeText,
      info.componentCount,
      componentWord,
      info.bytesPerComponent,
      byteWord
    )

    speak(text)
  }
}

// MARK: - Localized string helpers

private func L(_ key: String, comment: String = "") -> String {
  NSLocalizedString(key, comment: comment)
}

/// Returns a localized list of patterns for a voice command.
/// The localized string should contain phrases separated by "|".
private func LP(_ key: String) -> [String] {
  let raw = NSLocalizedString(key, comment: "Voice command patterns")
  return raw
    .split(separator: "|")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }
}
