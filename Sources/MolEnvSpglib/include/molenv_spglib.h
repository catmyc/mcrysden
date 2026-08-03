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

/* Resolve an International Hermann–Mauguin symbol to a unique space group
   (International Tables numbers 1 through 230). Case, whitespace, minus
   signs, slash punctuation, and screw-axis underscores are normalized only
   while comparing against spglib's database aliases. A successful call
   leaves `out_spacegroup_number` as zero when the symbol is unknown or
   ambiguous; no guess is made. */
MolEnvSpglibStatus molenv_spglib_spacegroup_number(const char *symbol,
                                                   int32_t *out_spacegroup_number);

/* Select a Hall setting compatible with Parser lattice conventions and copy
   its operations into caller-owned flat buffers. Rhombohedral R groups use
   the hexagonal H choice, monoclinic groups (3–15) use the
   unique-b choice, and others use the canonical lowest Hall number. No
   spglib-owned pointer escapes this call. `rotations` has
   `max_operations * 9` entries and `translations` has `max_operations * 3`;
   both are required when max_operations is positive. Returns
   MOLENV_SPGLIB_SEARCH_FAILED when no compatible Hall setting exists. */
MolEnvSpglibStatus molenv_spglib_operations(int32_t spacegroup_number,
                                            int32_t rotations[],
                                            double translations[],
                                            int32_t max_operations,
                                            int32_t *out_operations);

/* Resolve a Hall setting for a space group that is compatible with the
   parser lattice conventions AND whose international symbol matches the
   given alias. `symbol` may be NULL for the plain convention-based
   selection. When non-NULL, the alias is normalized the same way as
   molenv_spglib_spacegroup_number and must exactly match the selected
   Hall setting's own symbol; an alias that resolves to a different
   setting fails safely. Returns the chosen Hall number (>0) on success,
   or 0 when no compatible setting exists. */
int32_t molenv_spglib_select_hall_number(int32_t spacegroup_number,
                                         const char *symbol);

/* Symbol-aware variant of molenv_spglib_operations. When `symbol` is
   non-NULL, the Hall setting is selected by matching the symbol (via
   molenv_spglib_select_hall_number); when NULL, the plain convention-based
   selection is used. This lets CRYSCAL symbolic groups expand with the
   correct setting for their declared lattice convention. */
MolEnvSpglibStatus molenv_spglib_operations_with_symbol(int32_t spacegroup_number,
                                                       const char *symbol,
                                                       int32_t rotations[],
                                                       double translations[],
                                                       int32_t max_operations,
                                                       int32_t *out_operations);

#ifdef __cplusplus
}
#endif

#endif
