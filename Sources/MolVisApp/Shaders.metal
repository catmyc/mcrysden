// NOTE: Shaders.metal is intentionally EXCLUDED from the SwiftPM target
// (see Package.swift `exclude:`) and is NOT compiled. It exists only as
// reference/documentation. The runtime source of truth for all Metal shaders is
// the `Renderer.shaderSource` string in Sources/MolVisApp/Renderer.swift.
// Edit the Metal source there. Do not add this file back to the target or edit
// it expecting any runtime effect — it would silently diverge from the real code.
