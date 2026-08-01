import SwiftUI

struct VoiceHelpView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var voice: VoiceCommandService
  @EnvironmentObject var speech: SpeechHelper

  // If a section has >= this many commands, groups become collapsible.
  private let collapseThreshold = 100

  private typealias OverviewModel = VoiceCommandHandler.CommandOverview
  private typealias SectionModel = VoiceCommandHandler.CommandOverview.Section
  private typealias GroupModel = VoiceCommandHandler.CommandOverview.Section.Group
  private typealias ItemModel = VoiceCommandHandler.CommandOverview.Section.Group.Item

  private var handler: VoiceCommandHandler {
    VoiceCommandHandler(
      runtimeAppModel: runtimeAppModel,
      sharedAppModel: sharedAppModel,
      voice: voice,
      speak: { _ in },    // no speech output from the help window
      openSelectedEditor: { }
    )
  }

  var body: some View {
    let overview = handler.commandsOverview()

    TabView {
      overviewTab(overview)
        .tabItem {
          Label("voice_help_tab_overview", systemImage: "info.circle")
        }

      if let passiveSection = overview.sections.first(where: { $0.title == NSLocalizedString(
        "voice_overview_passive_title",
        comment: "Section title: passive mode"
      ) }) {
        sectionTab(
          passiveSection,
          headerTitle: passiveSection.title,
          showCategoriesSummary: false
        )
        .tabItem {
          Label("voice_help_tab_passive", systemImage: "zzz")
        }
      }

      if let mainSection = overview.sections.first(where: { $0.title == NSLocalizedString(
        "voice_overview_main_title",
        comment: "Section title: main commands"
      ) }) {
        sectionTab(
          mainSection,
          headerTitle: mainSection.title,
          showCategoriesSummary: false
        )
        .tabItem {
          Label("voice_help_tab_main", systemImage: "command")
        }
      }
    }
  }

  // MARK: - Overview tab

  private func overviewTab(_ overview: OverviewModel) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(overview.title)
            .font(.largeTitle.bold())

          Text(overview.subtitle)
            .font(.headline)
            .foregroundStyle(.secondary)
        }

        Text(overview.generalDescription)
          .font(.body)
          .foregroundStyle(.secondary)

        if !overview.sections.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("voice_help_sections_title")
              .font(.title3.bold())

            ForEach(overview.sections) { section in
              VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                  .font(.headline)

                Text(section.description)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .padding(.top, 8)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Generic section tab (used for Passive + Main)

  private func sectionTab(
    _ section: SectionModel,
    headerTitle: String,
    showCategoriesSummary: Bool
  ) -> some View {
    let totalCommands = section.groups.reduce(into: 0) { result, group in
      result += group.commands.count
    }

    let useCollapsibleGroups = totalCommands >= collapseThreshold

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(headerTitle)
          .font(.title.bold())

        if !section.description.isEmpty {
          Text(section.description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if showCategoriesSummary, !section.groups.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("voice_help_categories_title")
              .font(.headline)

            Text(
              section.groups
                .map { $0.title }
                .joined(separator: " · ")
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(.top, 4)
        }

        VStack(alignment: .leading, spacing: 12) {
          ForEach(section.groups) { group in
            if useCollapsibleGroups {
              collapsibleGroupView(group)
            } else {
              plainGroupView(group)
            }
          }
        }
        .padding(.top, 8)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Group views

  private func plainGroupView(_ group: GroupModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(group.title)
        .font(.headline)

      if !group.description.isEmpty {
        Text(group.description)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(group.commands) { item in
          commandRow(item)
        }
      }
      .padding(.top, 4)
    }
    .padding(.top, 8)
  }

  private func collapsibleGroupView(_ group: GroupModel) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        if !group.description.isEmpty {
          Text(group.description)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }

        ForEach(group.commands) { item in
          commandRow(item)
        }
      }
      .padding(.top, 4)
      .padding(.leading, 40) // adjust indent as you like
    } label: {
      Text(group.title)
        .font(.headline)
    }
    .padding(.top, 4)
  }

  // MARK: - Command row

  private func commandRow(_ item: ItemModel) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ForEach(item.patterns, id: \.self) { phrase in
          Text(phrase)
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
            )
        }
      }

      Text(item.description)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}
