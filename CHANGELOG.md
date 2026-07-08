# Changelog

All notable changes to mcrysden will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-07-08

### Added
- Quantum Espresso PWscf input parser: reads `.pwi` / `.in` / `.inp` files, including the `&SYSTEM` namelist (`ibrav`, `celldm`, `nat`, `ntyp`), `ATOMIC_SPECIES`, `ATOMIC_POSITIONS` (alat / bohr / angstrom / crystal), and `CELL_PARAMETERS`. Supports all 17 Bravais-lattice cases (`latgen`) and digit-suffixed species labels (`Fe1` → Fe).
- Force-parser CLI flags: `--xsf`, `--xyz`, `--pdb`, `--axsf`, `--pwi` override the extension-based dispatch, so a `.xsf` file renamed to `.xyz` hits the right parser.
- `Reset View` button (top of sidebar): reframes the camera — center on centroid, distance from bounding sphere, rotation cleared.
- Atom selection: click (no-drag) atoms to toggle selection; turns selected atoms bright yellow.
- Measurements: in Distance / Angle / Dihedral modes, picking the right number of atoms computes the quantity automatically. A cyan line connects the picked atoms; a docked bottom readout panel shows each selected atom's index, element symbol, Cartesian coordinates, and (when a unit cell is present) crystal fractional coordinates, plus the measured value.
- World-space lighting so shading stays fixed to the structure as you orbit.
- New structure examples under `Assets/`: BiFeO3, Si (diamond, zincblende), ZnS, GaAsH, fcc slabs, and QE inputs.

### Fixed
- Supercell now draws one unit-cell box per replica, centred on the whole atom set (atoms no longer strayed outside the boxes).
- Slab filtering: changing the slab distance no longer compounds on a previous filter; the atom set is always rebuilt from the full widened cell.
- Bond detection now uses XCrySDen's covalent-radii table verbatim (removes the old 1.3 fudge factor).
- Camera orbit now rotates around the camera's current up/right axes instead of world-fixed axes — horizontal drag orbits horizontally regardless of tilt.
- Vertical drag direction matches expectation (drag up tilts the view as expected).
- Headless `--export` no longer hangs: the export path now terminates the process via `NSApp.terminate(nil)` after a successful render.
- Headless input-file resolution now skips force-format flags, so `mcrysden --pwi file.in` works.
- Forced parse on non-matching content fails gracefully with a clear error.
- Atom-selection readout: fixed a crash (`String(format:)` with `%@` + Swift String on arm4) that aborted the process when the readout panel first rendered. The readout window is now bottom-docked with a macOS-style rounded panel and standard traffic-light buttons, and closing the main window terminates the program.

### Assets
- Added crystal/molecule example files to `Assets/` (BiFeO3, Si, ZnS, GaAsH, fcc-410, QE inputs).

## [1.0.0] — (initial release)

Native macOS crystal/molecule viewer — a from-scratch Swift/Metal reimagining of XCrySDen 1.6.2. Reads XSF, AXSF, XYZ, and PDB structures and renders crystals and molecules interactively via Metal, plus a headless PNG export mode.
