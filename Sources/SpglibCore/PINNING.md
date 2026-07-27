# Vendored spglib

This directory contains the upstream C implementation from spglib `v2.7.0`.

- Source: https://github.com/spglib/spglib/tree/v2.7.0
- Commit: `12355c77fb7c505a55f52cae36341d73b781a065`
- License: BSD-3-Clause, reproduced in `LICENSE` and in the upstream source
  file headers.

`version.h` is the generated-header equivalent required by the upstream C
sources. `spglib_f.c` is retained for provenance but excluded from the SwiftPM
target because this application uses only the C API.
