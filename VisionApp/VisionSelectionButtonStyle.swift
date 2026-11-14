import SwiftUI

/// Keep selection, hit testing and the system gaze highlight on one shared shape.
struct VisionSelectionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  var isSelected: Bool
  var tint: Color = .accentColor
  var cornerRadius: CGFloat = 8

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    configuration.label
      .foregroundStyle(tint)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(tint.opacity(configuration.isPressed ? 0.22 : (isSelected ? 0.14 : 0)), in: shape)
      .clipShape(shape)
      .contentShape([.interaction, .hoverEffect], shape)
      .hoverEffect(.highlight, isEnabled: isEnabled)
      .opacity(isEnabled ? 1 : 0.45)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
