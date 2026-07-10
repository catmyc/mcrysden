import SwiftUI

struct SideBar: View {
    @ObservedObject var state: SideBarState

    // Light-direction steppers work in whole degrees; the slider reads/writes
    // the same Lighting.azimuth/elevation the shader consumes.
    private let degRange: ClosedRange<Float> = 0...360

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
            // --- k-path (crystal only): Brillouin-zone overlay + band path. -----
            // The scene exposes cell + base atoms; the controller builds the
            // default high-symmetry path and writes the chosen export via a save
            // panel. Shown only for crystals (a cell with base atoms present).
            if state.isCrystal {
                Section("K-Path") {
                    Toggle("Brillouin Zone", isOn: $state.showBrillouinZone)
                    ForEach(Array(state.kPathPoints.enumerated()), id: \.offset) { i, kp in
                        HStack {
                            Text(kp.label.isEmpty ? "k\(i)" : kp.label)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(String(format: "(%.2f,%.2f,%.2f)", kp.frac.x, kp.frac.y, kp.frac.z))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Button("QE (.pwscf)") { state.onExportKPath?(KPath(points: state.kPathPoints), .qe) }
                        Button("kpf") { state.onExportKPath?(KPath(points: state.kPathPoints), .kpf) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
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
    }
}
