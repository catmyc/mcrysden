import Foundation
import simd
import XCTest
@testable import MolVisApp

final class ExtensibilityTests: XCTestCase {

    private func makeSyntheticBandStructure() -> BandStructure {
        let k0 = BandKPoint(k: SIMD3(0, 0, 0), weight: 1, label: "Γ", energies: [-2.0, 3.0])
        let k1 = BandKPoint(k: SIMD3(0.5, 0, 0), weight: 1, label: "X", energies: [-1.0, 4.0])
        return BandStructure(kPoints: [k0, k1], fermiEnergy: 0.0, nSpin: 1,
                             reciprocal: nil, kPointsAreCrystal: false,
                             kPointsPerSpin: 2, isMesh: false)
    }

    private func makeSyntheticDOS() -> DensityOfStates {
        let energies: [Float] = [-3, -2, -1, 0, 1, 2, 3]
        let values: [Float] = [0, 0.5, 0, 0, 0, 0.5, 0]
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "total", values: values)],
                               fermiEnergy: 0.0)
    }

    func testProjectRoundTripCombinesDatasets() throws {
        var scene = Scene()
        scene.atoms = [Atom(coord: SIMD3(0.1, 0.2, 0.3), atomicNumber: 14, label: "Si"),
                       Atom(coord: SIMD3(0.6, 0.7, 0.8), atomicNumber: 14, label: "Si")]
        scene.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        scene.bandStructure = makeSyntheticBandStructure()
        scene.densityOfStates = makeSyntheticDOS()

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("mcrysden_roundtrip_\(ProcessInfo.processInfo.globallyUniqueString).mvis")

        try ProjectStore.save(scene, to: url)
        XCTAssertTrue(ProjectStore.isValidProjectFile(url))

        let loaded = try ProjectStore.load(from: url)
        XCTAssertEqual(loaded.atoms, scene.atoms)
        XCTAssertEqual(loaded.cell, scene.cell)
        XCTAssertEqual(loaded.bandStructure?.kPoints.map(\.label),
                       scene.bandStructure?.kPoints.map(\.label))
        XCTAssertEqual(try XCTUnwrap(loaded.bandStructure?.fermiEnergy),
                       try XCTUnwrap(scene.bandStructure?.fermiEnergy),
                       accuracy: 1e-3)
        XCTAssertEqual(loaded.densityOfStates?.energies, scene.densityOfStates?.energies)
        XCTAssertEqual(loaded.densityOfStates?.series.first?.values,
                       scene.densityOfStates?.series.first?.values)

        // isValidProjectFile is false for a garbage file.
        let garbage = dir.appendingPathComponent("garbage.txt")
        try Data("not a project".utf8).write(to: garbage)
        XCTAssertFalse(ProjectStore.isValidProjectFile(garbage))

        // A truncated/corrupt project file throws a useful error.
        let corrupt = dir.appendingPathComponent("corrupt.txt")
        try Data(#"{"version": 1, "scene": {"atoms":"#.utf8).write(to: corrupt)
        XCTAssertThrowsError(try ProjectStore.load(from: corrupt))
    }

    func testScriptRunnerAndPluginRegistry() throws {
        // --- Plugin registry ---
        struct FakePlugin: AnalysisPlugin {
            let name = "fake-plugin"
            let summary = "A fake plugin for tests"
            func run(scene: Scene) -> String? { "fake-output" }
        }
        PluginRegistry.register(FakePlugin())
        defer { PluginRegistry.unregister(named: "fake-plugin") }

        let names = PluginRegistry.plugins().map { $0.name }
        XCTAssertTrue(names.contains("fake-plugin"))

        var scene = Scene()
        scene.atoms = [Atom(coord: .zero, atomicNumber: 1, label: "H")]
        let results = PluginRegistry.runAll(scene: scene)
        let fakeResult = results.first { $0.name == "fake-plugin" }
        XCTAssertEqual(fakeResult?.output, "fake-output")

        let listLines = PluginRegistry.listText().split(separator: "\n")
        XCTAssertTrue(listLines.contains { $0.hasPrefix("fake-plugin —") },
                      "registered plugin must appear in listText()")
        XCTAssertTrue(listLines.contains { $0.hasPrefix("band-gap —") })
        XCTAssertTrue(listLines.contains { $0.hasPrefix("dos-gap —") })

        // band-gap returns nil on a scene without bands.
        XCTAssertNil(PluginRegistry.plugin(named: "band-gap")?.run(scene: scene))

        // --- Script runner ---
        var emitted: [String] = []
        let ctx = ScriptContext(
            workingDirectory: FileManager.default.temporaryDirectory,
            onOutput: { emitted.append($0) },
            commands: [
                "echo": { $0.joined(separator: " ") },
                "boom": { _ in throw NSError(domain: "t", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "kaboom"]) },
            ]
        )

        let script = "echo a\n# comment\nhelp\nquit\necho b"
        let joined = try ScriptRunner.run(script: script, context: ctx)
        XCTAssertEqual(joined, "a\ncommands: boom echo")
        XCTAssertEqual(emitted, ["a", "commands: boom echo"])

        // Unknown command surfaces with the correct line number.
        do {
            _ = try ScriptRunner.run(script: "echo ok\nbogus", context: ctx)
            XCTFail("expected unknownCommand error")
        } catch let ScriptError.unknownCommand(cmd, line) {
            XCTAssertEqual(cmd, "bogus")
            XCTAssertEqual(line, 2)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // Quoted arguments are unquoted.
        let quoted = try ScriptRunner.run(script: #"echo "hello world""#, context: ctx)
        XCTAssertEqual(quoted, "hello world")

        // A throwing command becomes commandFailed with its line number.
        do {
            _ = try ScriptRunner.run(script: "echo ok\nboom", context: ctx)
            XCTFail("expected commandFailed error")
        } catch let ScriptError.commandFailed(cmd, line, msg) {
            XCTAssertEqual(cmd, "boom")
            XCTAssertEqual(line, 2)
            XCTAssertTrue(msg.contains("kaboom"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
