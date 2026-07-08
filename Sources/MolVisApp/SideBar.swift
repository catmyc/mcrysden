import SwiftUI

struct SideBar: View {
    @ObservedObject var state: SideBarState
    var body: some View {
        Form {
            Section {
                Button("Reset View") { state.onResetView?() }
                    .buttonStyle(.borderedProminent)
            }
            Section("Display") {
                Picker("Mode", selection: $state.displayMode) {
                    ForEach(DisplayMode.allCases.filter { $0 != .polyhedral }, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section("Appearance") {
                Slider(value: $state.atomScale, in: 0.05...1.0) { Text("Atom Scale: \(state.atomScale, specifier: "%.2f")") }
                Slider(value: $state.bondRadius, in: 0.02...0.4) { Text("Bond Radius: \(state.bondRadius, specifier: "%.2f")") }
                Toggle("Cell Frame", isOn: $state.showCellFrame)
                Toggle("Axes", isOn: $state.showAxes)
                Toggle("Element Labels", isOn: $state.showLabels)
                HStack { Text("BG"); TextField("hex", text: $state.backgroundHex).frame(width: 90) }
            }
            Section("Supercell") {
                Stepper("n1 = \(state.n1)", value: $state.n1, in: 1...6)
                Stepper("n2 = \(state.n2)", value: $state.n2, in: 1...6)
                Stepper("n3 = \(state.n3)", value: $state.n3, in: 1...6)
            }
            Section("Slab") {
                Toggle("Enable", isOn: $state.slabEnabled)
                if state.slabEnabled {
                    Slider(value: $state.slabA_dist, in: -20...20) { Text("Slab A dist: \(state.slabA_dist, specifier: "%.1f")") }
                    Slider(value: $state.slabB_dist, in: -20...20) { Text("Slab B dist: \(state.slabB_dist, specifier: "%.1f")") }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 200)
    }
}
