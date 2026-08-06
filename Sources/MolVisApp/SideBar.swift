import SwiftUI
import simd

struct SideBar: View {
    @ObservedObject var state: SideBarState

    // Light-direction steppers work in whole degrees; the slider reads/writes
    // the same Lighting.azimuth/elevation the shader consumes.
    private let degRange: ClosedRange<Float> = 0...360

    // Selected-node coordinate editor state. Selection is view-local; the
    // editor text fields are local so a partial edit (e.g. "0.") is never
    // committed as an invalid float. Edits are committed through the
    // SideBarState `updateKPathPoint(at:fractionalCoordinate:label:)` mutation.
    @State private var selectedKPointIndex: Int? = nil
    @State private var editKx: String = ""
    @State private var editKy: String = ""
    @State private var editKz: String = ""
    @State private var editLabel: String = ""
    // Local preset picker state. The preset is an action (not document state),
    // so this is view-local and never persisted or synced.
    @State private var selectedPreset: PublicationPreset = .default

    // Tracks whether any per-node editor field holds keyboard focus. Used to commit
    // the draft once on focus loss (instead of every keystroke) and to keep an
    // external route mutation from clobbering a draft in progress while focused.
    @FocusState private var editorFocused: Bool

    // Collapsed-state for each major sidebar section, persisted in UserDefaults
    // under CollapsibleSidebarSection.<case>.rawValue. A missing key defaults to
    // expanded (true); toggling writes the new value straight through.
    @AppStorage(CollapsibleSidebarSection.display.rawValue) private var displayExpanded = true
    @AppStorage(CollapsibleSidebarSection.appearance.rawValue) private var appearanceExpanded = true
    @AppStorage(CollapsibleSidebarSection.structureSummary.rawValue) private var structureSummaryExpanded = true
    @AppStorage(CollapsibleSidebarSection.colorPlane.rawValue) private var colorPlaneExpanded = true
    @AppStorage(CollapsibleSidebarSection.forces.rawValue) private var forcesExpanded = true
    @AppStorage(CollapsibleSidebarSection.kPath.rawValue) private var kPathExpanded = true
    @AppStorage(CollapsibleSidebarSection.supercell.rawValue) private var supercellExpanded = true
    @AppStorage(CollapsibleSidebarSection.slab.rawValue) private var slabExpanded = true
    @AppStorage(CollapsibleSidebarSection.structureTools.rawValue) private var structureToolsExpanded = true
    @AppStorage(CollapsibleSidebarSection.animation.rawValue) private var animationExpanded = true
    @AppStorage(CollapsibleSidebarSection.isosurface.rawValue) private var isosurfaceExpanded = true
    @AppStorage(CollapsibleSidebarSection.stereo.rawValue) private var stereoExpanded = true
    @AppStorage(CollapsibleSidebarSection.volumeSlices.rawValue) private var volumeSlicesExpanded = true
    @AppStorage(CollapsibleSidebarSection.fermiSurface.rawValue) private var fermiSurfaceExpanded = true
    @AppStorage(CollapsibleSidebarSection.symmetry.rawValue) private var symmetryExpanded = true
    @AppStorage(CollapsibleSidebarSection.coordination.rawValue) private var coordinationExpanded = true
    @AppStorage(CollapsibleSidebarSection.electronicStructure.rawValue) private var electronicStructureExpanded = true
    @AppStorage(CollapsibleSidebarSection.clipping.rawValue) private var clippingExpanded = true
    @AppStorage(CollapsibleSidebarSection.region.rawValue) private var regionExpanded = true
    @AppStorage(CollapsibleSidebarSection.xrd.rawValue) private var xrdExpanded = true

    var body: some View {
        Form {
            formContent
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 200)
        // Reload the editor fields when the selected index changes. Without this,
        // selecting a different node would leave stale text in the bound fields.
        .onChange(of: selectedKPointIndex) { _, _ in loadEditorFields() }
        .onChange(of: state.routeGeneration) { _, _ in
            // Whole-route replacement (Default/undo/clear/reset): drop the local
            // selection and cancel any draft, even if the selected index is still
            // valid — the route content changed under us.
            selectedKPointIndex = nil
            state.onSelectKPathNode?(nil)
            editKx = ""; editKy = ""; editKz = ""; editLabel = ""
        }
        .onChange(of: state.viewResetGeneration) { _, _ in
            // View reset: clear the local selection/editor to match the renderer
            // highlight the controller just dropped. The route is unchanged.
            selectedKPointIndex = nil
            state.onSelectKPathNode?(nil)
            editKx = ""; editKy = ""; editKz = ""; editLabel = ""
        }
        .onChange(of: state.kPathPoints) { _, _ in
            if let i = selectedKPointIndex, !state.kPathPoints.indices.contains(i) {
                selectedKPointIndex = nil
                state.onSelectKPathNode?(nil)
            }
            if !editorFocused {
                loadEditorFields()
            }
        }
        // Commit the draft once when every editor field loses focus (the user tabs
        // away or clicks elsewhere). No keystroke commits on its own.
        .onChange(of: editorFocused) { _, focused in
            if !focused { commitEdits() }
        }
    }

