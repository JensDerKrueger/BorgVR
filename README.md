<img src="borgvr.png" alt="BorgVR Logo" width="300"/>

# BorgVR

BorgVR stands for Bricked Out-of-Core Ray-Guided Volume Rendering and is a high-performance, large-scale, out-of-core, [ray-guided](https://en.wikipedia.org/wiki/Ray_tracing_(graphics)), [volume rendering](https://en.wikipedia.org/wiki/Volume_rendering) project. This project is developed by the [Computergraphics and Visualization Group](https://www.cgvis.de/) at the University of Duisburg-Essen and supports **visionOS, iOS/iPadOS, and macOS**. BorgVR started as an Apple Vision Pro spatial computing application and now also provides native iPhone, iPad, and Mac applications built around the same bricked volume rendering system.

---

## Overview

BorgVR extends the capabilities of volume rendering across Apple platforms. The system employs cutting-edge techniques in out-of-core raycasting to render complex, large-scale volumetric datasets seamlessly. On Apple Vision Pro, BorgVR provides immersive spatial visualization; on iPhone, iPad, and Mac, it offers native touch, pointer, and desktop workflows for interactive volume exploration.

### Key Features

- **High-Performance Volume Rendering**: Optimized Metal-based rendering for Apple Vision Pro, iPhone, iPad, and Mac.
- **Out-of-Core Data Handling**: Efficient management and rendering of massive datasets, suitable for high-resolution visualization and simulation.
- **Ray-Guided Volume Rendering**: Advanced ray-guided techniques for interactive visualization, supporting intuitive exploration of volumetric data.
- **GPU Acceleration**: Full utilization of Apple GPU capabilities to support real-time rendering.
- **Cross-Platform Collaboration**: SharePlay-based collaborative sessions can synchronize datasets and render state across supported Apple platforms.
- **Dataset Tools and Server Support**: Includes import/conversion workflows and server components for local and remote dataset access.

### Applications and Targets

- **VisionApp**: Native visionOS renderer for Apple Vision Pro.
- **iOSApp**: Native iPhone and iPad renderer.
- **macOSApp**: Native Mac renderer with import features and optional background dataset server support.
- **macOSServer**: Mac dataset server and import utility.
- **TerminalServerApp**: Command-line dataset server.
- **TerminalConverterApp**: Command-line dataset conversion tool.

---

## Research Basis

BorgVR is grounded in the following research publications. The full list of publications can be found on our [publications page](https://www.cgvis.de/publications.shtml).

1. **Investigating the Apple Vision Pro Spatial Computing Platform for GPU-Based Volume Visualization**  
   *Camilla Hrycak, David Lewakis, Jens Krüger*  
   *Proceedings of the IEEE VIS 2024 Conference*

2. **Embracing Raycasting for Virtual Reality**  
   *Andre Waschk, Jens Krüger*  
   *30th International Conference on Computer Graphics, Visualization and Computer Vision, WSCG 2022*

3. **FAVR - Accelerating Direct Volume Rendering for Virtual Reality Systems**  
   *Andre Waschk, Jens Krüger*  
   *2020 IEEE Visualization Conference (VIS)*

4. **Mobile Computational Steering for Interactive Prediction and Visualization of Deep Brain Stimulation Therapy**  
   *Johannes Vorwerk, Andrew Janson, Alexander Schiewe, Jens Krüger, Christopher R. Butson*  
   *Medical Image Analysis and Visualization Workshop, Supercomputing 2016*

5. **Mobile Decision Support System for Nurse Management of Deep Brain Stimulation**  
   *Gordon Duffley, D. Martinez, Jens Krüger, B. Lutz, M.S. Okun, Christopher R. Butson*  
   *20th International Congress on Parkinson’s and Movement Disorders*

6. **Trinity: A Novel Visualization and Data Distribution System**  
   *Andrey Krekhov, Jens Krüger*  
   *GPU Technology Conference 2016*

7. **State of the Art in Mobile Volume Rendering on iOS Devices**  
   *Alexander Schiewe, Mario Anstoots, Jens Krüger*  
   *EuroVis 2015 Short Paper Proceedings*

8. **An Analysis of Scalable GPU-Based Ray-Guided Volume Rendering**  
   *Thomas Fogal, Alexander Schiewe, Jens Krüger*  
   *IEEE Large Scale Data Analysis and Visualization Symposium 2013*

9. **Evaluation of Interactive Visualization on Mobile Computing Platforms for Selection of Deep Brain Stimulation Parameters**  
   *Christopher Butson, Georg Tamm, Sanket Jain, Thomas Fogal, Jens Krüger*  
   *IEEE Transactions on Visualization and Computer Graphics, 19(1):108 - 117, January 2013*

10. **Tuvok - An Architecture for Large Scale Volume Rendering**  
    *Jens Krüger, Thomas Fogal*  
    *Proceedings of the 15th Vision, Modeling and Visualization Workshop 2010*

These works provide the foundation for BorgVR’s architecture, data handling, and rendering approach, advancing the field of volume visualization and raycasting for immersive spatial computing applications.

---

## Installation

To get started with BorgVR, ensure that you have Xcode and the required Apple platform SDKs installed for the targets you want to build.

1. **Clone the repository**:
   ```bash
   git clone https://github.com/JensDerKrueger/BorgVR.git
   cd BorgVR
   ```

2. **Xcode Setup**:
   Open `BorgVR.xcodeproj` and configure the signing team for the app targets you want to build.

3. **Build and Run**:
   Use the Xcode schemes for the desired platform:
   - `VisionApp` or `VisionApp Release`
   - `iOSApp` or `iOSApp Release`
   - `macOSApp` or `macOSApp Release`
   - `macOSServer` or `macOSServer Release`
   - `TerminalServerApp`
   - `TerminalConverterApp`

---

## Usage

BorgVR is designed for research and educational use in high-performance visualization projects. Once deployed, it provides an interactive UI for volume exploration and manipulation, with support for loading custom volumetric datasets. The user experience is adapted to each platform: spatial interaction on Apple Vision Pro, touch interaction on iPhone and iPad, and desktop interaction on macOS.

---

## Contributing

We welcome contributions from researchers and developers interested in high-performance volume rendering. Please see `CONTRIBUTING.md` for guidelines on how to contribute to BorgVR.

---

## License

BorgVR is released under the [MIT License](LICENSE).

---

## Contact

For questions or further information, please reach out to the Computergraphics and Visualization Group at the University of Duisburg-Essen. Detailed contact information is available on our [official website](https://www.cgvis.de/).

---

## Acknowledgments

This project builds on years of research and development in volume rendering and spatial computing. We are grateful to all researchers and contributors whose work has made BorgVR possible, especially those whose publications have provided a foundation for this project’s algorithms and optimizations. A special thanks to the Apple Vision Pro team for creating a hardware platform that enables next-generation visualization experiences in spatial computing, and to the broader Apple platform ecosystem that makes it possible to share rendering technology across visionOS, iOS/iPadOS, and macOS.

We would also like to acknowledge the funding and support from the University of Duisburg-Essen and the collaborators and contributors to the IEEE VIS and WSCG conferences, as well as the Supercomputing and EuroVis workshops.

## Additional Resources

### Documentation

Comprehensive documentation, including API references, usage examples, and a developer's guide, can be found in the `docs` folder. Start with `docs/Getting_Started.md` for an introduction to the system architecture and basic usage.

### Tutorials

Example datasets and hands-on tutorials are provided to help users get up and running quickly. Visit the `examples` folder in the repository for sample projects, including real-world volume data and visualization cases.

### Related Projects

If you're interested in similar work, check out the following related projects by the Computergraphics and Visualization Group:

- **Tuvok**: Large-scale volume rendering architecture
- **Trinity**: Data distribution and visualization system for GPUs
- **FAVR**: Accelerated volume rendering for VR environments

---

## Future Work

BorgVR is an active research project, and we aim to continually improve its performance and feature set. Future plans include:

- **Enhanced Data Streaming**: Improving out-of-core data handling for larger datasets in real-time.
- **Cross-Platform Support**: Further improving shared workflows across visionOS, iOS/iPadOS, and macOS.
- **User Interaction Enhancements**: Adding more immersive controls and interaction capabilities in the mixed-reality environment.
- **Optimized Memory Management**: Further optimizing memory allocation and management on GPU resources to improve rendering efficiency.

Your feedback and contributions are invaluable in shaping the future of BorgVR. Join us on this journey to advance high-fidelity, large-scale, interactive volume visualization in mixed reality.

---

Thank you for using and supporting BorgVR!

**The BorgVR Team**  
Computergraphics and Visualization Group  
University of Duisburg-Essen
