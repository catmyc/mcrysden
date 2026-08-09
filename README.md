# mcrysden

**mcrysden** is a native macOS crystal and molecule viewer — a from-scratch Swift/Metal rewrite of [XCrySDen](http://www.xcrysden.org/) 1.6.2, built for Apple Silicon and Intel Macs running macOS 14+ (Sonoma). No Xcode project: a plain SwiftPM executable.

It reads the structural formats XCrySDen handles — XSF/AXSF, XYZ, PDB, CIF, POSCAR/CONTCAR/VASP, Quantum Espresso PWscf input/output (all 17 `ibrav`), Gaussian Cube, BXSF, WIEN2k `.struct`, CRYSCAL, ORCA, and FHI-aims — plus QE band structures and (total/projected) DOS tables. Structures render interactively through Metal with 7 display modes, and everything also exports headlessly to PNG and raster-backed PDF/SVG/EPS/PS.

Beyond the XCrySDen feature set it adds a SwiftUI sidebar, structure editing and generation tools, symmetry analysis (vendored spglib), canonical k-paths for all 29 Bravais variants with QE/VASP/Wannier90/KPF import/export, coordination analysis, band/DOS analysis, volumetric isosurfaces and color planes, animation playback and export, and extensible scripting.

## Build & run

```bash
swift build              # debug build
swift run mcrysden            # empty viewer
swift run mcrysden file.xsf   # open a structure
swift run mcrysden file.xsf --export out.png   # headless render
swift test                # run all tests
zsh scripts/smoke.sh      # CI smoke test (release build + headless export)
```

Local install: `swift build -c release && cp .build/release/mcrysden /usr/local/bin/`

## Highlights

- 18 parser families with force-format CLI flags (`--xsf --xyz --pwi --pwo --cif --cube --bxsf --struct --crystal --orca --fhi --bands --dos --crystal-band --crystal-dos`, …) and a 200 MB input cap
- Metal rendering: ball-stick/space-fill/wireframe/polyhedral/2D modes, Blinn-Phong lighting, MSAA, depth cueing, AO and soft shadows, image/gradient/solid backgrounds, stereo and anaglyph
- Supercell expansion, slab generation, cluster cutting, defect workflows, lattice editing
- Crystal symmetry (space group, Wyckoff), canonical HPKOT k-paths, BZ overlay, structure summary, powder XRD
- Band/DOS analysis with linked plots, coordination analysis, measurements, atom table
- State persistence (`.mvis-state`) and project files (`.mvis-project`)
- Headless conversion (`--convert`, `--convert-all`) and animation export (GIF/APNG/MP4)

## Documentation

- `docs/ROADMAP.md` — authoritative feature-status document
- `CHANGELOG.md` — release history
- `AGENTS.md` — architecture and workflow notes for contributors

## License

Third-party components: vendored [spglib](https://github.com/spglib/spglib) 2.7.0 and SeekPath (see `SEEKPATH_LICENSE.txt`).
