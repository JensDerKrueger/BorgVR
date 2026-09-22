<p align="center">
  <img src="borgvr.png" alt="BorgVR Logo" width="220"/>
</p>

# BorgVR

BorgVR is a bricked, out-of-core, ray-guided volume rendering system developed by the
[Computer Graphics and Visualization Group](https://www.cgvis.de/) at the University of
Duisburg-Essen. It started as a native Apple Vision Pro renderer and has since grown into
a family of native applications for **visionOS**, **iOS/iPadOS**, and **macOS**, accompanied
by Swift and C++ dataset servers and a WebGPU browser renderer.

The project is intended for interactive exploration of large volumetric datasets. It combines
native Metal renderers, dataset conversion tools, local and remote dataset servers, SharePlay
collaboration, and a WebGPU browser frontend served directly by the dataset server.

## What Is Included

- **VisionApp**: native visionOS volume renderer with spatial interaction, SharePlay, markers,
  and Logitech Muse support.
- **iOSApp**: adaptive native iPhone and iPad volume renderer with local and remote datasets.
- **macOSApp**: native Mac renderer with import tools, scripting, dockable editors, markers,
  and an optional background server.
- **macOSServer**: Mac GUI for dataset conversion, serving, and server-to-server synchronization.
- **TerminalServerApp**: command-line dataset server.
- **TerminalConverterApp**: command-line dataset conversion tool.
- **BORGVRServerCPP**: cross-platform C++17 implementation of the dataset server protocol,
  including synchronization and the embedded WebGPU frontend.
- **web**: responsive WebGPU renderer served directly by a BorgVR server.
- **html**: static support, privacy, and landing pages for app distribution.

## Features

### Rendering

- Bricked out-of-core rendering of volumes larger than GPU memory.
- Native Metal raycasters on visionOS, iOS/iPadOS, and macOS, plus a WebGPU browser renderer.
- Transfer-function, illuminated transfer-function, isosurface, clipping, LOD, and adaptive
  sampling controls.
- GPU-guided brick requests with progressive paging into a brick atlas.
- Interactive transfer-function editors and persistent transfer-function catalogs.

### Collaboration And Markers

- SharePlay collaboration with synchronized datasets, transforms, rendering parameters,
  transfer functions, and markers.
- Optional ad-hoc dataset servers for SharePlay sessions.
- Named and colored spherical markers on all native clients and in WebGPU.
- Directional sphere markers and tube-rendered stroke markers with a shared binary `.marker`
  format and dataset identity checks.
- Marker import, export, server catalogs, editing, and synchronized initial state for new
  SharePlay participants.
- Hand-based marker placement on Apple Vision Pro, including configurable quick markers.
- Logitech Muse spatial-stylus drawing on visionOS 26 or newer, with live stroke radius and
  color controls.

### Data And Servers

- Dataset import and conversion from BorgVR, QVIS, NRRD/NHDR, and DICOM workflows.
- Password-protected Swift and C++ dataset servers serving datasets, transfer functions,
  and marker files.
- Periodic server-to-server synchronization in the macOS server and C++ server, including
  resumable downloads of incomplete datasets.
- Optional HTTPS WebGPU hosting from the Swift server with generated self-signed certificates
  or imported PKCS#12 identities.
- macOS scripting support for repeatable interaction, rendering, and screenshots.

### WebGPU

- Responsive desktop and mobile UI with touch interaction and shareable renderer URLs.
- Optional persistent brick cache backed by IndexedDB, including cache statistics and clearing.
- Dataset-specific transfer-function and marker catalogs loaded from the server.
- Sphere and tube-mesh marker rendering.

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
Scripts/                Example macOS scripting files and command definitions
TransferFunctions/      Bundled transfer-function presets
```

## Building

### Requirements

- Xcode with the SDK required by the selected target. The current project targets iOS/iPadOS
  17.0 or newer, macOS 15.2 or newer, and visionOS 26.0 or newer.
- Apple development signing for device and App Store builds.
- A C++17 compiler and `make` for the standalone C++ server on macOS or Linux. A Visual Studio
  solution is also included for Windows.
- A browser with WebGPU support for the browser renderer. WebGPU on iPhone and iPad requires
  iOS/iPadOS 26 or newer.

### Apple Applications

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

### C++ Dataset Server

Build the standalone server on macOS or Linux with:

```sh
cd BORGVRServerCPP
make
```

The build first compiles a small C++ bootstrap tool that packages the current `web` directory as
LZ4-compressed embedded assets. `src/GeneratedWebAssets.cpp` and
`src/GeneratedWebAssets.h` are generated build inputs and are intentionally not tracked. No Python
runtime is required.

Run `make CONFIG=debug` for a debug build or, for example:

```sh
make run ARGS="12345 64 /path/to/datasets --web-port 8080"
```

The first two arguments select the native dataset-server port and maximum brick batch size. See the
server's command-line help for password, scan interval, WebGPU port, and sync-server options.

### Apple Vision Pro Development

Short setup notes for pairing and enabling development on Apple Vision Pro are kept in
[`readme.txt`](readme.txt).

## Dataset Server And WebGPU Frontend

BorgVR can expose datasets through its native server protocol. The Swift server can also start a
small HTTP/HTTPS server that serves the WebGPU frontend and dataset resources to a browser. Both
server implementations publish compatible dataset, transfer-function, and marker catalogs.

The WebGPU server is disabled by default. When enabled, HTTPS is enabled by default because remote
browser WebGPU access generally requires a secure context. If no certificate is configured, BorgVR
creates a temporary self-signed certificate at server startup. A custom `.p12` or `.pfx`
certificate can be imported in the app settings; its password is stored in the system Keychain.
For safety, plain HTTP binds to `localhost` only. HTTPS listens on the local network so browsers
on other devices can use WebGPU through a secure context. Use a reverse proxy such as nginx if you
intentionally want to expose it outside the local network.

The WebGPU frontend supports the main rendering modes, transfer-function editing, marker files,
touch controls, and optional persistent caching of downloaded bricks in IndexedDB. Browser storage
is scoped to the server origin and can be disabled or cleared from the renderer settings. The native
apps remain the primary high-performance and spatial rendering applications.

## Data Files

BorgVR uses three application-specific file types:

- `.data`: metadata followed by bricked, optionally compressed volume data.
- `.tf1d`: one-dimensional transfer functions and their display metadata.
- `.marker`: binary directional sphere and stroke annotations, including the unique ID of their
  source dataset.

Loading markers created for another dataset requires explicit confirmation. The repository includes
small sample datasets for testing. Larger datasets should be kept outside the repository and served
or opened from a local data directory.

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
