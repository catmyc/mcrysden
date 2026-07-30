import XCTest
@testable import MolVisApp

final class DOSGrapherTests: XCTestCase {
    private func makeDOS(fermi: Float? = 0.0) -> DensityOfStates {
        let energies = Array(stride(from: Float(-5), through: Float(5), by: Float(0.5)))
        let values = energies.map { exp(-($0 * $0) / 4.0) }   // Gaussian-ish DOS
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "Total DOS", values: values)],
                               fermiEnergy: fermi)
    }

    private func makeView() -> DOSGrapherView {
        let view = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.densityOfStates = makeDOS()
        return view
    }

    func testEnergyAtViewPointMidpoint() {
        let view = makeView()
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
        // Mid-energy of [-5, 5] is ~0.
        XCTAssertEqual(info!.energy, 0.0, accuracy: 1.5)
    }

    func testEnergyAtViewPointOutsideNil() {
        let view = makeView()
        XCTAssertNil(view.dataAtViewPoint(NSPoint(x: -50, y: -50)))
        XCTAssertNil(view.dataAtViewPoint(NSPoint(x: 100, y: -50)))
    }

    func testFermiShiftDoesNotCrash() {
        let view = makeView()
        view.fermiShift = 2.0
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
    }

    func testEnergyWindowApplied() {
        let view = makeView()
        view.energyWindow = -2...2
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
        // dataAtViewPoint reports original energy (unshifted) within the window range.
        XCTAssertGreaterThanOrEqual(info!.energy, -3.0)
        XCTAssertLessThanOrEqual(info!.energy, 3.0)
    }

    func testDefaultStateValid() {
        let view = makeView()
        XCTAssertNil(view.energyWindow)
        XCTAssertEqual(view.fermiShift, 0)
        XCTAssertEqual(view.zoomScale, 1.0)
        XCTAssertNotNil(view.dataAtViewPoint(NSPoint(x: 100, y: 150)))
    }
}
