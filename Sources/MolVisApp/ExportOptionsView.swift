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
        }
        .formStyle(.grouped)
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
