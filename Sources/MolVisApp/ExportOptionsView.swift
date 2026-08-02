import SwiftUI

struct ExportOptionsView: View {
    @ObservedObject var options: ExportOptions

    var body: some View {
        Form {
            Section {
                dimensionRow("Width", value: $options.width)
                dimensionRow("Height", value: $options.height)
                HStack {
                    Text("Pixels")
                    Spacer()
                    Text("\(options.pixelCount.formatted())")
                        .foregroundColor(.secondary)
                }
            }
            Section {
                ColorPicker("Background", selection: backgroundBinding)
                Toggle("Transparent", isOn: $options.isTransparent)
            }
            Section {
                // MSAA override for export: Use Document (nil) leaves the scene's
                // sample count untouched; Off (1) or 2x/4x/8x force that value for
                // this export only.
                Picker("MSAA", selection: $options.msaaSampleCount) {
                    ForEach(ExportOptions.msaaOptions, id: \.self) {
                        Text(msaaLabel($0)).tag($0)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func msaaLabel(_ value: Int?) -> String {
        guard let value else { return "Use Document" }
        if value == 1 { return "Off" }
        return "\(value)x"
    }

    private func dimensionRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Text("px")
                .foregroundColor(.secondary)
        }
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: options.backgroundColor) },
            set: { options.backgroundColor = NSColor($0) }
        )
    }
}
