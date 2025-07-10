import SwiftUI

// MARK: - PerformanceGraphView

/**
 A SwiftUI view that displays the performance graph for the application.

 This view observes the shared `AppModel` to retrieve the `PerformanceGraphModel`
 and renders it using the `PerformanceGraph` view.

 The layout includes:
 - A title labeled "Performance".
 - The actual performance graph below the title.
 */
struct PerformanceGraphView: View {
  /// The shared application model containing performance data.
  @Environment(AppModel.self) private var appModel

  /// The content and layout of the view.
  var body: some View {
    VStack(spacing: 20) {
      // Title text
      Text("Performance")
        .font(.title)
        .bold()

      // Embed the performance graph, passing in the model
      PerformanceGraph(model: appModel.performanceModel)
    }
    .padding()
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
