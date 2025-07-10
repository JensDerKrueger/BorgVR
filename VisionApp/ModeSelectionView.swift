import SwiftUI

/**
 A view that presents the mode selection interface for the BorgVR application.

 This view displays the current application version, an image, descriptive text about BorgVR,
 and provides options to either import a dataset or open an existing one. It also includes footer
 copyright information and a link to the CGVIS Duisburg website.
 */
struct ModeSelectionView: View {

  /**
   The shared application model, providing access to the application state (including the version).
   */
  @Environment(AppModel.self) private var appModel

  /**
   An environment value that provides a closure to open new windows.
   */
  @Environment(\.openWindow) private var openWindow

  /**
   The content and layout of the mode selection view.

   The view is organized in a vertical stack with the following components:
   - A large title displaying the BorgVR version.
   - A resizable image representing the application.
   - A descriptive section that explains the purpose and background of BorgVR, including a link to an IEEE paper.
   - Two buttons allowing the user to either import a dataset or open an existing dataset.
   - A footer with copyright information and a link to CGVIS Duisburg.
   */
  var body: some View {
    VStack(spacing: 20) {
      // Large title text
      Text("BorgVR Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
        .font(.largeTitle)
        .bold()

      Image("borgvr")
        .resizable()
        .scaledToFit()
        .frame(width: 400, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 10)

      // Description text section
      VStack(alignment: .leading, spacing: 10) {
        Text("Welcome to the BorgVR application.")
          .font(.title2)
          .bold()

        Text("""
                BorgVR is a **Bricked Out-of-Core, Ray-Guided Volume Rendering Application** designed for **Virtual and Augmented Reality** on the **Apple Vision Pro** platform. It has been built from the ground up to be fully optimized for Vision Pro, leveraging **Swift** and **Metal** for high-performance rendering. BorgVR is an **open-source** project, making it accessible for further development and collaboration.
                """)

        Text("""
                This application is part of an **ongoing research project**, exploring advanced techniques in volume rendering. Our work has been published in a **short paper** titled:
                """)

        // Link to the IEEE paper
        Link("**Investigating the Apple Vision Pro Spatial Computing Platform for GPU-Based Volume Visualization**",
             destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!)
        .font(.headline)
        .foregroundColor(.blue)

        Text("""
                presented at **IEEE Visualization 2024**. While the original study introduced the core technology, BorgVR now represents a **more sophisticated volume renderer**, integrating **Ray-Guided Volume Rendering** along with the latest advancements introduced in **visionOS 1.3 and beyond**.
                """)
      }
      .font(.body)
      .multilineTextAlignment(.leading)
      .padding()

      Spacer()

      HStack {

        /**
         A button that transitions the application state to open an existing dataset.

         Tapping this button sets the application state to `.selectData`, which initiates the dataset selection process.
         */
        Button("Open a Dataset") {
          appModel.currentState = .selectData
        }
        .padding()
        .buttonStyle(.borderedProminent)
        /**
         A button that transitions the application state to import a dataset.

         Tapping this button sets the application state to `.importData`, which initiates the dataset import process.
         */
        Button("Import a Dataset") {
          appModel.currentState = .importData
        }
        .padding()
        .buttonStyle(.borderedProminent)
        /**
         A button that transitions the application state to change the settings

         Tapping this button sets the application state to `.settings`, which initiates the dataset import process.
         */
        Button("Configure Settings") {
          appModel.currentState = .settings
        }
        .padding()
        .buttonStyle(.borderedProminent)
      }

      // Footer with copyright and external link
      HStack(spacing: 5) {
        Text("© 2024-2025")
        Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
      }
      .font(.footnote)
      .foregroundColor(.gray)
    }
    .padding()
    
  }
}
