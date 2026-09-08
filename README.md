<p align="center">
  <img src="borgvr.png" alt="BorgVR Logo" width="220"/>
</p>

# BorgVR

BorgVR is a bricked out-of-core, ray-guided volume rendering system developed by the
[Computer Graphics and Visualization Group](https://www.cgvis.de/) at the University of
Duisburg-Essen. It started as a native Apple Vision Pro renderer and has since grown into
a shared codebase for **visionOS**, **iOS/iPadOS**, and **macOS**.

The project is intended for interactive exploration of large volumetric datasets. It combines
native Metal renderers, dataset conversion tools, local and remote dataset servers, SharePlay
collaboration, and an experimental WebGPU browser frontend served directly by the dataset server.

## What Is Included

- **VisionApp**: native visionOS volume renderer for Apple Vision Pro.
- **iOSApp**: native iPhone and iPad volume renderer.
- **macOSApp**: native Mac renderer with import tools, scripting support, and optional background server.
- **macOSServer**: Mac GUI for dataset conversion and serving.
- **TerminalServerApp**: command-line dataset server.
- **TerminalConverterApp**: command-line dataset conversion tool.
- **BORGVRServerCPP**: C++ implementation of the dataset server protocol, including the embedded WebGPU frontend.
- **web**: WebGPU browser frontend used by the server.
- **html**: static support, privacy, and landing pages for app distribution.

## Features

- Bricked out-of-core volume rendering for datasets larger than GPU memory.
- Metal renderers shared across Apple platforms where possible.
- Transfer-function, isosurface, lighting, clipping, and LOD controls.
- GPU-guided brick requests with progressive paging into a brick atlas.
- SharePlay collaboration with synchronized dataset and render state.
- Optional ad-hoc dataset servers for collaboration sessions.
- Password-protected dataset servers.
- Optional HTTPS WebGPU server with generated self-signed certificates or imported PKCS#12 identities.
- WebGPU preview frontend for browsing and rendering datasets from a browser.
- Dataset import and conversion from supported volume formats.
- macOS scripting support for repeatable rendering and screenshots.

## Repository Layout

```text
AppSupport/             Shared Swift UI, renderer support, shaders, settings, and WebGPU assets
BORGVR-IO/              Dataset readers, metadata, raw access, and conversion helpers
BORGVR-Render/          Metal rendering infrastructure
BORGVR-Services/        Swift TCP dataset server and HTTP/WebGPU server
BORGVRServerCPP/        C++ dataset server implementation
VisionApp/              visionOS app target
iOSApp/                 iPhone and iPad app target
macOSApp/               macOS renderer app target
macOSServer/            macOS server/converter app target
TerminalServerApp/      Swift command-line dataset server
TerminalConverterApp/   Swift command-line converter
web/                    WebGPU browser frontend
html/                   App support/privacy website pages
```

## Building

Open `BorgVR.xcodeproj` in Xcode and select the scheme for the platform you want to build.

Common schemes:

- `VisionApp`
- `VisionApp Release`
- `iOSApp`
- `iOSApp Release`
- `macOSApp`
- `macOSApp Release`
- `macOSServer`
- `macOSServer Release`
- `TerminalServerApp`
- `TerminalConverterApp`

For App Store or device builds, configure your Apple development team and signing settings in Xcode.
The project uses the shared bundle identifier configured in the Xcode project.

### Apple Vision Pro Development

Short setup notes for pairing and enabling development on Apple Vision Pro are kept in `readme.txt`.

## Dataset Server And WebGPU Frontend

BorgVR can expose datasets through its native server protocol. The Swift server can also start a
small HTTP/HTTPS server that serves the WebGPU frontend and dataset resources to a browser.

The WebGPU server is disabled by default. When enabled, HTTPS is enabled by default because remote
browser WebGPU access generally requires a secure context. If no certificate is configured, BorgVR
creates a temporary self-signed certificate at server startup. A custom `.p12` or `.pfx`
certificate can be imported in the app settings; its password is stored in the system Keychain.
For safety, the WebGPU HTTP/HTTPS endpoint binds to `localhost` only. Use a reverse proxy such as
nginx if you intentionally want to expose it outside the local machine.

The WebGPU frontend is primarily intended as a convenient preview and dataset browser. The native
apps remain the main high-performance rendering applications.

## Data Files

BorgVR uses `.data` files containing metadata and bricked volume data. The repository includes small
sample datasets for testing. Larger datasets should be kept outside the repository and served or
opened from a local data directory.

## Research Background

BorgVR builds on several years of work on GPU volume rendering, ray-guided rendering, mobile
visualization, and virtual-reality visualization systems. Related publications include:

1. **Investigating the Apple Vision Pro Spatial Computing Platform for GPU-Based Volume Visualization**:
   Camilla Hrycak, David Lewakis, Jens Krueger, IEEE VIS 2024

2. **Embracing Raycasting for Virtual Reality**:
   Andre Waschk, Jens Krueger, WSCG 2022

3. **FAVR - Accelerating Direct Volume Rendering for Virtual Reality Systems**:
   Andre Waschk, Jens Krueger, IEEE VIS 2020

4. **State of the Art in Mobile Volume Rendering on iOS Devices**:
   Alexander Schiewe, Mario Anstoots, Jens Krueger, EuroVis 2015

5. **An Analysis of Scalable GPU-Based Ray-Guided Volume Rendering**:
   Thomas Fogal, Alexander Schiewe, Jens Krueger, IEEE LDAV 2013

More publications are listed on the [CGVIS publications page](https://www.cgvis.de/publications.shtml).

## License

BorgVR is released under the [MIT License](LICENSE).

## Contact

Computer Graphics and Visualization Group
University of Duisburg-Essen
[https://www.cgvis.de/](https://www.cgvis.de/)
