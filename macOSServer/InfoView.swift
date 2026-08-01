import SwiftUI

struct InfoView: View {

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      // Large title text
      Text(
        String(
          format: NSLocalizedString("info_title", comment: ""),
          Bundle.main.appVersion,
          Bundle.main.appBuild
        )
      )
      .font(.largeTitle)
      .bold()
      .frame(minWidth: 680, minHeight: 40)

      HStack {

        Image("borgvr")
          .resizable()
          .scaledToFit()
          .frame(width: 300, height: 300)
          .clipShape(RoundedRectangle(cornerRadius: 20))
          .shadow(radius: 10)

        Spacer()

        // Description text section
        VStack(alignment: .leading, spacing: 10) {
          Text("info_heading")
            .font(.title2)
            .bold()

          Text("info_paragraph_intro")

          Text("info_paragraph_papers")

          VStack(alignment: .leading, spacing: 2) {
            Link(
              "info_paper1_title",
              destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!
            )
            .font(.headline)
            .foregroundColor(.blue)
            Text("info_paper1_venue")

            Link(
              "info_paper2_title",
              destination: URL(string: "https://www.cgvis.de/publications.shtml#2025")!
            )
            .font(.headline)
            .foregroundColor(.blue)
            Text("info_paper2_venue")
          }

          Text("info_paragraph_future")
        }
        .font(.body)
        .multilineTextAlignment(.leading)
        .padding()
        .frame(minWidth: 700, minHeight: 300)
      }
      Spacer()

      HStack {
        Button {
          dismiss()
        } label: {
          Label("info_button_close", systemImage: "xmark.circle")
        }
      }

      // Footer with copyright and external link
      HStack(spacing: 5) {
        Text("info_footer_years")
        Link("info_footer_cgvis", destination: URL(string: "https://www.cgvis.de")!)
      }
      .font(.footnote)
      .foregroundColor(.gray)
    }
    .padding()
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
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
