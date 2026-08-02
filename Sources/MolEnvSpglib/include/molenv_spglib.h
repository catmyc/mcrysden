// Project-owned, allocation-safe façade for the vendored spglib C library.
// The public API intentionally exposes copied values only, never a spglib
// dataset pointer or any other upstream-owned allocation.

#ifndef MOLENV_SPGLIB_H
#define MOLENV_SPGLIB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MolEnvSpglibStatus {
    MOLENV_SPGLIB_OK = 0,
    MOLENV_SPGLIB_INVALID_ARGUMENT = 1,
    MOLENV_SPGLIB_ALLOCATION_FAILED = 2,
    MOLENV_SPGLIB_SEARCH_FAILED = 3,
    MOLENV_SPGLIB_STANDARDIZATION_FAILED = 4
} MolEnvSpglibStatus;

/*
 * All lattice arrays in this façade use three consecutive row vectors
 * [a_x,a_y,a_z, b_x,b_y,b_z, c_x,c_y,c_z]. This is the row-vector layout
 * used by spglib's higher-level interfaces. The façade transcribes it to the
 * vendored C API's documented column-vector lattice[3][3] representation
 * before every call. Fractional positions are [x,y,z] triples.
 *
 * Every pointer below is owned by the result and is released by
 * molenv_spglib_result_free. The result is fully copied before spglib's
 * SpglibDataset is freed. A NULL pointer is allowed only for an array whose
 * count is zero.
 */
typedef struct MolEnvSpglibResult {
    int32_t spacegroup_number;
    int32_t hall_number;
    char *international_symbol;
    char *hall_symbol;
    char *choice;
    char *pointgroup_symbol;

    /* P = B^-1 L: input fractional -> pre-idealized Bravais fractional.
       The affine position relation is x_B = P x_input + origin_shift.
       For reciprocal fractional coordinates, k_input = P^T k_B. */
    double transformation_matrix[9];
    double origin_shift[3];
    /* Input and raw lattices use row vectors in this façade. */
    double input_lattice[9];
    double preidealized_bravais_lattice[9];
    /* The primitive lattice and mapping come from one SpglibDataset. */
    double detected_primitive_lattice[9];
    double standardized_lattice[9];
    /* Cartesian rotation from the pre-idealized Bravais frame to the
       idealized standardized frame; not a fractional-coordinate map. */
    double standardized_rotation_matrix[9];

    int32_t n_operations;
    int32_t *rotations;          /* n_operations * 9 */
    double *translations;       /* n_operations * 3 */

    int32_t n_atoms;
    int32_t *wyckoffs;           /* n_atoms */
    char *site_symmetry_symbols; /* n_atoms * 7, NUL-padded records */
    int32_t *equivalent_atoms;   /* n_atoms */
    int32_t *crystallographic_orbits; /* n_atoms */
    int32_t *mapping_to_primitive; /* n_atoms */

    int32_t n_primitive_atoms;
    int32_t *primitive_types;    /* n_primitive_atoms */
    double *primitive_positions; /* n_primitive_atoms * 3 */

    int32_t n_std_atoms;
    int32_t *std_types;          /* n_std_atoms */
    double *std_positions;       /* n_std_atoms * 3 */
    int32_t *std_mapping_to_primitive; /* n_std_atoms */
} MolEnvSpglibResult;

/* Analyze one finite, nonsingular 3D periodic structure at exactly symprec. */
MolEnvSpglibStatus molenv_spglib_analyze(const double lattice_rows[9],
                                         const double positions[],
                                         const int32_t types[],
                                         int32_t num_atoms,
                                         double symprec,
                                         MolEnvSpglibResult **out_result);

void molenv_spglib_result_free(MolEnvSpglibResult *result);

/* Thread-local diagnostic for the most recent façade call. */
const char *molenv_spglib_last_error(void);

/* In-place Niggli reduction of a row-vector direct lattice. Returns
   MOLENV_SPGLIB_OK on success and the reduction transform can be derived
   from the input/output lattice pair by the caller. */
MolEnvSpglibStatus molenv_spglib_niggli_reduce(double lattice_rows[9],
                                               double symprec);

/* Resolve an International Hermann–Mauguin symbol to a unique cubic space
   group (International Tables numbers 195 through 230). Case, whitespace,
   minus signs, slash punctuation, and screw-axis underscores are normalized
   only while comparing against spglib's database aliases. A successful call
   leaves `out_spacegroup_number` as zero when the symbol is unknown,
   non-cubic, or ambiguous; no guess is made. */
MolEnvSpglibStatus molenv_spglib_cubic_spacegroup_number(const char *symbol,
                                                          int32_t *out_spacegroup_number);

/* Copy the conventional-coordinate operations for one numeric cubic space
   group (International Tables numbers 195 through 230) into caller-owned
   flat buffers. No spglib-owned pointer escapes this call. `rotations` has
   `max_operations * 9` entries and `translations` has `max_operations * 3`;
   both are required when max_operations is positive. */
MolEnvSpglibStatus molenv_spglib_cubic_operations(int32_t spacegroup_number,
                                                   int32_t rotations[],
                                                   double translations[],
                                                   int32_t max_operations,
                                                   int32_t *out_operations);

#ifdef __cplusplus
}
#endif

#endif
