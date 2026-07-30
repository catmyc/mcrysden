import XCTest
import simd
@testable import MolVisApp

final class CoordinationAnalysisTests: XCTestCase {
    private final class CheckStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func atom(_ x: Float, _ y: Float = 0, _ z: Float = 0,
                      _ atomicNumber: Int = 6) -> Atom {
        Atom(coord: SIMD3<Float>(x, y, z), atomicNumber: atomicNumber, label: "X")
    }

    private func cubicCell(_ side: Float) -> Cell {
        Cell(a: SIMD3<Float>(side, 0, 0),
             b: SIMD3<Float>(0, side, 0),
             c: SIMD3<Float>(0, 0, side))
    }

    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(a - b)
    }

    private func imageRecord(bin: SIMD3<Int64>, atomIndex: Int,
                             offset: SIMD3<Int64>) -> CoordinationAnalyzer.ImageRecord {
        CoordinationAnalyzer.ImageRecord(atomIndex: atomIndex, canonicalOffset: offset,
                                         position: .zero,
                                         bin: CoordinationAnalyzer.BinKey(x: bin.x, y: bin.y, z: bin.z))
    }

    private func imageSignature(_ record: CoordinationAnalyzer.ImageRecord) -> [Int64] {
        [record.bin.x, record.bin.y, record.bin.z, Int64(record.atomIndex),
         record.canonicalOffset.x, record.canonicalOffset.y, record.canonicalOffset.z]
    }

    private func neighbor(distance: Float, atomIndex: Int,
                          imageOffset: SIMD3<Int32>) -> CoordinationNeighbor {
        CoordinationNeighbor(atomIndex: atomIndex, imageOffset: imageOffset,
                             displacement: SIMD3<Float>(distance, 0, 0), distance: distance)
    }

    func testWaterStyleMoleculeAndReciprocalRecords() {
        let atoms = [
            atom(0, 0, 0, 8),
            atom(0.96, 0, 0, 1),
            atom(-0.24, 0.93, 0, 1)
        ]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)

        XCTAssertEqual(analysis?.coordinationNumbers, [2, 1, 1])
        XCTAssertEqual(analysis?.neighbors(of: 0).map(\.atomIndex), [1, 2])
        XCTAssertEqual(analysis?.neighbors(of: 1).first?.atomIndex, 0)
        XCTAssertEqual(analysis?.neighbors(of: 2).first?.atomIndex, 0)
        XCTAssertEqual(analysis?.neighbors(of: 0).first?.imageOffset, SIMD3<Int32>(0, 0, 0))
        guard let hydrogenNeighbor = analysis?.neighbors(of: 1).first else {
            XCTFail("expected a reciprocal O-H neighbor")
            return
        }
        XCTAssertEqual(hydrogenNeighbor.displacement.x, Float(-0.96), accuracy: 1e-5)
    }

    func testSparseAndUnknownElementsHaveNoNeighbors() {
        let atoms = [atom(0, 0, 0, 0), atom(0.1, 0, 0, 6), atom(100, 0, 0, 6)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
        XCTAssertEqual(analysis?.coordinationNumbers, [0, 0, 0])
    }

    func testEmptyInputReturnsEmptyAnalysis() {
        let analysis = CoordinationAnalyzer.analyze(atoms: [], cell: nil, periodicDim: 0)
        XCTAssertEqual(analysis, CoordinationAnalysis(neighborsByAtom: []))
    }

    func testOneDimensionalBoundaryWrapsOnlyConfiguredAxis() {
        let atoms = [atom(0, 0, 0), atom(2.5, 5, 5)]
        let cell = Cell(a: SIMD3<Float>(3, 0, 0),
                        b: SIMD3<Float>(0, 3, 0),
                        c: SIMD3<Float>(0, 0, 3))
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell, periodicDim: 1)

        XCTAssertEqual(analysis?.coordinationNumbers, [0, 0])
        let ySeparated = [atom(0, 0, 0), atom(2.5, 0, 0)]
        let yAnalysis = CoordinationAnalyzer.analyze(atoms: ySeparated, cell: cell, periodicDim: 1)
        XCTAssertEqual(yAnalysis?.coordinationNumbers, [1, 1])
        XCTAssertEqual(yAnalysis?.neighbors(of: 0).first?.imageOffset, SIMD3<Int32>(-1, 0, 0))
    }

    func testTwoDimensionalBoundaryWrapsAAndBNotC() {
        let cell = cubicCell(3)
        let atoms = [atom(0, 0, 0), atom(2.8, 2.8, 0)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell, periodicDim: 2)
        XCTAssertEqual(analysis?.coordinationNumbers, [1, 1])

        let cSeparated = [atom(0, 0, 0), atom(2.8, 2.8, 2.8)]
        let noCWrap = CoordinationAnalyzer.analyze(atoms: cSeparated, cell: cell, periodicDim: 2)
        XCTAssertEqual(noCWrap?.coordinationNumbers, [0, 0])
    }

    func testThreeDimensionalSelfImagesProduceSimpleCubicNeighbors() {
        let atoms = [atom(0, 0, 0)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cubicCell(1.5), periodicDim: 3)
        let neighbors = analysis?.neighbors(of: 0) ?? []

        XCTAssertEqual(neighbors.count, 6)
        XCTAssertEqual(Set(neighbors.map(\.imageOffset)), Set([
            SIMD3<Int32>(-1, 0, 0), SIMD3<Int32>(1, 0, 0),
            SIMD3<Int32>(0, -1, 0), SIMD3<Int32>(0, 1, 0),
            SIMD3<Int32>(0, 0, -1), SIMD3<Int32>(0, 0, 1)
        ]))
        XCTAssertTrue(neighbors.allSatisfy { $0.atomIndex == 0 })
    }

    func testMultipleImagesOfAnotherAtomAreRetained() {
        let atoms = [atom(0), atom(0.5)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cubicCell(1), periodicDim: 3)
        let records = analysis?.neighbors(of: 0).filter { $0.atomIndex == 1 } ?? []
        XCTAssertGreaterThanOrEqual(records.count, 4)
        XCTAssertTrue(records.contains { $0.imageOffset.x == -2 && $0.imageOffset.y == 0 && $0.imageOffset.z == 0 })
        XCTAssertTrue(records.contains { $0.imageOffset.x == 1 && $0.imageOffset.y == 0 && $0.imageOffset.z == 0 })
    }

    func testSkewCellFindsTheExactShortImage() {
        let cell = Cell(a: SIMD3<Float>(1, 0, 0),
                        b: SIMD3<Float>(0.4, 0.6, 0),
                        c: SIMD3<Float>(0, 0, 4))
        let atoms = [atom(0, 0, 0, 1), atom(0.56, 0.24, 0, 1)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell, periodicDim: 2)
        let neighbors = analysis?.neighbors(of: 0).filter { $0.atomIndex == 1 } ?? []
        let expected = SIMD3<Float>(0.16, -0.36, 0)
        XCTAssertTrue(neighbors.contains { distance($0.displacement, expected) < 1e-4 })

        let cutoff = CoordinationAnalyzer.defaultRadiusScale *
            (ElementTable.covalentRadius(1) + ElementTable.covalentRadius(1))
        var oracle = Set<SIMD3<Int32>>()
        for i in -4...4 {
            for j in -4...4 {
                let displacement = SIMD3<Float>(0.56, 0.24, 0) +
                    cell.a * Float(i) + cell.b * Float(j)
                let d = simd_length(displacement)
                if d > 1e-7 && d <= cutoff {
                    oracle.insert(SIMD3<Int32>(Int32(i), Int32(j), 0))
                }
            }
        }
        XCTAssertEqual(Set(neighbors.map(\.imageOffset)), oracle)
    }

    func testSortingAndReciprocalDisplacementAreDeterministic() {
        let atoms = [atom(0), atom(1.2), atom(0.8)]
        let first = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
        let second = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.neighbors(of: 0).map(\.atomIndex), [2, 1])
        for i in atoms.indices {
            for neighbor in first?.neighbors(of: i) ?? [] {
                let reverse = first?.neighbors(of: neighbor.atomIndex).first {
                    $0.atomIndex == i && $0.displacement == -neighbor.displacement
                }
                XCTAssertNotNil(reverse)
            }
        }
    }

    func testImageSortCancellationAndCompletedOrderingAreDeterministic() {
        let records = [
            imageRecord(bin: SIMD3(1, 0, 0), atomIndex: 1, offset: .zero),
            imageRecord(bin: SIMD3(0, 1, 0), atomIndex: 4, offset: .zero),
            imageRecord(bin: SIMD3(0, 0, 1), atomIndex: 4, offset: .zero),
            imageRecord(bin: SIMD3(0, 0, 0), atomIndex: 2, offset: SIMD3(0, 1, 0)),
            imageRecord(bin: SIMD3(0, 0, 0), atomIndex: 2, offset: SIMD3(0, 0, 1)),
            imageRecord(bin: SIMD3(0, 0, 0), atomIndex: 1, offset: SIMD3(1, 0, 0)),
            imageRecord(bin: SIMD3(0, 0, 0), atomIndex: 1, offset: .zero)
        ]
        var sorted = records
        XCTAssertTrue(CoordinationAnalyzer.sortImageRecordsForTesting(&sorted))
        XCTAssertEqual(sorted.map(imageSignature), [
            imageSignature(records[6]), imageSignature(records[5]), imageSignature(records[4]),
            imageSignature(records[3]), imageSignature(records[2]), imageSignature(records[1]),
            imageSignature(records[0])
        ])

        var largeRecords = Array((0..<4_096).reversed()).map { index in
            imageRecord(bin: SIMD3(Int64(index / 97), Int64(index % 97), 0),
                        atomIndex: index, offset: .zero)
        }
        var calls = 0
        XCTAssertFalse(CoordinationAnalyzer.sortImageRecordsForTesting(&largeRecords, isCancelled: {
            calls += 1
            return calls >= 100
        }))
        XCTAssertGreaterThan(calls, 1)
    }

    func testLargeNeighborSortCancellationAndCompletedOrderingAreDeterministic() {
        let records = [
            neighbor(distance: 2, atomIndex: 2, imageOffset: SIMD3(0, 0, 0)),
            neighbor(distance: 1, atomIndex: 3, imageOffset: SIMD3(0, 1, 0)),
            neighbor(distance: 1, atomIndex: 1, imageOffset: SIMD3(0, 0, 1)),
            neighbor(distance: 1, atomIndex: 1, imageOffset: SIMD3(0, 0, 0))
        ]
        var sorted = records
        XCTAssertTrue(CoordinationAnalyzer.sortNeighborsForTesting(&sorted))
        XCTAssertEqual(sorted, [records[3], records[2], records[1], records[0]])

        var largeRecords = (0..<4_096).map { index in
            neighbor(distance: Float((index * 37) % 1_000) / 1_000,
                     atomIndex: index % 53,
                     imageOffset: SIMD3(Int32(index % 11), Int32(index % 17), Int32(index % 23)))
        }
        var calls = 0
        XCTAssertFalse(CoordinationAnalyzer.sortNeighborsForTesting(&largeRecords, isCancelled: {
            calls += 1
            return calls >= 100
        }))
        XCTAssertGreaterThan(calls, 1)
    }

    func testBinIndexConstructionCompletesForUniqueBins() {
        let records = (0..<8_192).map { index in
            imageRecord(bin: SIMD3(Int64(index), 0, 0), atomIndex: index, offset: .zero)
        }

        guard let bins = CoordinationAnalyzer.buildBinIndexForTesting(records) else {
            XCTFail("bin index construction should complete")
            return
        }

        XCTAssertEqual(bins.count, records.count)
        XCTAssertEqual(bins[CoordinationAnalyzer.BinKey(x: 0, y: 0, z: 0)], 0..<1)
        XCTAssertEqual(bins[CoordinationAnalyzer.BinKey(x: 8_191, y: 0, z: 0)], 8_191..<8_192)
    }

    func testCancellationDuringLongSameBinIndexConstructionReturnsNil() {
        let records = (0..<8_192).map { index in
            imageRecord(bin: .zero, atomIndex: index, offset: .zero)
        }
        var cancellationRequested = false
        var checkpoints: [Int] = []

        let bins = CoordinationAnalyzer.buildBinIndexForTesting(records,
            isCancelled: { cancellationRequested },
            onConstructionCheckpoint: { processedRecords in
                checkpoints.append(processedRecords)
                cancellationRequested = true
            })

        XCTAssertNil(bins)
        XCTAssertEqual(checkpoints, [4_096])
    }

    func testShellGroupingUsesAdjacentDistancesAndMean() {
        let n0 = CoordinationNeighbor(atomIndex: 1, imageOffset: SIMD3(0, 0, 0),
                                      displacement: SIMD3(1, 0, 0), distance: 1)
        let n1 = CoordinationNeighbor(atomIndex: 2, imageOffset: SIMD3(0, 0, 0),
                                      displacement: SIMD3(1.04, 0, 0), distance: 1.04)
        let n2 = CoordinationNeighbor(atomIndex: 3, imageOffset: SIMD3(0, 0, 0),
                                      displacement: SIMD3(1.08, 0, 0), distance: 1.08)
        let n3 = CoordinationNeighbor(atomIndex: 4, imageOffset: SIMD3(0, 0, 0),
                                      displacement: SIMD3(2, 0, 0), distance: 2)
        let analysis = CoordinationAnalysis(neighborsByAtom: [[n0, n1, n2, n3]])
        let shells = analysis.shells(of: 0, tolerance: 0.05)
        XCTAssertEqual(shells.count, 2)
        XCTAssertEqual(shells[0].neighbors.count, 3)
        XCTAssertEqual(shells[0].distance, 1.04, accuracy: 1e-5)
        XCTAssertEqual(shells[1].distance, 2, accuracy: 1e-5)
        XCTAssertTrue(analysis.shells(of: 0, tolerance: .nan).isEmpty)
        XCTAssertTrue(analysis.shells(of: 9).isEmpty)
    }

    func testStoredCoordinationNumbersAndCandidateChecksArePrecomputed() {
        let neighbor = CoordinationNeighbor(atomIndex: 1, imageOffset: SIMD3(0, 0, 0),
                                             displacement: SIMD3(1, 0, 0), distance: 1)
        let analysis = CoordinationAnalysis(neighborsByAtom: [[neighbor], [], [neighbor]],
                                            candidateChecks: 17)

        XCTAssertEqual(analysis.coordinationNumbers, [1, 0, 1])
        XCTAssertEqual(analysis.candidateChecks, 17)
    }

    func testCSRStorageMatchesCompatibilityRepresentationAndEquatable() {
        let n0 = CoordinationNeighbor(atomIndex: 1, imageOffset: SIMD3(0, 0, 0),
                                       displacement: SIMD3(1, 0, 0), distance: 1)
        let n1 = CoordinationNeighbor(atomIndex: 2, imageOffset: SIMD3(1, 0, 0),
                                       displacement: SIMD3(2, 0, 0), distance: 2)
        let nested = CoordinationAnalysis(neighborsByAtom: [[n0, n1], [], [n0]],
                                           candidateChecks: 9)
        guard let flat = CoordinationAnalysis(records: [n0, n1, n0], offsets: [0, 2, 2, 3],
                                              counts: [2, 0, 1], candidateChecks: 9) else {
            XCTFail("valid CSR cardinality should initialize")
            return
        }

        XCTAssertEqual(flat, nested)
        XCTAssertEqual(flat.neighbors, [n0, n1, n0])
        XCTAssertEqual(flat.offsets, [0, 2, 2, 3])
        XCTAssertEqual(flat.coordinationNumbers, [2, 0, 1])
        XCTAssertEqual(flat.neighborsByAtom, [[n0, n1], [], [n0]])
        XCTAssertEqual(flat.neighbors(of: 0), [n0, n1])
        XCTAssertEqual(flat.neighbors(of: 1), [])
    }

    func testFlatInitializerValidatesCSRCardinality() {
        let neighbor = CoordinationNeighbor(atomIndex: 1, imageOffset: .zero,
                                             displacement: SIMD3(1, 0, 0), distance: 1)
        XCTAssertNotNil(CoordinationAnalysis(records: [neighbor], offsets: [0, 1, 1],
                                             counts: [1, 0], candidateChecks: 0))
        XCTAssertNil(CoordinationAnalysis(records: [neighbor], offsets: [0, 0],
                                           counts: [1], candidateChecks: 0))
        XCTAssertNil(CoordinationAnalysis(records: [neighbor], offsets: [0, 1, 1],
                                           counts: [0, 1], candidateChecks: 0))
        XCTAssertNil(CoordinationAnalysis(records: [neighbor], offsets: [0, 1],
                                           counts: [1], candidateChecks: -1))
    }

    func testTranslationInvarianceForWholeStructure() {
        let cell = cubicCell(3)
        let atoms = [atom(0.2, 0.3, 0.4), atom(2.7, 0.3, 0.4)]
        let shifted = atoms.map {
            Atom(coord: $0.coord + SIMD3<Float>(3, 3, 3), atomicNumber: $0.atomicNumber, label: $0.label)
        }
        let original = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell, periodicDim: 3)
        let translated = CoordinationAnalyzer.analyze(atoms: shifted, cell: cell, periodicDim: 3)
        XCTAssertEqual(original?.coordinationNumbers, translated?.coordinationNumbers)
        XCTAssertEqual(original?.neighbors(of: 0).map(\.imageOffset), translated?.neighbors(of: 0).map(\.imageOffset))
        XCTAssertEqual(original?.neighbors(of: 1).map(\.imageOffset), translated?.neighbors(of: 1).map(\.imageOffset))
        guard let originalDistance = original?.neighbors(of: 0).first?.distance,
              let translatedDistance = translated?.neighbors(of: 0).first?.distance else {
            XCTFail("expected translated neighbor distances")
            return
        }
        XCTAssertEqual(originalDistance, translatedDistance, accuracy: 1e-5)
    }

    func testEffectiveSupercellCoordinatesUseSuppliedExpandedCell() {
        let atoms = [atom(0), atom(1)]
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cubicCell(2), periodicDim: 3)
        XCTAssertEqual(analysis?.coordinationNumbers, [2, 2])
        XCTAssertEqual(analysis?.neighbors(of: 0).map(\.imageOffset), [SIMD3<Int32>(-1, 0, 0), SIMD3<Int32>(0, 0, 0)])
    }

    func testInvalidParametersAndGeometryReturnNil() {
        let atoms = [atom(0)]
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 4))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0, radiusScale: .nan))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0, radiusScale: 0.09))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                  maxCandidateChecks: -1))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: Cell(a: .zero, b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1)), periodicDim: 1))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1)), periodicDim: 2))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: [atom(.infinity)], cell: nil, periodicDim: 0))
    }

    func testCapsRefusePartialResults() {
        let water = [atom(0, 0, 0, 8), atom(1, 0, 0, 1)]
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: water, cell: nil, periodicDim: 0,
                                                  maxNeighborRecords: 0))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: [atom(0)], cell: cubicCell(1), periodicDim: 3,
                                                   maxGeneratedImages: 1))
    }

    func testStorageBudgetRefusesBeforeAnalysisStorage() {
        let atoms = [atom(0), atom(1)]
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                  maxStorageBytes: 0))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                  maxStorageBytes: 1))
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                  maxNeighborRecords: 1,
                                                  maxStorageBytes: 1_000))
    }

    func testDefaultCapsCoverFiveHundredThousandAtomsAtCN12() {
        let directedRecords = 500_000 * 12
        XCTAssertGreaterThan(CoordinationAnalyzer.defaultMaxNeighborRecords, 6_000_000)
        XCTAssertLessThanOrEqual(directedRecords, CoordinationAnalyzer.defaultMaxNeighborRecords)
        XCTAssertGreaterThan(CoordinationAnalyzer.defaultMaxCandidateChecks, 10_000_000)
        XCTAssertGreaterThanOrEqual(CoordinationAnalyzer.defaultMaxStorageBytes, 512 * 1024 * 1024)
        let flatRecordBytes = directedRecords * MemoryLayout<CoordinationNeighbor>.stride
        XCTAssertLessThan(flatRecordBytes, CoordinationAnalyzer.defaultMaxStorageBytes)
    }

    func testDenseBinDoesNotPreallocateACartesianGrid() {
        let atoms = (0..<128).map { _ in atom(0) }
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
        XCTAssertNotNil(analysis)
        XCTAssertTrue(analysis!.coordinationNumbers.allSatisfy { $0 == 0 })
        XCTAssertEqual(analysis?.candidateChecks, atoms.count * atoms.count)
    }

    func testCandidateBudgetCountsDensePairsThatAcceptNoNeighbors() {
        let atoms = (0..<16).map { _ in atom(0) }
        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                  maxCandidateChecks: 15))
    }

    func testCancellationDuringPeriodicImageGenerationReturnsNil() {
        var calls = 0
        let analysis = CoordinationAnalyzer.analyze(atoms: [atom(0)], cell: cubicCell(1), periodicDim: 3,
                                                    isCancelled: {
                                                        calls += 1
                                                        return calls >= 70
                                                    })

        XCTAssertNil(analysis)
        XCTAssertGreaterThanOrEqual(calls, 70)
    }

    func testCancellationDuringCandidateTraversalReturnsNil() {
        var calls = 0
        let atoms = (0..<8).map { _ in atom(0) }
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0,
                                                    isCancelled: {
                                                        calls += 1
                                                        return calls >= 65
                                                    })

        XCTAssertNil(analysis)
        XCTAssertGreaterThanOrEqual(calls, 65)
    }

    func testConcurrentAnalysesKeepCandidateChecksIndependent() {
        let store = CheckStore()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let atoms = index.isMultiple(of: 2) ? [atom(0)] : [atom(0), atom(1)]
            let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
            if let analysis {
                store.append(analysis.candidateChecks)
            }
        }

        XCTAssertEqual(store.snapshot.sorted(), [Int](repeating: 1, count: 8) +
                       [Int](repeating: 4, count: 8))
    }

    func testGeneratedImageCapCountsOnlyRetainedImagesAfterAABBPruning() {
        let analysis = CoordinationAnalyzer.analyze(atoms: [atom(0)], cell: cubicCell(10), periodicDim: 3,
                                                    maxGeneratedImages: 1)

        XCTAssertEqual(analysis?.coordinationNumbers, [0])
        XCTAssertEqual(analysis?.candidateChecks, 1)
    }

    func testLargePeriodicSceneDoesNotPreRejectOffsetWorkByAtomCount() {
        let atomCount = 185_185
        let atoms = (0..<atomCount).map { atom(Float($0 * 10), 0, 0, 1) }
        let cell = Cell(a: SIMD3<Float>(Float(atomCount * 10 + 10), 0, 0),
                        b: .zero, c: .zero)
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell, periodicDim: 1,
                                                    maxGeneratedImages: atomCount)

        XCTAssertEqual(analysis?.coordinationNumbers.count, atomCount)
        XCTAssertEqual(analysis?.candidateChecks, atomCount)
    }

    func testPathologicalSkewCellHitsAttemptedOffsetCap() {
        let cell = Cell(a: SIMD3<Float>(1, 0, 0),
                        b: SIMD3<Float>(1, 0.000001, 0),
                        c: SIMD3<Float>(0, 0, 1))

        XCTAssertNil(CoordinationAnalyzer.analyze(atoms: [atom(0)], cell: cell, periodicDim: 2))
    }

    func testInclusiveCutoffUsesDoubleBoundary() {
        let cutoff = Float(Double(ElementTable.covalentRadius(1)) * 2)
        let below = CoordinationAnalyzer.analyze(atoms: [atom(0, 0, 0, 1), atom(cutoff.nextDown, 0, 0, 1)],
                                                 cell: nil, periodicDim: 0, radiusScale: 1)
        let at = CoordinationAnalyzer.analyze(atoms: [atom(0, 0, 0, 1), atom(cutoff, 0, 0, 1)],
                                               cell: nil, periodicDim: 0, radiusScale: 1)
        let above = CoordinationAnalyzer.analyze(atoms: [atom(0, 0, 0, 1), atom(cutoff.nextUp, 0, 0, 1)],
                                                 cell: nil, periodicDim: 0, radiusScale: 1)

        XCTAssertEqual(below?.coordinationNumbers, [1, 1])
        XCTAssertEqual(at?.coordinationNumbers, [1, 1])
        XCTAssertEqual(above?.coordinationNumbers, [0, 0])
    }

    func testSpatialCandidateChecksAreSubquadraticForSeparatedAtoms() {
        let atoms = (0..<1000).map { atom(Float($0) * 10) }
        let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: nil, periodicDim: 0)
        XCTAssertNotNil(analysis)
        XCTAssertLessThan(analysis?.candidateChecks ?? Int.max, atoms.count * atoms.count / 20)
    }
}
