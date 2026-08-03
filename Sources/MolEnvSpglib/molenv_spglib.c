#include "molenv_spglib.h"

#include "niggli.h"
#include "spglib.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MOLENV_SPGLIB_MAX_ATOMS 4096
#define MOLENV_SPGLIB_MAX_STANDARD_ATOMS 400000
#define MOLENV_SPGLIB_MAX_OPERATIONS 4096
#define MOLENV_SPGLIB_FIRST_CUBIC_SPACEGROUP 195
#define MOLENV_SPGLIB_LAST_CUBIC_SPACEGROUP 230
#define MOLENV_SPGLIB_LAST_SPACEGROUP 230
#define MOLENV_SPGLIB_LAST_HALL_NUMBER 530
#define MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY 64
/* Spglib's symprec is a Cartesian distance in Angstroms. Keep synchronous
   analysis inside a practical range and never retry with a changed value. */
#define MOLENV_SPGLIB_MIN_SYMPREC 1e-8
#define MOLENV_SPGLIB_MAX_SYMPREC 1e-1

static _Thread_local char molenv_spglib_error[256];

static void set_error(const char *message) {
    if (message == NULL) message = "unknown symmetry error";
    (void)snprintf(molenv_spglib_error, sizeof(molenv_spglib_error), "%s", message);
}

static void set_spglib_error(const char *prefix) {
    const char *detail = spg_get_error_message(spg_get_error_code());
    if (detail == NULL || detail[0] == '\0') detail = "spglib failed";
    (void)snprintf(molenv_spglib_error, sizeof(molenv_spglib_error), "%s: %s",
                   prefix, detail);
}

const char *molenv_spglib_last_error(void) { return molenv_spglib_error; }

static int checked_count(size_t count, size_t item_size, size_t *bytes) {
    if (item_size != 0 && count > SIZE_MAX / item_size) return 0;
    *bytes = count * item_size;
    return 1;
}

static int finite_matrix(const double *values, size_t count) {
    size_t i;
    if (values == NULL) return 0;
    for (i = 0; i < count; i++) {
        if (!isfinite(values[i])) return 0;
    }
    return 1;
}

static double determinant(double const lattice[3][3]) {
    return lattice[0][0] * (lattice[1][1] * lattice[2][2] - lattice[1][2] * lattice[2][1])
         - lattice[0][1] * (lattice[1][0] * lattice[2][2] - lattice[1][2] * lattice[2][0])
         + lattice[0][2] * (lattice[1][0] * lattice[2][1] - lattice[1][1] * lattice[2][0]);
}

static int invert_matrix(double inverse[3][3], double const matrix[3][3]) {
    double scale = 0.0;
    double normalized[3][3];
    double det;
    int i, j;

    for (i = 0; i < 3; i++) {
        for (j = 0; j < 3; j++) {
            scale = fmax(scale, fabs(matrix[i][j]));
        }
    }
    if (!isfinite(scale) || scale <= 0.0) return 0;
    for (i = 0; i < 3; i++) {
        for (j = 0; j < 3; j++) {
            normalized[i][j] = matrix[i][j] / scale;
        }
    }
    det = determinant(normalized);
    if (!isfinite(det) || fabs(det) <= 1e-12) return 0;

    inverse[0][0] = (normalized[1][1] * normalized[2][2] - normalized[1][2] * normalized[2][1]) / det / scale;
    inverse[0][1] = (normalized[0][2] * normalized[2][1] - normalized[0][1] * normalized[2][2]) / det / scale;
    inverse[0][2] = (normalized[0][1] * normalized[1][2] - normalized[0][2] * normalized[1][1]) / det / scale;
    inverse[1][0] = (normalized[1][2] * normalized[2][0] - normalized[1][0] * normalized[2][2]) / det / scale;
    inverse[1][1] = (normalized[0][0] * normalized[2][2] - normalized[0][2] * normalized[2][0]) / det / scale;
    inverse[1][2] = (normalized[0][2] * normalized[1][0] - normalized[0][0] * normalized[1][2]) / det / scale;
    inverse[2][0] = (normalized[1][0] * normalized[2][1] - normalized[1][1] * normalized[2][0]) / det / scale;
    inverse[2][1] = (normalized[0][1] * normalized[2][0] - normalized[0][0] * normalized[2][1]) / det / scale;
    inverse[2][2] = (normalized[0][0] * normalized[1][1] - normalized[0][1] * normalized[1][0]) / det / scale;
    return finite_matrix(&inverse[0][0], 9);
}