    // The full Form body is extracted to keep each builder below the type-checker's
    // complexity threshold.
    @ViewBuilder
    private var formContent: some View {
        Section {
            Button("Reset View") { state.onResetView?() }
                .buttonStyle(.borderedProminent)
            HStack(spacing: 4) {
                Text("Standard")
                    .font(.caption)
                    .foregroundColor(.secondary)
                standardCrystalViewButton(StandardCrystalView.view100.label, .view100)
                standardCrystalViewButton(StandardCrystalView.view110.label, .view110)
                standardCrystalViewButton(StandardCrystalView.view111.label, .view111)
            }
            cameraBookmarkContent
        }
            CollapsibleSection(title: "Display", isExpanded: $displayExpanded) {
                Picker("Mode", selection: $state.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Show Scale", isOn: $state.showScaleIndicator)
                Toggle("Bond Distances", isOn: $state.showBondDistances)
            }
            // --- Structure Summary ----------------------------------------------
            // Compact readout of the loaded structure. Hidden entirely for an
            // empty viewer (no atoms); crystal fields appear only for crystals.
            if let summary = state.structureSummary {
                CollapsibleSection(title: "Structure Summary", isExpanded: $structureSummaryExpanded) {
                    structureSummaryGrid(summary)
                    Button("Atom Table…") { state.onShowAtomTable?() }
                        .buttonStyle(.bordered)
                    Divider()
                    Button("Compare…") { state.onShowComparison?() }
                        .buttonStyle(.bordered)
                    if !state.comparisonStatusText.isEmpty {
                        Text(state.comparisonStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Displacement arrows", isOn: $state.showComparisonArrows)
                            .disabled(state.comparisonCalculating)
                        HStack {
                            Button("Export CSV") { state.onExportComparisonCSV?() }
                                .disabled(state.comparisonCalculating)
                            Button("Clear") { state.onClearComparison?() }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
            // --- Appearance: material + background ---------------------------------
            CollapsibleSection(title: "Appearance", isExpanded: $appearanceExpanded) {
                Slider(value: $state.atomScale, in: 0.05...1.0) { Text("Atom Scale: \(state.atomScale, specifier: "%.2f")") }
                Slider(value: $state.bondRadius, in: 0.02...0.4) { Text("Bond Radius: \(state.bondRadius, specifier: "%.2f")") }
                Toggle("Cell Frame", isOn: $state.showCellFrame)
                Toggle("Axes", isOn: $state.showAxes)
                Toggle("Element Labels", isOn: $state.showLabels)
                // Projection: orthographic removes perspective foreshortening and is
                // the conventional choice for crystal/molecule illustrations.
                Toggle("Orthographic", isOn: $state.orthographic)
                // Hide the atomic structure (atoms/bonds/polyhedra) so the user can
                // focus on the cell frame, axes, or Brillouin-zone overlay.
                Toggle("Show Structure", isOn: $state.showStructure)
                // Brillouin-zone wireframe (crystal only). Hidden for molecules,
                // which have no reciprocal lattice.
                Toggle("Brillouin Zone", isOn: $state.showBrillouinZone)

                // Background: solid vs gradient vs image. The hex fields only
                // appear for solid/gradient; the image field only for .image.
                Picker("Background", selection: $state.backgroundType) {
                    Text("Solid").tag(BackgroundType.solid)
                    Text("Gradient").tag(BackgroundType.gradient_top)
                    Text("Image").tag(BackgroundType.image)
                }
                .pickerStyle(.segmented)
                if state.backgroundType == .image {
                    HStack {
                        Text("File")
                        Button("Choose…") { state.onPickBackgroundImage?() }
                        Text(((state.backgroundImagePath as NSString?)?.lastPathComponent) ?? "(none)")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack {
                        Text("Top"); TextField("hex", text: $state.backgroundHex).frame(width: 90)
                    }
                    if state.backgroundType == .gradient_top {
                        HStack {
                            Text("Bottom"); TextField("hex", text: $state.backgroundBottomHex).frame(width: 90)
                        }
                    }
                }

                // Phong lighting — intensity terms are unitless 0..1 multipliers and
                // shininess is a power-of-two exponent; the light direction is a
                // spherical azimuth/elevation the renderer converts to a vector.
                Text("Lighting").font(.subheadline).bold()
                Slider(value: $state.lighting.ambient, in: 0...1) { Text("Ambient: \(state.lighting.ambient, specifier: "%.2f")") }
                Slider(value: $state.lighting.diffuse, in: 0...1) { Text("Diffuse: \(state.lighting.diffuse, specifier: "%.2f")") }
                Slider(value: $state.lighting.specular, in: 0...1) { Text("Specular: \(state.lighting.specular, specifier: "%.2f")") }
                Slider(value: $state.lighting.shininess, in: 1...128) { Text("Shininess: \(Int(state.lighting.shininess))") }
                Slider(value: $state.lighting.azimuth, in: degRange) { Text("Light Azimuth: \(Int(state.lighting.azimuth))°") }
                Slider(value: $state.lighting.elevation, in: -90...90) { Text("Light Elevation: \(Int(state.lighting.elevation))°") }
                // MSAA anti-aliasing. The picker sets the render-target sample
                // count directly (Off=1, 2x=2, 4x=4, 8x=8 samples).
                Picker("MSAA", selection: $state.msaaSampleCount) {
                    ForEach(MSAASampleCount.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                // Rendering-quality controls: line width, transparency, depth cueing,
                // and AO/shadow approximations.
                Text("Quality").font(.subheadline).bold()
                Slider(value: $state.opacity, in: 0.05...1.0) { Text("Opacity: \(state.opacity, specifier: "%.2f")") }
                Slider(value: $state.lineWidth, in: 1.0...6.0) { Text("Line Width: \(state.lineWidth, specifier: "%.1f") px") }
                Slider(value: $state.depthCueingStrength, in: 0...1) { Text("Depth Cueing: \(state.depthCueingStrength, specifier: "%.2f")") }
                Toggle("Ambient Occlusion", isOn: Binding(
                    get: { state.aoStrength > 0 },
                    set: { state.aoStrength = $0 ? 0.5 : 0.0 }))
                if state.aoStrength > 0 {
                    Slider(value: $state.aoStrength, in: 0.05...1) { Text("AO Strength: \(state.aoStrength, specifier: "%.2f")") }
                    Picker("AO Quality", selection: $state.aoQuality) {
                        ForEach(0...3, id: \.self) { Text(aoQualityLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Soft Shadows", isOn: Binding(
                    get: { state.shadowStrength > 0 },
                    set: { state.shadowStrength = $0 ? 0.5 : 0.0 }))
                if state.shadowStrength > 0 {
                    Slider(value: $state.shadowStrength, in: 0.05...1) { Text("Shadow Strength: \(state.shadowStrength, specifier: "%.2f")") }
                    Picker("Shadow Quality", selection: $state.shadowQuality) {
                        ForEach(0...3, id: \.self) { Text(shadowQualityLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                // Preset is an action (not document state): selecting one
                // applies its quality settings to the state fields.
                Picker("Preset", selection: $selectedPreset) {
                    ForEach(PublicationPreset.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedPreset) { _, newValue in
                    state.applyPreset(newValue)
                }
            }
            // --- Stereo / anaglyph -------------------------------------------
            CollapsibleSection(title: "Stereo", isExpanded: $stereoExpanded) {
                Picker("Mode", selection: $state.anaglyphMode) {
                    ForEach([AnaglyphMode.off, .redCyan, .greenMagenta], id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }
            // --- Isosurface (volumetric scalar field) ---------------------------
            // Shown only when the loaded file carried a DATAGRID/.cube-style 3D
            // scalar grid. The slider sweeps the iso level over the field's value
            // range; the surface is drawn as a depth-tested lit shell.
            if state.hasScalarField {
                CollapsibleSection(title: "Isosurface", isExpanded: $isosurfaceExpanded) {
                    Toggle("Show Surface", isOn: $state.showIsoSurface)
                    if state.orbitalCount > 1 {
                        Stepper("Orbital \(state.currentOrbital + 1) of \(state.orbitalCount)",
                                value: $state.currentOrbital,
                                in: 0...(state.orbitalCount - 1))
                    }
                    // The primary iso level slider is always visible: it seeds new
                    // levels AND drives the legacy ±pair when the spec list is empty.
                    Slider(value: $state.isoLevel, in: state.isoRange) {
                        Text("Iso level: \(state.isoLevel, specifier: "%.3f")")
                    }
                    // When the spec list is non-empty, render exactly the enabled
                    // specs: one row each with a color swatch, enabled toggle, a
                    // per-level slider, and a delete button.
                    ForEach(Array(state.isoSurfaces.enumerated()), id: \.offset) { index, spec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                ColorPicker("",
                                            selection: Binding(
                                                get: { Color(hex: spec.colorHex) ?? .white },
                                                set: { newColor in
                                                    var c = state.isoSurfaces
                                                    c[index].colorHex = newColor.hexString
                                                    state.isoSurfaces = c
                                                }),
                                            supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 44, height: 20)
                                Toggle("On", isOn: Binding(
                                    get: { state.isoSurfaces[index].enabled },
                                    set: { var c = state.isoSurfaces; c[index].enabled = $0; state.isoSurfaces = c }))
                                    .labelsHidden()
                                Spacer()
                                Button(role: .destructive) {
                                    state.removeIsoSurfaceSpec(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this iso level")
                            }
                            Slider(value: Binding(
                                get: { state.isoSurfaces[index].level },
                                set: { var c = state.isoSurfaces; c[index].level = $0; state.isoSurfaces = c }),
                                in: state.isoRange) {
                                Text("Level \(state.isoSurfaces[index].level, specifier: "%.3f")")
                            }
                        }
                    }
                    HStack {
                        Button("+ Add level") {
                            state.addIsoSurfaceSpec()
                        }
                        .disabled(state.isoSurfaces.count >= 8)
                        Spacer()
                        Button("Reset to ± pair") {
                            state.resetIsoSurfaces()
                        }
                        .disabled(state.isoSurfaces.isEmpty)
                    }
                }
            }
            // --- Fermi surface (BXSF) ----------------------------------------
            // Shown only when the loaded file carried a Fermi-surface grid. Each
            // band is surfaced at the Fermi energy; the toggle hides/shows the
            // whole multi-band cage independently of the scalar isosurface.
            if state.hasFermiSurface {
                CollapsibleSection(title: "Fermi Surface", isExpanded: $fermiSurfaceExpanded) {
                    Toggle("Show Fermi Surface", isOn: $state.showFermiSurface)
                }
            }
            // --- Color plane (2D scalar grid) --------------------------------
            // Shown only when the loaded file carried a DATAGRID_2D block. The
            // colormap + contour view swaps in for the 3D canvas while toggled on.
            if state.hasGrid2D {
                CollapsibleSection(title: "Color Plane", isExpanded: $colorPlaneExpanded) {
                    Toggle("Show Color Plane", isOn: $state.showColorPlane)
                    Picker("Colormap", selection: $state.colorPlaneColormap) {
                        ForEach(Colormap.allCases, id: \.self) { cm in
                            Text(cm.displayName).tag(cm)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Contours", isOn: $state.colorPlaneContourEnabled)
                    Stepper("Contour count \(state.colorPlaneContourCount)",
                            value: $state.colorPlaneContourCount,
                            in: 2...20)
                        .disabled(!state.colorPlaneContourEnabled)
                }
            }
            // --- Volume Slices (3D scalar field on fractional planes) --------
            // Shown only when the loaded file carried a 3D scalar grid AND is a
            // crystal (fractional plane needs a cell). Each slice samples the field
            // on a fractional plane and draws it as a textured quad in the 3D scene.
            if state.hasScalarField && state.isCrystal {
                CollapsibleSection(title: "Volume Slices", isExpanded: $volumeSlicesExpanded) {
                    ForEach(Array(state.volumeSlices.enumerated()), id: \.offset) { index, slice in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Toggle("On", isOn: Binding(
                                    get: { state.volumeSlices[index].enabled },
                                    set: { var c = state.volumeSlices; c[index].enabled = $0; state.volumeSlices = c }))
                                    .labelsHidden()
                                Spacer()
                                Button(role: .destructive) {
                                    state.removeVolumeSlice(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this slice")
                            }
                            Stepper("h = \(state.volumeSlices[index].h)", value: Binding(
                                get: { state.volumeSlices[index].h },
                                set: { var c = state.volumeSlices; c[index].h = $0; state.volumeSlices = c }),
                                in: -8...8)
                            Stepper("k = \(state.volumeSlices[index].k)", value: Binding(
                                get: { state.volumeSlices[index].k },
                                set: { var c = state.volumeSlices; c[index].k = $0; state.volumeSlices = c }),
                                in: -8...8)
                            Stepper("l = \(state.volumeSlices[index].l)", value: Binding(
                                get: { state.volumeSlices[index].l },
                                set: { var c = state.volumeSlices; c[index].l = $0; state.volumeSlices = c }),
                                in: -8...8)
                            Slider(value: Binding(
                                get: { state.volumeSlices[index].distance },
                                set: { var c = state.volumeSlices; c[index].distance = $0; state.volumeSlices = c }),
                                in: -2...2, step: 0.01) {
                                Text("Distance: \(state.volumeSlices[index].distance, specifier: "%.2f")")
                            }
                        }
                    }
                    Button("+ Add slice") {
                        state.addVolumeSlice()
                    }
                    .disabled(state.volumeSlices.count >= 3)
                }
            }
            // --- Clipping plane (crystal only, display-only) -------------------
            // A display-only plane that culls structure and/or isosurfaces behind
            // it. Never mutates scene atoms. Fractional convention matches Slab
            // (keep h*x+k*y+l*z >= distance). Only meaningful with a unit cell.
            if state.isCrystal {
                CollapsibleSection(title: "Clipping", isExpanded: $clippingExpanded) {
                    clippingContent
                }
            }
            // --- Region Integration (view-state only, NOT persisted) -----------
            // Gated on a scalar field. Bounded uniform-lattice sampling over a
            // box/sphere region; synchronous recompute on every slider change.
            if state.hasScalarField {
                CollapsibleSection(title: "Region Integration", isExpanded: $regionExpanded) {
                    regionContent
                }
            }
            // --- Forces (QE output): per-atom force arrows + energy readout. ---
            // Shown only when the loaded file carried a parsed `Forces acting on
            // atoms` block. The arrows are force vectors drawn from each atom.
            if state.hasForceSet {
                CollapsibleSection(title: "Forces", isExpanded: $forcesExpanded) {
                    forcesContent
                }
            }
            // --- k-path (crystal only): Brillouin-zone overlay + band path. -----
            // The scene exposes cell + base atoms; the controller builds the
            // default high-symmetry path and writes the chosen export via a save
            // panel. Shown only for crystals (a cell with base atoms present).
            if state.isCrystal {
                CollapsibleSection(title: "Symmetry", isExpanded: $symmetryExpanded) {
                    SymmetrySection(state: state)
                }
                CollapsibleSection(title: "K-Path", isExpanded: $kPathExpanded) {
                    kPathContent
                }
                CollapsibleSection(title: "Powder XRD", isExpanded: $xrdExpanded) {
                    xrdContent
                }
            }
            CollapsibleSection(title: "Supercell", isExpanded: $supercellExpanded) {
                Stepper("n1 = \(state.n1)", value: $state.n1, in: 1...6)
                Stepper("n2 = \(state.n2)", value: $state.n2, in: 1...6)
                Stepper("n3 = \(state.n3)", value: $state.n3, in: 1...6)
            }
            // --- Slab: enable + two Miller planes (h/k/l + distance each) ----------
            CollapsibleSection(title: "Slab", isExpanded: $slabExpanded) {
                Toggle("Enable", isOn: $state.slabEnabled)
                if state.slabEnabled {
                    Text("Plane A (h k l)").font(.subheadline).bold()
                    Stepper("h = \(state.slabA_h)", value: $state.slabA_h, in: -8...8)
                    Stepper("k = \(state.slabA_k)", value: $state.slabA_k, in: -8...8)
                    Stepper("l = \(state.slabA_l)", value: $state.slabA_l, in: -8...8)
                    Slider(value: $state.slabA_dist, in: -20...20) { Text("Slab A dist: \(state.slabA_dist, specifier: "%.1f")") }
                    Text("Plane B (h k l)").font(.subheadline).bold()
                    Stepper("h = \(state.slabB_h)", value: $state.slabB_h, in: -8...8)
                    Stepper("k = \(state.slabB_k)", value: $state.slabB_k, in: -8...8)
                    Stepper("l = \(state.slabB_l)", value: $state.slabB_l, in: -8...8)
                    Slider(value: $state.slabB_dist, in: -20...20) { Text("Slab B dist: \(state.slabB_dist, specifier: "%.1f")") }
                }
            }
            // --- Structure tools: basis transform, deformation, cluster, surface ---
            // Runtime-only (not persisted). The primitive/conventional transforms,
            // elastic deformation, cluster cut, and Miller-index surface builder.
            if state.structureSummary?.atomCount ?? 0 > 0 {
                CollapsibleSection(title: "Structure Tools", isExpanded: $structureToolsExpanded) {
                    structureToolsContent
                }
            }
            // --- Coordination: opt-in covalent-radius neighbor analysis -----------
            // The derived data is intentionally not part of Scene persistence. The
            // section is available only when the displayed structure has atoms.
            if state.structureSummary?.atomCount ?? 0 > 0 {
                CollapsibleSection(title: "Coordination", isExpanded: $coordinationExpanded) {
                    Toggle("Enable", isOn: $state.coordinationEnabled)
                    Slider(value: $state.coordinationRadiusScale,
                           in: 0.50...2.00, step: 0.05) {
                        Text("Covalent-radius scale: \(state.coordinationRadiusScale, specifier: "%.2f")")
                    }
                    Text(state.coordinationStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !state.coordinationSummaryText.isEmpty {
                        Text(state.coordinationSummaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Toggle("Color by coordination", isOn: $state.showCoordinationColors)
                        .disabled(!state.coordinationEnabled || !state.coordinationAnalysisAvailable)
                    if state.coordinationAnalysisAvailable {
                        Divider()
                        Button("Neighbor Table…") { state.onShowNeighborTable?() }
                            .buttonStyle(.bordered)
                        distributionContent
                        if !state.polyhedronSummaryText.isEmpty {
                            Divider()
                            Text(state.polyhedronSummaryText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Button("Polyhedron Metrics…") { state.onShowPolyhedronTable?() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            // --- Electronic-structure graph interaction -----------------------------
            // Available when the loaded scene carries band or DOS data. Lets the
            // user clip the energy window, shift the Fermi reference, and read the
            // cursor energy / band gap. Gated on electronicStructureEnabled.
            if state.electronicStructureEnabled {
                CollapsibleSection(title: "Electronic Structure", isExpanded: $electronicStructureExpanded) {
                    Toggle("Energy window", isOn: $state.energyWindowEnabled)
                    if state.energyWindowEnabled {
                        HStack {
                            Text("Min")
                            TextField("Min", value: $state.energyWindowMin, format: .number)
                                .textFieldStyle(.roundedBorder)
                            Text("Max")
                            TextField("Max", value: $state.energyWindowMax, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Slider(value: $state.fermiShift, in: -5...5, step: 0.1) {
                        Text("Fermi shift: \(state.fermiShift, specifier: "%.1f") eV")
                    }
                    if !state.electronicStructureCursorText.isEmpty {
                        Text(state.electronicStructureCursorText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let report = state.electronicAnalysisReport {
                        Divider()
                        Text(report.summaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Export Text") { state.onExportElectronicAnalysisText?(report) }
                            Button("Export CSV") { state.onExportElectronicAnalysisCSV?(report) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
            // --- AXSF animation playback -------------------------------------------
            // Only shown for multi-frame AXSF files (frameCount > 1); the controls
            // reload the scene frame-by-frame through Parser.load(frameIndex:).
            if state.frameCount > 1 {
                CollapsibleSection(title: "Animation", isExpanded: $animationExpanded) {
                    HStack {
                        Button("◀ Prev") { state.frameIndex = max(0, state.frameIndex - 1) }
                        Button(state.isPlaying ? "⏸ Pause" : "▶ Play") { state.isPlaying.toggle() }
                        Button("Next ▶") { state.frameIndex = min(state.frameCount - 1, state.frameIndex + 1) }
                    }
                    Slider(value: Binding(
                        get: { Double(state.frameIndex) },
                        set: { state.frameIndex = Int($0.rounded()) }
                    ), in: 0...Double(state.frameCount - 1), step: 1) {
                        Text("Frame: \(state.frameIndex + 1) / \(state.frameCount)")
                    }
                }
            }
    }

    // MARK: - Camera bookmarks

    /// The three document-scoped camera slots live beside the standard-view
    /// controls. Names are runtime-only bindings; the controller owns the
    /// optional CameraBookmark values and handles all slot bounds checks.
    @ViewBuilder
    private var cameraBookmarkContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Camera Bookmarks")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(0..<CameraBookmark.slotCount, id: \.self) { index in
                HStack(spacing: 3) {
                    TextField("View \(index + 1)", text: Binding(
                        get: { state.cameraBookmarkName(at: index) },
                        set: { state.setCameraBookmarkName(at: index, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 48)
                    Button(action: { state.onSaveCameraBookmark?(index) }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Save camera bookmark \(index + 1)")
                    .help("Save the current camera in slot \(index + 1).")
                    Button(action: { state.onRecallCameraBookmark?(index) }) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.cameraBookmarkIsAvailable(at: index))
                    .accessibilityLabel("Recall camera bookmark \(index + 1)")
                    .help(state.cameraBookmarkIsAvailable(at: index)
                        ? "Recall the camera saved in slot \(index + 1)."
                        : "Slot \(index + 1) is empty; save a camera before recalling it.")
                    Button(action: { state.onClearCameraBookmark?(index) }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.cameraBookmarkIsAvailable(at: index))
                    .accessibilityLabel("Clear camera bookmark \(index + 1)")
                    .help(state.cameraBookmarkIsAvailable(at: index)
                        ? "Clear slot \(index + 1); keep its name for the next save."
                        : "Slot \(index + 1) is empty; save a camera before clearing it.")
                }
                .font(.caption)
            }
        }
    }

    // MARK: - k-path coordinate editor helpers

    /// Toggle selection of the node at `i`. Selecting loads its values into the
    /// local editor fields; deselecting commits any pending valid edits first.
    private func toggleSelection(_ i: Int) {
        if selectedKPointIndex == i {
            commitEdits()
            selectedKPointIndex = nil
            state.onSelectKPathNode?(nil)
        } else {
            commitEdits()
            selectedKPointIndex = i
            state.onSelectKPathNode?(i)
            loadEditorFields()
        }
    }

    /// Copy the selected node's values into the local editor text fields. No-op
    /// when nothing is selected or the index is out of range.
    private func loadEditorFields() {
        guard let i = selectedKPointIndex, state.kPathPoints.indices.contains(i) else { return }
        let kp = state.kPathPoints[i]
        editKx = formatCoord(kp.frac.x)
        editKy = formatCoord(kp.frac.y)
        editKz = formatCoord(kp.frac.z)
        editLabel = kp.label
    }

    /// Commit the local editor fields back to state, but only when every
    /// coordinate field parses to a finite float. A partial edit like "0." or
    /// an empty field leaves the stored value untouched instead of corrupting it.
    private func commitEdits() {
        guard let i = selectedKPointIndex, state.kPathPoints.indices.contains(i) else { return }
        guard let kx = Float(editKx), kx.isFinite,
              let ky = Float(editKy), ky.isFinite,
              let kz = Float(editKz), kz.isFinite else { return }
        let frac = SIMD3<Float>(kx, ky, kz)
        let label = String(editLabel.prefix(64))
        let current = state.kPathPoints[i]
        // Skip the write when nothing actually changed — avoids pushing a spurious
        // undo entry and prevents a feedback loop through `state.kPathPoints`.
        guard current.frac != frac || current.label != label else { return }
        state.updateKPathPoint(at: i, fractionalCoordinate: frac, label: label)
    }

    /// Format a fractional coordinate for editing. Swift's default Float->String is
    /// the shortest representation that round-trips exactly (Float(String(v)) == v),
    /// so merely opening/closing the editor can never change a stored coordinate
    /// or flip its provenance.
    private func formatCoord(_ v: Float) -> String {
        String(v)
    }

    private func reciprocalDistanceText(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.3f Å^-1", value)
    }

    private func kPathDistanceReadout(at index: Int) -> KPathDistanceReadout? {
        guard state.kPathDistanceReadouts.indices.contains(index) else { return nil }
        return state.kPathDistanceReadouts[index]
    }

    private func kPathIsComponentStart(at index: Int) -> Bool {
        index == 0 || state.kPathBreaks.contains(index - 1)
    }

    private func kPathDistancePrefix(at index: Int) -> String {
        kPathIsComponentStart(at: index) ? (index == 0 ? "Start" : "Start |") : "In"
    }

    // Per-k-path-point rows: extracted to keep the Section builder below the
    // type-checker's complexity threshold.
    private var kPathRows: some View {
        ForEach(Array(state.kPathPoints.enumerated()), id: \.offset) { i, kp in
            // Two-line row: keeps each route item narrow enough for the ~20%
            // sidebar (a single line of label + 3 controls + coordinates overflows).
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // Selection control: tapping it toggles the per-node
                    // coordinate editor open for this point.
                    Button(action: { toggleSelection(i) }) {
                        Image(systemName: selectedKPointIndex == i ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(selectedKPointIndex == i ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit coordinates of point \(i + 1)")
                    Text("\(i + 1).")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("", text: Binding(
                        // Bounds-safe: a row closure can outlive a deletion/reorder.
                        get: { state.kPathPoints.indices.contains(i) ? state.kPathPoints[i].label : "" },
                        set: { state.updateLabel(at: i, to: $0) }
                     ))
                     .frame(maxWidth: 40)
                    Text(String(format: "(%.2f,%.2f,%.2f)", kp.frac.x, kp.frac.y, kp.frac.z))
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                }
                Text("\(kPathDistancePrefix(at: i)) \(reciprocalDistanceText(kPathDistanceReadout(at: i)?.incomingDistance))  total \(reciprocalDistanceText(kPathDistanceReadout(at: i)?.cumulativeDistance))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityLabel(kPathIsComponentStart(at: i) && i > 0
                        ? "Disconnected component start; incoming distance unavailable; cumulative distance \(reciprocalDistanceText(kPathDistanceReadout(at: i)?.cumulativeDistance))"
                        : "Incoming distance \(reciprocalDistanceText(kPathDistanceReadout(at: i)?.incomingDistance)); cumulative distance \(reciprocalDistanceText(kPathDistanceReadout(at: i)?.cumulativeDistance))")
                // Selected-node coordinate editor. Text fields are bound to local
                // state so a partial edit (e.g. "0.") never commits an invalid
                // float. Drafts are committed ONCE on focus loss or via the
                // explicit Apply button — not on every keystroke, which would
                // clobber the field with a state reload mid-edit.
                if selectedKPointIndex == i {
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                        GridRow {
                            Text("kx").font(.caption)
                            TextField("kx", text: $editKx)
                                .textFieldStyle(.roundedBorder)
                                .focused($editorFocused)
                                .onSubmit { commitEdits() }
                        }
                        GridRow {
                            Text("ky").font(.caption)
                            TextField("ky", text: $editKy)
                                .textFieldStyle(.roundedBorder)
                                .focused($editorFocused)
                                .onSubmit { commitEdits() }
                        }
                        GridRow {
                            Text("kz").font(.caption)
                            TextField("kz", text: $editKz)
                                .textFieldStyle(.roundedBorder)
                                .focused($editorFocused)
                                .onSubmit { commitEdits() }
                        }
                        GridRow {
                            Text("Label").font(.caption)
                            TextField("label", text: $editLabel)
                                .textFieldStyle(.roundedBorder)
                                .focused($editorFocused)
                                .onSubmit { commitEdits() }
                        }
                        GridRow {
                            EmptyView()
                            Button("Apply") { commitEdits() }
                                .buttonStyle(.bordered).font(.caption)
                        }
                    }
                }
                HStack(spacing: 2) {
                    Spacer()
                    Button(action: { commitEdits(); state.moveUp(at: i); selectedKPointIndex = nil; state.onSelectKPathNode?(nil) }) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless).disabled(i == 0)
                    Button(action: { commitEdits(); state.moveDown(at: i); selectedKPointIndex = nil; state.onSelectKPathNode?(nil) }) {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless).disabled(i == state.kPathPoints.count - 1)
                    Button(action: { commitEdits(); state.remove(at: i); selectedKPointIndex = nil; state.onSelectKPathNode?(nil) }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            // Break toggle between this point and the next.
            if i < state.kPathPoints.count - 1 {
                HStack {
                    Spacer()
                    let isBroken = state.kPathBreaks.contains(i)
                    Button(action: { state.toggleBreak(at: i) }) {
                        Image(systemName: isBroken ? "line.diagonal" : "line.horizontal")
                            .foregroundColor(isBroken ? .red : .green)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isBroken ? "Break between \(state.kPathPoints[i].label) and \(state.kPathPoints[i+1].label)" : "Connection between \(state.kPathPoints[i].label) and \(state.kPathPoints[i+1].label)")
                    .accessibilityHint(isBroken ? "Double tap to connect" : "Double tap to break")
                    .help(isBroken ? "Break: no segment joins these points — click to connect" : "Connected: segment joins these points — click to break")
                }
            }
        }
    }

    // Lazy section bodies: extracted so each closure stays below the type-checker's
    // complexity threshold. Each is invoked from within a CollapsibleSection.

    @ViewBuilder
    private var forcesContent: some View {
        Toggle("Show Force Arrows", isOn: $state.showForces)
            .disabled(state.displayMode.is2D)
        Slider(value: $state.forceScale, in: 5...200) { Text("Arrow Scale: \(Int(state.forceScale))") }
        Text(state.forceSummary)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
    }

    // MARK: - Clipping plane (display-only)

    @ViewBuilder
    private var clippingContent: some View {
        let isEnabled = state.clipPlane?.enabled ?? false
        Toggle("Enable Clip Plane", isOn: Binding(
            get: { isEnabled },
            set: { enabled in
                if enabled {
                    var clip = state.clipPlane ?? ClipPlane()
                    clip.enabled = true
                    state.clipPlane = clip
                } else {
                    state.clipPlane = nil
                }
            }))
        Stepper("h \(state.clipPlane?.h ?? 0)", value: Binding(
            get: { state.clipPlane?.h ?? 0 },
            set: { var c = state.clipPlane ?? ClipPlane(); c.h = $0; c.enabled = true; state.clipPlane = c }),
            in: -8...8)
            .disabled(!isEnabled)
        Stepper("k \(state.clipPlane?.k ?? 1)", value: Binding(
            get: { state.clipPlane?.k ?? 1 },
            set: { var c = state.clipPlane ?? ClipPlane(); c.k = $0; c.enabled = true; state.clipPlane = c }),
            in: -8...8)
            .disabled(!isEnabled)
        Stepper("l \(state.clipPlane?.l ?? 0)", value: Binding(
            get: { state.clipPlane?.l ?? 0 },
            set: { var c = state.clipPlane ?? ClipPlane(); c.l = $0; c.enabled = true; state.clipPlane = c }),
            in: -8...8)
            .disabled(!isEnabled)
        Slider(value: Binding(
            get: { state.clipPlane?.distance ?? 0 },
            set: { var c = state.clipPlane ?? ClipPlane(); c.distance = $0; c.enabled = true; state.clipPlane = c }),
            in: -20...20) {
            Text("Distance: \(state.clipPlane?.distance ?? 0, specifier: "%.2f")")
        }
        .disabled(!isEnabled)
        Toggle("Clip structure", isOn: Binding(
            get: { state.clipPlane?.applyToStructure ?? true },
            set: { var c = state.clipPlane ?? ClipPlane(); c.applyToStructure = $0; c.enabled = true; state.clipPlane = c }))
            .disabled(!isEnabled)
        Toggle("Clip isosurfaces", isOn: Binding(
            get: { state.clipPlane?.applyToIsosurfaces ?? true },
            set: { var c = state.clipPlane ?? ClipPlane(); c.applyToIsosurfaces = $0; c.enabled = true; state.clipPlane = c }))
            .disabled(!isEnabled)
    }

    // MARK: - Region integration (view-state only)

    @ViewBuilder
    private var regionContent: some View {
        Picker("Shape", selection: $state.regionShape) {
            ForEach(RegionShape.allCases, id: \.self) { shape in
                Text(shape.displayName).tag(shape)
            }
        }
        .pickerStyle(.segmented)
        Slider(value: $state.regionCenter.x, in: -20...20) { Text("Center X: \(state.regionCenter.x, specifier: "%.1f") Å") }
        Slider(value: $state.regionCenter.y, in: -20...20) { Text("Center Y: \(state.regionCenter.y, specifier: "%.1f") Å") }
        Slider(value: $state.regionCenter.z, in: -20...20) { Text("Center Z: \(state.regionCenter.z, specifier: "%.1f") Å") }
        if state.regionShape == .box {
            Slider(value: $state.regionHalfExtents.x, in: 0.1...20) { Text("Half X: \(state.regionHalfExtents.x, specifier: "%.1f") Å") }
            Slider(value: $state.regionHalfExtents.y, in: 0.1...20) { Text("Half Y: \(state.regionHalfExtents.y, specifier: "%.1f") Å") }
            Slider(value: $state.regionHalfExtents.z, in: 0.1...20) { Text("Half Z: \(state.regionHalfExtents.z, specifier: "%.1f") Å") }
        } else {
            Slider(value: $state.regionRadius, in: 0.1...20) { Text("Radius: \(state.regionRadius, specifier: "%.1f") Å") }
        }
        if let error = state.regionComputeError {
            Text(error)
                .font(.caption).foregroundColor(.red)
        } else if !state.regionResultSummary.isEmpty {
            Text(state.regionResultSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            Text("No region computed")
                .font(.caption).foregroundColor(.secondary)
        }
        Button("Whole field") { state.onComputeWholeField?() }
            .buttonStyle(.bordered).font(.caption)
        if !state.regionWholeFieldSummary.isEmpty {
            Text(state.regionWholeFieldSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    /// Distribution/RDF readout derived from the coordination analysis. Shows
    /// bond-length and bond-angle histograms plus the radial distribution
    /// function (3D periodic only, actual g(r) values). Each can be exported
    /// as CSV.
    @ViewBuilder
    private var distributionContent: some View {
        if let dist = state.distributionAnalysis {
            Text("Bond lengths: \(dist.uniquePairCount) unique pairs")
                .font(.caption).foregroundColor(.secondary)
            Text(dist.bondLengthHistogram.bins.isEmpty ? "(no bonds)" :
                dist.bondLengthHistogram.bins.map { "\($0.center): \($0.count)" }.joined(separator: ", "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(3)
            Text("Bond angles: \(dist.uniqueAngleCount) unique angles")
                .font(.caption).foregroundColor(.secondary)
            if dist.radialDistribution.isAvailable {
                let rdf = dist.radialDistribution
                Text("RDF: \(rdf.pairCount) pairs, r ≤ \(String(format: "%.1f", rdf.maxRadius)) Å" + (rdf.wasCapped ? " (capped)" : ""))
                    .font(.caption).foregroundColor(.secondary)
                // Show peak g(r) value as a quick readout
                if let peakBin = rdf.bins.max(by: { $0.g < $1.g }) {
                    Text("Peak g(r) = \(String(format: "%.2f", peakBin.g)) at \(String(format: "%.2f", peakBin.center)) Å")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("RDF: \(dist.radialDistribution.unavailableReason ?? "unavailable")")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("Export CSV") { state.onExportDistributionCSV?(dist) }
                    .buttonStyle(.bordered).font(.caption)
            }
        } else {
            Text("Distribution analysis unavailable")
            .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Structure tools (runtime-only, not persisted)

    @ViewBuilder
    private var structureToolsContent: some View {
        // Cell Basis
        Text("Cell Basis").font(.subheadline).bold()
        Picker("Representation", selection: Binding(
            get: { state.cellRepresentation },
            set: { state.onApplyBasisTransform?($0) }
        )) {
            ForEach(CellRepresentation.allCases, id: \.self) { rep in
                Text(rep.label).tag(rep)
            }
        }
        .pickerStyle(.menu)
        if !state.basisTransformHelp.isEmpty {
            Text(state.basisTransformHelp)
                .font(.caption).foregroundColor(.secondary)
        }
        if !state.structureToolsStatusText.isEmpty {
            Text(state.structureToolsStatusText)
                .font(.caption).foregroundColor(.secondary)
        }

        // Deform Cell
        Text("Deform Cell").font(.subheadline).bold()
        deformationGrid
        HStack {
            Button("Apply") { state.onApplyDeformation?() }
            Button("Reset") {
                let saved = state.onChange
                state.onChange = nil
                state.deformationMatrix = [1,0,0, 0,1,0, 0,0,1]
                state.onChange = saved
            }
        }

        // Cut Cluster
        Text("Cut Cluster").font(.subheadline).bold()
        Slider(value: $state.clusterCenter.x, in: -20...20) { Text("Center X: \(state.clusterCenter.x, specifier: "%.1f")") }
        Slider(value: $state.clusterCenter.y, in: -20...20) { Text("Center Y: \(state.clusterCenter.y, specifier: "%.1f")") }
        Slider(value: $state.clusterCenter.z, in: -20...20) { Text("Center Z: \(state.clusterCenter.z, specifier: "%.1f")") }
        Slider(value: $state.clusterRadius, in: 1...20) { Text("Radius: \(state.clusterRadius, specifier: "%.1f") Å") }
        Button("Cut Cluster") { state.onCutCluster?() }

        // Surface Builder
        Text("Surface Builder").font(.subheadline).bold()
        if state.surfaceBuilderAvailable {
            Stepper("h = \(state.surfaceH)", value: $state.surfaceH, in: -8...8)
            Stepper("k = \(state.surfaceK)", value: $state.surfaceK, in: -8...8)
            Stepper("l = \(state.surfaceL)", value: $state.surfaceL, in: -8...8)
            Stepper("Layers = \(state.surfaceLayers)", value: $state.surfaceLayers, in: 1...100)
            Stepper("Termination = \(state.surfaceTermination)", value: $state.surfaceTermination,
                    in: 0...max(0, state.surfaceTerminationOptions - 1))
            Stepper("Stack count = \(state.surfaceStackCount)", value: $state.surfaceStackCount, in: 1...10)
            Slider(value: Binding(
                get: { state.surfaceVacuum },
                set: { state.surfaceVacuum = $0; state.onSurfaceVacuumChange?() }
            ), in: 0...50) { Text("Vacuum: \(state.surfaceVacuum, specifier: "%.1f") Å") }
            if state.surfaceVacuumAdjustable {
                Text("Current vacuum: \(state.surfaceVacuum, specifier: "%.2f") Å")
                    .font(.caption).foregroundColor(.secondary)
            }
            Button("Build Slab") { state.onBuildSurface?() }
        } else {
            Text("Surface builder requires a 3D periodic crystal.")
                .font(.caption).foregroundColor(.secondary)
        }
        if !state.surfaceStatusText.isEmpty {
            Text(state.surfaceStatusText)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 3x3 deformation matrix editor. Bounds-safe: each field reads/writes only
    /// while the matrix has 9 elements (identity otherwise).
    @ViewBuilder
    private var deformationGrid: some View {
        if state.deformationMatrix.count == 9 {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                GridRow {
                    TextField("", value: deformationBinding(0), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(1), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(2), format: .number).frame(width: 56)
                }
                GridRow {
                    TextField("", value: deformationBinding(3), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(4), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(5), format: .number).frame(width: 56)
                }
                GridRow {
                    TextField("", value: deformationBinding(6), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(7), format: .number).frame(width: 56)
                    TextField("", value: deformationBinding(8), format: .number).frame(width: 56)
                }
            }
        }
    }

    private func deformationBinding(_ i: Int) -> Binding<Float> {
        Binding(
            get: { state.deformationMatrix.indices.contains(i) ? state.deformationMatrix[i] : [1,0,0,0,1,0,0,0,1][i] },
            set: {
                if state.deformationMatrix.indices.contains(i) {
                    state.deformationMatrix[i] = $0
                }
            }
        )
    }

    @ViewBuilder
    private var kPathContent: some View {
        Toggle("Brillouin Zone", isOn: $state.showBrillouinZone)
        Toggle("Edit on BZ", isOn: $state.editKPathOnBZ)
            .disabled(!state.reciprocalEditorAvailable)
        if let status = state.reciprocalEditorStatusText {
            Text(status)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel("Reciprocal editor unavailable: \(status)")
        }
        if state.editKPathOnBZ {
            // Concise active instruction. The controller shows white BZ-landmark
            // crosses; clicking appends one to the route.
            Text("Click a white landmark to append it. Drag to orbit.")
                .font(.caption).foregroundColor(.secondary)
        }
        kPathRows
        HStack {
            // Undo stays enabled after a Clear (the pre-clear route is restorable);
            // it is gated on undo availability, not on whether the route is empty.
            Button("Undo") { state.undoLast() }.disabled(!state.canUndo)
            Button("Clear") { state.clear() }.disabled(state.kPathPoints.isEmpty)
            Button("Default") { state.resetToDefault() }
            Button("Import…") { state.onImportKPath?() }
                .help("Import a k-path from QE K_POINTS, VASP KPOINTS, Wannier90 kpoint_path, or XCrySDen KPF")
        }
        .buttonStyle(.bordered).font(.caption)
        if !state.kPathPoints.isEmpty {
            Text("Total connected: \(reciprocalDistanceText(state.kPathTotalDistance))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
        HStack {
            exportButton("QE (.pwscf)", .qe)
            exportButton("QE crystal_b", .qeCrystalB)
            exportButton("QE tpiba_b", .qeTpibaB)
        }
        .buttonStyle(.bordered).font(.caption)
        HStack {
            exportButton("Wannier90", .wannier90)
            exportButton("kpf", .kpf)
            exportButton("VASP", .vasp)
        }
        .buttonStyle(.bordered).font(.caption)
        Stepper("Samples per segment \(state.kPathSampling)",
                value: $state.kPathSampling, in: 2...200)
    }

    @ViewBuilder
    private var xrdContent: some View {
        Picker("Wavelength", selection: $state.xrdWavelengthIndex) {
            ForEach(0..<PowderXRD.wavelengthOptions.count, id: \.self) { i in
                Text("\(PowderXRD.wavelengthOptions[i].name) · \(PowderXRD.wavelengthOptions[i].wavelength, specifier: "%.4f") Å")
            }
        }
        Slider(value: $state.xrdMaxTwoTheta, in: 10...160) {
            Text("Max 2θ: \(state.xrdMaxTwoTheta, specifier: "%.0f")°")
        }
        Slider(value: $state.xrdFWHM, in: 0.05...2.0, step: 0.05) {
            Text("FWHM: \(state.xrdFWHM, specifier: "%.2f")°")
        }
        Toggle("Peak labels", isOn: $state.xrdShowLabels)
        Toggle("Use electron density", isOn: $state.xrdUseElectronDensity)
            .disabled(!state.hasScalarField)
        if !state.hasScalarField {
            Text("Load a volumetric file to project its density")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Text(state.xrdStatusText)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
        HStack {
            Button("Show Pattern…") { state.onShowXRDWindow?() }
            Button("Export CSV") { state.onExportXRDCSV?() }
                .disabled(!(state.xrdPattern?.peaks.isEmpty == false))
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    /// One standard crystallographic orientation action. All three buttons share
    /// the same runtime availability because they require the same valid cell,
    /// 3D display, and non-editing prerequisites.
    private func standardCrystalViewButton(_ title: String, _ view: StandardCrystalView) -> some View {
        Button(title) { state.onStandardCrystalView?(view) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .disabled(!state.standardCrystalViewAvailable)
            .help(state.standardCrystalViewHelp)
            .accessibilityLabel("Standard crystallographic view \(title)")
    }

    /// One k-path export action. Disabled with an explanatory tooltip when the
    /// current route cannot be encoded in the format (per KPathExport policy);
    /// otherwise invokes the controller's export path via `onExportKPath`.
    private func exportButton(_ title: String, _ format: KPathExportFormat) -> some View {
        let route = KPath(points: state.kPathPoints, breaks: state.kPathBreaks)
        return Button(title) { state.onExportKPath?(route, format) }
            .disabled(!KPathExport.isEnabledInEditor(route, as: format))
            .help(KPathExport.editorHelp(route, as: format))
    }
}

private struct SymmetrySection: View {
    @ObservedObject var state: SideBarState

    var body: some View {
        Group {
            if let analysis = state.crystalSymmetry,
               let symmetry = analysis.symmetry {
                // Space group / crystal system / Bravais / point group live in
                // Structure Summary; here we show only the symmetry-unique fields.
                Text("Wyckoff: \(symmetry.wyckoffLetters.joined(separator: ", "))")
                    .font(.system(.caption, design: .monospaced))
                Text("Sym ops: \(symmetry.symmetryOperations.count)")
                Text("Tolerance: \(symmetry.tolerance, specifier: "%.1e")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("Unavailable")
                    .foregroundColor(.secondary)
                Text(state.crystalSymmetry?.reasonDescription ?? "symmetry was not analyzed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let tolerance = state.crystalSymmetry?.tolerance {
                    Text("Tolerance: \(tolerance, specifier: "%.1e")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// A collapsible sidebar section: a `Section` whose header is a chevron toggle,
/// with the body shown only when expanded. The collapsed/expanded flag is owned by
/// the caller (typically an `@AppStorage`-backed value) so state survives restarts.
/// Matches the grouped-form styling: subheadline bold title, caption chevron.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(title).font(.subheadline).bold()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
            }
        }
    }
}

// MARK: - Lazy section bodies (extracted so each stays below the type-checker limit)

@ViewBuilder
private func structureSummaryGrid(_ summary: StructureSummary) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
        GridRow {
            Text("Formula").font(.caption).foregroundColor(.secondary)
            Text(summary.formula)
                .font(.system(.caption, design: .monospaced))
        }
        GridRow {
            Text("Atoms").font(.caption).foregroundColor(.secondary)
            Text("\(summary.atomCount)")
                .font(.system(.caption, design: .monospaced))
        }
        if summary.isAsymmetricUnit {
            GridRow {
                Text("")
                Text("(asymmetric unit)")
                    .font(.caption).foregroundColor(.secondary).gridCellColumns(1)
            }
        }
        if summary.isCrystal {
            GridRow {
                Text("a").font(.caption).foregroundColor(.secondary)
                Text(summary.latticeA.map { String(format: "%.4f", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("b").font(.caption).foregroundColor(.secondary)
                Text(summary.latticeB.map { String(format: "%.4f", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("c").font(.caption).foregroundColor(.secondary)
                Text(summary.latticeC.map { String(format: "%.4f", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("α").font(.caption).foregroundColor(.secondary)
                Text(summary.alpha.map { String(format: "%.2f°", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("β").font(.caption).foregroundColor(.secondary)
                Text(summary.beta.map { String(format: "%.2f°", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("γ").font(.caption).foregroundColor(.secondary)
                Text(summary.gamma.map { String(format: "%.2f°", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("Volume").font(.caption).foregroundColor(.secondary)
                Text(summary.cellVolume.map { String(format: "%.2f Å³", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("Density").font(.caption).foregroundColor(.secondary)
                Text(summary.density.map { String(format: "%.3f g/cm³", $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("Space group").font(.caption).foregroundColor(.secondary)
                Text(spaceGroupText(summary))
                    .font(.system(.caption, design: .monospaced))
            }
            GridRow {
                Text("Crystal system").font(.caption).foregroundColor(.secondary)
                Text(summary.crystalSystem ?? "—")
            }
            GridRow {
                Text("Bravais lattice").font(.caption).foregroundColor(.secondary)
                Text(summary.bravaisLattice ?? "—")
            }
            GridRow {
                Text("Point group").font(.caption).foregroundColor(.secondary)
                Text(summary.pointGroup ?? "—")
            }
        }
    }
}

private func aoQualityLabel(_ value: Int) -> String {
    switch value {
    case 0: return "Off"
    case 1: return "Low"
    case 2: return "Med"
    default: return "High"
    }
}

private func shadowQualityLabel(_ value: Int) -> String {
    switch value {
    case 0: return "Off"
    case 1: return "Low"
    case 2: return "Med"
    default: return "High"
    }
}

private func spaceGroupText(_ summary: StructureSummary) -> String {
    if let n = summary.spaceGroupNumber, let s = summary.spaceGroupSymbol {
        return "\(n) \(s)"
    }
    if let n = summary.spaceGroupNumber { return "\(n)" }
    if let s = summary.spaceGroupSymbol { return s }
    return "—"
}

// MARK: - Color hex conversion (for the iso-spec ColorPicker)

private extension Color {
    /// Create a Color from a "#RRGGBB" or "RRGGBB" hex string. Falls back to
    /// white on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Convert to a "#RRGGBB" hex string. Falls back to "#FFFFFF" if the
    /// color is not in an RGB-compatible colorspace.
    var hexString: String {
        let ns = NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

