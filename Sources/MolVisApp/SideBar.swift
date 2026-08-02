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
    @AppStorage(CollapsibleSidebarSection.animation.rawValue) private var animationExpanded = true
    @AppStorage(CollapsibleSidebarSection.isosurface.rawValue) private var isosurfaceExpanded = true
    @AppStorage(CollapsibleSidebarSection.fermiSurface.rawValue) private var fermiSurfaceExpanded = true
    @AppStorage(CollapsibleSidebarSection.symmetry.rawValue) private var symmetryExpanded = true
    @AppStorage(CollapsibleSidebarSection.coordination.rawValue) private var coordinationExpanded = true
    @AppStorage(CollapsibleSidebarSection.electronicStructure.rawValue) private var electronicStructureExpanded = true

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
        }
            CollapsibleSection(title: "Display", isExpanded: $displayExpanded) {
                Picker("Mode", selection: $state.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            // --- Structure Summary ----------------------------------------------
            // Compact readout of the loaded structure. Hidden entirely for an
            // empty viewer (no atoms); crystal fields appear only for crystals.
            if let summary = state.structureSummary {
                CollapsibleSection(title: "Structure Summary", isExpanded: $structureSummaryExpanded) {
                    structureSummaryGrid(summary)
                    Button("Atom Table…") { state.onShowAtomTable?() }
                        .buttonStyle(.bordered)
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

                // Background: solid vs gradient. The second hex field only appears
                // for the gradient case (there is no second color to set otherwise).
                Picker("Background", selection: $state.backgroundType) {
                    Text("Solid").tag(BackgroundType.solid)
                    Text("Gradient").tag(BackgroundType.gradient_top)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Top"); TextField("hex", text: $state.backgroundHex).frame(width: 90)
                }
                if state.backgroundType == .gradient_top {
                    HStack {
                        Text("Bottom"); TextField("hex", text: $state.backgroundBottomHex).frame(width: 90)
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
                    Slider(value: $state.isoLevel, in: state.isoRange) {
                        Text("Iso level: \(state.isoLevel, specifier: "%.3f")")
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

private func spaceGroupText(_ summary: StructureSummary) -> String {
    if let n = summary.spaceGroupNumber, let s = summary.spaceGroupSymbol {
        return "\(n) \(s)"
    }
    if let n = summary.spaceGroupNumber { return "\(n)" }
    if let s = summary.spaceGroupSymbol { return s }
    return "—"
}
