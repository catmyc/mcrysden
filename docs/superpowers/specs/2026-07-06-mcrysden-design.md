# mcrysden — design spec

**Date:** 2026-07-06
**Source model:** XCrySDen 1.6.2 (`/Users/mao/devs/xcrysden-1.6.2`)
**Platform:** macOS 14+ (Sonoma), Apple Silicon or Intel, Xcode 15+
**Scope:** v1 — core crystal/molecule viewer, native Metal, terminal-launched.

---

## 1. Goal & non-goals

**Goal.** A native macOS program that reads the same structure files XCrySDen reads (XSF, AXSF, XYZ, PDB) and renders crystals and molecules interactively — ball-stick, space-fill, wireframe, polyhedral, plus 2D projection modes — with supercell replication and slab/vacuum construction. Launched from the terminal; can also render a PNG headlessly from a saved state.

**Non-goals (deferred to v2+).** Isosurfaces / 3D scalar fields, Brillouin-zone / k-path / Fermi-surface tools, external-code converters (PWSCF, WIEN2k, Gaussian, ORCA, CRYSTAL, FHI), a scripting language, anaglyph/stereo, App-Store packaging, anything non-macOS.

---

## 2. Architecture

### 2.1 Process lifecycle — `NSApplication` (Option A)

`@main` → `NSApplicationDelegate` (`MolVisApp`). On `applicationDidFinishLaunching`:

- If argv contains `--export <path>`: build the scene, render once to an offscreen texture, write PNG, `exit(0)`. No window is ever created.
- Otherwise: build an `NSWindow` containing an `NSSplitView` — left sidebar is a SwiftUI `NSHostingController { SideBar() }`, right canvas is an `MTKView` (Metal) owned by `MainWindowController`.

This makes headless export a clean early-exit path rather than a hack around SwiftUI scene bootstrapping.

### 2.2 Module layout

```
mcrysden/
├── Package.swift
├── Sources/
│   ├── MolVisApp/        App, Renderer, Model, State, Export, Camera, Shaders.metal
│   ├── MolEnvParse/       C parser module (libMolEnvParse — XSF/AXSF/XYZ/PDB)
│   └── MolVisShaders/     (Shaders.metal — or kept inside MolVisApp)
├── Tests/                 unit + snapshot + UITests
├── scripts/               smoke.sh
└── docs/superpowers/specs/this-file.md
```

Module boundaries:

- `MolVisApp` owns the process, the window, the renderer, the scene model, state, export. It never calls the C parser directly — it goes through a thin Swift wrapper in the same module.
- `MolEnvParse` is C-only. Exposes `parse_xsf`, `parse_axsf`, `parse_xyz`, `parse_pdb`, each returning a heap-allocated `MolEnvScene*`. Swift copies the data into Swift value types, then calls `molenv_scene_free`. No shared ownership, no C pointers held across async boundaries.
- `Renderer` is format-agnostic: given a `Scene`, it draws. Same `encode(to:target:viewport:scene:)` drives both the on-screen MTKView path and the offscreen export path.

### 2.3 Tech stack

Swift 5.9, Metal 3, AppKit lifecycle, SwiftUI for the sidebar via `NSHostingController`, SPM for build, XCTest for tests.

---

## 3. Data flow

### 3.1 GUI mode

```
argv → MolVisApp.applicationDidFinishLaunching
  └── MainWindowController.windowDidLoad
        ├── Parse.readURL(fileURL) → Scene            [C → Swift snapshot]
        ├── stateURL? → StateStore.apply(to: &scene)
        └── Renderer.scene = scene  →  MTKView draw loop @ 60/120 Hz
```

User action (sidebar control) → `MainWindowController` mutates `Scene` (e.g. `scene.superCell = (2,1,1)`) → renderer redraws next frame.

### 3.2 Headless mode

```
argv → MolVisApp.applicationDidFinishLaunching
  ├── Parse.readURL(fileURL) → Scene
  ├── stateURL? → StateStore.apply(to: &scene)
  ├── PngExporter.export(scene:to:size:)
  │     ├── builds MTLDevice + owned MTLTexture (no MTKView)
  │     ├── runs one render pass through the SAME Renderer.encode(...)
  │     ├── blits → CGImage → CGImageDestination → PNG
  │     └── returns
  └── NSApp.terminate(self); exit(0)
```