static void multiply_matrix(double destination[3][3],
                            double const lhs[3][3],
                            double const rhs[3][3]) {
    double product[3][3];
    int i, j, k;
    for (i = 0; i < 3; i++) {
        for (j = 0; j < 3; j++) {
            product[i][j] = 0.0;
            for (k = 0; k < 3; k++) {
                product[i][j] += lhs[i][k] * rhs[k][j];
            }
        }
    }
    memcpy(destination, product, sizeof(product));
}

static void multiply_matrix_vector(double destination[3],
                                   double const matrix[3][3],
                                   double const vector[3]) {
    double product[3];
    int i, j;
    for (i = 0; i < 3; i++) {
        product[i] = 0.0;
        for (j = 0; j < 3; j++) product[i] += matrix[i][j] * vector[j];
    }
    memcpy(destination, product, sizeof(product));
}

static void copy_matrix(double destination[9], double const source[3][3]) {
    size_t i;
    for (i = 0; i < 9; i++) destination[i] = source[i / 3][i % 3];
}

static void copy_lattice_rows(double destination[9], double const source[3][3]) {
    int basis, component;
    for (basis = 0; basis < 3; basis++) {
        for (component = 0; component < 3; component++) {
            destination[basis * 3 + component] = source[component][basis];
        }
    }
}

static int copy_ints(int32_t **destination, int const *source, size_t count) {
    size_t bytes;
    size_t i;
    if (count == 0) return 1;
    if (source == NULL || !checked_count(count, sizeof(int32_t), &bytes)) return 0;
    *destination = (int32_t *)malloc(bytes);
    if (*destination == NULL) return 0;
    for (i = 0; i < count; i++) (*destination)[i] = (int32_t)source[i];
    return 1;
}

static int copy_rotations(int32_t **destination, int const (*source)[3][3], size_t count) {
    size_t bytes;
    size_t i;
    if (count == 0) return 1;
    if (source == NULL || count > SIZE_MAX / 9 ||
        !checked_count(count * 9, sizeof(int32_t), &bytes)) return 0;
    *destination = (int32_t *)malloc(bytes);
    if (*destination == NULL) return 0;
    for (i = 0; i < count; i++) {
        size_t j;
        for (j = 0; j < 9; j++) (*destination)[i * 9 + j] = (int32_t)source[i][j / 3][j % 3];
    }
    return 1;
}

static int copy_translations(double **destination, double const (*source)[3], size_t count) {
    size_t bytes;
    if (count == 0) return 1;
    if (source == NULL || count > SIZE_MAX / 3 ||
        !checked_count(count * 3, sizeof(double), &bytes)) return 0;
    *destination = (double *)malloc(bytes);
    if (*destination == NULL) return 0;
    memcpy(*destination, source, bytes);
    return 1;
}

static int copy_positions(double **destination, double const (*source)[3], size_t count) {
    size_t bytes;
    if (count == 0) return 1;
    if (source == NULL || count > SIZE_MAX / 3 ||
        !checked_count(count * 3, sizeof(double), &bytes)) return 0;
    *destination = (double *)malloc(bytes);
    if (*destination == NULL) return 0;
    memcpy(*destination, source, bytes);
    return 1;
}

static int copy_site_symbols(char **destination, char const (*source)[7], size_t count) {
    size_t bytes;
    if (count == 0) return 1;
    if (source == NULL || !checked_count(count, sizeof(source[0]), &bytes)) return 0;
    *destination = (char *)malloc(bytes);
    if (*destination == NULL) return 0;
    memcpy(*destination, source, bytes);
    return 1;
}

void molenv_spglib_result_free(MolEnvSpglibResult *result) {
    if (result == NULL) return;
    free(result->international_symbol);
    free(result->hall_symbol);
    free(result->choice);
    free(result->pointgroup_symbol);
    free(result->rotations);
    free(result->translations);
    free(result->wyckoffs);
    free(result->site_symmetry_symbols);
    free(result->equivalent_atoms);
    free(result->crystallographic_orbits);
    free(result->mapping_to_primitive);
    free(result->primitive_types);
    free(result->primitive_positions);
    free(result->std_types);
    free(result->std_positions);
    free(result->std_mapping_to_primitive);
    free(result);
}

