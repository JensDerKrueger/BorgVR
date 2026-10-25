import SwiftUI

#if os(macOS) || os(iOS)
enum ScreenControlAppearance {
  static var surface: Color {
    #if os(macOS)
    Color(nsColor: .controlBackgroundColor)
    #else
    Color(uiColor: .secondarySystemBackground)
    #endif
  }
}

struct ScreenControlButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var accent: Color = .secondary
  var isSelected = false
  var showsAccent = false
  var horizontalPadding: CGFloat = 8
  var verticalPadding: CGFloat = 5
  var minimumHeight: CGFloat = 28

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minHeight: minimumHeight)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(ScreenControlAppearance.surface)
        RoundedRectangle(cornerRadius: 6)
          .fill(accent.opacity(isSelected ? 0.12 : 0))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(isSelected ? accent : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
      }
      .overlay(alignment: .bottom) {
        if showsAccent {
          Capsule().fill(accent).frame(width: 18, height: 2).padding(.bottom, 3)
        }
      }
      .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
  }
}
#endif

extension View {
  @ViewBuilder
  func screenControlButtons() -> some View {
    #if os(macOS) || os(iOS)
    buttonStyle(ScreenControlButtonStyle())
    #else
    self
    #endif
  }

  @ViewBuilder
  func screenControlMenu() -> some View {
    #if os(macOS) || os(iOS)
    foregroundStyle(.primary)
      .tint(.primary)
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(ScreenControlAppearance.surface, in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
      }
    #else
    self
    #endif
  }
}