The single constraint that makes both modes share code: `Renderer.encode` takes the target texture as a parameter and never assumes an `MTKView` exists.

---

## 4. C parser module (`MolEnvParse`)

### 4.1 Port, don't rewrite

XCrySDen's `C/readstrf.c` (XSF), `C/readXYZ.c` (XYZ), and PDB parser are mature. Port them; don't rewrite from scratch.

### 4.2 Public C header

```c
// molenv_parse.h
typedef struct { float coord[3]; int atomic_number; char label[8]; } MolEnvAtom;
typedef struct { int i, j; } MolEnvBond;
typedef struct {
    int natoms; MolEnvAtom *atoms;
    int nbonds;  MolEnvBond  *bonds;
    float cell[3][3];   // row-major lattice vectors; all-zero for molecules
    int is_crystal;     // 1 if cell is set
    int periodic_dim;   // 0..3
    char title[256];
} MolEnvScene;

MolEnvScene* parse_xsf  (const char *path);
MolEnvScene* parse_axsf (const char *path, int frame_index);
MolEnvScene* parse_xyz  (const char *path);
MolEnvScene* parse_pdb  (const char *path);
void molenv_scene_free(MolEnvScene*);
const char* molenv_last_error(void);   // thread-local "path:line: reason"
```

### 4.3 Memory discipline