static char *copy_string_n(const char *source, size_t maximum_length) {
    size_t length = 0;
    char *copy;
    if (source == NULL) return NULL;
    while (length < maximum_length && source[length] != '\0') length++;
    copy = (char *)malloc(length + 1);
    if (copy == NULL) return NULL;
    memcpy(copy, source, length);
    copy[length] = '\0';
    return copy;
}

static double wrap_fractional(double value);

static MolEnvSpglibStatus copy_dataset(MolEnvSpglibResult *result,
                                        SpglibDataset const *dataset,
                                        double const lattice[3][3],
                                        double const positions[],
                                        int const types[],
                                        int32_t num_atoms) {
    double primitive_inverse[3][3];
    double input_to_primitive[3][3];
    double transformation_inverse[3][3];
    double preidealized_bravais[3][3];
    double (*primitive_positions)[3] = NULL;
    int *primitive_types = NULL;
    unsigned char *primitive_seen = NULL;
    int primitive_count = 0;
    MolEnvSpglibStatus status = MOLENV_SPGLIB_OK;
    size_t i;
    size_t bytes;

    if (dataset == NULL || result == NULL || positions == NULL || types == NULL) {
        set_error("missing spglib dataset data");
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }
    if (dataset->n_operations < 0 || dataset->n_operations > MOLENV_SPGLIB_MAX_OPERATIONS ||
        dataset->n_atoms != num_atoms || dataset->n_atoms <= 0 || dataset->n_std_atoms <= 0 ||
        dataset->n_std_atoms > MOLENV_SPGLIB_MAX_STANDARD_ATOMS) {
        set_error("spglib returned invalid dataset sizes");
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }
    if (dataset->mapping_to_primitive == NULL ||
        !finite_matrix(&dataset->primitive_lattice[0][0], 9) ||
        !invert_matrix(primitive_inverse, dataset->primitive_lattice) ||
        !finite_matrix(&dataset->transformation_matrix[0][0], 9) ||
        !invert_matrix(transformation_inverse, dataset->transformation_matrix) ||
        !finite_matrix(&dataset->origin_shift[0], 3) ||
        !finite_matrix(&dataset->std_lattice[0][0], 9) ||
        !finite_matrix(&dataset->std_rotation_matrix[0][0], 9)) {
        set_error("spglib returned non-finite or singular lattice data");
        return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
    }

    for (i = 0; i < (size_t)num_atoms; i++) {
        int mapped = dataset->mapping_to_primitive[i];
        if (mapped < 0 || mapped >= num_atoms) {
            set_error("spglib returned an out-of-range primitive mapping");
            return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
        }
        if (mapped + 1 > primitive_count) primitive_count = mapped + 1;
    }
    if (primitive_count <= 0 || primitive_count > num_atoms ||
        ((int)num_atoms % primitive_count) != 0) {
        set_error("spglib returned an incomplete primitive mapping");
        return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
    }
    if (dataset->std_mapping_to_primitive == NULL) {
        set_error("spglib returned a missing standardized primitive mapping");
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }
    for (i = 0; i < (size_t)dataset->n_std_atoms; i++) {
        int mapped = dataset->std_mapping_to_primitive[i];
        if (mapped < 0 || mapped >= primitive_count) {
            set_error("spglib returned an out-of-range standardized primitive mapping");
            return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
        }
    }

    if (!checked_count((size_t)primitive_count, sizeof(*primitive_types), &bytes) ||
        !checked_count((size_t)primitive_count, sizeof(*primitive_positions), &bytes)) {
        set_error("primitive result allocation size overflow");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }

    result->spacegroup_number = (int32_t)dataset->spacegroup_number;
    result->hall_number = (int32_t)dataset->hall_number;
    result->international_symbol = copy_string_n(dataset->international_symbol,
                                                  sizeof(dataset->international_symbol));
    result->hall_symbol = copy_string_n(dataset->hall_symbol,
                                        sizeof(dataset->hall_symbol));
    result->choice = copy_string_n(dataset->choice, sizeof(dataset->choice));
    result->pointgroup_symbol = copy_string_n(dataset->pointgroup_symbol,
                                              sizeof(dataset->pointgroup_symbol));
    if (result->international_symbol == NULL || result->hall_symbol == NULL ||
        result->choice == NULL || result->pointgroup_symbol == NULL) {
        set_error("could not copy spglib symbols");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }
    copy_matrix(result->transformation_matrix, dataset->transformation_matrix);
    memcpy(result->origin_shift, dataset->origin_shift, sizeof(result->origin_shift));
    copy_lattice_rows(result->input_lattice, lattice);
    copy_lattice_rows(result->detected_primitive_lattice, dataset->primitive_lattice);
    copy_lattice_rows(result->standardized_lattice, dataset->std_lattice);
    copy_matrix(result->standardized_rotation_matrix, dataset->std_rotation_matrix);
    multiply_matrix(preidealized_bravais, lattice, transformation_inverse);
    if (!finite_matrix(&preidealized_bravais[0][0], 9)) {
        set_error("spglib transformation produced a non-finite Bravais lattice");
        return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
    }
    copy_lattice_rows(result->preidealized_bravais_lattice, preidealized_bravais);

    result->n_operations = (int32_t)dataset->n_operations;
    result->n_atoms = (int32_t)dataset->n_atoms;
    result->n_std_atoms = (int32_t)dataset->n_std_atoms;
    if (!copy_rotations(&result->rotations, dataset->rotations, (size_t)dataset->n_operations) ||
        !copy_translations(&result->translations, dataset->translations, (size_t)dataset->n_operations) ||
        !copy_ints(&result->wyckoffs, dataset->wyckoffs, (size_t)dataset->n_atoms) ||
        !copy_site_symbols(&result->site_symmetry_symbols, dataset->site_symmetry_symbols,
                           (size_t)dataset->n_atoms) ||
        !copy_ints(&result->equivalent_atoms, dataset->equivalent_atoms, (size_t)dataset->n_atoms) ||
        !copy_ints(&result->crystallographic_orbits, dataset->crystallographic_orbits,
                   (size_t)dataset->n_atoms) ||
        !copy_ints(&result->mapping_to_primitive, dataset->mapping_to_primitive,
                   (size_t)dataset->n_atoms) ||
        !copy_ints(&result->std_types, dataset->std_types, (size_t)dataset->n_std_atoms) ||
        !copy_positions(&result->std_positions, dataset->std_positions,
                        (size_t)dataset->n_std_atoms) ||
        !copy_ints(&result->std_mapping_to_primitive, dataset->std_mapping_to_primitive,
                   (size_t)dataset->n_std_atoms)) {
        set_error("could not copy spglib dataset arrays");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }

    primitive_positions = (double (*)[3])calloc((size_t)primitive_count,
                                                 sizeof(*primitive_positions));
    primitive_types = (int *)calloc((size_t)primitive_count, sizeof(*primitive_types));
    primitive_seen = (unsigned char *)calloc((size_t)primitive_count,
                                              sizeof(*primitive_seen));
    if (primitive_positions == NULL || primitive_types == NULL || primitive_seen == NULL) {
        set_error("could not allocate primitive representation buffers");
        status = MOLENV_SPGLIB_ALLOCATION_FAILED;
        goto primitive_cleanup;
    }
    multiply_matrix(input_to_primitive, primitive_inverse, lattice);
    if (!finite_matrix(&input_to_primitive[0][0], 9)) {
        set_error("primitive coordinate transformation is non-finite");
        status = MOLENV_SPGLIB_STANDARDIZATION_FAILED;
        goto primitive_cleanup;
    }
    for (i = 0; i < (size_t)num_atoms; i++) {
        int mapped = dataset->mapping_to_primitive[i];
        double primitive_position[3];
        if (primitive_seen[mapped] == 0) {
            multiply_matrix_vector(primitive_position, input_to_primitive,
                                   &positions[i * 3]);
            if (!finite_matrix(primitive_position, 3)) {
                set_error("primitive representative position is non-finite");
                status = MOLENV_SPGLIB_STANDARDIZATION_FAILED;
                goto primitive_cleanup;
            }
            primitive_positions[mapped][0] = wrap_fractional(primitive_position[0]);
            primitive_positions[mapped][1] = wrap_fractional(primitive_position[1]);
            primitive_positions[mapped][2] = wrap_fractional(primitive_position[2]);
            primitive_types[mapped] = (int)types[i];
            primitive_seen[mapped] = 1;
        } else if (primitive_types[mapped] != (int)types[i]) {
            set_error("spglib primitive mapping mixes atomic types");
            status = MOLENV_SPGLIB_STANDARDIZATION_FAILED;
            goto primitive_cleanup;
        }
    }
    for (i = 0; i < (size_t)primitive_count; i++) {
        if (primitive_seen[i] == 0) {
            set_error("spglib primitive mapping does not cover every index");
            status = MOLENV_SPGLIB_STANDARDIZATION_FAILED;
            goto primitive_cleanup;
        }
    }

    result->n_primitive_atoms = (int32_t)primitive_count;
    if (!copy_ints(&result->primitive_types, primitive_types, (size_t)primitive_count) ||
        !copy_positions(&result->primitive_positions, primitive_positions,
                        (size_t)primitive_count)) {
        set_error("could not copy primitive dataset representation");
        status = MOLENV_SPGLIB_ALLOCATION_FAILED;
    }

primitive_cleanup:
    free(primitive_seen);
    free(primitive_positions);
    free(primitive_types);
    return status;
}

