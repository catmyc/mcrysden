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

    var body: some View {
        Form {
            Section {
                Button("Reset View") { state.onResetView?() }
                    .buttonStyle(.borderedProminent)
            }
            Section("Display") {
                Picker("Mode", selection: $state.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            // --- Structure Summary ----------------------------------------------
            // Compact readout of the loaded structure. Hidden entirely for an
            // empty viewer (no atoms); crystal fields appear only for crystals.
            if let summary = state.structureSummary {
                StructureSummarySection(summary: summary)
            }
            // --- Appearance: material + background ---------------------------------
            Section("Appearance") {
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
                Section("Isosurface") {
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
                Section("Fermi Surface") {
                    Toggle("Show Fermi Surface", isOn: $state.showFermiSurface)
                }
            }
            // --- Color plane (2D scalar grid) --------------------------------
            // Shown only when the loaded file carried a DATAGRID_2D block. The
            // colormap + contour view swaps in for the 3D canvas while toggled on.
            if state.hasGrid2D {
                Section("Color Plane") {
                    Toggle("Show Color Plane", isOn: $state.showColorPlane)
                }
            }
            // --- Forces (QE output): per-atom force arrows + energy readout. ---
            // Shown only when the loaded file carried a parsed `Forces acting on
            // atoms` block. The arrows are force vectors drawn from each atom.
            if state.hasForceSet {
                ForcesSection(state: state)
            }
            // --- k-path (crystal only): Brillouin-zone overlay + band path. -----
            // The scene exposes cell + base atoms; the controller builds the
            // default high-symmetry path and writes the chosen export via a save
            // panel. Shown only for crystals (a cell with base atoms present).
            if state.isCrystal {
                SymmetrySection(state: state)
                Section("K-Path") {
                    Toggle("Brillouin Zone", isOn: $state.showBrillouinZone)
                    Toggle("Edit on BZ", isOn: $state.editKPathOnBZ)
                    if state.editKPathOnBZ {
                        // Concise active instruction. The controller shows white
                        // BZ-landmark crosses; clicking appends one to the route.
                        Text("Click a white landmark to append it. Drag to orbit.")
                            .font(.caption).foregroundColor(.secondary)
                    }
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
                    HStack {
                        // Undo stays enabled after a Clear (the pre-clear route is restorable);
                        // it is gated on undo availability, not on whether the route is empty.
                        Button("Undo") { state.undoLast() }.disabled(!state.canUndo)
                        Button("Clear") { state.clear() }.disabled(state.kPathPoints.isEmpty)
                        Button("Default") { state.resetToDefault() }
                    }
                    .buttonStyle(.bordered).font(.caption)
                    HStack {
                        let route = KPath(points: state.kPathPoints, breaks: state.kPathBreaks)
                        Button("QE (.pwscf)") { state.onExportKPath?(route, .qe) }
                            .disabled(!KPathExport.isEnabledInEditor(route, as: .qe))
                            .help(KPathExport.editorHelp(route, as: .qe))
                        // KPF cannot represent disconnected segments: a repeated
                        // label only indicates a break when the shared endpoint
                        // happens to be that label, which is ambiguous. Disable
                        // the button and explain why when it cannot encode the route.
                        Button("kpf") { state.onExportKPath?(route, .kpf) }
                            .disabled(!KPathExport.isEnabledInEditor(route, as: .kpf))
                            .help(KPathExport.editorHelp(route, as: .kpf))
                    }
                    .buttonStyle(.bordered).font(.caption)
                }
            }
            Section("Supercell") {
                Stepper("n1 = \(state.n1)", value: $state.n1, in: 1...6)
                Stepper("n2 = \(state.n2)", value: $state.n2, in: 1...6)
                Stepper("n3 = \(state.n3)", value: $state.n3, in: 1...6)
            }
            // --- Slab: enable + two Miller planes (h/k/l + distance each) ----------
            Section("Slab") {
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
            // --- AXSF animation playback -------------------------------------------
            // Only shown for multi-frame AXSF files (frameCount > 1); the controls
            // reload the scene frame-by-frame through Parser.load(frameIndex:).
            if state.frameCount > 1 {
                Section("Animation") {
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
}

private struct SymmetrySection: View {
    @ObservedObject var state: SideBarState

    var body: some View {
        Section("Symmetry") {
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

/// Collapsible "Structure Summary" section: lattice parameters, angles, volume,
/// formula, atom count, density, and symmetry. Crystal-specific rows appear only
/// when the scene is periodic. Labels are caption-sized; values are monospaced.
/// The header toggles the body open/closed, matching the k-path node chevron.
private struct StructureSummarySection: View {
    let summary: StructureSummary
    @State private var expanded = true

    var body: some View {
        Section {
            Button(action: { expanded.toggle() }) {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Structure Summary").font(.subheadline).bold()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
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
                            Text(spaceGroupText)
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
        }
    }

    private var spaceGroupText: String {
        if let n = summary.spaceGroupNumber, let s = summary.spaceGroupSymbol {
            return "\(n) \(s)"
        }
        if let n = summary.spaceGroupNumber { return "\(n)" }
        if let s = summary.spaceGroupSymbol { return s }
        return "—"
    }
}

/// Forces sidebar section: per-atom force arrows + energy readout. Arrows render in
/// every 3D mode; in 2D modes atoms are screen-space (a separate Renderer2D) and
/// world-space vectors have no meaningful projection, so the toggle is disabled there
/// rather than promise invisible arrows.
private struct ForcesSection: View {
    @ObservedObject var state: SideBarState
    var body: some View {
        Section("Forces") {
            Toggle("Show Force Arrows", isOn: $state.showForces)
                .disabled(state.displayMode.is2D)
            Slider(value: $state.forceScale, in: 5...200) { Text("Arrow Scale: \(Int(state.forceScale))") }
            Text(state.forceSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}
