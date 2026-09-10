import SwiftUI

struct AdaptiveLayout {
  enum ModeSelectionStyle {
    case portrait
    case compactLandscape
    case regularLandscape
  }

  enum RenderControlPlacement {
    case overlayTop
  }

  let size: CGSize
  let safeAreaInsets: EdgeInsets
  let horizontalSizeClass: UserInterfaceSizeClass?
  let verticalSizeClass: UserInterfaceSizeClass?

  var isLandscape: Bool {
    size.width > size.height
  }

  var isRegularWidth: Bool {
    horizontalSizeClass == .regular || size.width >= 1000
  }

  var isCompactHeight: Bool {
    verticalSizeClass == .compact || size.height < 500
  }

  var modeSelectionStyle: ModeSelectionStyle {
    guard isLandscape else {
      return .portrait
    }
    return size.width >= 1000 ? .regularLandscape : .compactLandscape
  }

  var renderControlPlacement: RenderControlPlacement {
    .overlayTop
  }

  init(
    size: CGSize,
    safeAreaInsets: EdgeInsets,
    horizontalSizeClass: UserInterfaceSizeClass?,
    verticalSizeClass: UserInterfaceSizeClass?
  ) {
    self.size = size
    self.safeAreaInsets = safeAreaInsets
    self.horizontalSizeClass = horizontalSizeClass
    self.verticalSizeClass = verticalSizeClass
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