static double wrap_fractional(double value) {
    double wrapped = fmod(value, 1.0);
    if (wrapped < 0.0) wrapped += 1.0;
    if (wrapped == 1.0 || wrapped == -0.0) wrapped = 0.0;
    return wrapped;
}

static int nonsingular(double const lattice[3][3]) {
    double scale = 0.0;
    double normalized[3][3];
    int i, j;
    for (i = 0; i < 3; i++) {
        for (j = 0; j < 3; j++) scale = fmax(scale, fabs(lattice[i][j]));
    }
    if (!isfinite(scale) || scale == 0.0) return 0;
    for (i = 0; i < 3; i++) {
        for (j = 0; j < 3; j++) normalized[i][j] = lattice[i][j] / scale;
    }
    return isfinite(determinant(normalized)) && fabs(determinant(normalized)) > 1e-12;
}

MolEnvSpglibStatus molenv_spglib_analyze(const double lattice_rows[9],
                                         const double positions[],
                                         const int32_t types[],
                                         int32_t num_atoms,
                                         double symprec,
                                         MolEnvSpglibResult **out_result) {
    double lattice[3][3];
    double (*wrapped_positions)[3] = NULL;
    int *spglib_types = NULL;
    SpglibDataset *dataset = NULL;
    MolEnvSpglibResult *result = NULL;
    size_t position_bytes;
    size_t type_bytes;
    int i;

    molenv_spglib_error[0] = '\0';
    if (out_result == NULL) {
        set_error("missing output pointer");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    *out_result = NULL;
    if (lattice_rows == NULL || positions == NULL || types == NULL ||
        num_atoms <= 0 || num_atoms > MOLENV_SPGLIB_MAX_ATOMS) {
        set_error("invalid symmetry input");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (!isfinite(symprec) || symprec < MOLENV_SPGLIB_MIN_SYMPREC ||
        symprec > MOLENV_SPGLIB_MAX_SYMPREC) {
        set_error("symmetry tolerance must be in [1e-8, 1e-1] Angstrom");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (!finite_matrix(lattice_rows, 9)) {
        set_error("invalid symmetry lattice");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    for (i = 0; i < num_atoms; i++) {
        if (!finite_matrix(&positions[i * 3], 3) || types[i] <= 0) {
            set_error("invalid atom position or type");
            return MOLENV_SPGLIB_INVALID_ARGUMENT;
        }
    }
    /* Input is [a,b,c] rows; spglib C stores the same basis vectors as
       columns: lattice[cartesian_component][basis_vector]. */
    for (i = 0; i < 3; i++) {
        lattice[0][i] = lattice_rows[i * 3 + 0];
        lattice[1][i] = lattice_rows[i * 3 + 1];
        lattice[2][i] = lattice_rows[i * 3 + 2];
    }
    if (!nonsingular(lattice)) {
        set_error("cell is singular or numerically degenerate");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }

    if (!checked_count((size_t)num_atoms, sizeof(*wrapped_positions), &position_bytes) ||
        !checked_count((size_t)num_atoms, sizeof(*spglib_types), &type_bytes)) {
        set_error("symmetry input allocation size overflow");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }
    wrapped_positions = (double (*)[3])calloc(1, position_bytes);
    spglib_types = (int *)calloc(1, type_bytes);
    if (wrapped_positions == NULL || spglib_types == NULL) {
        free(wrapped_positions);
        free(spglib_types);
        set_error("could not allocate symmetry input buffers");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }
    for (i = 0; i < num_atoms; i++) {
        wrapped_positions[i][0] = wrap_fractional(positions[i * 3 + 0]);
        wrapped_positions[i][1] = wrap_fractional(positions[i * 3 + 1]);
        wrapped_positions[i][2] = wrap_fractional(positions[i * 3 + 2]);
        spglib_types[i] = (int)types[i];
    }

    dataset = spg_get_dataset(lattice, wrapped_positions, spglib_types,
                              (int)num_atoms, symprec);
    if (dataset == NULL) {
        set_spglib_error("space-group search failed");
        free(wrapped_positions);
        free(spglib_types);
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }
    result = (MolEnvSpglibResult *)calloc(1, sizeof(*result));
    if (result == NULL) {
        spg_free_dataset(dataset);
        free(wrapped_positions);
        free(spglib_types);
        set_error("could not allocate symmetry result");
        return MOLENV_SPGLIB_ALLOCATION_FAILED;
    }
    {
        MolEnvSpglibStatus status = copy_dataset(result, dataset, lattice, &wrapped_positions[0][0],
                                                   spglib_types, num_atoms);
        spg_free_dataset(dataset);
        dataset = NULL;
        free(wrapped_positions);
        free(spglib_types);
        if (status != MOLENV_SPGLIB_OK) {
            molenv_spglib_result_free(result);
            return status;
        }
    }
    *out_result = result;
    return MOLENV_SPGLIB_OK;
}

/* CRYSCAL commonly writes short Hermann–Mauguin symbols with spaces and
   omits punctuation such as the minus sign in `F M 3 M` for Fm-3m. Only the
   punctuation that is conventional in these symbols is ignored; every other
   non-ASCII character is rejected. The database comparison below decides
   whether the resulting alias is unique, rather than inferring a group from
   its letter/digit pattern. */
static int normalize_international_symbol(const char *source,
                                          char destination[MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY]) {
    size_t output_length = 0;
    size_t i;
    int has_symbol_character = 0;

    if (source == NULL) return 0;
    for (i = 0; source[i] != '\0'; i++) {
        unsigned char character = (unsigned char)source[i];
        if (character == ' ' || character == '\t' || character == '\r' ||
            character == '\n' || character == '\f' || character == '\v' ||
            character == '-' || character == '_' || character == '/') {
            continue;
        }
        if (character >= 'a' && character <= 'z') {
            character = (unsigned char)(character - ('a' - 'A'));
        } else if (!((character >= 'A' && character <= 'Z') ||
                     (character >= '0' && character <= '9'))) {
            return 0;
        }
        if (output_length + 1 >= MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY) {
            return 0;
        }
        destination[output_length++] = (char)character;
        has_symbol_character = 1;
    }
    if (!has_symbol_character) return 0;
    destination[output_length] = '\0';
    return 1;
}

static int normalized_symbol_matches(const char *normalized_input,
                                     const char *candidate) {
    char normalized_candidate[MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY];
    return normalize_international_symbol(candidate, normalized_candidate) &&
           strcmp(normalized_input, normalized_candidate) == 0;
}

MolEnvSpglibStatus molenv_spglib_operations_with_symbol(
    int32_t spacegroup_number, const char *symbol, int32_t rotations[],
    double translations[], int32_t max_operations, int32_t *out_operations);

MolEnvSpglibStatus molenv_spglib_spacegroup_number(const char *symbol,
                                                   int32_t *out_spacegroup_number) {
    char normalized_symbol[MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY];
    int matched_spacegroup = 0;
    int ambiguous = 0;
    int hall;

    molenv_spglib_error[0] = '\0';
    if (out_spacegroup_number == NULL) {
        set_error("missing space-group output number");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    *out_spacegroup_number = 0;
    /* Unknown or malformed symbols intentionally resolve to zero without an
       error: the CRYSCAL caller must leave such input symmetry-incomplete. */
    if (!normalize_international_symbol(symbol, normalized_symbol)) {
        return MOLENV_SPGLIB_OK;
    }

    /* Search every Hall setting and every international-symbol spelling in the
       vendored database across all 230 space groups. Multiple settings for
       one group are harmless; an alias that reaches different international
       numbers is not accepted. */
    for (hall = 1; hall <= MOLENV_SPGLIB_LAST_HALL_NUMBER; hall++) {
        SpglibSpacegroupType type = spg_get_spacegroup_type(hall);
        const char *candidates[3] = {
            type.international_short,
            type.international,
            type.international_full
        };
        int candidate_index;
        if (type.number <= 0) continue;
        for (candidate_index = 0; candidate_index < 3; candidate_index++) {
            if (!normalized_symbol_matches(normalized_symbol, candidates[candidate_index])) {
                continue;
            }
            if (matched_spacegroup == 0) {
                matched_spacegroup = type.number;
            } else if (matched_spacegroup != type.number) {
                ambiguous = 1;
            }
        }
    }
    if (!ambiguous && matched_spacegroup >= 1 &&
        matched_spacegroup <= MOLENV_SPGLIB_LAST_SPACEGROUP) {
        *out_spacegroup_number = (int32_t)matched_spacegroup;
    }
    return MOLENV_SPGLIB_OK;
}

/* Infer the lattice system from a space group number using the standard
   International Tables ranges. */
static int lattice_system_rhombohedral(int spacegroup_number) {
    switch (spacegroup_number) {
        case 146: case 148: case 155: case 160:
        case 161: case 166: case 167:
            return 1;
        default:
            return 0;
    }
}

static int lattice_system_monoclinic(int spacegroup_number) {
    return spacegroup_number >= 3 && spacegroup_number <= 15;
}

/* Select a Hall setting compatible with parser lattice conventions.
   Rhombohedral R groups use the hexagonal H choice, monoclinic groups
   (3–15) use the unique-b choice, and others use the canonical lowest Hall
   number. When `symbol` is non-NULL, the selected Hall setting's own
   normalized symbol must match it; otherwise the choice fails safely. */
int32_t molenv_spglib_select_hall_number(int32_t spacegroup_number,
                                         const char *symbol) {
    char normalized_symbol[MOLENV_SPGLIB_NORMALIZED_SYMBOL_CAPACITY];
    int want_h = 0;
    int want_unique_b = 0;
    int first_hall = 0;
    int best_hall = 0;
    int hall;

    molenv_spglib_error[0] = '\0';
    if (spacegroup_number < 1 || spacegroup_number > MOLENV_SPGLIB_LAST_SPACEGROUP) {
        set_error("space-group number out of range");
        return 0;
    }

    want_h = lattice_system_rhombohedral(spacegroup_number);
    want_unique_b = lattice_system_monoclinic(spacegroup_number);

    /* If a symbol was supplied, the selected Hall setting must match it. */
    int have_symbol = 0;
    if (symbol != NULL) {
        have_symbol = normalize_international_symbol(symbol, normalized_symbol);
    }

    for (hall = 1; hall <= MOLENV_SPGLIB_LAST_HALL_NUMBER; hall++) {
        SpglibSpacegroupType type = spg_get_spacegroup_type(hall);
        if (type.number != spacegroup_number) continue;

        if (first_hall == 0) first_hall = hall;

        /* Enforce symbol compatibility when a symbol was given. */
        if (have_symbol) {
            const char *candidates[3] = {
                type.international_short,
                type.international,
                type.international_full
            };
            int matches = 0;
            for (int c = 0; c < 3; c++) {
                if (normalized_symbol_matches(normalized_symbol, candidates[c])) {
                    matches = 1;
                    break;
                }
            }
            if (!matches) continue;
        }

        /* Rhombohedral R groups: require the hexagonal H choice. */
        if (want_h) {
            if (type.choice[0] == 'H') {
                best_hall = hall;
                break;
            }
            continue;
        }

        /* Monoclinic: every choice beginning with 'b' uses the parser's
           unique-b convention. Suffixes select cell/origin variants while
           preserving that unique axis; prefer the first compatible one. */
        if (want_unique_b) {
            if (type.choice[0] == 'b') {
                best_hall = hall;
                break;
            }
            continue;
        }

        /* Others: canonical lowest Hall number wins. */
        best_hall = hall;
        break;
    }

    if (best_hall == 0) {
        if (want_h) {
            set_error("space group has no hexagonal Hall setting compatible with CRYSCAL");
        } else if (want_unique_b) {
            set_error("space group has no unique-b Hall setting compatible with CRYSCAL");
        } else if (first_hall == 0) {
            set_error("space group is absent from the spglib database");
        } else {
            set_error("space group has no Hall setting compatible with CRYSCAL");
        }
        return 0;
    }
    return (int32_t)best_hall;
}

MolEnvSpglibStatus molenv_spglib_operations(int32_t spacegroup_number,
                                            int32_t rotations[],
                                            double translations[],
                                            int32_t max_operations,
                                            int32_t *out_operations) {
    return molenv_spglib_operations_with_symbol(spacegroup_number, NULL, rotations,
                                                translations, max_operations,
                                                out_operations);
}

/* Core operation lookup with optional symbol-selected Hall setting.
   When `symbol` is non-NULL, the Hall setting must match the symbol
   (via molenv_spglib_select_hall_number); otherwise the plain
   convention-based Hall selection is used. */
MolEnvSpglibStatus molenv_spglib_operations_with_symbol(int32_t spacegroup_number,
                                                       const char *symbol,
                                                       int32_t rotations[],
                                                       double translations[],
                                                       int32_t max_operations,
                                                       int32_t *out_operations) {
    int hall_number;
    int database_rotations[192][3][3];
    double database_translations[192][3];
    int operation_count;
    int i;
    int j;

    molenv_spglib_error[0] = '\0';
    if (out_operations == NULL) {
        set_error("missing operation output count");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    *out_operations = 0;
    if (spacegroup_number < 1 || spacegroup_number > MOLENV_SPGLIB_LAST_SPACEGROUP) {
        set_error("operation lookup requires space-group number 1 through 230");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (max_operations <= 0 || max_operations > 192 || rotations == NULL ||
        translations == NULL) {
        set_error("invalid operation output buffers");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }

    hall_number = (int)molenv_spglib_select_hall_number(spacegroup_number, symbol);
    if (hall_number == 0) {
        /* Error message already set by molenv_spglib_select_hall_number. */
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }

    operation_count = spg_get_symmetry_from_database(database_rotations,
                                                       database_translations,
                                                       hall_number);
    if (operation_count <= 0 || operation_count > 192) {
        set_error("spglib returned an invalid operation count");
        return MOLENV_SPGLIB_SEARCH_FAILED;
    }
    if (operation_count > max_operations) {
        set_error("operation output capacity is too small");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    for (i = 0; i < operation_count; i++) {
        for (j = 0; j < 9; j++) {
            rotations[i * 9 + j] = (int32_t)database_rotations[i][j / 3][j % 3];
        }
        for (j = 0; j < 3; j++) {
            if (!isfinite(database_translations[i][j])) {
                set_error("spglib returned a non-finite operation translation");
                return MOLENV_SPGLIB_SEARCH_FAILED;
            }
            translations[i * 3 + j] = database_translations[i][j];
        }
    }
    *out_operations = (int32_t)operation_count;
    return MOLENV_SPGLIB_OK;
}

MolEnvSpglibStatus molenv_spglib_niggli_reduce(double lattice_rows[9],
                                               double symprec) {
    double lattice[3][3];
    int i;

    molenv_spglib_error[0] = '\0';
    if (lattice_rows == NULL) {
        set_error("missing Niggli lattice pointer");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (!finite_matrix(lattice_rows, 9)) {
        set_error("Niggli lattice contains non-finite values");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (!isfinite(symprec) || symprec < MOLENV_SPGLIB_MIN_SYMPREC ||
        symprec > MOLENV_SPGLIB_MAX_SYMPREC) {
        set_error("Niggli tolerance must be in [1e-8, 1e-1]");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    /* Input is [a,b,c] rows; niggli_reduce expects column-major
       lattice[3][3] where lattice[cartesian][basis]. */
    for (i = 0; i < 3; i++) {
        lattice[0][i] = lattice_rows[i * 3 + 0];
        lattice[1][i] = lattice_rows[i * 3 + 1];
        lattice[2][i] = lattice_rows[i * 3 + 2];
    }
    if (!nonsingular(lattice)) {
        set_error("Niggli lattice is singular");
        return MOLENV_SPGLIB_INVALID_ARGUMENT;
    }
    if (!niggli_reduce(&lattice[0][0], symprec, -1)) {
        set_error("Niggli reduction failed");
        return MOLENV_SPGLIB_STANDARDIZATION_FAILED;
    }
    /* Copy back to row-major. */
    for (i = 0; i < 3; i++) {
        lattice_rows[i * 3 + 0] = lattice[0][i];
        lattice_rows[i * 3 + 1] = lattice[1][i];
        lattice_rows[i * 3 + 2] = lattice[2][i];
    }
    return MOLENV_SPGLIB_OK;
}