C allocates with `malloc` (drop XCrySDen's `xcMalloc`). Swift receives the pointer, immediately copies into Swift value types, then calls `molenv_scene_free`. No C pointer held across an async boundary.

### 4.4 What's stripped

All `XC_*` Tcl command registration. All OpenGL calls. `ReadXSF`'s `BEGIN_DATAGRID`/`END_DATAGRID` handling (deferred — v2 isosurfaces). `MakeBonds()` is ported into `Parse/bond.c` (~150 lines, format-independent, distance heuristic = covalent radii sum × 1.3).

---

## 5. Scene model

`Scene` is a Swift `struct` (value type — cheap to copy, easy to snapshot for state save).

```swift
struct Scene {
    var atoms: [Atom]
    var bonds: [Bond]
    var cell: Cell?                   // nil for molecules
    var title: String
    var displayMode: DisplayMode      // .ballStick, .spaceFill, .wireFrame, .polyhedral
    var superCell: SuperCell          // (n1,n2,n3), default (1,1,1)
    var slab: Slab?                   // two planes; nil = full cell
    var background: CGColor
    var showCellFrame: Bool
    var showAxes: Bool
    var atomScale: Float              // 0..1 for ball-stick
    var bondRadius: Float
}
```

### 5.1 Display modes

| Mode | Atom geom | Bond geom | Notes |
|---|---|---|---|
| `.ballStick` | instanced sphere, r = covalent × atomScale | instanced cylinder | default |
| `.spaceFill` | instanced sphere, r = van der Waals | none | CPK |
| `.wireFrame` | none (or tiny dots) | thin cylinder | |
| `.polyhedral` | none | none; draw polyhedron faces | port XCrySDen's `voronoi.c` |

All four use **instancing** — one `drawPrimitives(instanceCount:)` per geometry type. Sphere and cylinder are pre-tessellated once into static vertex buffers at init; per-instance buffers carry position/radius/color.

### 5.2 Supercell

`Scene.widenSuperCell(_:)` returns a new `Scene` with atoms replicated across `n1×n2×n3` cells and bonds recomputed across periodic boundaries. Called only on user input, not per-frame. Hard atom-count cap (default 500k) — requests beyond it are refused with a non-fatal alert, scene unchanged.

### 5.3 Slab

`Scene.slab` is two `Plane` values (h,k,l, distance). Fragments outside are discarded in the vertex shader via clip-space distance (cheap, per-vertex).

### 5.4 2D modes

A separate `Renderer2D` uses the same `Scene` but an orthographic camera looking down the projection axis, drawing lines/points. `MainWindowController` swaps `Renderer` ↔ `Renderer2D` when the user picks a 2D display mode. Shares sidebar and state model with the 3D path.

---

## 6. Camera & interaction

`MolVisCanvasView: NSView` wraps the `MTKView` and handles `NSResponder` events directly (not through SwiftUI):

- **mouseDragged** (no modifier) → rotate (arcball around structure centroid).
- **mouseDragged + option** → pan (screen-space translate).
- **scrollWheel** / **magnify** → zoom (exponential dolly).
- **rightMouseDragged** → slab distance (when slab active).

```swift
struct Camera {
    var center: SIMD3<Float>
    var distance: Float
    var rotation: simd_quatf
    var projectionPerspective: Bool
}
```

Arcball ported from XCrySDen's `C/cryTransform.c` / `C/3D.c` (`GetRotXYMat`). `projectionMatrix()` returns perspective or ortho based on `projectionPerspective` (forced ortho for 2D modes).

The camera is **view state, not scene state** — it is NOT serialized in the state file. Reopening a file resets the view.

Per-frame the Renderer builds `viewMatrix × projectionMatrix` into a uniform buffer at index 0; atoms draw with `modelMatrix(instance) × view × proj`.

---

## 7. Colors, background & light

### 7.1 Element table

Static `ElementTable` (Swift) keyed by atomic number, sourced from XCrySDen's `Tcl/Xcrysden_resources` / `propC95.tcl`: 118-element RGB table, covalent radii, van der Waals radii, symbols. Bundled as a compiled array literal in `ElementTable.swift` — no runtime file load.

### 7.2 Color schemes

"Atomic" scheme: instance color = `ElementTable.colors[Z]`. XCrySDen's other schemes (slab-fractional, distance, monochrome) are computed **per-instance in Swift** before each frame (they reference scene geometry), not in the shader.

### 7.3 Background

Sidebar picker → `scene.background: CGColor` → `MTLClearColor` on the render pass. Solid color only in v1.

### 7.4 Lighting

Single directional light + ambient in the fragment shader. No IBL, no HDR, no user-repositionable lights in v1.

```cpp
// Shaders.metal — fragment
float3 N = normalize(in.normal);
float3 L = normalize(light_dir);
float diff = max(dot(N, L), 0.0);
float3 ambient = materialColor * 0.35;
float3 diffuse = materialColor * diff * 0.65;
out.color = float4(ambient + diffuse, 1.0);
```

Light direction fixed in view-space (top-left).

---

## 8. State file (`.molvis-state`)

JSON, human-readable and diffable.

```json
{
  "version": 1,
  "source": "/path/to/input.xsf",
  "displayMode": "ballStick",
  "supercell": [2, 1, 1],
  "slab": {
    "planeA": {"h": 0, "k": 1, "l": 0, "distance": 5.0},
    "planeB": {"h": 0, "k": -1, "l": 0, "distance": 12.0}
  },
  "background": "#101014",
  "showCellFrame": true,
  "showAxes": true,
  "atomScale": 0.35,
  "bondRadius": 0.10,
  "camera": {
    "center": [1.2, 0.5, -0.3],
    "distance": 18.0,
    "rotation": [0.12, 0.45, -0.21, 0.85],
    "perspective": true
  }
}
```

- `source` is an absolute path (no security-scoped bookmark in v1).
- `camera` is optional — if absent, the app computes a default framing (centroid + bounding-sphere fit).
- `displayMode` unknown → `.ballStick` fallback (forward-compatible).
- `version > 1` → non-fatal alert, abort load, leave current scene.

`StateStore` uses `JSONEncoder`/`JSONDecoder` with `Codable` on `Scene` + `Camera`. The C parser is not involved.

---

## 9. Error handling

Two principles: **never crash on malformed input; never swallow an error silently.**

- **Parser errors.** `parse_*` returns `nil` on failure, writes reason to thread-local `molenv_last_error`. Swift wraps as `ParseError { path, line, reason }` with `localizedDescription == "file.xsf:142: unexpected token <FOOBAR>"`. I/O errors caught on Swift side before calling C. GUI shows non-fatal alert; headless prints to stderr and `exit(1)`.
- **Renderer errors.** Shader compile/link failures caught at Renderer construction (once at launch), surfaced as fatal alert. OOM during supercell expansion bounded by the 500k-atom cap — non-fatal refusal.
- **State load errors.** Missing keys → defaults. Unknown `displayMode` → `.ballStick` + console log. `version > 1` → non-fatal alert, abort load. Invalid numbers → clamped + console warning.

In all cases: no crash, no on-disk corruption, no scene deletion. Worst case: user dismisses an alert and proceeds with reasonable defaults.

---

## 10. Testing

Three layers, no mocking framework.

- **Unit tests (XCTest).** `ParseTests` (happy + pathological for each format, assert `ParseError.line`); `SceneTests` (supercell atom count, periodic bonds, slab retained-atom set); `StateStoreTests` (Codable round-trip bit-exact; missing-key / unknown-displayMode / too-high-version all default cleanly); `ElementTableTests` (`symbols[1] == "He"`, `radiiVDW.count == 118`).
- **Snapshot tests.** Fixed `Scene` + `Camera` → offscreen render → MurmurHash3 of downsampled (256²) pixel bytes. Hash committed to test bundle; CI re-renders and compares; mismatch fails the build and attaches the new PNG to the test log for visual diff + hash bump.
- **UI tests + smoke.** Small SwiftUI UI test drives the sidebar (pick SpaceFill, assert `displayMode` changed). `scripts/smoke.sh` builds headless, runs `mcrysden ../examples/Si.xsf state.mvis --export out.png`, asserts output exists and is non-trivial size.
- **CI.** GitHub Actions on `macos-14` (Apple Silicon) — unit + snapshot + smoke. No Linux leg.

---

## 11. Build, launch & workflow

- **Build.** SPM — `swift build`. C parser is a `CLibrary` target inside the package. macOS 14+ deployment target, Xcode 15+.
- **Launch.**
  ```
  swift run mcrysden                                  # empty viewer
  swift run mcrysden file.xsf                          # open structure
  swift run mcrysden file.xsf state.mvis               # apply saved state
  swift run mcrysden file.xsf state.mvis --export fig.png   # headless
  swift run mcrysden --help
  ```
  Element table is compiled in via `Bundle.module`, so it works regardless of cwd.
- **Install.** `swift build -c release && cp .build/release/mcrysden /usr/local/bin/` → call `mcrysden file.xsf` from anywhere.
- **Repo.** One package, one executable product, one test target. Flat and discoverable.

---

## 12. v1 delivery order (suggested)

Each step is independently demoable in the GUI before moving on. Note the **design invariant**: `Renderer.encode(to commandBuffer:, target: MTLTexture, viewport:, scene:)` must take the target texture as a parameter *from step 2* so that headless export (step 10) is the same code path, not a later retrofit.

1. SPM package skeleton + `MolEnvParse` C target + one trivial test that links.
2. `parse_xyz` + `parse_pdb` (simplest) → `Scene` model → `Renderer` draws one instanced sphere via `encode(to:target:viewport:scene:)` (target = the MTKView's current drawable) → `MTKView` shows it. This step proves the C→Swift bridge works end-to-end.
3. `parse_xsf` + `parse_axsf` → unit-cell frame + axes + bonds.
4. Display-mode switching (ballStick → spaceFill → wireFrame → polyhedral).
5. Camera: arcball rotate + dolly zoom + pan.
6. Sidebar (SwiftUI): display-mode picker, atom scale, bond radius, background, cell/axes toggles.
7. Supercell + slab.
8. 2D renderer swap.
9. `StateStore` (save/load `.molvis-state`).
10. `PngExporter` — reuse `Renderer.encode` with an **owned** `MTLTexture` target (no MTKView), blit → `CGImage` → PNG — plus the `--export` CLI path in `MolVisApp` and `scripts/smoke.sh`.
11. Snapshot tests + CI.
12. Element-table polish, color schemes, polyhedral via ported `voronoi.c`.
