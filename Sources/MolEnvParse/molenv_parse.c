#include "molenv_parse.h"
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifndef PI
#define PI 3.14159265358979323846
#endif

static __thread char last_error[512];

const char* molenv_last_error(void) { return last_error; }

static void set_error(const char *path, int line, const char *reason) {
    if (line > 0) snprintf(last_error, sizeof(last_error), "%s:%d: %s", path, line, reason);
    else          snprintf(last_error, sizeof(last_error), "%s: %s", path, reason);
}

/* True only if `x` is a finite double that still fits a float. sscanf %lf can
   parse a value like 1e39 (finite, within DBL_RANGE) that overflows to +inf on a
   (float) cast — an isfinite() check alone would let that non-finite float into
   the scene. Guard the cast the same way a human would inspect a value. */
static int in_float_range(double x) {
    return isfinite(x) && x >= -FLT_MAX && x <= FLT_MAX;
}

void molenv_grid_free(MolEnvGrid *g) {
    if (!g) return;
    free(g->values);
}

void molenv_scene_free(MolEnvScene *s) {
    if (!s) return;
    free(s->atoms);
    free(s->bonds);
    molenv_grid_free(s->grid);
    free(s->grid);
    free(s);
}

static MolEnvScene* new_scene(const char *path) {
    MolEnvScene *s = calloc(1, sizeof(MolEnvScene));
    if (!s) { set_error(path, 0, "out of memory"); return NULL; }
    s->periodic_dim = 3;
    return s;
}

/* Symbol -> atomic number (H..Og, Z=1..118). C-local table; returns 0 if not
   found. molenv_symbol_to_z() compares up to 3 chars, so every standard symbol
   (all 1-2 letters) matches unambiguously. */
static const struct { const char* sym; int z; } el[] = {
  {"H",1},{"He",2},{"Li",3},{"Be",4},{"B",5},{"C",6},{"N",7},{"O",8},
  {"F",9},{"Ne",10},{"Na",11},{"Mg",12},{"Al",13},{"Si",14},{"P",15},
  {"S",16},{"Cl",17},{"Ar",18},{"K",19},{"Ca",20},{"Sc",21},{"Ti",22},
  {"V",23},{"Cr",24},{"Mn",25},{"Fe",26},{"Co",27},{"Ni",28},{"Cu",29},
  {"Zn",30},{"Ga",31},{"Ge",32},{"As",33},{"Se",34},{"Br",35},{"Kr",36},
  {"Rb",37},{"Sr",38},{"Y",39},{"Zr",40},{"Nb",41},{"Mo",42},{"Tc",43},
  {"Ru",44},{"Rh",45},{"Pd",46},{"Ag",47},{"Cd",48},{"In",49},{"Sn",50},
  {"Sb",51},{"Te",52},{"I",53},{"Xe",54},{"Cs",55},{"Ba",56},{"La",57},
  {"Ce",58},{"Pr",59},{"Nd",60},{"Pm",61},{"Sm",62},{"Eu",63},{"Gd",64},
  {"Tb",65},{"Dy",66},{"Ho",67},{"Er",68},{"Tm",69},{"Yb",70},{"Lu",71},
  {"Hf",72},{"Ta",73},{"W",74},{"Re",75},{"Os",76},{"Ir",77},{"Pt",78},
  {"Au",79},{"Hg",80},{"Tl",81},{"Pb",82},{"Bi",83},{"Po",84},{"At",85},
  {"Rn",86},{"Fr",87},{"Ra",88},{"Ac",89},{"Th",90},{"Pa",91},{"U",92},
  {"Np",93},{"Pu",94},{"Am",95},{"Cm",96},{"Bk",97},{"Cf",98},{"Es",99},
  {"Fm",100},{"Md",101},{"No",102},{"Lr",103},{"Rf",104},{"Db",105},
  {"Sg",106},{"Bh",107},{"Hs",108},{"Mt",109},{"Ds",110},{"Rg",111},
  {"Cn",112},{"Nh",113},{"Fl",114},{"Mc",115},{"Lv",116},{"Ts",117},
  {"Og",118}
};
static int molenv_symbol_to_z(const char *s) {
    /* Fold the input to lowercase (ASCII only) so "Fe"/"fe"/"FE" all match.
       The stored tables are title-cased ("Fe"); lowercase each on the fly for
       comparison without modifying them. */
    char t[4]={0}; for(int i=0;i<3 && s[i]; i++) t[i]=tolower((unsigned char)s[i]);
    for (size_t i=0;i<sizeof(el)/sizeof(el[0]);i++) {
        char u[4]={0};
        for (int j=0;j<3 && el[i].sym[j];j++) u[j]=tolower((unsigned char)el[i].sym[j]);
        if (strcmp(t,u)==0) return el[i].z;
    }
    return 0;
}

/* Covalent-radius bond heuristic, operating purely on a MolEnvScene. */
/* Scaled covalent radius for element z (thread-safe: no shared mutable state).
   Returns 1.05 * rcovdef[z] with a 0-fallback for z out of range, matching the
   old static cov[119] cache semantics without the data race. */
static float bond_rcov(int z) {
    static const float rcovdef[] = {
        0.38f, 0.38f, 0.38f, 1.23f, 0.89f, 0.91f,
        0.77f, 0.75f, 0.73f, 0.71f, 0.71f,
        1.60f, 1.40f, 1.25f, 1.11f, 1.00f,
        1.04f, 0.99f, 0.98f, 2.13f, 1.74f,
        1.60f, 1.40f, 1.35f, 1.40f, 1.40f,
        1.40f, 1.35f, 1.35f, 1.35f, 1.35f,
        1.30f, 1.25f, 1.15f, 1.15f, 1.14f,
        1.12f, 2.20f, 2.00f, 1.85f, 1.55f,
        1.45f, 1.45f, 1.35f, 1.30f, 1.35f,
        1.40f, 1.60f, 1.55f, 1.55f, 1.41f,
        1.45f, 1.40f, 1.40f, 1.31f, 2.60f,
        2.00f, 1.75f, 1.55f, 1.55f, 1.55f,
        1.55f, 1.55f, 1.55f, 1.55f, 1.55f,
        1.55f, 1.55f, 1.55f, 1.55f, 1.55f,
        1.55f, 1.55f, 1.45f, 1.35f, 1.35f,
        1.30f, 1.35f, 1.35f, 1.35f, 1.50f,
        1.90f, 1.80f, 1.60f, 1.55f, 1.55f,
        1.55f, 2.80f, 1.44f, 1.95f, 1.55f,
        1.55f, 1.55f, 1.55f, 1.55f, 1.55f,
        1.55f, 1.55f, 1.55f, 1.55f, 1.55f
    };
    int n = (int)(sizeof(rcovdef)/sizeof(rcovdef[0]));
    return (z >= 0 && z < n) ? 1.05f * rcovdef[z] : 0.0f;
}

static double det3d(const double m[3][3]) {
    return m[0][0]*(m[1][1]*m[2][2] - m[2][1]*m[1][2])
         - m[0][1]*(m[1][0]*m[2][2] - m[2][0]*m[1][2])
         + m[0][2]*(m[1][0]*m[2][1] - m[2][0]*m[1][1]);
}

/* Validate only the active periodic subspace. A slab/polymer may embed a
   rank-two/rank-one lattice in 3D, while a crystal/QE/POSCAR cell must be full
   rank. The tolerance is relative to the vector lengths so tiny valid cells
   and near-singular malformed cells are not confused. */
static int cell_rank_usable(const double cell[3][3], int periodic_dim) {
    if (periodic_dim <= 0) return 1;
    if (periodic_dim == 1) {
        double n = 0.0;
        for (int j = 0; j < 3; j++) n += cell[0][j] * cell[0][j];
        return isfinite(n) && n > 1e-30;
    }
    if (periodic_dim == 2) {
        double a2 = 0.0, b2 = 0.0, dot = 0.0;
        for (int j = 0; j < 3; j++) {
            a2 += cell[0][j] * cell[0][j];
            b2 += cell[1][j] * cell[1][j];
            dot += cell[0][j] * cell[1][j];
        }
        double gram_det = a2 * b2 - dot * dot;
        double scale = a2 * b2;
        return isfinite(gram_det) && isfinite(scale) && scale > 0.0 && gram_det > 1e-12 * scale;
    }
    double det = det3d(cell);
    double scale = 1.0;
    for (int i = 0; i < 3; i++) {
        double n = 0.0;
        for (int j = 0; j < 3; j++) n += cell[i][j] * cell[i][j];
        if (!isfinite(n) || n <= 0.0) return 0;
        scale *= sqrt(n);
    }
    return isfinite(det) && isfinite(scale) && scale > 0.0 && fabs(det) > 1e-12 * scale;
}

static int parse_bounded_long(const char *token, long minimum, long maximum, long *out) {
    errno = 0;
    char *end = NULL;
    long value = strtol(token, &end, 10);
    if (errno == ERANGE || end == token || *end != '\0' || value < minimum || value > maximum) return 0;
    *out = value;
    return 1;
}

#define MOLENV_BOND_MAX_ATOMS 8000
#define MOLENV_BOND_MAX_CAP 2000000     /* ~32 MB bond buffer ceiling */
#define MOLENV_BOND_MAX_DEGREE 128     /* per-atom degree cap */
#define MOLENV_BOND_SEARCH_LIMIT 100000

/* Pseudoinverse rows for the active periodic lattice vectors. A full 3D
   determinant is not required: polymer and slab cells intentionally have only
   one or two periodic vectors. */
typedef struct {
    int dim;
    double basis[3][3];
    double pinv[3][3];
    double row_norm[3];
} PeriodicBondBasis;

static int periodic_bond_basis_init(const MolEnvScene *s, PeriodicBondBasis *out) {
    memset(out, 0, sizeof(*out));
    int dim = s->periodic_dim;
    if (dim < 1 || dim > 3) return 0;
    out->dim = dim;
    for (int i = 0; i < dim; i++) {
        for (int j = 0; j < 3; j++) {
            double value = (double)s->cell[i][j];
            if (!isfinite(value)) return -1;
            out->basis[i][j] = value;
        }
    }

    if (dim == 1) {
        double g = 0.0;
        for (int j = 0; j < 3; j++) g += out->basis[0][j] * out->basis[0][j];
        if (!isfinite(g) || g <= 1e-30) return -1;
        for (int j = 0; j < 3; j++) out->pinv[0][j] = out->basis[0][j] / g;
    } else if (dim == 2) {
        double g00 = 0.0, g01 = 0.0, g11 = 0.0;
        for (int j = 0; j < 3; j++) {
            g00 += out->basis[0][j] * out->basis[0][j];
            g01 += out->basis[0][j] * out->basis[1][j];
            g11 += out->basis[1][j] * out->basis[1][j];
        }
        double det = g00 * g11 - g01 * g01;
        double scale = g00 * g11;
        if (!isfinite(det) || !isfinite(scale) || scale <= 0.0 || det <= 1e-12 * scale) return -1;
        double i00 = g11 / det, i01 = -g01 / det, i11 = g00 / det;
        for (int j = 0; j < 3; j++) {
            out->pinv[0][j] = i00 * out->basis[0][j] + i01 * out->basis[1][j];
            out->pinv[1][j] = i01 * out->basis[0][j] + i11 * out->basis[1][j];
        }
    } else {
        double m[3][3];
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) m[i][j] = out->basis[i][j];
        double det = det3d(m);
        double scale = 1.0;
        for (int i = 0; i < 3; i++) {
            double length_sq = 0.0;
            for (int j = 0; j < 3; j++) length_sq += m[i][j] * m[i][j];
            if (!isfinite(length_sq) || length_sq <= 0.0) return -1;
            scale *= sqrt(length_sq);
        }
        if (!isfinite(det) || !isfinite(scale) || scale <= 0.0 || fabs(det) <= 1e-12 * scale) return -1;
        double inv[3][3];
        inv[0][0]=(m[1][1]*m[2][2]-m[2][1]*m[1][2])/det;
        inv[0][1]=(m[0][2]*m[2][1]-m[0][1]*m[2][2])/det;
        inv[0][2]=(m[0][1]*m[1][2]-m[0][2]*m[1][1])/det;
        inv[1][0]=(m[1][2]*m[2][0]-m[1][0]*m[2][2])/det;
        inv[1][1]=(m[0][0]*m[2][2]-m[0][2]*m[2][0])/det;
        inv[1][2]=(m[0][2]*m[1][0]-m[0][0]*m[1][2])/det;
        inv[2][0]=(m[1][0]*m[2][1]-m[1][1]*m[2][0])/det;
        inv[2][1]=(m[0][1]*m[2][0]-m[0][0]*m[2][1])/det;
        inv[2][2]=(m[0][0]*m[1][1]-m[0][1]*m[1][0])/det;
        /* B has lattice vectors as rows, so coefficient i is d dot inv[*][i]. */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) out->pinv[i][j] = inv[j][i];
    }

    for (int i = 0; i < dim; i++) {
        double norm_sq = 0.0;
        for (int j = 0; j < 3; j++) norm_sq += out->pinv[i][j] * out->pinv[i][j];
        if (!isfinite(norm_sq) || norm_sq <= 0.0) return -1;
        out->row_norm[i] = sqrt(norm_sq);
    }
    return 1;
}

/* Return whether a periodic image is within `tol` of d. The coefficient box
   is derived from the lattice pseudoinverse, so every possible image inside
   the threshold is enumerated exactly. A pathological box returns -1 rather
   than falling back to an approximate nearest-image calculation. */
static int periodic_bond_within(const PeriodicBondBasis *basis,
                                double dx, double dy, double dz, double tol) {
    double d[3] = {dx, dy, dz};
    if (!isfinite(dx) || !isfinite(dy) || !isfinite(dz) || !isfinite(tol) || tol < 0.0) return -1;
    double lo_d[3], hi_d[3];
    int64_t lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    int64_t total = 1;
    for (int i = 0; i < basis->dim; i++) {
        double center = d[0] * basis->pinv[i][0] +
                        d[1] * basis->pinv[i][1] +
                        d[2] * basis->pinv[i][2];
        double bound = tol * basis->row_norm[i];
        if (!isfinite(center) || !isfinite(bound) || center < -1e15 || center > 1e15) return -1;
        lo_d[i] = ceil(center - bound - 1e-12);
        hi_d[i] = floor(center + bound + 1e-12);
        if (!isfinite(lo_d[i]) || !isfinite(hi_d[i]) ||
            lo_d[i] < -1e15 || hi_d[i] > 1e15 || hi_d[i] < lo_d[i]) return 0;
        lo[i] = (int64_t)lo_d[i];
        hi[i] = (int64_t)hi_d[i];
        int64_t span = hi[i] - lo[i] + 1;
        if (span <= 0 || total > MOLENV_BOND_SEARCH_LIMIT / span) return -1;
        total *= span;
    }

    double tol_sq = tol * tol;
    if (!isfinite(tol_sq)) return -1;
    int64_t n[3] = {lo[0], lo[1], lo[2]};
    for (int64_t attempt = 0; attempt < total; attempt++) {
        double cx = d[0], cy = d[1], cz = d[2];
        for (int i = 0; i < basis->dim; i++) {
            double coefficient = (double)n[i];
            cx -= coefficient * basis->basis[i][0];
            cy -= coefficient * basis->basis[i][1];
            cz -= coefficient * basis->basis[i][2];
        }
        double distance_sq = cx * cx + cy * cy + cz * cz;
        if (isfinite(distance_sq) && distance_sq <= tol_sq) return 1;

        for (int i = 0; i < basis->dim; i++) {
            if (n[i] < hi[i]) {
                n[i]++;
                break;
            }
            n[i] = lo[i];
        }
    }
    return 0;
}

static MolEnvBond* make_bonds(const MolEnvScene *s, const char *path, float factor, int *out_nbonds) {
    /* Documented workload guard: the O(n^2) bond pass is skipped above this count
       (n^2/2 pair comparisons: 8000 atoms => ~32M, well under a second in C). A
       scene can still render (bonds == 0); bonds are recomputed on demand in
       Scene+Init if a smaller structure legitimately needs them. The guard reads
       natoms (an int) before dereferencing the atom buffer, so any size is refused
       promptly and never allocates. */
    if (!s || !out_nbonds || !isfinite(factor) || factor < 0.0f) {
        if (out_nbonds) *out_nbonds = 0;
        return NULL;
    }
    if (s->natoms < 0 || s->natoms > MOLENV_BOND_MAX_ATOMS) { set_error(path,0,"too many atoms for bond heuristic"); *out_nbonds=0; return NULL; }
    PeriodicBondBasis periodic_basis;
    int periodic_status = 0;
    if (s->is_crystal && s->periodic_dim >= 1) {
        periodic_status = periodic_bond_basis_init(s, &periodic_basis);
        if (periodic_status < 0) {
            set_error(path, 0, "invalid periodic cell for bond heuristic");
            *out_nbonds = 0;
            return NULL;
        }
    }
    int cap = s->natoms * 4, nb = 0;
    if (cap < 4) cap = 4;
    MolEnvBond *b = calloc((size_t)cap, sizeof(MolEnvBond));
    if (!b) { set_error(path,0,"out of memory"); *out_nbonds=0; return NULL; }
    int *degree = calloc((size_t)s->natoms, sizeof(int));
    if (!degree) { free(b); set_error(path,0,"out of memory"); *out_nbonds=0; return NULL; }

    const int do_periodic = periodic_status > 0;

    for (int i=0;i<s->natoms;i++) for (int j=i+1;j<s->natoms;j++) {
        int zi=s->atoms[i].atomic_number, zj=s->atoms[j].atomic_number;
        if (zi<=0 || zi>118 || zj<=0 || zj>118) continue;
        double r=(double)bond_rcov(zi)+(double)bond_rcov(zj);
        double tol = r * (double)factor;
        double rcut2=tol*tol;
        double dx=(double)s->atoms[i].coord[0]-(double)s->atoms[j].coord[0],
               dy=(double)s->atoms[i].coord[1]-(double)s->atoms[j].coord[1],
               dz=(double)s->atoms[i].coord[2]-(double)s->atoms[j].coord[2];
        if (!isfinite(dx) || !isfinite(dy) || !isfinite(dz) || !isfinite(rcut2)) {
            free(degree); free(b); set_error(path,0,"non-finite atom coordinate in bond heuristic"); *out_nbonds=0; return NULL;
        }

        int bonded = 0;
        if (!do_periodic) {
            double d2=dx*dx+dy*dy+dz*dz;
            bonded = (d2 <= rcut2);
        } else {
            int within = periodic_bond_within(&periodic_basis, dx, dy, dz, tol);
            if (within < 0) {
                free(degree); free(b); set_error(path,0,"periodic bond search exceeded safety limit"); *out_nbonds=0; return NULL;
            }
            bonded = within > 0;
        }

        if (bonded) {
            if (degree[i] >= MOLENV_BOND_MAX_DEGREE || degree[j] >= MOLENV_BOND_MAX_DEGREE) {
                free(degree); free(b); set_error(path,0,"per-atom bond degree exceeded"); *out_nbonds=0; return NULL;
            }
            if (nb>=cap) {
                if (cap > MOLENV_BOND_MAX_CAP / 2) { free(degree); free(b); set_error(path,0,"bond capacity exceeded"); *out_nbonds=0; return NULL; }
                int ncap = cap * 2;
                if (ncap < cap || ncap > MOLENV_BOND_MAX_CAP) ncap = MOLENV_BOND_MAX_CAP;
                MolEnvBond *t=realloc(b, (size_t)ncap * sizeof(MolEnvBond));
                if (!t) { free(degree); free(b); set_error(path,0,"out of memory"); *out_nbonds=0; return NULL; }
                b=t; cap = ncap;
            }
            b[nb].i=i; b[nb].j=j; nb++;
            degree[i]++; degree[j]++;
        }
    }
    free(degree);
    *out_nbonds = nb;
    return b;
}

/* Public wrapper — used by Swift to recompute bonds after supercell expansion. */
MolEnvBond* molenv_make_bonds(const MolEnvScene *scene, float factor, int *out_nbonds) {
    return make_bonds(scene, "", factor, out_nbonds);
}
void molenv_free_bonds(MolEnvBond *bonds) { free(bonds); }

static MolEnvScene* parse_xyz_impl(const char *path);

MolEnvScene* parse_xyz(const char *path) {
    last_error[0] = '\0';
    return parse_xyz_impl(path);
}

/* ----- XSF / AXSF ----- */

/* Extract the first whitespace-delimited token, uppercased. Returns length. */
static int first_tok(const char *line, char *out, int cap) {
    while (*line==' '||*line=='\t') line++;
    int i=0;
    while (*line && *line!=' ' && *line!='\t' && *line!='\n' && *line!='\r' && i<cap-1) out[i++]=*line++;
    out[i]='\0';
    for (int k=0;k<i;k++) out[k]=toupper((unsigned char)out[k]);
    return i;
}

/* True if `line` is an atom record: a leading token that is a numeric Z
   (+/- optional digits) or an element symbol (letters), followed by three
   floats (x y z). Used to know where an ATOMS/ATOMS_FRAC block ends — any line
   that is not a well-formed atom record (an XSF section keyword, prose, or a
   malformed row) terminates the block. Requiring the full "token + 3 floats"
   shape keeps arbitrary prose and section keywords (which are never followed by
   three floats) from being mistaken for atoms, while accepting symbol rows such
   as "Si 0 0 0" that the block body already parses. */
static int atom_line_p(const char *line) {
    while (*line == ' ' || *line == '\t') line++;
    if (!*line) return 0;
    /* First whitespace-delimited token. */
    char tok[16];
    int i = 0;
    while (*line && *line != ' ' && *line != '\t' && *line != '\n' && *line != '\r' && i < 15)
        tok[i++] = *line++;
    tok[i] = '\0';
    if (i == 0) return 0;
    int numeric = 1, alpha = 1, digits = 0;
    for (int k = 0; k < i; k++) {
        char c = tok[k];
        if (k == 0 && (c == '+' || c == '-')) { alpha = 0; continue; }
        if (c >= '0' && c <= '9') { alpha = 0; digits++; }
        else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) { numeric = 0; }
        else { numeric = 0; alpha = 0; }
    }
    if (!((numeric && digits >= 1) || alpha)) return 0;
    /* Three coordinates must follow the token. */
    double x, y, z;
    if (sscanf(line, "%lf %lf %lf", &x, &y, &z) < 3) return 0;
    return 1;
}

/* True if `line` (first whitespace-delimited token, uppercased) opens a DATAGRID
   block in any of the forms parse_xsf's scanner recognizes. Lets the ATOMS branch
   hand a trailing grid to read_datagrid_block without the held line being lost
   into the trailing scan (which would mis-position the cursor and fail the rigid
   comment-then-ident read). */
static int is_datagrid_opener(const char *line, char *tok) {
    if (first_tok(line, tok, 64) == 0) return 0;
    return strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
           strncmp(tok,"DATAGRID_",8)==0 ||
           strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
           strcmp(tok,"DATAGRID3D")==0 || strcmp(tok,"DATAGRID2D")==0 ||
           strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0;
}

/* True if the uppercased tok is a DATAGRID opener whose ident is embedded in the
   token itself (the caller consumed that line), so read_datagrid_block must skip the
   separate comment+ident read and extract dim/ident from the token. Covers the bare
   "DATAGRID_3D_<name>" form and the direct "BEGIN_DATAGRID_3D_<name>" form (no block
   wrapper, no preceding comment line). The block-wrapped form (BEGIN_BLOCK_DATAGRID_3D)
   is handled separately and is NOT matched here. */
static int is_bare_datagrid(const char *tok) {
    return strncmp(tok,"DATAGRID_",8)==0 ||
           strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
           strcmp(tok,"DATAGRID3D")==0 || strcmp(tok,"DATAGRID2D")==0 ||
           strncmp(tok,"BEGIN_DATAGRID",14)==0;
}

/* Read a single DATAGRID block's body. On entry `fp` is positioned right after
   the BEGIN_BLOCK_DATAGRID_3D/2D line (the caller consumes that keyword). The
   body is:
        <comment line>
        BEGIN_DATAGRID_3D_<ident>   (or _2D; also the bare form without BEGIN_)
        nx ny [nz]                 (nz for 3D; 2D writes only nx ny)
        ox oy oz                   (origin)
        v0x v0y v0z                (i-axis span)
        v1x v1y v1z                (j-axis span)
        v2x v2y v2z                (k-axis span; 3D only — 2D spans a plane)
        <nx*ny*nz floats, x-fastest>
        END_DATAGRID_3D
   The vector count is driven by g->dim: a 2D grid writes two span vectors (it
   spans a plane) and the value stream follows immediately after, so an
   unconditional 3-vector read would mis-align the values. Returns 0 and fills
   `g` on success, -1 on failure (error set). The grid is left in `g` as-is on
   failure (caller frees in molenv_scene_free). */
static int read_datagrid_block_ex(FILE *fp, MolEnvGrid *g, const char *path, int *ln,
                                   const char *opener_tok);
static MolEnvScene* parse_xsf_gridonly(const char *path);

/* Wrapper for wrapped/block DATAGRID (BEGIN_DATAGRID or block form). */
static int read_datagrid_block(FILE *fp, MolEnvGrid *g, const char *path, int *ln) {
    return read_datagrid_block_ex(fp, g, path, ln, NULL);
}

/* Read a single DATAGRID block's body. For the wrapped (BLOCK/BEGIN_) form,
   `opener_tok` is NULL and the body is <comment> <ident-line> <dims> ... . For the
   bare/standalone form ("DATAGRID_3D_<name>" consumed by the caller), `opener_tok`
   holds that uppercased opener: dim and ident are extracted from it and dims are read
   directly (there is no separate comment or ident line in that form). */
static int read_datagrid_block_ex(FILE *fp, MolEnvGrid *g, const char *path, int *ln,
                                   const char *opener_tok) {
    char line[256], tok[64];
    memset(g, 0, sizeof(*g));
    g->dim = 3;

    if (opener_tok) {
        /* Bare form: the opener line ("DATAGRID_3D_<name>") was consumed by the
           caller. Identify the dimension from the token and read dims directly. */
        g->dim = (strstr(opener_tok,"2D") && !strstr(opener_tok,"3D")) ? 2 : 3;
        const char *id = strstr(opener_tok,"DATAGRID_");
        if (id) {
            id += 9;
            while (*id && (*id == '2' || *id == '3' || *id == 'D')) id++;
            while (*id == '_') id++;
            if (*id) snprintf(g->ident, sizeof(g->ident), "%.*s", (int)(sizeof(g->ident)-1), id);
        }
    } else {
        /* Wrapped form: read comment + ident lines. */
        if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
        (*ln)++;
        snprintf(g->ident, sizeof(g->ident), "%.*s", (int)(sizeof(g->ident)-1), line);
        g->ident[strcspn(g->ident,"\r\n")] = '\0';
        if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
        (*ln)++;
        if (first_tok(line, tok, sizeof(tok))==0) { set_error(path,*ln,"expected DATAGRID ident line"); return -1; }
        const char *id = tok;
        if (strncmp(tok,"BEGIN_",6)==0) id = tok + 6;
        if (strncmp(id,"DATAGRID_",9)!=0) {
            set_error(path,*ln,"expected DATAGRID_3D/DATAGRID_2D ident line"); return -1;
        }
        g->dim = (id[9]=='2') ? 2 : 3;
    }

    /* dimensions */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    {
        char sx[64] = {0}, sy[64] = {0}, sz[64] = {0}, extra[64] = {0};
        int parsed = sscanf(line, "%63s %63s %63s %63s", sx, sy, sz, extra);
        int expected = g->dim == 2 ? 2 : 3;
        long lx = 0, ly = 0, lz = 0;
        if (parsed != expected || !parse_bounded_long(sx, 1, 25000000, &lx) ||
            !parse_bounded_long(sy, 1, 25000000, &ly) ||
            (g->dim == 3 && !parse_bounded_long(sz, 1, 25000000, &lz))) {
            set_error(path,*ln,"malformed DATAGRID dims"); return -1;
        }
        int nx = (int)lx, ny = (int)ly, nz = (int)lz;
        if (g->dim==2) { g->n[0]=nx; g->n[1]=ny; g->n[2]=1; }
        else           { g->n[0]=nx; g->n[1]=ny; g->n[2]=nz; }
    }

    /* origin */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    if (sscanf(line,"%f %f %f",&g->orig[0],&g->orig[1],&g->orig[2])<3) {
        set_error(path,*ln,"malformed DATAGRID origin"); return -1;
    }
    if (!isfinite(g->orig[0]) || !isfinite(g->orig[1]) || !isfinite(g->orig[2])) {
        set_error(path,*ln,"non-finite DATAGRID origin"); return -1;
    }

    /* span vectors: two for a 2D grid (it spans a plane), three for 3D. Reading
       three unconditionally would consume the first value line of a 2D grid. */
    int nvec = (g->dim == 2) ? 2 : 3;
    for (int ax=0; ax<nvec; ax++) {
        if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
        (*ln)++;
        if (sscanf(line,"%f %f %f",&g->vec[ax][0],&g->vec[ax][1],&g->vec[ax][2])<3) {
            set_error(path,*ln,"malformed DATAGRID vector"); return -1;
        }
        if (!isfinite(g->vec[ax][0]) || !isfinite(g->vec[ax][1]) || !isfinite(g->vec[ax][2])) {
            set_error(path,*ln,"non-finite DATAGRID vector"); return -1;
        }
    }

    /* values — x-fastest, any whitespace run. Read with fscanf so line breaks
       don't matter (grid may be a single long line or many). Cap the aggregate
       allocation: a malicious file can declare a grid whose product overflows size_t
       or requests an absurd amount of memory before any value is read. */
    const long grid_cap = 25000000L;
    if (g->n[0] <= 0 || g->n[1] <= 0 || g->n[2] <= 0 ||
        g->n[0] > grid_cap / g->n[1] ||
        (long)g->n[0] * g->n[1] > grid_cap / g->n[2]) {
        set_error(path,*ln,"DATAGRID dimensions overflow"); return -1;
    }
    long count = (long)g->n[0] * g->n[1] * g->n[2];
    g->values = malloc((size_t)count * sizeof(float));
    if (!g->values) { set_error(path,*ln,"out of memory for DATAGRID values"); return -1; }
    g->minval = FLT_MAX; g->maxval = -FLT_MAX;
    for (long i=0; i<count; i++) {
        float v;
        if (fscanf(fp, "%f", &v)!=1) {
            free(g->values); g->values = NULL;
            set_error(path,*ln,"short DATAGRID values"); return -1;
        }
        if (!isfinite(v)) {
            free(g->values); g->values = NULL;
            set_error(path,*ln,"non-finite DATAGRID value"); return -1;
        }
        g->values[i] = v;
        if (v < g->minval) g->minval = v;
        if (v > g->maxval) g->maxval = v;
    }

    /* advance to END_DATAGRID_3D line */
    int saw_end = 0;
    while (fgets(line, sizeof(line), fp)) {
        (*ln)++;
        first_tok(line, tok, sizeof(tok));
        if (strcmp(tok,"END_DATAGRID_3D")==0 || strcmp(tok,"END_DATAGRID_2D")==0) {
            saw_end = 1; break;
        }
    }
    if (!saw_end) {
        free(g->values); g->values = NULL;
        set_error(path,*ln,"missing END_DATAGRID marker"); return -1;
    }
    return 0;
}

/* Read one PRIMCOORD structure chunk from the current file position.
   Reads an optional preceding structure keyword + PRIMVEC. Returns atom
   count on success, -1 on error. `*atoms` is reallocated; any prior value
   is freed (so callers can iterate frames on a single buffer). */
static int read_chunk(FILE *fp, float cell[3][3], int *pd, int *have_cell,
                      MolEnvAtom **atoms, int *natoms, MolEnvGrid **gridOut,
                      const char *path, int *ln) {
    char line[256], tok[64];
    char held[256]; int have_held = 0;
    int saw_primcoord = 0;
    while (1) {
        if (have_held) { strcpy(line, held); have_held = 0; }
        else { if (!fgets(line, sizeof(line), fp)) break; (*ln)++; }
        if (first_tok(line, tok, sizeof(tok)) == 0) continue;
        if (tok[0]=='#') continue;

        if (strcmp(tok,"CRYSTAL")==0)  { *pd = 3; continue; }
        if (strcmp(tok,"MOLECULE")==0) { *pd = 0; continue; }
        if (strcmp(tok,"SLAB")==0)     { *pd = 2; continue; }
        if (strcmp(tok,"POLYMER")==0)  { *pd = 1; continue; }

        if (strcmp(tok,"CONVVEC")==0) {
            for (int r=0;r<3;r++) { if (!fgets(line,sizeof(line),fp)) return -1; (*ln)++; }
            continue;
        }
        if (strcmp(tok,"PRIMVEC")==0) {
            for (int r=0;r<3;r++) {
                /* XSF files in the wild may separate vector records with blank
                   or comment-only lines. Treat those as inter-record whitespace
                   while still requiring exactly three finite numeric vectors. */
                while (1) {
                    if (!fgets(line,sizeof(line),fp)) { set_error(path,*ln,"unexpected end in PRIMVEC"); return -1; }
                    (*ln)++;
                    if (first_tok(line,tok,sizeof(tok))==0 || tok[0]=='#') continue;
                    break;
                }
                double a,b,c;
                if (sscanf(line,"%lf %lf %lf",&a,&b,&c)<3) { set_error(path,*ln,"malformed PRIMVEC row"); return -1; }
                if (!in_float_range(a) || !in_float_range(b) || !in_float_range(c)) { set_error(path,*ln,"non-finite PRIMVEC row"); return -1; }
                cell[r][0]=(float)a; cell[r][1]=(float)b; cell[r][2]=(float)c;
            }
            *have_cell = 1;
            continue;
        }
        if (strcmp(tok,"CONVCOORD")==0) {
            char na_tok[64] = {0}, nc_tok[64] = {0}, extra[64] = {0};
            if (!fgets(line,sizeof(line),fp)) return -1; (*ln)++;
            if (sscanf(line, "%63s %63s %63s", na_tok, nc_tok, extra) != 2) {
                set_error(path,*ln,"malformed CONVCOORD header"); return -1;
            }
            long na = 0, nc = 0;
            if (!parse_bounded_long(na_tok, 1, 500000, &na) ||
                !parse_bounded_long(nc_tok, 0, 500000, &nc)) {
                set_error(path,*ln,"unreasonable atom count in CONVCOORD"); return -1;
            }
            if (nc > 0 && na > 500000 / nc) {
                set_error(path,*ln,"CONVCOORD record count exceeds cap"); return -1;
            }
            long records = na * nc;
            for (long i=0; i<records; i++) { if(!fgets(line,sizeof(line),fp)) return -1; (*ln)++; }
            continue;
        }
        if (strcmp(tok,"PRIMCOORD")==0) {
            int na=0;
            if (!fgets(line,sizeof(line),fp)) { set_error(path,*ln,"unexpected end after PRIMCOORD"); return -1; }
            (*ln)++;
            /* Strict parse of the first integer only: PRIMCOORD headers carry
               `na nc` (atoms, repeats). sscanf("%d") on overflowed integers is
               implementation-defined; strtol + endp rejects partial parses.
               We only require na to be valid; nc is consumed separately. */
            char *endp2 = NULL;
            long na_long = strtol(line, &endp2, 10);
            if (endp2 == line || na_long < 1 || na_long > 500000) { set_error(path,*ln,"malformed PRIMCOORD header"); return -1; }
            na = (int)na_long;
            MolEnvAtom *at = calloc((size_t)na, sizeof(MolEnvAtom));
            if (!at) { set_error(path,*ln,"out of memory"); return -1; }
            for (int i=0;i<na;i++) {
                if (!fgets(line,sizeof(line),fp)) { free(at); set_error(path,*ln,"unexpected end in PRIMCOORD"); return -1; }
                (*ln)++;
                char Zstr[16]; double x,y,z;
                int nf = sscanf(line,"%15s %lf %lf %lf",Zstr,&x,&y,&z);
                if (nf < 4) { free(at); set_error(path,*ln,"malformed PRIMCOORD atom"); return -1; }
                if (!in_float_range(x) || !in_float_range(y) || !in_float_range(z)) { free(at); set_error(path,*ln,"non-finite PRIMCOORD atom"); return -1; }
                char *endp = NULL;
                long Znum = strtol(Zstr, &endp, 10);
                if (endp && *endp == '\0') {
                    at[i].atomic_number = (Znum >= 1 && Znum <= 118) ? (int)Znum : 0;
                    snprintf(at[i].label,sizeof(at[i].label),"%ld",Znum);
                } else {
                    at[i].atomic_number = molenv_symbol_to_z(Zstr);
                    snprintf(at[i].label,sizeof(at[i].label),"%s",Zstr);
                }
                at[i].coord[0]=(float)x; at[i].coord[1]=(float)y; at[i].coord[2]=(float)z;
            }
            free(*atoms);
            *atoms = at; *natoms = na;
            saw_primcoord = 1;
            break;
        }
        if (strcmp(tok,"ATOMS")==0 || strcmp(tok,"ATOMS_FRAC")==0) {
            int frac = (strcmp(tok,"ATOMS_FRAC")==0);
            if (frac && !*have_cell) { set_error(path,*ln,"ATOMS_FRAC before PRIMVEC"); return -1; }
            MolEnvAtom *at = NULL; int na = 0, acap = 0;
            while (fgets(line,sizeof(line),fp)) {
                (*ln)++;
                if (first_tok(line,tok,sizeof(tok))==0) continue;
                if (tok[0]=='#') continue;
                if (!atom_line_p(line)) { strcpy(held,line); have_held=1; break; }
                /* First token is a Z number or element symbol; then three coords.
                   Accept both so "Si"/"O" work in ATOMS/ATOMS_FRAC as in PRIMCOORD. */
                double x, y, z;
                int zi = 0;
                char lbl[16] = {0};
                {
                    char Zstr[16];
                    if (sscanf(line,"%15s %lf %lf %lf",Zstr,&x,&y,&z) < 4) continue;
                    if (!in_float_range(x) || !in_float_range(y) || !in_float_range(z)) { free(at); set_error(path,*ln,"non-finite ATOMS coordinate"); return -1; }
                    char *endp = NULL;
                    long Znum = strtol(Zstr, &endp, 10);
                    if (endp && *endp == '\0') {
                        zi = (Znum >= 1 && Znum <= 118) ? (int)Znum : 0;
                        snprintf(lbl,sizeof(lbl),"%ld",Znum);
                    } else {
                        zi = molenv_symbol_to_z(Zstr);
                        snprintf(lbl,sizeof(lbl),"%s",Zstr);
                    }
                }
                if (na>=acap) {
                    if (acap >= 500000) { free(at); set_error(path,*ln,"too many atoms in ATOMS block"); return -1; }
                    acap = acap?acap*2:16; if (acap>500000) acap=500000;
                    MolEnvAtom *t=realloc(at,(size_t)acap*sizeof(MolEnvAtom)); if(!t){free(at);set_error(path,*ln,"out of memory");return -1;} at=t;
                }
                float fx=(float)x, fy=(float)y, fz=(float)z;
                if (frac) {
                    /* Compute in double: individually finite x/y/z and cell
                       components can still overflow to ±inf when multiplied in
                       float. Validate the derived Cartesian components before
                       casting to float and committing the atom. */
                    double dx = x*cell[0][0] + y*cell[1][0] + z*cell[2][0];
                    double dy = x*cell[0][1] + y*cell[1][1] + z*cell[2][1];
                    double dz = x*cell[0][2] + y*cell[1][2] + z*cell[2][2];
                    if (!in_float_range(dx) || !in_float_range(dy) || !in_float_range(dz)) {
                        free(at); set_error(path,*ln,"non-finite Cartesian coordinate"); return -1;
                    }
                    at[na].coord[0] = (float)dx;
                    at[na].coord[1] = (float)dy;
                    at[na].coord[2] = (float)dz;
                } else {
                    at[na].coord[0]=fx; at[na].coord[1]=fy; at[na].coord[2]=fz;
                }
                at[na].atomic_number=zi;
                /* Use the parsed symbol/number label; fall back to Z for plain integers. */
                if (lbl[0] != '\0') snprintf(at[na].label,sizeof(at[na].label),"%s",lbl);
                else snprintf(at[na].label,sizeof(at[na].label),"%d",zi);
                na++;
            }
            saw_primcoord = 1;
            // A DATAGRID block can follow the atoms (e.g. a molecule's color-plane
            // grid, DATAGRID_2D after ATOMS). The held line holds its opener; capture
            // it here with the cursor on the comment line — exactly where the grid
            // path below expects to be — so the trailing scan isn't left hunting
            // from a mis-positioned cursor. Without this the rigid comment-then-ident
            // read fails and the 2D grid is silently lost.
            //
            // Ownership rule: *atoms/*gridOut are only ever mutated on the success
            // path, after every fallible operation has completed. On any error the
            // caller's pointers are left untouched (caller retains ownership of its
            // prior value, usually NULL) and every locally-allocated buffer is freed
            // here. This keeps the contract uniform across all error sites and lets
            // both callers treat a -1 return as "nothing to free".
            if (have_held && is_datagrid_opener(held, tok) && gridOut && *gridOut == NULL) {
                MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
                if (!g) { free(at); set_error(path,*ln,"out of memory for DATAGRID"); return -1; }
                const char *opener = is_bare_datagrid(tok) ? tok : NULL;
                if (read_datagrid_block_ex(fp, g, path, ln, opener) < 0) { free(at); molenv_grid_free(g); free(g); return -1; }
                *gridOut = g;
            }
            free(*atoms);
            *atoms = at; *natoms = na;
            break;
        }
        if (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
            is_bare_datagrid(tok) ||
            strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
            /* Capture the first DATAGRID block into the scene (subsequent ones
               are skipped by advancing past the END_DATAGRID line). */
            if (gridOut && *gridOut == NULL) {
                MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
                if (!g) { set_error(path,*ln,"out of memory for DATAGRID"); return -1; }
                const char *opener = is_bare_datagrid(tok) ? tok : NULL;
                if (read_datagrid_block_ex(fp, g, path, ln, opener) < 0) { molenv_grid_free(g); free(g); return -1; }
                *gridOut = g;
            } else {
                /* skip the block body so the structure scan can continue */
                while (fgets(line,sizeof(line),fp)) {
                    (*ln)++;
                    if (first_tok(line,tok,sizeof(tok))>0 &&
                        (strcmp(tok,"END_DATAGRID_3D")==0 || strcmp(tok,"END_DATAGRID_2D")==0)) break;
                }
            }
            continue;
        }
        if (strcmp(tok,"INFO")==0 || strcmp(tok,"BEGIN_INFO")==0) {
            while (fgets(line,sizeof(line),fp)) {
                (*ln)++;
                if (first_tok(line,tok,sizeof(tok))>0 &&
                    (strcmp(tok,"END_INFO")==0 || strcmp(tok,"INFO_END")==0)) break;
            }
            continue;
        }
        /* ANIMSTEPS / DIM / RECIP-* / WIGNER / BRILLOUIN / ATOM / FRAME
           and any other single-line keywords: ignore. */
    }
    if (!saw_primcoord) { set_error(path,0,"no PRIMCOORD found"); return -1; }
    return *natoms;
}

/* Scan an XSF file for the presence of a structure section. Returns 1 if any
    structure keyword is found, 0 otherwise. Lets parse_xsf distinguish a
    genuinely structure-free DATAGRID file (which may fall back to a grid-only
    parse) from a truncated/malformed one (where the real parsing error must
    surface instead of being masked by the fallback).

    Structure intent is signaled by the atomic-data keywords (PRIMCOORD, ATOMS,
    ATOMS_FRAC) but also by the lattice/crystal headers that precede them: a
    file beginning CRYSTAL/PRIMVEC (or MOLECULE/SLAB/POLYMER) is meant to carry
    a structure even if its atom block is missing or truncated. Without this, a
    truncated "CRYSTAL + PRIMVEC" file falls through to the grid-only path and
    loses the useful "no PRIMCOORD found" error behind "no DATAGRID block". */
static int xsf_has_structure(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[256], tok[64];
    int found = 0;
    while (fgets(line, sizeof(line), fp)) {
        if (first_tok(line, tok, sizeof(tok)) == 0) continue;
        if (tok[0] == '#') continue;
        if (strcmp(tok, "CRYSTAL") == 0 ||
            strcmp(tok, "MOLECULE") == 0 ||
            strcmp(tok, "SLAB") == 0 ||
            strcmp(tok, "POLYMER") == 0 ||
            strcmp(tok, "PRIMVEC") == 0 ||
            strcmp(tok, "PRIMCOORD") == 0 ||
            strcmp(tok, "ATOMS") == 0 ||
            strcmp(tok, "ATOMS_FRAC") == 0) {
            found = 1;
            break;
        }
    }
    fclose(fp);
    return found;
}

MolEnvScene* parse_xsf(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }
    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    float cell[3][3]={{0}}; int pd=3, have_cell=0, ln=0;
    MolEnvAtom *atoms=NULL; int natoms=0;
    MolEnvGrid *grid=NULL;
    int rc = read_chunk(fp, cell,&pd,&have_cell,&atoms,&natoms,&grid,path,&ln);
    if (rc < 0) {
        /* Only fall back to a structure-free DATAGRID parse when the file truly
           has no structure section. A malformed PRIMCOORD/ATOMS that read_chunk
           failed on means the file WAS meant to carry a structure — surface that
           error instead of silently returning a grid-only scene. */
        if (xsf_has_structure(path)) {
            if (grid) { molenv_grid_free(grid); free(grid); }
            fclose(fp); molenv_scene_free(s);
            return NULL;
        }
        /* No structure section at all: fall back to structure-free DATAGRID.
           read_chunk may have captured a grid before hitting EOF; free it so the
           grid-only path re-reads it from scratch (its own grid is heap-owned). */
        if (grid) { molenv_grid_free(grid); free(grid); grid = NULL; }
        fclose(fp); molenv_scene_free(s);
        return parse_xsf_gridonly(path);
    }
    s->atoms = atoms; s->natoms = natoms;
    s->grid = grid;
    memcpy(s->cell, cell, sizeof(s->cell));
    s->periodic_dim = pd;
    s->is_crystal = have_cell ? 1 : 0;

    /* A grid that follows the structure block is not seen by read_chunk (it
       breaks after PRIMCOORD/ATOMS). Scan the remaining lines and capture the
       first trailing DATAGRID block. */
    if (s->grid == NULL) {
        char line[256], tok[64];
        while (fgets(line, sizeof(line), fp)) {
            ln++;
            if (first_tok(line, tok, sizeof(tok)) == 0 || tok[0]=='#') continue;
            if (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
                is_bare_datagrid(tok) ||
                strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
                MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
                if (!g) { fclose(fp); set_error(path,ln,"out of memory for DATAGRID");
                           molenv_scene_free(s); return NULL; }
                const char *opener = is_bare_datagrid(tok) ? tok : NULL;
                if (read_datagrid_block_ex(fp, g, path, &ln, opener) < 0) { molenv_grid_free(g); free(g);
                    fclose(fp); molenv_scene_free(s); return NULL; }
                s->grid = g;
                break;
            }
        }
    }
    if (have_cell) {
        double matrix[3][3];
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) matrix[i][j] = cell[i][j];
        if (!cell_rank_usable(matrix, pd)) {
            molenv_scene_free(s); set_error(path, 0, "singular periodic cell"); return NULL;
        }
    }
    fclose(fp);

    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* Parse a genuinely structure-free DATAGRID file (no atoms): a standalone
    2D/3D grid with no structure headers (CRYSTAL/MOLECULE/SLAB/POLYMER/PRIMVEC).
    Returns NULL with error set if no DATAGRID block is found. Used for grid-only
    XSF files, consistent with how grid2D/scalarField scenes render without atoms.
    Note: a grid-only file that DOES carry PRIMVEC is treated as structure intent
    and routed to the structure path, so it never reaches here. */
static MolEnvScene* parse_xsf_gridonly(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }
    char line[256], tok[64];
    MolEnvGrid *grid = NULL;
    int ln = 0;
    while (fgets(line, sizeof(line), fp)) {
        ln++;
        if (first_tok(line, tok, sizeof(tok)) == 0 || tok[0]=='#') continue;
        if (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
            is_bare_datagrid(tok) ||
            strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
            MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
            if (!g) { fclose(fp); set_error(path,ln,"out of memory for DATAGRID"); return NULL; }
            const char *opener = is_bare_datagrid(tok) ? tok : NULL;
            if (read_datagrid_block_ex(fp, g, path, &ln, opener) < 0) { molenv_grid_free(g); free(g);
                fclose(fp); return NULL; }
            grid = g;
            break;
        }
    }
    fclose(fp);
    if (!grid) { set_error(path,0,"no DATAGRID block found"); return NULL; }
    MolEnvScene *s = new_scene(path);
    if (!s) { molenv_grid_free(grid); free(grid); return NULL; }
    s->grid = grid;
    s->natoms = 0;
    s->is_crystal = 0;
    s->periodic_dim = 0;
    snprintf(s->title,sizeof(s->title),"%s", "grid data");
    return s;
}

MolEnvScene* parse_axsf(const char *path, int frame_index) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }
    char line[256], tok[64];
    int nframes = 0, ln = 0;
    /* First pass: find ANIMSTEPS count. */
    while (fgets(line,sizeof(line),fp)) {
        ln++;
        if (first_tok(line,tok,sizeof(tok))>0 && strcmp(tok,"ANIMSTEPS")==0) {
            char n_tok[64] = {0};
            if (sscanf(line, "%*63s %63s", n_tok) != 1) {
                fclose(fp); set_error(path,0,"malformed ANIMSTEPS count"); return NULL;
            }
            long n = 0;
            if (!parse_bounded_long(n_tok, 1, 500000, &n)) {
                fclose(fp); set_error(path,0,"unreasonable ANIMSTEPS count"); return NULL;
            }
            nframes = (int)n;
        }
    }
    if (nframes == 0) { fclose(fp); set_error(path,0,"ANIMSTEPS header not found"); return NULL; }
    if (frame_index < 0 || frame_index >= nframes) { fclose(fp); set_error(path,0,"frame index out of range"); return NULL; }
    rewind(fp);
    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    float cell[3][3]={{0}}; int pd=3, have_cell=0, lnb=0;
    MolEnvAtom *atoms=NULL; int natoms=0;
    MolEnvGrid *grid=NULL;
    int current = 0;
    while (current <= frame_index) {
        int rc = read_chunk(fp, cell,&pd,&have_cell,&atoms,&natoms,&grid,path,&lnb);
        if (rc < 0) { molenv_grid_free(grid); free(grid); fclose(fp); molenv_scene_free(s); return NULL; }
        if (current == frame_index) break;
        /* discard this frame's atoms (and grid); keep cell/is_crystal */
        free(atoms); atoms=NULL; natoms=0;
        molenv_grid_free(grid); free(grid); grid=NULL;
        current++;
    }
    fclose(fp);
    s->atoms = atoms; s->natoms = natoms;
    s->grid = grid;
    memcpy(s->cell, cell, sizeof(s->cell));
    s->periodic_dim = pd;
    s->is_crystal = have_cell ? 1 : 0;
    if (have_cell) {
        double matrix[3][3];
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) matrix[i][j] = cell[i][j];
        if (!cell_rank_usable(matrix, pd)) {
            molenv_scene_free(s); set_error(path, 0, "singular periodic cell"); return NULL;
        }
    }
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/// Scan only the header of an AXSF file and return its ANIMSTEPS count.
/// Mirrors the first pass of parse_axsf so the count matches exactly what
/// the parser will accept as valid frame indices. Returns 0 on any failure
/// (not an AXSF, malformed, or single-frame).
int molenv_axsf_frame_count(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) { return 0; }
    char line[256], tok[64];
    int nframes = 0;
    while (fgets(line, sizeof(line), fp)) {
        if (first_tok(line, tok, sizeof(tok)) > 0 && strcmp(tok, "ANIMSTEPS") == 0) {
            char n_tok[64] = {0};
            long n = 0;
            if (sscanf(line, "%*63s %63s", n_tok) == 1 &&
                parse_bounded_long(n_tok, 1, 500000, &n)) nframes = (int)n;
        }
    }
    fclose(fp);
    return nframes;
}

/* ----- PDB ----- */

MolEnvScene* parse_pdb(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }
    char line[1024];
    long long count = 0;
    int ln = 0, got_title = 0;
    char title[256] = {0};

    /* First pass: count atoms + capture an optional title. count is long long so
       a huge file cannot overflow the counter; we cap at 500000 below. */
    while (fgets(line,sizeof(line),fp)) {
        ln++;
        if (strncmp(line,"ATOM",4)==0 || strncmp(line,"HETATM",6)==0) count++;
        if (!got_title && (strncmp(line,"TITLE",5)==0 || strncmp(line,"HEADER",6)==0)) {
            /* remainder of the line, trimmed */
            char buf[256];
            if (strncmp(line,"TITLE",5)==0) snprintf(buf,sizeof(buf),"%s",line+5);
            else                             snprintf(buf,sizeof(buf),"%s",line+6);
            char *p = buf;
            while (*p==' '||*p=='\t') p++;
            size_t len = strlen(p);
            while (len>0 && (p[len-1]=='\n'||p[len-1]=='\r'||p[len-1]==' ')) p[--len]='\0';
            if (len > 0) { snprintf(title,sizeof(title),"%s",p); got_title = 1; }
        }
        if (strncmp(line,"END",3)==0 || strncmp(line,"ENDMDL",6)==0) break;
    }
    if (count > 500000LL) { fclose(fp); set_error(path, ln, "unreasonable atom count in PDB"); return NULL; }
    rewind(fp);

    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    if (!got_title) snprintf(title,sizeof(title),"%s","PDB structure");

    s->atoms = calloc((size_t)count, sizeof(MolEnvAtom));
    if (!s->atoms || count==0) {
        if (count==0) set_error(path,ln,"no atoms found"); else set_error(path,0,"out of memory");
        fclose(fp); molenv_scene_free(s); return NULL;
    }

    int i = 0;
    while (fgets(line,sizeof(line),fp) && i < count) {
        if (strncmp(line,"ATOM",4)!=0 && strncmp(line,"HETATM",6)!=0) continue;
        if (strncmp(line,"END",3)==0 || strncmp(line,"ENDMDL",6)==0) break;
        int have_coord = 0;
        double x=0,y=0,z=0;
        /* Columns 31-38,39-46,47-54 (1-based) == line[30..], using 8-char fields. */
        char xs[9]={0}, ys[9]={0}, zs[9]={0};
        if ((int)strlen(line) >= 54) {
            memcpy(xs, line+30, 8); xs[8]='\0';
            memcpy(ys, line+38, 8); ys[8]='\0';
            memcpy(zs, line+46, 8); zs[8]='\0';
            if (sscanf(xs,"%lf",&x) == 1 && sscanf(ys,"%lf",&y) == 1 && sscanf(zs,"%lf",&z) == 1
                && isfinite(x) && isfinite(y) && isfinite(z))
                have_coord = 1;
        }
        if (!have_coord) continue;
        /* Element symbol: PDB cols 77-78 (line[76..77]) are the authoritative
           element source per PDB 3.x; fall back to atom name (cols 13-16). */
        char sym[4]={0};
        if ((int)strlen(line) >= 78) {
            char e0 = line[76], e1 = line[77];
            if (e0 != ' ' && e0 != '\0') {
                sym[0] = toupper((unsigned char)e0);
                sym[1] = (e1 != ' ' && e1 != '\0') ? (char)tolower((unsigned char)e1) : '\0';
                sym[2] = '\0';
            }
        }
        if (sym[0] == '\0' && (int)strlen(line) >= 14) {
            char c0 = line[12], c1 = line[13];
            if (c0==' ') {
                sym[0]=c1; sym[1]='\0';
            } else if (c0!='\0') {
                sym[0]=toupper((unsigned char)c0);
                sym[1]=tolower((unsigned char)c1);
                sym[2]='\0';
            }
        }
        MolEnvAtom *a = &s->atoms[i];
        a->coord[0]=(float)x; a->coord[1]=(float)y; a->coord[2]=(float)z;
        a->atomic_number = molenv_symbol_to_z(sym);
        snprintf(a->label,sizeof(a->label),"%s",sym);
        i++;
    }
    fclose(fp);
    s->natoms = i;
    s->is_crystal = 0;
    s->periodic_dim = 0;
    snprintf(s->title,sizeof(s->title),"%s",title);
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- Quantum Espresso PWscf input (.pwi / .in / .inp) ----- */


/* 1 Bohr in Angstroms (QE constant bohr_radius_angs). */
#define BOHR_TO_ANG 0.529177210903f

/* Port of QE's latgen.f90: given ibrav + celldm, fill cell[3][3] (row-major
   lattice vectors, in Bohr). Returns 0 on success, -1 if ibrav unsupported. */
static int latgen(int ibrav, const double celldm[6], double cell[3][3]) {
    double a = celldm[1], b = celldm[1] * celldm[2], c = celldm[1] * celldm[3];
    double cosbc = celldm[4], cosac = celldm[5], cosab = celldm[6];
    double sqrt3 = sqrt(3.0), sq3 = sqrt3 / 2.0;
    double t;
    int i, j;
    for (i = 0; i < 3; i++) for (j = 0; j < 3; j++) cell[i][j] = 0.0;
    switch (ibrav) {
    case 1: /* sc */
        cell[0][0] = a; cell[1][1] = a; cell[2][2] = a; break;
    case 2: /* fcc */
        cell[0][0] = -a/2; cell[0][2] =  a/2;
        cell[1][1] =  a/2; cell[1][2] =  a/2;
        cell[2][0] = -a/2; cell[2][1] =  a/2; break;
    case 3: /* bcc */
        cell[0][0] =  a/2; cell[0][1] =  a/2; cell[0][2] =  a/2;
        cell[1][0] = -a/2; cell[1][1] =  a/2; cell[1][2] =  a/2;
        cell[2][0] = -a/2; cell[2][1] = -a/2; cell[2][2] =  a/2; break;
    case 4: /* hexagonal */
        cell[0][0] = a;
        cell[1][0] = -a/2; cell[1][1] = a * sq3;
        cell[2][2] = c; break;
    case 5: { /* Trigonal R, 3-fold axis along (001) c: three length-a vectors, pairwise cos == celldm(4). */
        if (cosbc < -0.5 || cosbc > 1.0) return -1;
        double sr2 = sqrt(2.0);
        double term1 = sqrt(1.0 + 2.0 * cosbc);
        double term2 = sqrt(1.0 - cosbc);
        cell[0][0] = a * term2 / sr2;
        cell[0][1] = -cell[0][0] / sqrt3;
        cell[0][2] = a * term1 / sqrt3;
        cell[1][1] = sr2 * a * term2 / sqrt3;
        cell[1][2] = a * term1 / sqrt3;
        cell[2][0] = -a * term2 / sr2;
        cell[2][1] = cell[0][1];
        cell[2][2] = a * term1 / sqrt3;
        break;
    }
    case -5: { /* Trigonal R, 3-fold axis along (111): three length-a vectors, pairwise cos == celldm(4). */
        if (cosbc < -0.5 || cosbc > 1.0) return -1;
        double term1 = sqrt(1.0 + 2.0 * cosbc);
        double term2 = sqrt(1.0 - cosbc);
        double f1 = a * (term1 - 2.0 * term2) / 3.0;
        double f2 = a * (term1 + term2) / 3.0;
        cell[0][0] = f1; cell[0][1] = f2; cell[0][2] = f2;
        cell[1][0] = f2; cell[1][1] = f1; cell[1][2] = f2;
        cell[2][0] = f2; cell[2][1] = f2; cell[2][2] = f1;
        break;
    }
    case 6: /* tetragonal */
        cell[0][0] = a; cell[1][1] = a; cell[2][2] = c; break;
    case 7: /* tetragonal I (bct) */
        cell[0][0] =  a/2; cell[0][1] = -a/2; cell[0][2] = c/2;
        cell[1][0] =  a/2; cell[1][1] =  a/2; cell[1][2] = c/2;
        cell[2][0] = -a/2; cell[2][1] = -a/2; cell[2][2] = c/2; break;
    case 8: /* orthorhombic */
        cell[0][0] = a; cell[1][1] = b; cell[2][2] = c; break;
    case 9: /* orthorhombic base-centered */
        cell[0][0] =  a/2; cell[0][1] =  b/2;
        cell[1][0] = -a/2; cell[1][1] =  b/2;
        cell[2][2] = c; break;
    case -9: /* orthorhombic base-centered (alt) */
        cell[0][0] =  a/2; cell[0][1] = -b/2;
        cell[1][0] =  a/2; cell[1][1] =  b/2;
        cell[2][2] = c; break;
    case 91: /* orthorhombic one-face base-centered (A) */
        cell[0][0] = a;
        cell[1][1] =  b/2; cell[1][2] = -c/2;
        cell[2][1] =  b/2; cell[2][2] =  c/2; break;
    case 10: /* orthorhombic face-centered */
        cell[0][0] =  a/2; cell[0][2] =  c/2;
        cell[1][0] =  a/2; cell[1][1] =  b/2;
        cell[2][1] =  b/2; cell[2][2] =  c/2; break;
    case 11: /* orthorhombic body-centered */
        cell[0][0] =  a/2; cell[0][1] =  b/2; cell[0][2] =  c/2;
        cell[1][0] = -a/2; cell[1][1] =  b/2; cell[1][2] =  c/2;
        cell[2][0] = -a/2; cell[2][1] = -b/2; cell[2][2] =  c/2; break;
    case 12: /* monoclinic P, unique axis c: tilt in the a-b plane, cos = celldm(4). */
        if (cosbc < -1.0 || cosbc > 1.0) return -1;
        double sc = sin(acos(cosbc));
        cell[0][0] = a; cell[2][2] = c;
        cell[1][0] = b * cosbc; cell[1][1] = b * sc; break;
    case -12: /* monoclinic P, unique axis b: tilt in the a-c plane, cos = celldm(5). */
        if (cosac < -1.0 || cosac > 1.0) return -1;
        double sb = sin(acos(cosac));
        cell[0][0] = a; cell[1][1] = b;
        cell[2][0] = c * cosac; cell[2][2] = c * sb; break;
    case 13: { /* One-face centered monoclinic, unique axis c: cos == celldm(4). */
        if (cosbc < -1.0 || cosbc > 1.0) return -1;
        double sen = sqrt(1.0 - cosbc * cosbc);
        cell[0][0] =  a / 2.0;
        cell[0][2] = -(a * celldm[3]) / 2.0;   /* a1(3) = -a1(1)*(c/a) = -c/2 */
        cell[1][0] =  b * cosbc;               /* a2(1) = a*(b/a)*cos */
        cell[1][1] =  b * sen;                 /* a2(2) = a*(b/a)*sen */
        cell[2][0] =  a / 2.0;
        cell[2][2] =  (a * celldm[3]) / 2.0;    /* a3(3) = -a1(3) = c/2 */
        break;
    }
    case -13: { /* One-face centered monoclinic, unique axis b: cos == celldm(5). */
        if (cosac < -1.0 || cosac > 1.0) return -1;
        double sen = sqrt(1.0 - cosac * cosac);
        cell[0][0] =  a / 2.0;
        cell[0][1] =  b / 2.0;
        cell[1][0] = -a / 2.0;
        cell[1][1] =  b / 2.0;
        cell[2][0] =  c * cosac;
        cell[2][2] =  c * sen;
        break;
    }
    case 14: { /* triclinic */
        double sinab = sin(acos(cosab));
        double omega = a*b*c * sqrt(1.0 - cosab*cosab - cosac*cosac - cosbc*cosbc
                                     + 2.0*cosab*cosac*cosbc);
        cell[0][0] = a;
        cell[1][0] = b * cosab;
        cell[1][1] = b * sinab;
        cell[2][0] = c * cosac;
        cell[2][1] = c * (cosbc - cosac*cosab) / sinab;
        cell[2][2] = omega / (a * b * sinab);
        (void)omega; break;
    }
    default: return -1;
    }
    return 0;
}

/* Strip trailing digits from a QE species label to recover the element symbol
   (e.g. "Fe1" -> "Fe", "O" -> "O"). QE labels the same element differently
   across inequivalent sites this way. Writes the result into out (cap 4). */
static void qe_element(const char *s, char *out) {
    int i = 0;
    while (s[i] && i < 3) { out[i] = s[i]; i++; }
    /* walk back over trailing digits */
    while (i > 0 && out[i-1] >= '0' && out[i-1] <= '9') i--;
    out[i] = '\0';
}

/* Trim leading/trailing whitespace in place. */
static void trim_in_place(char *s) {
    char *a = s;
    while (*a == ' ' || *a == '\t') a++;
    if (a != s) { size_t n = strlen(a); memmove(s, a, n + 1); }
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t')) s[--n] = '\0';
}

/* Parse a celldm(N) key. Returns the index (1..6) or 0 if not celldm.
    Case-insensitive so "CELldm(1)", "Celldm(1)" etc. all resolve (QE input is
    case-insensitive). */
static int celldm_index(const char *key) {
    if (strncasecmp(key, "celldm(", 7) != 0) return 0;
    return atoi(key + 7);
}

/* Grow the four parallel atom buffers to ``ncap`` slots each. On success the
   originals are freed and replaced through the pointers, returning 1. On any
   allocation failure, ownership-safe cleanup frees exactly the live allocation
   per axis (the new buffer if that realloc succeeded, else the original) and
   returns 0 with *ax..*asym untouched apart from the freed ones — the caller
   then abandons the buffers and returns NULL. No double-free whether all,
   none, or a subset succeed. */
static int grow4(double **ax, double **ay, double **az, char (**asym)[8], int ncap)
{
    double *tx = realloc(*ax, ncap * sizeof(double));
    double *ty = realloc(*ay, ncap * sizeof(double));
    double *tz = realloc(*az, ncap * sizeof(double));
    char (*ts)[8] = realloc(*asym, ncap * sizeof(*ts));
    if (!tx || !ty || !tz || !ts) {
        if (tx) free(tx); else free(*ax); *ax = NULL;
        if (ty) free(ty); else free(*ay); *ay = NULL;
        if (tz) free(tz); else free(*az); *az = NULL;
        if (ts) free(ts); else free(*asym); *asym = NULL;
        return 0;
    }
    *ax = tx; *ay = ty; *az = tz; *asym = ts;
    return 1;
}

MolEnvScene* parse_pwi(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    char line[1024];
    int ln = 0;
    int ibrav = 0, nat = 0, ntyp = 0;
    double celldm[7] = {0}; /* 1-indexed: celldm[1..6] */
    int in_system = 0;

    /* Species table from ATOMIC_SPECIES: symbol -> Z (max 32 species). */
    char species_sym[32][8];
    int species_z[32];
    int nspecies = 0;

    /* Raw atom data + position unit (dynamically grown). */
    int cap = 64, natoms = 0;
    double *ax = malloc(cap * sizeof(double));
    double *ay = malloc(cap * sizeof(double));
    double *az = malloc(cap * sizeof(double));
    char (*asym)[8] = malloc(cap * sizeof(*asym));
    char pos_unit[16] = "alat"; /* default */

    /* CELL_PARAMETERS (ibrav=0). */
    double cellpar[3][3] = {{0}};
    char cell_unit[16] = "alat";
    int have_cellpar = 0;

    if (!ax || !ay || !az || !asym) {
        free(ax); free(ay); free(az); free(asym);
        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
    }

    while (fgets(line, sizeof(line), fp)) {
        ln++;
        /* Strip leading/trailing whitespace + newlines. */
        char *p = line;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        size_t len = strlen(p);
        while (len > 0 && (p[len-1] == ' ' || p[len-1] == '\t' ||
                           p[len-1] == '\n' || p[len-1] == '\r')) p[--len] = '\0';

        if (in_system) {
            if (*p == '/') { in_system = 0; continue; }
            /* key = value (support multiple comma-separated assignments per line) */
            char *scan = p;
            while (scan && *scan) {
                while (*scan == ' ' || *scan == '\t') scan++;
                if (*scan == '\0' || *scan == '!' || *scan == '/') break;
                char *eq = strchr(scan, '=');
                if (!eq) break;
                char key[64];
                int klen = (int)(eq - scan);
                if (klen >= (int)sizeof(key)) klen = (int)sizeof(key) - 1;
                memcpy(key, scan, klen); key[klen] = '\0';
                while (klen > 0 && key[klen-1] == ' ') key[--klen] = '\0';
                char *vp = eq + 1;
                while (*vp == ' ') vp++;
                /* find end of value: comma, ! comment, or end of string */
                char *vend = vp;
                while (*vend && *vend != ',' && *vend != '!' && *vend != '/') vend++;
                char saved = *vend;
                if (*vend == ',' || *vend == '!' || *vend == '/') *vend = '\0';
                /* strip trailing spaces from value */
                char *ve = vend - 1;
                while (ve >= vp && (*ve == ' ' || *ve == '\t')) *ve-- = '\0';
                size_t vlen = strlen(vp);
                if (vlen >= 2 && ((vp[0]=='\'' && vp[vlen-1]=='\'') || (vp[0]=='"' && vp[vlen-1]=='"'))) {
                    vp[vlen-1] = '\0'; vp++;
                }

                int ci = celldm_index(key);
                if (ci >= 1 && ci <= 6) {
                    /* Validate finite: atof on overflowed values produces +/-inf
                       which silently corrupts the generated cell. */
                    char *celldm_end = NULL;
                    double cv = strtod(vp, &celldm_end);
                    if (!isfinite(cv)) {
                        free(ax); free(ay); free(az); free(asym);
                        fclose(fp); set_error(path, ln, "non-finite celldm value"); return NULL;
                    }
                    celldm[ci] = cv;
                } else if (strcasecmp(key, "ibrav") == 0) {
                    ibrav = atoi(vp);
                } else if (strcasecmp(key, "nat") == 0) {
                    char *endp = NULL;
                    long v = strtol(vp, &endp, 10);
                    if (endp == vp || !endp || (*endp != '\0' && *endp != ' ') || v < 1 || v > 500000) {
                        free(ax); free(ay); free(az); free(asym);
                        fclose(fp); set_error(path, ln, "nat out of range (1..500000)"); return NULL;
                    }
                    nat = (int)v;
                } else if (strcasecmp(key, "ntyp") == 0) {
                    char *endp = NULL;
                    long v = strtol(vp, &endp, 10);
                    if (endp == vp || !endp || (*endp != '\0' && *endp != ' ') || v < 1 || v > 32) {
                        free(ax); free(ay); free(az); free(asym);
                        fclose(fp); set_error(path, ln, "ntyp out of range (1..32)"); return NULL;
                    }
                    ntyp = (int)v;
                }
                if (saved == '!') break;
                if (saved == ',') { scan = vend + 1; continue; }
                break;
            }
            continue;
        }

        if (strcasecmp(p, "&SYSTEM") == 0) { in_system = 1; continue; }

        if (strcmp(p, "ATOMIC_SPECIES") == 0) {
            /* Read exactly ntyp species lines (skip blank/comment lines). */
            while (nspecies < ntyp && fgets(line, sizeof(line), fp)) {
                ln++;
                char *q = line;
                while (*q == ' ' || *q == '\t') q++;
                if (*q == '\0' || *q == '#' || *q == '/') continue;
                char sym[16], pp[256]; double mass;
                if (sscanf(q, "%15s %lf %255s", sym, &mass, pp) < 2) continue;
                if (nspecies >= 32) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "too many species (max 32)"); return NULL;
                }
                snprintf(species_sym[nspecies], sizeof(species_sym[0]), "%s", sym);
                char el[4]; qe_element(sym, el);
                species_z[nspecies] = molenv_symbol_to_z(el[0] ? el : sym);
                nspecies++;
            }
            continue;
        }

        if (strncmp(p, "ATOMIC_POSITIONS", 16) == 0) {
            /* optional {unit}, (unit), or bare keyword: "ATOMIC_POSITIONS crystal"
               (PWscf accepts all three forms). */
            char *b = strchr(p, '{');
            if (b) {
                char *be = strchr(b, '}');
                if (be) { *be = '\0'; snprintf(pos_unit, sizeof(pos_unit), "%s", b + 1); trim_in_place(pos_unit); }
            } else {
                char *op = strchr(p, '(');
                if (op) {
                    char *cp = strchr(op, ')');
                    if (cp) { *cp = '\0'; snprintf(pos_unit, sizeof(pos_unit), "%s", op + 1); trim_in_place(pos_unit); }
                } else {
                    /* bare form: the token after "ATOMIC_POSITIONS" is the unit */
                    char *u = p + 16;
                    while (*u == ' ' || *u == '\t') u++;
                    char *e = u;
                    while (*e && *e != ' ' && *e != '\t') e++;
                    if (*e) *e = '\0';
                    if (*u) { snprintf(pos_unit, sizeof(pos_unit), "%s", u); trim_in_place(pos_unit); }
                }
            }
            /* Read exactly nat position lines. */
            while (natoms < nat && fgets(line, sizeof(line), fp)) {
                ln++;
                char *q = line;
                while (*q == ' ' || *q == '\t') q++;
                if (*q == '\0' || *q == '#' || *q == '/') break;
                char sym[16]; double x, y, z;
                if (sscanf(q, "%15s %lf %lf %lf", sym, &x, &y, &z) < 4) break;
                if (natoms >= cap) {
                    if (cap > 1 << 29) {     /* never need more than this many slots */
                        if (ax) { free(ax); } if (ay) { free(ay); }
                        if (az) { free(az); } if (asym) { free(asym); }
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    int ncap = cap * 2;
                    if (ncap < cap) ncap = cap + (1 << 28); /* overflow-safe growth */
                    if (!grow4(&ax, &ay, &az, &asym, ncap)) {
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    cap = ncap;
                }
                snprintf(asym[natoms], sizeof(asym[0]), "%s", sym);
                ax[natoms] = x; ay[natoms] = y; az[natoms] = z;
                natoms++;
            }
            /* A QE input declares nat atoms and prints exactly nat position
               lines; exiting early means a truncated / malformed block. Refuse
               the partial structure rather than silently returning it. */
            if (nat > 0 && natoms != nat) {
                free(ax); free(ay); free(az); free(asym);
                fclose(fp); set_error(path, 0, "truncated ATOMIC_POSITIONS block"); return NULL;
            }
            continue;
        }

        if (strncasecmp(p, "CELL_PARAMETERS", 15) == 0) {
            char *b = strchr(p, '{');
            if (b) {
                char *be = strchr(b, '}');
                if (be) { *be = '\0'; snprintf(cell_unit, sizeof(cell_unit), "%s", b + 1); trim_in_place(cell_unit); }
            } else {
                char *op = strchr(p, '(');
                if (op) {
                    char *cp = strchr(op, ')');
                    if (cp) { *cp = '\0'; snprintf(cell_unit, sizeof(cell_unit), "%s", op + 1); trim_in_place(cell_unit); }
                } else {
                    /* bare form: CELL_PARAMETERS bohr / angstrom / alat */
                    char *u = p + 15;
                    while (*u == ' ' || *u == '\t') u++;
                    char *e = u;
                    while (*e && *e != ' ' && *e != '\t') e++;
                    *e = '\0';
                    if (*u) snprintf(cell_unit, sizeof(cell_unit), "%s", u);
                }
            }
            int r = 0;
            while (r < 3 && fgets(line, sizeof(line), fp)) {
                ln++;
                double u, v, w;
                if (sscanf(line, "%lf %lf %lf", &u, &v, &w) < 3) continue;
                cellpar[r][0] = u; cellpar[r][1] = v; cellpar[r][2] = w;
                r++;
            }
            have_cellpar = (r == 3);
            continue;
        }

        /* K_POINTS and anything else: skip. */
    }
    fclose(fp);

    /* Validate. */
    if (natoms == 0) {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "no ATOMIC_POSITIONS found"); return NULL;
    }

    /* Build the cell in Angstroms. */
    double cell[3][3];
    if (ibrav == 0) {
        if (!have_cellpar) {
            free(ax); free(ay); free(az); free(asym);
            set_error(path, 0, "ibrav=0 requires CELL_PARAMETERS"); return NULL;
        }
        /* cellpar is in cell_unit; convert to Ang. strcasecmp: valid uppercase
           tokens like (BOHR) must not silently fall through to angstrom. An
           unknown unit is a hard error, not a silent default. */
        float scale = 1.0f;
        if (strcasecmp(cell_unit, "bohr") == 0) scale = BOHR_TO_ANG;
        else if (strcasecmp(cell_unit, "alat") == 0) scale = (float)(celldm[1] * BOHR_TO_ANG);
        else if (strcasecmp(cell_unit, "angstrom") == 0) scale = 1.0f;
        else if (strcasecmp(cell_unit, "crystal") == 0) { /* fractional atoms need a cell below */ scale = 1.0f; }
        else {
            free(ax); free(ay); free(az); free(asym);
            set_error(path, 0, "unknown CELL_PARAMETERS unit in pwi"); return NULL;
        }
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) cell[i][j] = cellpar[i][j] * scale;
        /* Validate the derived cell is finite and in float range. */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
            if (!in_float_range(cell[i][j])) { free(ax); free(ay); free(az); free(asym); set_error(path, 0, "non-finite cell in pwi"); return NULL; }
    } else {
        if (latgen(ibrav, celldm, cell) != 0) {
            char buf[128]; snprintf(buf, sizeof(buf), "unsupported ibrav=%d", ibrav);
            free(ax); free(ay); free(az); free(asym);
            set_error(path, 0, buf); return NULL;
        }
        /* latgen returns Bohr -> convert to Ang. */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) cell[i][j] *= BOHR_TO_ANG;
        /* Validate the generated cell is finite and in float range. */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
            if (!in_float_range(cell[i][j])) { free(ax); free(ay); free(az); free(asym); set_error(path, 0, "non-finite cell from latgen"); return NULL; }
    }

    if (!cell_rank_usable(cell, 3)) {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "singular cell in pwi"); return NULL;
    }

    /* Convert atom positions to Cartesian Angstroms. */
    float pos_scale = 1.0f;
    int frac = 0;
    if (strcasecmp(pos_unit, "bohr") == 0) pos_scale = BOHR_TO_ANG;
    else if (strcasecmp(pos_unit, "alat") == 0) { pos_scale = (float)(celldm[1] * BOHR_TO_ANG); if (!isfinite(pos_scale) || !in_float_range((double)celldm[1] * BOHR_TO_ANG)) { free(ax); free(ay); free(az); free(asym); set_error(path, 0, "non-finite alat scale in pwi"); return NULL; } }
    else if (strcasecmp(pos_unit, "crystal") == 0) frac = 1;
    else if (strcasecmp(pos_unit, "angstrom") == 0) { /* scale=1 */ }
    else {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "unknown ATOMIC_POSITIONS unit in pwi"); return NULL;
    }

    MolEnvScene *s = new_scene(path);
    if (!s) { free(ax); free(ay); free(az); free(asym); return NULL; }
    s->atoms = calloc(natoms, sizeof(MolEnvAtom));
    if (!s->atoms) {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL;
    }

    for (int i = 0; i < natoms; i++) {
        double px = ax[i], py = ay[i], pz = az[i];
        double cx, cy, cz;
        if (frac) {
            cx = px*cell[0][0] + py*cell[1][0] + pz*cell[2][0];
            cy = px*cell[0][1] + py*cell[1][1] + pz*cell[2][1];
            cz = px*cell[0][2] + py*cell[1][2] + pz*cell[2][2];
        } else {
            cx = px * pos_scale; cy = py * pos_scale; cz = pz * pos_scale;
        }
        if (!in_float_range(cx) || !in_float_range(cy) || !in_float_range(cz)) {
            free(ax); free(ay); free(az); free(asym);
            molenv_scene_free(s); set_error(path, 0, "non-finite atom coordinate in pwi"); return NULL;
        }
        MolEnvAtom *a = &s->atoms[i];
        a->coord[0] = (float)cx; a->coord[1] = (float)cy; a->coord[2] = (float)cz;
        snprintf(a->label, sizeof(a->label), "%s", asym[i]);
        char el[4]; qe_element(asym[i], el);
        a->atomic_number = molenv_symbol_to_z(el[0] ? el : asym[i]);
    }
    free(ax); free(ay); free(az); free(asym);

    s->natoms = natoms;
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) s->cell[i][j] = (float)cell[i][j];
    s->is_crystal = 1;
    s->periodic_dim = 3;
    snprintf(s->title, sizeof(s->title), "%s", "QE structure");
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- Quantum Espresso PWscf output (.pwo) -----
   XCrySDen parses .pwo via scripts/pwo2xsf_anim.awk (+ pwo_xsf2xsf.f, which
   only adds CONVVEC). mcrysden's philosophy is native parsers (no shell filter,
   headless-friendly), so we reproduce the awk contract directly in C. Markers:

     bravais-lattice index     = <n>          -> ibrav (informational only)
     lattice parameter (alat)  = <val> a.u.   -> alat in Bohr
     number of atoms/cell      = <n>          -> nat
     crystal axes:  (cart. coord) ...         -> initial lattice (alat units)
     CELL_PARAMETERS [alat|angstrom|bohr]    -> PRIMVEC (latest block wins)
     ATOMIC_POSITIONS [alat|angstrom|bohr|crystal]  -> one block = one ionic step
     Forces acting on atoms                   -> ignored (not rendered)

   Each ATOMIC_POSITIONS block is a frame; the most recent CELL_PARAMETERS (or
   crystal axes) block supplies its cell. Units resolve to Angstroms via alat
   (celldm(1) bohr value) exactly as parse_pwi does. */

/* Count ATOMIC_POSITIONS blocks (= number of ionic steps). */
int molenv_pwo_frame_count(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[1024];
    int count = 0;
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (strncmp(p, "ATOMIC_POSITIONS", 16) == 0) count++;
    }
    fclose(fp);
    return count;
}

/* Read the next 3 lines as a 3x3 matrix (row-major) into m[3][3]. Returns 0 on
   success, -1 if fewer than 3 valid rows were found or any value is non-finite. */
static int read_3x3(FILE *fp, double m[3][3], int *ln, const char *path) {
    int r = 0;
    char line[1024];
    while (r < 3 && fgets(line, sizeof(line), fp)) {
        (*ln)++;
        double a, b, c;
        if (sscanf(line, "%lf %lf %lf", &a, &b, &c) < 3) continue;
        if (!isfinite(a) || !isfinite(b) || !isfinite(c)) {
            set_error(path, *ln, "non-finite matrix value");
            return -1;
        }
        m[r][0] = a; m[r][1] = b; m[r][2] = c;
        r++;
    }
    return (r == 3) ? 0 : -1;
}

/* Dispatch a unit token (alat|angstrom|bohr|crystal). Sets *scale (multiplier to
   Angstroms) and, for crystal, *frac=1. alat scales by alat_ang (Bohr->Å).
   Returns 0 on success, -1 if the unit is unknown (not bohr/angstrom/alat/crystal).
   Uses strcasecmp so valid uppercase tokens like (BOHR) are not silently ignored. */
static int unit_scales(const char *unit, double alat_ang, double *scale, int *frac) {
    *scale = 1.0; *frac = 0;
    if (strcasecmp(unit, "bohr") == 0) *scale = BOHR_TO_ANG;
    else if (strcasecmp(unit, "alat") == 0) {
        if (!isfinite(alat_ang) || alat_ang <= 0.0) return -1;
        *scale = alat_ang;
    }
    else if (strcasecmp(unit, "crystal") == 0) { *scale = 1.0; *frac = 1; }
    else if (strcasecmp(unit, "angstrom") == 0) { /* scale already 1 */ }
    else return -1;
    return 0;
}

/* Parse frame `frame_index` (0-based) of a .pwo file. Mirrors parse_pwi's memory
   discipline: dynamic atom arrays, frac->Cart via vectors-as-columns cell. */
MolEnvScene* parse_pwo(const char *path, int frame_index) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    char line[1024];
    int ln = 0;
    double alat_bohr = 0.0;     /* alat in Bohr; celldm(1) */
    int nat = 0;
    int have_alat = 0;

    /* Current cell (row-major lattice vectors, Angstroms) sourced from the most
       recent crystal-axes / CELL_PARAMETERS block. */
    double cell[3][3] = {{0}};
    int have_cell = 0;

    int cap = 64, natoms = 0;
    double *ax = malloc(cap * sizeof(double));
    double *ay = malloc(cap * sizeof(double));
    double *az = malloc(cap * sizeof(double));
    char (*asym)[8] = malloc(cap * sizeof(*asym));
    if (!ax || !ay || !az || !asym) {
        free(ax); free(ay); free(az); free(asym);
        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
    }

    int step = 0;            /* ATOMIC_POSITIONS block counter */
    int target_done = 0;     /* have we filled the requested frame? */

    while (fgets(line, sizeof(line), fp)) {
        ln++;
        char *p = line;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

        /* alat (celldm(1) in Bohr). */
        if (strncmp(p, "lattice parameter (alat)", 24) == 0) {
            char *eq = strchr(p, '=');
            if (eq) {
                alat_bohr = atof(eq + 1);
                if (!isfinite(alat_bohr) || alat_bohr <= 0.0) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "non-finite or non-positive alat in pwo"); return NULL;
                }
            }
            have_alat = 1;
            continue;
        }
        if (strncmp(p, "number of atoms/cell", 20) == 0) {
            /* Strict parse: atoi on overflowed values is undefined; strtol + endp
               rejects partial parses and caps at 500000. */
            char *eq = strrchr(p, '=');
            char *nat_str = eq ? eq + 1 : "0";
            char *nat_end = NULL;
            long nat_val = strtol(nat_str, &nat_end, 10);
            while (nat_end && (*nat_end == ' ' || *nat_end == '\t' || *nat_end == '\r' || *nat_end == '\n')) nat_end++;
            if (nat_end == nat_str || (nat_end && *nat_end != '\0') || nat_val < 1 || nat_val > 500000) {
                nat = 0;
            } else {
                nat = (int)nat_val;
            }
            continue;
        }

        /* Initial lattice from crystal axes (alat units). */
        if (strncmp(p, "crystal axes", 12) == 0) {
            if (read_3x3(fp, cell, &ln, path) == 0 && have_alat) {
                double alat_ang = alat_bohr * (double)BOHR_TO_ANG;
                int cell_ok = 1;
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++) {
                        cell[i][j] *= alat_ang;
                        if (!in_float_range(cell[i][j])) cell_ok = 0;
                    }
                if (!cell_ok) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "non-finite cell in pwo crystal axes"); return NULL;
                }
                have_cell = 1;
            }
            continue;
        }

        /* CELL_PARAMETERS block: latest overrides current cell. */
        if (strncmp(p, "CELL_PARAMETERS", 15) == 0) {
            char unit[16] = "alat";
            double local_alat = 0;
            char *op = strchr(p, '(');
            if (op) {
                char *cp = strchr(op, ')');
                if (cp) {
                    *cp = '\0';
                    char *u = op + 1;
                    while (*u == ' ') u++;
                    char *eq = strchr(u, '=');
                    if (eq && strncasecmp(u, "alat", 4) == 0) {
                        snprintf(unit, sizeof(unit), "alat");
                        char *val = eq + 1;
                        while (*val == ' ') val++;
                        double va = atof(val);
                        if (va > 0) local_alat = va * (double)BOHR_TO_ANG;
                    } else {
                        snprintf(unit, sizeof(unit), "%s", u);
                    }
                    trim_in_place(unit);
                }
            } else {
                char *u = p + 15;
                while (*u == ' ' || *u == '\t') u++;
                char *e = u;
                while (*e && *e != ' ' && *e != '\t') e++;
                *e = '\0';
                if (*u) snprintf(unit, sizeof(unit), "%s", u);
                trim_in_place(unit);
            }
            double raw[3][3];
            if (read_3x3(fp, raw, &ln, path) == 0) {
                double scale = 1.0; int frac_dummy = 0;
                double base_alat_ang = have_alat ? alat_bohr * (double)BOHR_TO_ANG : 0.0;
                double alat_ang = (local_alat > 0) ? local_alat : base_alat_ang;
                if (unit_scales(unit, alat_ang, &scale, &frac_dummy) != 0) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "unknown CELL_PARAMETERS unit in pwo"); return NULL;
                }
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++) {
                        cell[i][j] = raw[i][j] * scale;
                        if (!in_float_range(cell[i][j])) {
                            free(ax); free(ay); free(az); free(asym);
                            fclose(fp); set_error(path, ln, "non-finite cell in pwo CELL_PARAMETERS"); return NULL;
                        }
                    }
                have_cell = 1;
            }
            continue;
        }

        /* ATOMIC_POSITIONS block = one ionic step. */
        if (strncmp(p, "ATOMIC_POSITIONS", 16) == 0) {
            char unit[16] = "alat";
            char *op = strchr(p, '(');
            if (op) {
                char *cp = strchr(op, ')');
                if (cp) { *cp = '\0'; snprintf(unit, sizeof(unit), "%s", op + 1); trim_in_place(unit); }
            }
            double scale = 1.0; int frac = 0;
            double alat_ang = have_alat ? alat_bohr * (double)BOHR_TO_ANG : 0.0;
            if (unit_scales(unit, alat_ang, &scale, &frac) != 0) {
                free(ax); free(ay); free(az); free(asym);
                fclose(fp); set_error(path, ln, "unknown ATOMIC_POSITIONS unit in pwo"); return NULL;
            }

            const int is_target = (step == frame_index);
            int got = 0;
            while (got < nat && fgets(line, sizeof(line), fp)) {
                ln++;
                char *q = line;
                while (*q == ' ' || *q == '\t') q++;
                if (*q == '\0' || *q == '#') break;
                char sym[16]; double px, py, pz;
                if (sscanf(q, "%15s %lf %lf %lf", sym, &px, &py, &pz) < 4) break;
                if (!is_target) { got++; continue; }   /* skip non-target frames */
                if (!isfinite(px) || !isfinite(py) || !isfinite(pz)) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "non-finite atom coordinate in target pwo frame"); return NULL;
                }
                if (frac && !have_cell) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "fractional target frame requires a cell in pwo"); return NULL;
                }
                if (got >= cap) {
                    if (cap > 1 << 29) {
                        if (ax) { free(ax); } if (ay) { free(ay); }
                        if (az) { free(az); } if (asym) { free(asym); }
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    int ncap = cap * 2;
                    if (ncap < cap) ncap = cap + (1 << 28); /* overflow-safe growth */
                    if (!grow4(&ax, &ay, &az, &asym, ncap)) {
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    cap = ncap;
                }
                snprintf(asym[got], sizeof(asym[0]), "%s", sym);
                if (frac) {
                    /* crystal: fractional -> Cartesian, vectors-as-columns (cell[i][j]). */
                    double cx = px*cell[0][0] + py*cell[1][0] + pz*cell[2][0];
                    double cy = px*cell[0][1] + py*cell[1][1] + pz*cell[2][1];
                    double cz = px*cell[0][2] + py*cell[1][2] + pz*cell[2][2];
                    ax[got] = cx; ay[got] = cy; az[got] = cz;
                } else {
                    ax[got] = px * scale; ay[got] = py * scale; az[got] = pz * scale;
                }
                if (!in_float_range(ax[got]) || !in_float_range(ay[got]) || !in_float_range(az[got])) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, ln, "non-finite atom coordinate in target pwo frame"); return NULL;
                }
                got++;
            }
            if (is_target) {
                /* The block declares nat atoms; an early EOF / malformed line
                   would otherwise yield a truncated frame. Reject it. */
                if (nat > 0 && got != nat) {
                    free(ax); free(ay); free(az); free(asym);
                    fclose(fp); set_error(path, 0, "truncated ATOMIC_POSITIONS in target frame"); return NULL;
                }
                natoms = got; target_done = 1; break;
            }
            step++;
            continue;
        }
        /* Everything else (Forces, energies, Dynamics...) is skipped. */
    }
    fclose(fp);

    if (!target_done || natoms == 0) {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "no (target) ATOMIC_POSITIONS found");
        return NULL;
    }

    MolEnvScene *s = new_scene(path);
    if (!s) { free(ax); free(ay); free(az); free(asym); return NULL; }
    s->atoms = calloc(natoms, sizeof(MolEnvAtom));
    if (!s->atoms) {
        free(ax); free(ay); free(az); free(asym);
        set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL;
    }
    for (int i = 0; i < natoms; i++) {
        MolEnvAtom *a = &s->atoms[i];
        a->coord[0] = (float)ax[i]; a->coord[1] = (float)ay[i]; a->coord[2] = (float)az[i];
        snprintf(a->label, sizeof(a->label), "%s", asym[i]);
        char el[4]; qe_element(asym[i], el);
        a->atomic_number = molenv_symbol_to_z(el[0] ? el : asym[i]);
    }
    free(ax); free(ay); free(az); free(asym);

    s->natoms = natoms;
    if (have_cell) {
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
            s->cell[i][j] = (float)cell[i][j];
        if (!cell_rank_usable(cell, 3)) {
            molenv_scene_free(s); set_error(path, 0, "singular cell in pwo"); return NULL;
        }
    }
    s->is_crystal = have_cell;
    s->periodic_dim = 3;
    snprintf(s->title, sizeof(s->title), "%s", "QE PWscf output");
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- CIF ----- */

#define MAX_SYMOPS 192
#define MOLENV_ATOM_CAP 500000

/* Case-insensitive match for CIF symmetry-operation tag names. */
static int is_symop_tag(const char *tag) {
    return strcasecmp(tag, "_symmetry_equiv_pos_as_xyz") == 0 ||
           strcasecmp(tag, "_symmetry_equiv.pos_as_xyz") == 0 ||
           strcasecmp(tag, "_space_group_symop_operation_xyz") == 0 ||
           strcasecmp(tag, "_space_group_symop.operation_xyz") == 0;
}

/* Parse a CIF symmetry-operation expression "x, y, z", "-x, -y, -z", "x+1/2, y, z".
   Extracts a 3x3 integer rotation matrix `rot` (values -1/0/1) and a double
   translation vector `trans`. Returns 0 on success, -1 on error with a message
   written to `err` (cap `err_cap`). */
static int parse_symop(const char *str, int rot[3][3], double trans[3],
                        char *err, size_t err_cap)
{
    char buf[256];
    size_t slen = strlen(str);
    if (slen >= sizeof(buf)) { snprintf(err, err_cap, "symmetry operation too long"); return -1; }
    memcpy(buf, str, slen + 1);

    /* Trim trailing whitespace; a trailing comma after any number of
       collected components must be rejected. */
    {
        size_t blen = strlen(buf);
        while (blen > 0 && (buf[blen-1] == ' ' || buf[blen-1] == '\t')) buf[--blen] = '\0';
        if (blen > 0 && buf[blen-1] == ',') {
            snprintf(err, err_cap, "trailing comma in operation component"); return -1;
        }
    }

    /* Split on commas into exactly 3 nonempty component strings. */
    char *comps[3] = {NULL, NULL, NULL};
    int ncomp = 0;
    char *p = buf, *start = buf;
    while (*p) {
        if (*p == ',') {
            *p++ = '\0';
            while (*start == ' ' || *start == '\t') start++;
            if (*start == '\0') { snprintf(err, err_cap, "empty component in operation"); return -1; }
            if (ncomp >= 3) { snprintf(err, err_cap, "more than 3 components in operation"); return -1; }
            comps[ncomp++] = start;
            start = p;
        } else {
            p++;
        }
    }
    {
        while (*start == ' ' || *start == '\t') start++;
        if (*start) {
            if (ncomp >= 3) { snprintf(err, err_cap, "more than 3 components in operation"); return -1; }
            comps[ncomp++] = start;
        } else if (ncomp < 3) {
            snprintf(err, err_cap, "expected 3 components in operation, got %d", ncomp);
            return -1;
        }
    }
    /* Trailing comma results in empty last component — reject. */
    if (ncomp != 3) { snprintf(err, err_cap, "expected 3 components in operation, got %d", ncomp); return -1; }
    for (int k = 0; k < 3; k++) {
        char *t = comps[k];
        while (*t == ' ' || *t == '\t') t++;
        if (*t == '\0') { snprintf(err, err_cap, "empty component in operation"); return -1; }
    }

    memset(rot, 0, 9 * sizeof(int));
    trans[0] = trans[1] = trans[2] = 0.0;

    for (int c = 0; c < 3; c++) {
        char *s = comps[c];
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '\0') continue;

        int first = 1;
        while (*s) {
            while (*s == ' ' || *s == '\t') s++;
            if (*s == '\0') break;

            /* Check for / * or other non-affine continuation after a completed term. */
            if (!first) {
                if (*s == '/') {
                    s++; while (*s == ' ' || *s == '\t') s++;
                    char *dend = NULL; double den = strtod(s, &dend);
                    if (dend > s && den == 0.0) {
                        snprintf(err, err_cap, "zero denominator in operation component %d", c + 1);
                        return -1;
                    }
                    snprintf(err, err_cap, "non-affine term in operation component %d", c + 1);
                    return -1;
                }
                if (*s == '*' || *s == '.' || *s == ',') {
                    snprintf(err, err_cap, "non-affine term in operation component %d", c + 1);
                    return -1;
                }
            }

            int sign;
            if (*s == '+') { sign = 1; s++; }
            else if (*s == '-') { sign = -1; s++; }
            else if (first) { sign = 1; }
            else { snprintf(err, err_cap, "expected '+' or '-' between terms in operation component %d", c + 1); return -1; }
            first = 0;

            while (*s == ' ' || *s == '\t') s++;
            if (*s == '\0') { snprintf(err, err_cap, "incomplete term in operation component %d", c + 1); return -1; }

            /* Bare variable (x, y, z). */
            if ((*s == 'x' || *s == 'X') && !isalnum((unsigned char)s[1])) {
                rot[c][0] += sign; s++;
                goto term_done;
            }
            if ((*s == 'y' || *s == 'Y') && !isalnum((unsigned char)s[1])) {
                rot[c][1] += sign; s++;
                goto term_done;
            }
            if ((*s == 'z' || *s == 'Z') && !isalnum((unsigned char)s[1])) {
                rot[c][2] += sign; s++;
                goto term_done;
            }

            {
                /* Numeric coefficient, possibly with fraction or inf/nan. */
                char *nend = NULL;
                double coeff = strtod(s, &nend);
                if (nend == s) {
                    snprintf(err, err_cap, "invalid term in operation component %d", c + 1);
                    return -1;
                }
                if (!isfinite(coeff)) {
                    snprintf(err, err_cap, "non-finite (inf/nan) term in operation component %d", c + 1);
                    return -1;
                }
                s = nend;

                /* Fraction. */
                if (*s == '/') {
                    s++;
                    while (*s == ' ' || *s == '\t') s++;
                    char *dend = NULL;
                    double den = strtod(s, &dend);
                    if (dend == s || den == 0.0) {
                        snprintf(err, err_cap, "zero denominator in operation component %d", c + 1);
                        return -1;
                    }
                    if (!isfinite(den)) {
                        snprintf(err, err_cap, "non-finite (inf/nan) denominator in operation component %d", c + 1);
                        return -1;
                    }
                    coeff /= den;
                    s = dend;
                }

                if (!isfinite(coeff)) {
                    snprintf(err, err_cap, "non-finite (inf/nan) term in operation component %d", c + 1);
                    return -1;
                }

                while (*s == ' ' || *s == '\t') s++;
                if (*s == '*') { s++; while (*s == ' ' || *s == '\t') s++; }

                if (*s == 'x' || *s == 'X') {
                    if (coeff != floor(coeff) || coeff < -1.0 || coeff > 1.0) {
                        snprintf(err, err_cap, "rotation coefficient out of range [-1,1] in operation component %d", c + 1);
                        return -1;
                    }
                    rot[c][0] += sign * (int)coeff;
                    s++;
                } else if (*s == 'y' || *s == 'Y') {
                    if (coeff != floor(coeff) || coeff < -1.0 || coeff > 1.0) {
                        snprintf(err, err_cap, "rotation coefficient out of range [-1,1] in operation component %d", c + 1);
                        return -1;
                    }
                    rot[c][1] += sign * (int)coeff;
                    s++;
                } else if (*s == 'z' || *s == 'Z') {
                    if (coeff != floor(coeff) || coeff < -1.0 || coeff > 1.0) {
                        snprintf(err, err_cap, "rotation coefficient out of range [-1,1] in operation component %d", c + 1);
                        return -1;
                    }
                    rot[c][2] += sign * (int)coeff;
                    s++;
                } else {
                    trans[c] += sign * coeff;
                }
            }

        term_done:;
        }
    }

    /* Validate determinant is ±1. */
    {
        int det = rot[0][0] * (rot[1][1] * rot[2][2] - rot[1][2] * rot[2][1])
                - rot[0][1] * (rot[1][0] * rot[2][2] - rot[1][2] * rot[2][0])
                + rot[0][2] * (rot[1][0] * rot[2][1] - rot[1][1] * rot[2][0]);
        if (det != 1 && det != -1) {
            snprintf(err, err_cap, "singular rotation in operation (determinant %d)", det);
            return -1;
        }
    }

    return 0;
}

/* Compute inverse of a 3x3 cell matrix (columns are lattice vectors).
   Returns 0 on success, -1 if singular. Row norms of the inverse are
   written to `row_norm` (fractional shift per unit Cartesian distance). */
static int invert_cell(const float cell[3][3], double inv[3][3],
                        double row_norm[3]) {
    double a0=cell[0][0], a1=cell[0][1], a2=cell[0][2];
    double b0=cell[1][0], b1=cell[1][1], b2=cell[1][2];
    double c0=cell[2][0], c1=cell[2][1], c2=cell[2][2];
    double det = a0*(b1*c2-b2*c1) - a1*(b0*c2-b2*c0) + a2*(b0*c1-b1*c0);
    double scale = sqrt(a0*a0+a1*a1+a2*a2) * sqrt(b0*b0+b1*b1+b2*b2) * sqrt(c0*c0+c1*c1+c2*c2);
    if (fabs(det) <= 1e-15 * scale + 1e-30) return -1;
    double id = 1.0/det;
    inv[0][0] = (b1*c2-b2*c1)*id; inv[0][1] = (a2*c1-a1*c2)*id; inv[0][2] = (a1*b2-a2*b1)*id;
    inv[1][0] = (b2*c0-b0*c2)*id; inv[1][1] = (a0*c2-a2*c0)*id; inv[1][2] = (a2*b0-a0*b2)*id;
    inv[2][0] = (b0*c1-b1*c0)*id; inv[2][1] = (a1*c0-a0*c1)*id; inv[2][2] = (a0*b1-a1*b0)*id;
    for (int i = 0; i < 3; i++) {
        row_norm[i] = sqrt(inv[i][0]*inv[i][0]+inv[i][1]*inv[i][1]+inv[i][2]*inv[i][2]);
        if (row_norm[i] < 1e-30) row_norm[i] = 1e-30;
    }
    return 0;
}

/* Exact threshold predicate: returns 1 if two fractional positions have a
   periodic-image Cartesian distance < tol, 0 if none do, or -1 if the exact
   integer search box would be impractically large (pathological cell).  For
   each axis i, any integer shift n_i satisfying the bound is enumerated; the
   bound is derived from |d_i - n_i| <= tol * inv_norm[i]. */
#define DEDUP_BOX_LIMIT 100000
static int frac_within_tol(double fx1, double fy1, double fz1,
                            double fx2, double fy2, double fz2,
                            const float cell[3][3],
                            const double inv_norm[3],
                            double tol) {
    double df[3] = {fx1 - fx2, fy1 - fy2, fz1 - fz2};
    double tol_sq = tol * tol;

    int64_t lo[3], hi[3];
    int64_t nr[3];
    for (int i = 0; i < 3; i++) {
        double bound = tol * inv_norm[i];
        double d_lo = ceil(df[i] - bound - 1e-14);
        double d_hi = floor(df[i] + bound + 1e-14);
        if (d_lo < -1e15 || d_lo > 1e15 || d_hi < -1e15 || d_hi > 1e15) return -1;
        lo[i] = (int64_t)d_lo;
        hi[i] = (int64_t)d_hi;
        if (hi[i] < lo[i]) return 0;
        nr[i] = hi[i] - lo[i] + 1;
        if (nr[i] <= 0) return 0;
    }

    int64_t total = nr[0];
    if (total > DEDUP_BOX_LIMIT / nr[1]) return -1;
    total *= nr[1];
    if (total > DEDUP_BOX_LIMIT / nr[2]) return -1;
    total *= nr[2];
    if (total > DEDUP_BOX_LIMIT) return -1;

    for (int n0 = lo[0]; n0 <= hi[0]; n0++) {
        double d0 = df[0] - n0;
        for (int n1 = lo[1]; n1 <= hi[1]; n1++) {
            double d1 = df[1] - n1;
            double cx1 = d0 * cell[0][0] + d1 * cell[1][0];
            double cy1 = d0 * cell[0][1] + d1 * cell[1][1];
            double cz1 = d0 * cell[0][2] + d1 * cell[1][2];
            for (int n2 = lo[2]; n2 <= hi[2]; n2++) {
                double d2 = df[2] - n2;
                double cx = cx1 + d2 * cell[2][0];
                double cy = cy1 + d2 * cell[2][1];
                double cz = cz1 + d2 * cell[2][2];
                double sq = cx*cx + cy*cy + cz*cz;
                if (sq < tol_sq) return 1;
            }
        }
    }
    return 0;
}

/* Dedup hash table for symmetry expansion. Key is bucket index in
   fractional space.  Scale is derived from the cell's minimum singular
   value so that any two atoms within 1e-5 Angstrom Cartesian distance
   are guaranteed to fall in the same or adjacent buckets, with PBC
   handled by wrapped bucket indices. */
#define DEDUP_TOL 1e-5

typedef struct {
    int bx, by, bz;
    int atomic_number;
    char *label;             /* strdup'd; freed when table is destroyed */
    double fx, fy, fz;        /* fractional coords for distance check */
    int occupied;
} DedupEntry;

static uint64_t dedup_hash(int bx, int by, int bz, int z, const char *label) {
    uint64_t h = 0xcbf29ce484222325ULL;
    h ^= (uint64_t)(int32_t)bx; h *= 0x100000001b3ULL;
    h ^= (uint64_t)(int32_t)by; h *= 0x100000001b3ULL;
    h ^= (uint64_t)(int32_t)bz; h *= 0x100000001b3ULL;
    h ^= (uint64_t)(uint32_t)z;  h *= 0x100000001b3ULL;
    if (z == 0) {
        for (const char *p = label; *p; p++) {
            h ^= (uint64_t)(unsigned char)*p; h *= 0x100000001b3ULL;
        }
    }
    return h;
}

/* Free all strdup'd labels in the hash table. */
static void dedup_free_labels(DedupEntry *ht, size_t size) {
    if (!ht) return;
    for (size_t i = 0; i < size; i++) {
        if (ht[i].occupied) free(ht[i].label);
    }
}

/* Insert a new dedup entry. Label is strdup'd. Returns 0 on success, -1 on
   table full or allocation failure. */
static int dedup_insert(DedupEntry *ht, size_t ht_size, int bx, int by, int bz,
                         int z, const char *label,
                         double fx, double fy, double fz) {
    uint64_t h = dedup_hash(bx, by, bz, z, label);
    for (uint32_t i = 0; i < (uint32_t)ht_size; i++) {
        uint32_t pos = (uint32_t)((h + i) % ht_size);
        DedupEntry *e = &ht[pos];
        if (!e->occupied) {
            e->bx = bx; e->by = by; e->bz = bz;
            e->atomic_number = z;
            e->label = strdup(label);
            if (!e->label) return -1;
            e->fx = fx; e->fy = fy; e->fz = fz;
            e->occupied = 1;
            return 0;
        }
    }
    return -1;
}

/* Tri-state duplicate check: returns 1 if candidate matches any previously
   inserted atom within DEDUP_TOL, 0 if not, or -1 on error (pathological
   cell prevents exact check).  Probes 3×3×3 periodic neighbor buckets and
   uses the exact frac_within_tol predicate for each potential match. */
static int dedup_is_dup(DedupEntry *ht, size_t ht_size,
                         double fx, double fy, double fz,
                         int z, const char *label,
                         const float cell[3][3],
                         const double inv_norm[3],
                         int nbx, int nby, int nbz) {
    int bx = (int)floor(fx*nbx); bx %= nbx; if (bx < 0) bx += nbx;
    int by = (int)floor(fy*nby); by %= nby; if (by < 0) by += nby;
    int bz = (int)floor(fz*nbz); bz %= nbz; if (bz < 0) bz += nbz;

    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dz = -1; dz <= 1; dz++) {
                int px = (bx+dx) % nbx; if (px < 0) px += nbx;
                int py = (by+dy) % nby; if (py < 0) py += nby;
                int pz = (bz+dz) % nbz; if (pz < 0) pz += nbz;

                uint64_t h = dedup_hash(px, py, pz, z, label);
                for (uint32_t i = 0; i < (uint32_t)ht_size; i++) {
                    uint32_t pos = (uint32_t)((h+i) % ht_size);
                    DedupEntry *e = &ht[pos];
                    if (!e->occupied) break;
                    if (e->bx == px && e->by == py && e->bz == pz &&
                        e->atomic_number == z &&
                        (z != 0 || strcmp(e->label, label) == 0)) {
                        int r = frac_within_tol(fx, fy, fz,
                                                e->fx, e->fy, e->fz,
                                                cell, inv_norm, DEDUP_TOL);
                        if (r < 0) return -1;
                        if (r > 0) return 1;
                    }
                }
            }
        }
    }
    return 0;
}

/* Split a line into whitespace-delimited tokens, respecting single- and
   double-quoted strings (a quoted value never splits on internal spaces).
   Tokens point into the (mutated) line buffer. Returns token count on
   success, or -1 if an unterminated quoted string is encountered. */
static int split_tokens(char *p, char **toks, int maxtoks) {
    int n = 0;
    while (*p && n < maxtoks) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == '\0') break;
        char *start;
        if (*p == '\'' || *p == '"') {
            char q = *p++; start = p;
            while (*p && *p != q && *p != '\n' && *p != '\r') p++;
            if (*p == q) { *p++ = '\0'; }
            else { return -1; }
        } else {
            start = p;
            while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
            if (*p) { *p++ = '\0'; }
        }
        toks[n++] = start;
    }
    return n;
}

/* Strict parse of a CIF numeric value. Accepts ".5", signed decimals,
   trailing uncertainty "(digits)" before optional exponent, and rejects
   ".", "?", empty, NaN/Inf, hex/octal/binary, garbage-after-parse.
   Verifies finite after exponent application.
   Returns 0 on success, -1 on failure (output not modified). */
static int cif_strict_float(const char *s, double *out) {
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '\0') return -1;
    if (s[0] == '?' || (s[0] == '.' && (s[1] == '\0' || s[1] == ' ' || s[1] == '\t' || s[1] == '('))) return -1;
    if (strstr(s, "0x") || strstr(s, "0X") || strstr(s, "0o") || strstr(s, "0O") ||
        strstr(s, "0b") || strstr(s, "0B")) return -1;
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s || !isfinite(v)) return -1;
    s = end;
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '(') {
        s++;
        if (*s < '0' || *s > '9') return -1;
        while (*s >= '0' && *s <= '9') s++;
        if (*s != ')') return -1;
        s++;
    }
    /* Exponent after uncertainty. */
    if (*s == 'e' || *s == 'E') {
        s++;
        if (*s == '+' || *s == '-') s++;
        char *exp_end = NULL;
        long exp = strtol(s, &exp_end, 10);
        if (exp_end > s) { v *= pow(10.0, (double)exp); s = exp_end; }
        else return -1;
    }
    if (!isfinite(v)) return -1;
    while (*s == ' ' || *s == '\t') s++;
    if (*s != '\0') return -1;
    *out = v;
    return 0;
}

/* Resolve an element symbol for a CIF atom label (e.g. "Fe1" -> "Fe",
   "Fe3+" -> "Fe", "CA" -> "Ca"). Strips trailing digits and charge
   indicators (+/-). Writes the canonical symbol into el (at most 3 chars
   + NUL, so the buffer needs >= 4 bytes) and returns its atomic number
   via molenv_symbol_to_z. Unknown -> el empty, Z 0. */
static int cif_resolve_z(const char *label, char *el) {
    char t[8] = {0};
    int i = 0;
    while (label[i] && i < 6) { t[i] = label[i]; i++; }
    t[i] = '\0';
    int stripped = 1;
    while (stripped) {
        stripped = 0;
        while (i > 0 && t[i - 1] >= '0' && t[i - 1] <= '9') { t[--i] = '\0'; stripped = 1; }
        if (i > 0 && (t[i - 1] == '+' || t[i - 1] == '-')) { t[--i] = '\0'; stripped = 1; }
    }
    if (i == 0) { el[0] = '\0'; return 0; }
    if (i > 3) i = 3; /* canonical symbols are <= 2 letters; cap defensively */
    el[0] = (char)toupper((unsigned char)t[0]);
    for (int k = 1; k < i; k++) el[k] = (char)tolower((unsigned char)t[k]);
    el[i] = '\0';
    return molenv_symbol_to_z(el);
}

/* Build a row-major 3x3 lattice from a,b,c,alpha,beta,gamma (degrees):
   a along x, b in the xy-plane. Returns 0 on success, -1 if any derived
   component is non-finite or out of float range. The cell overflows to ±inf
   on the (float) cast when extreme lengths meet a near-zero sin(gamma)
   (division blows up); bounds are already checked on the inputs, so any
   failure here is the derived arithmetic, not a bad input. */
static int cif_build_cell(double a, double b, double c,
                          double alpha, double beta, double gamma,
                          float cell[3][3]) {
    double gal = gamma * PI / 180.0;
    double alr = alpha * PI / 180.0;
    double ber = beta * PI / 180.0;
    double cgal = cos(gal), sg = sin(gal), cber = cos(ber), cal = cos(alr);
    double cx = c * cber;
    double cy = c * (cal - cber * cgal) / sg;
    double cz2 = c * c - cx * cx - cy * cy;
    if (cz2 <= 0) cz2 = 0;
    double cz = sqrt(cz2);
    /* Validate every derived component in double before the (float) cast —
       cx/cy/cz can overflow to ±inf even from finite a/b/c/angles. */
    if (!in_float_range(a) || !in_float_range(b * cgal) || !in_float_range(b * sg) ||
        !in_float_range(cx) || !in_float_range(cy) || !in_float_range(cz)) {
        return -1;
    }
    cell[0][0] = (float)a; cell[0][1] = 0.0f; cell[0][2] = 0.0f;
    cell[1][0] = (float)(b * cgal); cell[1][1] = (float)(b * sg); cell[1][2] = 0.0f;
    cell[2][0] = (float)cx; cell[2][1] = (float)cy; cell[2][2] = (float)cz;
    return 0;
}

/* ---------- Group validation for declared symmetry operations ---------- */

/* Check if two 3x3 rotation matrices are equal. */
static int rot_eq(int a[3][3], int b[3][3]) {
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            if (a[i][j] != b[i][j]) return 0;
    return 1;
}

/* Check if two translation vectors are equivalent modulo lattice (tol 1e-10). */
static int trans_eq_mod1(double a[3], double b[3]) {
    for (int i = 0; i < 3; i++) {
        double d = remainder(a[i] - b[i], 1.0);
        if (fabs(d) > 1e-10) return 0;
    }
    return 1;
}

/* Compose two Seitz operations: (R2|t2) ° (R1|t1) = (R2*R1 | t2 + R2*t1). */
static void seitz_compose(int r1[3][3], double t1[3],
                           int r2[3][3], double t2[3],
                           int rout[3][3], double tout[3]) {
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            rout[i][j] = r2[i][0]*r1[0][j] + r2[i][1]*r1[1][j] + r2[i][2]*r1[2][j];
        }
        tout[i] = t2[i] + r2[i][0]*t1[0] + r2[i][1]*t1[1] + r2[i][2]*t1[2];
    }
}

/* Validate that the nops declared symmetry operations are valid and
   self-consistent.  Checks identity presence and metric preservation.
   Returns 0 on success, -1 on failure with error message written to
   `err`. */
static int validate_symmetry_group(int nops, int rot[MAX_SYMOPS][3][3],
                                    double trans[MAX_SYMOPS][3],
                                    const float cell[3][3],
                                    char *err, size_t err_cap) {
    /* 1. Identity must be present. */
    int id_rot[3][3] = {{1,0,0},{0,1,0},{0,0,1}};
    double zero[3] = {0};
    int found_id = 0;
    for (int i = 0; i < nops; i++) {
        if (rot_eq(rot[i], id_rot) && trans_eq_mod1(trans[i], zero)) {
            found_id = 1; break;
        }
    }
    if (!found_id) {
        snprintf(err, err_cap, "no identity operation in symmetry group");
        return -1;
    }

    /* 2. Metric preservation: each rotation must satisfy R^T * G * R = G.
          Tolerance is component-local (scale-aware), not a global gmax.
          An anisotropic cell should not admit incompatible swaps while
          float-rounded valid cells pass. */
    double G[3][3];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            G[i][j] = cell[i][0]*(double)cell[j][0] +
                      cell[i][1]*(double)cell[j][1] +
                      cell[i][2]*(double)cell[j][2];

    for (int m = 0; m < nops; m++) {
        double RG[3][3], RTGR[3][3];
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                RG[i][j] = rot[m][0][i]*G[0][j] +
                           rot[m][1][i]*G[1][j] +
                           rot[m][2][i]*G[2][j];
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                RTGR[i][j] = RG[i][0]*rot[m][0][j] +
                             RG[i][1]*rot[m][1][j] +
                             RG[i][2]*rot[m][2][j];
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++) {
                double scale = sqrt(fabs(G[i][i] * G[j][j]));
                double mtol = 8.0 * FLT_EPSILON * scale;
                if (fabs(RTGR[i][j] - G[i][j]) > mtol) {
                    snprintf(err, err_cap, "operation does not preserve cell metric");
                    return -1;
                }
            }
    }

    /* 3. Closure under composition: every ordered pair product
          must match a declared operation (rotation + translation mod 1). */
    for (int i = 0; i < nops; i++) {
        for (int j = 0; j < nops; j++) {
            int r_comp[3][3];
            double t_comp[3];
            seitz_compose(rot[j], trans[j],
                          rot[i], trans[i],
                          r_comp, t_comp);
            int found = 0;
            for (int k = 0; k < nops; k++) {
                if (rot_eq(r_comp, rot[k]) &&
                    trans_eq_mod1(t_comp, trans[k])) {
                    found = 1; break;
                }
            }
            if (!found) {
                snprintf(err, err_cap, "symmetry group not closed under composition");
                return -1;
            }
        }
    }

    return 0;
}

/* ---------- CIF token-stream reader ---------- */

/* CIF tokenizer context — parse-local, no global state. */
typedef struct {
    char unread[2048];
    int have_unread;
    int unread_quoted;  /* quoted status of the unread token */
    int unread_line;    /* line number of the unread token */
    int line;           /* updated by each token read */
    int quoted;         /* whether last-read token was quoted */
    int error;          /* non-zero if last read encountered a fatal error */
} CIFTokCtx;

static int cif_read_token(CIFTokCtx *ctx, FILE *fp, char *buf, size_t cap) {
    int c;
    ctx->error = 0;
    ctx->quoted = 0;

    if (ctx->have_unread) {
        strncpy(buf, ctx->unread, cap - 1); buf[cap - 1] = '\0';
        ctx->quoted = ctx->unread_quoted;
        ctx->line = ctx->unread_line;
        ctx->have_unread = 0;
        return 1;
    }

top:
    c = fgetc(fp);
    {
        int col = 1;
        while (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (c == '\n') { ctx->line++; col = 1; }
            else if (c == ' ' || c == '\t') { col++; }
            c = fgetc(fp);
        }
        if (c == EOF) return 0;
        if (c == '#') {
            while ((c = fgetc(fp)) != EOF && c != '\n');
            if (c == '\n') ctx->line++;
            goto top;
        }
        if (c == ';' && col == 1) {
            ctx->quoted = 1;
            int i = 0;
            int eol = 1;
            /* Capture content after opening ';' as the first line of text.
               Normalize CRLF to LF: \r\n is a single line ending, bare \r is
               content. */
            while ((c = fgetc(fp)) != EOF && c != '\n') {
                if (c == '\r') {
                    int p = fgetc(fp);
                    if (p == '\n') { c = '\n'; break; }
                    if (p != EOF) ungetc(p, fp);
                }
                if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
                buf[i++] = c;
                eol = 0;
            }
            if (c == EOF) { ctx->error = 1; buf[0] = '\0'; return 0; }
            if (c == '\n') { ctx->line++; eol = 1; }
            /* Read subsequent lines until ';' in column 1. */
            while ((c = fgetc(fp)) != EOF) {
                if (c == '\r') {
                    int p = fgetc(fp);
                    if (p == '\n') c = '\n';
                    else { if (p != EOF) ungetc(p, fp); }
                }
                if (eol && c == ';') break;
                if (c == '\n') {
                    ctx->line++;
                    int next = fgetc(fp);
                    if (next == '\r') {
                        int nn = fgetc(fp);
                        if (nn == '\n') next = '\n';
                        else { if (nn != EOF) ungetc(nn, fp); }
                    }
                    if (next == ';') break;
                    if (next != EOF) {
                        if (next == '\n') { /* blank line: keep the newline */
                            ctx->line++;
                            if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
                            buf[i++] = '\n';
                            eol = 1;
                            continue;
                        }
                        ungetc(next, fp);
                    }
                    if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
                    buf[i++] = '\n';
                    eol = 1;
                } else {
                    if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
                    buf[i++] = c;
                    eol = 0;
                }
            }
            if (c == EOF) { ctx->error = 1; buf[0] = '\0'; return 0; }
            buf[i] = '\0';
            return 1;
        }
    }

    int i = 0;

    /* single/double-quoted.
       The closing quote is recognized only when followed by whitespace
       or EOF. A '#' immediately after the quote is NOT a legal
       closing/comment boundary — CIF comments require a whitespace/token
       boundary before '#' — so it is preserved as literal continuation on
       the embedded-quote path. A closing quote followed by whitespace then
       '#' remains a valid token followed by a comment. */
    if (c == '\'' || c == '"') {
        ctx->quoted = 1;
        char q = c;
        int escaped = 0;
        while ((c = fgetc(fp)) != EOF) {
            if (c == q) {
                int peek = fgetc(fp);
                if (peek == EOF || peek == ' ' || peek == '\t' || peek == '\n' || peek == '\r') {
                    if (peek == '\n') {
                        ctx->line++;
                    } else if (peek != EOF) {
                        ungetc(peek, fp);
                    }
                    break;
                }
                /* Quote char inside the string: emit it and continue. */
                if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
                buf[i++] = (char)q;
                if (peek != EOF) ungetc(peek, fp);
                continue;
            }
            if (c == '\n') { ctx->line++; ctx->error = 1; buf[0] = '\0'; return 0; }
            if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
            buf[i++] = c;
        }
        if (c == EOF) { ctx->error = 1; buf[0] = '\0'; return 0; }
        buf[i] = '\0';
        return 1;
    }

    /* unquoted: read until whitespace, EOF, or inline comment.
       '#' at token boundary (i==0) starts a comment; inside a token
       it is ordinary data. */
    while (c != EOF && c != ' ' && c != '\t' && c != '\n' && c != '\r') {
        if (c == '#') {
            if (i == 0) break;
            if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
            buf[i++] = c;
            c = fgetc(fp);
            continue;
        }
        if (i >= (int)cap - 1) { ctx->error = 1; buf[0] = '\0'; return 0; }
        buf[i++] = c;
        c = fgetc(fp);
    }
    buf[i] = '\0';
    if (c == '#') {
        while ((c = fgetc(fp)) != EOF && c != '\n');
        if (c == '\n') ctx->line++;
    } else if (c == '\n') {
        ctx->line++;
    } else if (c != EOF) {
        ungetc(c, fp);
    }
    return 1;
}

static void cif_unread(CIFTokCtx *ctx, const char *tok) {
    strncpy(ctx->unread, tok, sizeof(ctx->unread) - 1);
    ctx->unread[sizeof(ctx->unread) - 1] = '\0';
    ctx->have_unread = 1;
    ctx->unread_quoted = ctx->quoted;
    ctx->unread_line = ctx->line;
}

static int is_cell_tag(const char *tag) {
    return strcasecmp(tag, "_cell_length_a") == 0 ||
           strcasecmp(tag, "_cell_length_b") == 0 ||
           strcasecmp(tag, "_cell_length_c") == 0 ||
           strcasecmp(tag, "_cell_angle_alpha") == 0 ||
           strcasecmp(tag, "_cell_angle_beta") == 0 ||
           strcasecmp(tag, "_cell_angle_gamma") == 0;
}

/* Predefined symmetrically expected defaults for cell angles (used only when
   all six cell fields are NOT present, so completeness is never claimed). */
#define CIF_DEFAULT_ANGLE 90.0

/* ---------- CIF parser ---------- */

MolEnvScene* parse_cif(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    /* Cell parameters with presence tracking. */
    double len_a = 0, len_b = 0, len_c = 0;
    double al_deg = CIF_DEFAULT_ANGLE, be_deg = CIF_DEFAULT_ANGLE, ga_deg = CIF_DEFAULT_ANGLE;
    int cell_present[6] = {0};

    /* Working atom buffer. We record a per-atom `frac` flag and the raw
       (fractional) coordinates, then convert to Cartesian in a second pass
       once the cell parameters are known — the cell tags can legally appear
       before or after the atom loop. */
    typedef struct { double coord[3]; int atomic_number; char *label; int frac; } Catom;
    Catom *at = NULL;
    int natoms = 0, acap = 0;
    char title[256] = {0};

    enum { NORM, LOOP_HDRS, LOOP_DATA };
    int state = NORM;
    int col_label = -1, col_type = -1;
    int col_fx = -1, col_fy = -1, col_fz = -1;
    int col_cx = -1, col_cy = -1, col_cz = -1;
    int ncols = 0;
    int atom_loop = 0;

    /* Symmetry operation tracking. */
    int symop_rot[MAX_SYMOPS][3][3];
    double symop_trans[MAX_SYMOPS][3];
    int nops = 0, symop_loop = 0, col_symop = -1, have_symops = 0;
    int symop_missing = 0;

    /* Token accumulator for loop data rows. row_quoted parallels row_toks,
       recording the quoted status of each accumulated token (quoted tokens
       are never control words, and their `.`/`?` content is literal data). */
    char *row_toks[64];
    int row_quoted[64];
    int row_used = 0;
    int in_block = 0;
    int block_started = 0;

    char tok_buf[2048];
    CIFTokCtx ctx = {0};
    while (1) {
        if (!cif_read_token(&ctx, fp, tok_buf, sizeof(tok_buf))) {
            if (ctx.error) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp); set_error(path, ctx.line, "unterminated CIF token"); return NULL;
            }
            /* Check for partial row on EOF. */
            if (state == LOOP_DATA && row_used > 0) {
                for (int k = 0; k < row_used; k++) free(row_toks[k]);
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp);
                set_error(path, ctx.line, "partial CIF loop data row"); return NULL;
            }
            break;
        }
        char *tok = tok_buf;

        if (state == LOOP_DATA) {
            int is_break = (!ctx.quoted &&
                            (tok[0] == '_' ||
                             strcasecmp(tok, "loop_") == 0 ||
                             strncasecmp(tok, "data_", 5) == 0 ||
                             strcasecmp(tok, "stop_") == 0 ||
                             strncasecmp(tok, "save_", 5) == 0 ||
                             strcasecmp(tok, "global_") == 0));

            if (is_break && row_used == 0) {
                state = NORM; cif_unread(&ctx, tok); continue;
            }
            if (is_break && row_used > 0) {
                for (int k = 0; k < row_used; k++) free(row_toks[k]);
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp);
                set_error(path, ctx.line, "partial CIF loop data row"); return NULL;
            }

            row_toks[row_used++] = strdup(tok);
            if (!row_toks[row_used - 1]) {
                for (int k = 0; k < row_used - 1; k++) free(row_toks[k]);
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp); set_error(path, ctx.line, "out of memory"); return NULL;
            }
            row_quoted[row_used - 1] = ctx.quoted;

            if (row_used == ncols) {
                if (symop_loop && col_symop >= 0 && col_symop < ncols) {
                    char *val = row_toks[col_symop];
                    if (!row_quoted[col_symop] && (strcmp(val, ".") == 0 || strcmp(val, "?") == 0)) {
                        symop_missing = 1;
                    } else if (nops >= MAX_SYMOPS) {
                        for (int k = 0; k < ncols; k++) free(row_toks[k]);
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "too many symmetry operations; exceeded max 192"); return NULL;
                    } else {
                        char *valp = val;
                        size_t vl = strlen(valp);
                        while (vl > 0 && (valp[vl-1] == ' ' || valp[vl-1] == '\t')) valp[--vl] = '\0';
                        char op_err[128];
                        if (parse_symop(valp, symop_rot[nops], symop_trans[nops], op_err, sizeof(op_err)) < 0) {
                            for (int k = 0; k < ncols; k++) free(row_toks[k]);
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp); set_error(path, ctx.line, op_err); return NULL;
                        }
                        nops++; have_symops = 1;
                    }
                }

                if (atom_loop && (col_fx >= 0 || col_cx >= 0)) {
                    int is_frac = (col_fx >= 0);
                    int cx = is_frac ? col_fx : col_cx;
                    int cy = is_frac ? col_fy : col_cy;
                    int cz = is_frac ? col_fz : col_cz;
                    if (cx >= 0 && cy >= 0 && cz >= 0 && cx < ncols && cy < ncols && cz < ncols) {
                        double fx, fy, fz;
                        if (cif_strict_float(row_toks[cx], &fx) < 0 ||
                            cif_strict_float(row_toks[cy], &fy) < 0 ||
                            cif_strict_float(row_toks[cz], &fz) < 0) {
                            for (int k = 0; k < ncols; k++) free(row_toks[k]);
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp);
                            set_error(path, ctx.line, "malformed or non-finite atom coordinate"); return NULL;
                        }
                        if (!in_float_range(fx) || !in_float_range(fy) || !in_float_range(fz)) {
                            for (int k = 0; k < ncols; k++) free(row_toks[k]);
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp);
                            set_error(path, ctx.line, "non-finite atom coordinate"); return NULL;
                        }

                        const char *lbl = (col_label >= 0 && col_label < ncols) ? row_toks[col_label] : NULL;
                        const char *ts_val = (col_type >= 0 && col_type < ncols) ? row_toks[col_type] : NULL;
                        int type_present = (ts_val && (row_quoted[col_type] || (strcmp(ts_val, ".") != 0 && strcmp(ts_val, "?") != 0)));
                        char el[8] = {0};
                        int z = 0;
                        if (type_present)
                            z = cif_resolve_z(ts_val, el);
                        if (z == 0 && !type_present && lbl)
                            z = cif_resolve_z(lbl, el);

                        if (natoms >= 500000) {
                            for (int k = 0; k < ncols; k++) free(row_toks[k]);
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp);
                            set_error(path, ctx.line, "too many CIF atoms"); return NULL;
                        }
                        if (natoms >= acap) {
                            acap = acap ? acap * 2 : 16;
                            Catom *t = realloc(at, acap * sizeof(Catom));
                            if (!t) {
                                for (int k = 0; k < ncols; k++) free(row_toks[k]);
                                for (int k = 0; k < natoms; k++) free(at[k].label);
                                free(at); fclose(fp);
                                set_error(path, ctx.line, "out of memory"); return NULL;
                            }
                            at = t;
                        }
                        Catom *a = &at[natoms];
                        a->coord[0] = fx;
                        a->coord[1] = fy;
                        a->coord[2] = fz;
                        a->frac = is_frac;
                        a->atomic_number = z;
                        if (z != 0 && el[0]) {
                            a->label = strdup(el);
                        } else if (type_present) {
                            a->label = strdup(ts_val);
                        } else if (lbl) {
                            a->label = strdup(lbl);
                        } else {
                            a->label = strdup("");
                        }
                        if (!a->label) {
                            for (int k = 0; k < ncols; k++) free(row_toks[k]);
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp);
                            set_error(path, ctx.line, "out of memory"); return NULL;
                        }
                        natoms++;
                    }
                }

                for (int k = 0; k < ncols; k++) free(row_toks[k]);
                row_used = 0;
            }
            continue;
        }

        /* NORM or LOOP_HDRS handling. */

        /* First data block: capture title and start reading. Subsequent data_
           blocks terminate the first block. */
        if (ctx.quoted) { /* quoted tokens are never controls: skip */ }
        else if (strncasecmp(tok, "data_", 5) == 0) {
            if (state == LOOP_HDRS) state = NORM;
            if (!block_started) {
                in_block = 1;
                block_started = 1;
                snprintf(title, sizeof(title), "%s", tok + 5);
            } else {
                /* A second data_ block (e.g. after a global_ scope) must not
                   re-enter and contaminate the already-selected first block. */
                break;
            }
            continue;
        }
        else if (strcasecmp(tok, "global_") == 0) {
            if (state == LOOP_HDRS) state = NORM;
            if (in_block) {
                /* global_ after the selected first data block has begun: leave
                   that block and enter an ignored global scope so subsequent
                   global tags/loops cannot contaminate the parsed structure or
                   its completeness. in_block=0 routes the rest through the
                   !in_block skip guard below. */
                in_block = 0;
            }
            /* global_ before the first data_ block must not consume it.
               Skip global_ content without setting in_block. */
            continue;
        }

        /* stop_ terminates only the current loop; data block stays active. */
        if (!ctx.quoted && strcasecmp(tok, "stop_") == 0) {
            if (state == LOOP_HDRS) state = NORM;
            continue;
        }
        /* save_<name> enters a nested save frame; closing save_ returns to
           the parent data block rather than discarding it. Skip through the
           entire save frame. */
        if (!ctx.quoted && strncasecmp(tok, "save_", 5) == 0) {
            if (state == LOOP_HDRS) state = NORM;
            if (strcasecmp(tok, "save_") != 0) {
                /* save_<name>: skip all content until matching save_ */
                char tmp[2048];
                int depth = 1;
                while (depth > 0 && cif_read_token(&ctx, fp, tmp, sizeof(tmp))) {
                    if (ctx.quoted) continue;
                    if (strncasecmp(tmp, "save_", 5) == 0) {
                        if (strcasecmp(tmp, "save_") == 0) depth--;
                        else depth++;
                    }
                }
                if (ctx.error || depth > 0) {
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "unterminated save frame"); return NULL;
                }
            } /* else bare save_ closes the current save frame; stay in_block */
            continue;
        }

        /* Outside a data block: skip everything. */
        if (!in_block) continue;

        if (state == NORM) {
            if (!ctx.quoted && strcasecmp(tok, "loop_") == 0) {
                state = LOOP_HDRS;
                col_label = col_type = -1;
                col_fx = col_fy = col_fz = -1;
                col_cx = col_cy = col_cz = -1;
                col_symop = -1; symop_loop = 0;
                ncols = 0;
                atom_loop = 0;
                continue;
            }

            if (tok[0] == '_') {
                char *tag = tok;
                {
                    int p = fgetc(fp);
                    if (p == EOF) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "missing value after single tag"); return NULL;
                    }
                    /* Value may follow on current or next line */
                    if (p != EOF) ungetc(p, fp);
                }
                char val_buf[2048];
                if (!cif_read_token(&ctx, fp, val_buf, sizeof(val_buf))) {
                    if (ctx.error) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "unterminated CIF token"); return NULL;
                    }
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "missing value after single tag"); return NULL;
                }
                char *val = val_buf;
                int val_quoted = ctx.quoted;

                /* An unquoted value that is itself a reserved/control token
                   (data_*, loop_, stop_, save_/save_name, global_, or another
                   data-name) is not a literal value — the tag is missing its
                   value. Unread it so it is recognized as the next structural
                   element and report the missing value. Quoted strings equal to
                   controls remain valid literal values. */
                if (!val_quoted &&
                    (val[0] == '_' ||
                     strcasecmp(val, "loop_") == 0 ||
                     strncasecmp(val, "data_", 5) == 0 ||
                     strcasecmp(val, "stop_") == 0 ||
                     strncasecmp(val, "save_", 5) == 0 ||
                     strcasecmp(val, "global_") == 0)) {
                    cif_unread(&ctx, val);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "missing value after single tag"); return NULL;
                }

                char peek_buf[2048];
                int have_peek = cif_read_token(&ctx, fp, peek_buf, sizeof(peek_buf));
                if (ctx.error) {
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "unterminated CIF token"); return NULL;
                }
                if (have_peek) {
                    int peek_break = (!ctx.quoted &&
                                      (peek_buf[0] == '_' ||
                                       strcasecmp(peek_buf, "loop_") == 0 ||
                                       strncasecmp(peek_buf, "data_", 5) == 0 ||
                                       strcasecmp(peek_buf, "stop_") == 0 ||
                                       strncasecmp(peek_buf, "save_", 5) == 0 ||
                                        strcasecmp(peek_buf, "global_") == 0));
                    if (peek_break) {
                        cif_unread(&ctx, peek_buf);
                    } else if (is_symop_tag(tag) || is_cell_tag(tag)) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "surplus data after single tag value"); return NULL;
                    } else {
                        cif_unread(&ctx, peek_buf);
                    }
                }

                int is_cell = 0;
                int cell_idx = -1;
                double *dst = NULL;
                if (is_cell_tag(tag)) {
                    is_cell = 1;
                    if (strcasecmp(tag, "_cell_length_a") == 0)        { cell_idx = 0; dst = &len_a; }
                    else if (strcasecmp(tag, "_cell_length_b") == 0)   { cell_idx = 1; dst = &len_b; }
                    else if (strcasecmp(tag, "_cell_length_c") == 0)   { cell_idx = 2; dst = &len_c; }
                    else if (strcasecmp(tag, "_cell_angle_alpha") == 0) { cell_idx = 3; dst = &al_deg; }
                    else if (strcasecmp(tag, "_cell_angle_beta") == 0)  { cell_idx = 4; dst = &be_deg; }
                    else if (strcasecmp(tag, "_cell_angle_gamma") == 0) { cell_idx = 5; dst = &ga_deg; }
                } else if (is_symop_tag(tag)) {
                    if (!val_quoted && (strcmp(val, ".") == 0 || strcmp(val, "?") == 0)) {
                        symop_missing = 1;
                    } else if (nops >= MAX_SYMOPS) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "too many symmetry operations; exceeded max 192"); return NULL;
                    } else {
                        char *vp = val;
                        size_t vl = strlen(vp);
                        while (vl > 0 && (vp[vl-1] == ' ' || vp[vl-1] == '\t')) vp[--vl] = '\0';
                        char op_err[128];
                        if (parse_symop(vp, symop_rot[nops], symop_trans[nops], op_err, sizeof(op_err)) < 0) {
                            for (int k = 0; k < natoms; k++) free(at[k].label);
                            free(at); fclose(fp); set_error(path, ctx.line, op_err); return NULL;
                        }
                        nops++; have_symops = 1;
                    }
                }
                if (is_cell) {
                    double v;
                    if (cif_strict_float(val, &v) < 0) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "malformed or non-finite cell parameter"); return NULL;
                    }
                    if (!in_float_range(v)) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "non-finite cell parameter"); return NULL;
                    }
                    if (cell_idx >= 3 && (v <= 0 || v >= 180)) {
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "cell angle out of (0,180) range"); return NULL;
                    }
                    if (dst) {
                        *dst = v;
                        if (cell_idx >= 0) cell_present[cell_idx] = 1;
                    }
                }
                continue;
            }

            /* Anything else in NORM state is a value without a tag — skip. */
            continue;
        }

        /* state == LOOP_HDRS */
        if (!ctx.quoted && tok[0] == '_') {
            if (ncols >= 64) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp);
                set_error(path, ctx.line, "too many columns in CIF loop (max 64)"); return NULL;
            }
            ncols++;
            if (strcasecmp(tok, "_atom_site_label") == 0)            col_label = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_type_symbol") == 0) col_type = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_fract_x") == 0)     col_fx = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_fract_y") == 0)     col_fy = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_fract_z") == 0)     col_fz = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_Cartn_x") == 0)     col_cx = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_Cartn_y") == 0)     col_cy = ncols - 1;
            else if (strcasecmp(tok, "_atom_site_Cartn_z") == 0)     col_cz = ncols - 1;
            else if (is_symop_tag(tok)) { col_symop = ncols - 1; symop_loop = 1; have_symops = 1; }
            continue;
        }

        if (ncols == 0) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); fclose(fp);
            set_error(path, ctx.line, "loop_ with no data-name headers"); return NULL;
        }
        atom_loop = (col_label >= 0 || col_type >= 0) &&
                    ((col_fx >= 0 && col_fy >= 0 && col_fz >= 0) ||
                     (col_cx >= 0 && col_cy >= 0 && col_cz >= 0));
        state = LOOP_DATA;
        row_used = 0;
        {
            int is_break = (!ctx.quoted &&
                            (tok[0] == '_' ||
                             strcasecmp(tok, "loop_") == 0 ||
                             strncasecmp(tok, "data_", 5) == 0 ||
                             strcasecmp(tok, "stop_") == 0 ||
                             strncasecmp(tok, "save_", 5) == 0 ||
                             strcasecmp(tok, "global_") == 0));
            if (is_break) {
                state = NORM; cif_unread(&ctx, tok); continue;
            }
            row_toks[0] = strdup(tok);
            if (!row_toks[0]) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp); set_error(path, ctx.line, "out of memory"); return NULL;
            }
            row_quoted[0] = ctx.quoted;
            row_used = 1;
            if (ncols == 1) {
                goto process_row;
            }
        }
        continue;

process_row:
        if (row_used != ncols) {
            for (int k = 0; k < row_used; k++) free(row_toks[k]);
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); fclose(fp);
            set_error(path, ctx.line, "partial CIF loop data row"); return NULL;
        }

        if (symop_loop && col_symop >= 0 && col_symop < ncols) {
            char *val = row_toks[col_symop];
            if (!row_quoted[col_symop] && (strcmp(val, ".") == 0 || strcmp(val, "?") == 0)) {
                symop_missing = 1;
            } else if (nops >= MAX_SYMOPS) {
                for (int k = 0; k < ncols; k++) free(row_toks[k]);
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); fclose(fp);
                set_error(path, ctx.line, "too many symmetry operations; exceeded max 192"); return NULL;
            } else {
                char *vp = val;
                size_t vl = strlen(vp);
                while (vl > 0 && (vp[vl-1] == ' ' || vp[vl-1] == '\t')) vp[--vl] = '\0';
                char op_err[128];
                if (parse_symop(vp, symop_rot[nops], symop_trans[nops], op_err, sizeof(op_err)) < 0) {
                    for (int k = 0; k < ncols; k++) free(row_toks[k]);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp); set_error(path, ctx.line, op_err); return NULL;
                }
                nops++; have_symops = 1;
            }
        }

        if (atom_loop && (col_fx >= 0 || col_cx >= 0)) {
            int is_frac = (col_fx >= 0);
            int cx = is_frac ? col_fx : col_cx;
            int cy = is_frac ? col_fy : col_cy;
            int cz = is_frac ? col_fz : col_cz;
            if (cx >= 0 && cy >= 0 && cz >= 0 && cx < ncols && cy < ncols && cz < ncols) {
                double fx, fy, fz;
                if (cif_strict_float(row_toks[cx], &fx) < 0 ||
                    cif_strict_float(row_toks[cy], &fy) < 0 ||
                    cif_strict_float(row_toks[cz], &fz) < 0) {
                    for (int k = 0; k < ncols; k++) free(row_toks[k]);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "malformed or non-finite atom coordinate"); return NULL;
                }
                if (!in_float_range(fx) || !in_float_range(fy) || !in_float_range(fz)) {
                    for (int k = 0; k < ncols; k++) free(row_toks[k]);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "non-finite atom coordinate"); return NULL;
                }

                const char *lbl = (col_label >= 0 && col_label < ncols) ? row_toks[col_label] : NULL;
                const char *ts_val = (col_type >= 0 && col_type < ncols) ? row_toks[col_type] : NULL;
                int type_present = (ts_val && (row_quoted[col_type] || (strcmp(ts_val, ".") != 0 && strcmp(ts_val, "?") != 0)));
                char el[8] = {0};
                int z = 0;
                if (type_present)
                    z = cif_resolve_z(ts_val, el);
                if (z == 0 && !type_present && lbl)
                    z = cif_resolve_z(lbl, el);

                if (natoms >= 500000) {
                    for (int k = 0; k < ncols; k++) free(row_toks[k]);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "too many CIF atoms"); return NULL;
                }
                if (natoms >= acap) {
                    acap = acap ? acap * 2 : 16;
                    Catom *t = realloc(at, acap * sizeof(Catom));
                    if (!t) {
                        for (int k = 0; k < ncols; k++) free(row_toks[k]);
                        for (int k = 0; k < natoms; k++) free(at[k].label);
                        free(at); fclose(fp);
                        set_error(path, ctx.line, "out of memory"); return NULL;
                    }
                    at = t;
                }
                Catom *a = &at[natoms];
                a->coord[0] = fx;
                a->coord[1] = fy;
                a->coord[2] = fz;
                a->frac = is_frac;
                a->atomic_number = z;
                if (z != 0 && el[0]) {
                    a->label = strdup(el);
                } else if (type_present) {
                    a->label = strdup(ts_val);
                } else if (lbl) {
                    a->label = strdup(lbl);
                } else {
                    a->label = strdup("");
                }
                if (!a->label) {
                    for (int k = 0; k < ncols; k++) free(row_toks[k]);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); fclose(fp);
                    set_error(path, ctx.line, "out of memory"); return NULL;
                }
                natoms++;
            }
        }

        for (int k = 0; k < ncols; k++) free(row_toks[k]);
        row_used = 0;
        continue;
    }
    fclose(fp);

    if (natoms == 0) {
        for (int k = 0; k < natoms; k++) free(at[k].label);
        free(at);
        set_error(path, 0, "no atom sites found");
        return NULL;
    }

    int all_six = cell_present[0] && cell_present[1] && cell_present[2] &&
                  cell_present[3] && cell_present[4] && cell_present[5];
    int saw_cell = (len_a > 0 && len_b > 0 && len_c > 0);
    if (!saw_cell) {
        for (int i = 0; i < natoms; i++) {
            if (at[i].frac) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at);
                set_error(path, 0, "fractional CIF coordinates require a cell"); return NULL;
            }
        }
    }

    int all_frac = 1;
    for (int i = 0; i < natoms; i++) { if (!at[i].frac) { all_frac = 0; break; } }

    float cell[3][3] = {{0}};
    int completeness = 2;  /* unknown */

    /* Expansion path: valid ops + all-six cell + all-fractional + no missing ./. */
    if (have_symops && nops > 0 && !symop_missing && all_six && all_frac) {
        /* Validate cell geometry before any conversion. */
        if (len_a <= 0 || len_b <= 0 || len_c <= 0 ||
            !isfinite(len_a) || !isfinite(len_b) || !isfinite(len_c)) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "non-positive or non-finite cell length"); return NULL;
        }
        if (al_deg <= 0 || al_deg >= 180 || be_deg <= 0 || be_deg >= 180 ||
            ga_deg <= 0 || ga_deg >= 180) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "cell angle out of (0,180) range"); return NULL;
        }

        long long total = (long long)natoms * nops;
        if (total > MOLENV_ATOM_CAP) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "operation cap exceeded"); return NULL;
        }

        if (cif_build_cell(len_a, len_b, len_c, al_deg, be_deg, ga_deg, cell) < 0) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "non-finite cell components"); return NULL;
        }

        /* Reject geometrically degenerate cell: positive determinant (right-handed)
           with scale-aware tolerance. */
        {
            double a0 = cell[0][0], a1 = cell[0][1], a2 = cell[0][2];
            double b0 = cell[1][0], b1 = cell[1][1], b2 = cell[1][2];
            double c0 = cell[2][0], c1 = cell[2][1], c2 = cell[2][2];
            double det = a0*(b1*c2-b2*c1) - a1*(b0*c2-b2*c0) + a2*(b0*c1-b1*c0);
            double det_scale = sqrt(a0*a0+a1*a1+a2*a2) * sqrt(b0*b0+b1*b1+b2*b2) * sqrt(c0*c0+c1*c1+c2*c2);
            if (det <= 1e-15 * det_scale) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); set_error(path, 0, "degenerate (zero-volume) cell"); return NULL;
            }
        }

        /* Validate group before expansion. */
        {
            char gerr[256];
            if (validate_symmetry_group(nops, symop_rot, symop_trans, cell, gerr, sizeof(gerr)) < 0) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); set_error(path, 0, gerr); return NULL;
            }
        }

        /* Compute per-axis bucket counts from inverse-lattice row norms.
           bucket_width = 1/nbx must be >= inv_norm[i] * DEDUP_TOL, i.e.
           nbx <= 1/(DEDUP_TOL * inv_norm[i]).  Compute in double domain,
           then convert to int with a minimum of 1 (no unsafe nb>=100 clamp). */
        double inv_norm[3];
        {
            double dummy_inv[3][3];
            if (invert_cell(cell, dummy_inv, inv_norm) < 0) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); set_error(path, 0, "singular cell matrix"); return NULL;
            }
        }
        double nbx_d = 1.0 / (DEDUP_TOL * inv_norm[0]);
        double nby_d = 1.0 / (DEDUP_TOL * inv_norm[1]);
        double nbz_d = 1.0 / (DEDUP_TOL * inv_norm[2]);
        if (nbx_d > 1e9) nbx_d = 1e9;
        if (nby_d > 1e9) nby_d = 1e9;
        if (nbz_d > 1e9) nbz_d = 1e9;
        int nbx = (int)floor(nbx_d);
        int nby = (int)floor(nby_d);
        int nbz = (int)floor(nbz_d);
        if (nbx < 1) nbx = 1;
        if (nby < 1) nby = 1;
        if (nbz < 1) nbz = 1;

        /* Dynamic hash table: size from candidate count at safe load factor ~0.67. */
        size_t ht_size = (size_t)(total * 1.5);
        if (ht_size < 64) ht_size = 64;
        DedupEntry *ht = calloc(ht_size, sizeof(DedupEntry));
        if (!ht) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "out of memory"); return NULL;
        }

        int expanded_cap = (int)total;
        MolEnvAtom *expanded = calloc((size_t)expanded_cap, sizeof(MolEnvAtom));
        if (!expanded) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); free(ht); set_error(path, 0, "out of memory"); return NULL;
        }

        int expanded_count = 0;
        for (int i = 0; i < natoms; i++) {
            double fx = at[i].coord[0], fy = at[i].coord[1], fz = at[i].coord[2];
            for (int j = 0; j < nops; j++) {
                double nx = symop_rot[j][0][0]*fx + symop_rot[j][0][1]*fy + symop_rot[j][0][2]*fz + symop_trans[j][0];
                double ny = symop_rot[j][1][0]*fx + symop_rot[j][1][1]*fy + symop_rot[j][1][2]*fz + symop_trans[j][1];
                double nz = symop_rot[j][2][0]*fx + symop_rot[j][2][1]*fy + symop_rot[j][2][2]*fz + symop_trans[j][2];

                nx = nx - floor(nx);
                ny = ny - floor(ny);
                nz = nz - floor(nz);
                if (nx >= 1.0) nx -= 1.0; if (nx < 0) nx = 0;
                if (ny >= 1.0) ny -= 1.0; if (ny < 0) ny = 0;
                if (nz >= 1.0) nz -= 1.0; if (nz < 0) nz = 0;

                double cx = nx*cell[0][0] + ny*cell[1][0] + nz*cell[2][0];
                double cy = nx*cell[0][1] + ny*cell[1][1] + nz*cell[2][1];
                double cz = nx*cell[0][2] + ny*cell[1][2] + nz*cell[2][2];

                if (!in_float_range(cx) || !in_float_range(cy) || !in_float_range(cz)) {
                    dedup_free_labels(ht, ht_size);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); free(ht); free(expanded);
                    set_error(path, 0, "non-finite Cartesian coordinate after expansion"); return NULL;
                }

                int znum = at[i].atomic_number;
                int dup_ret = dedup_is_dup(ht, ht_size, nx, ny, nz, znum, at[i].label,
                                           cell, inv_norm, nbx, nby, nbz);
                if (dup_ret < 0) {
                    dedup_free_labels(ht, ht_size);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); free(ht); free(expanded);
                    set_error(path, 0, "dedup: pathological cell — exact check too expensive");
                    return NULL;
                }
                if (dup_ret > 0) continue;

                int ibx = (int)floor(nx*nbx); ibx %= nbx; if (ibx < 0) ibx += nbx;
                int iby = (int)floor(ny*nby); iby %= nby; if (iby < 0) iby += nby;
                int ibz = (int)floor(nz*nbz); ibz %= nbz; if (ibz < 0) ibz += nbz;

                if (dedup_insert(ht, ht_size, ibx, iby, ibz,
                    znum, at[i].label, nx, ny, nz) < 0) {
                    dedup_free_labels(ht, ht_size);
                    for (int k = 0; k < natoms; k++) free(at[k].label);
                    free(at); free(ht); free(expanded);
                    set_error(path, 0, "dedup hash table full"); return NULL;
                }

                expanded[expanded_count].coord[0] = (float)cx;
                expanded[expanded_count].coord[1] = (float)cy;
                expanded[expanded_count].coord[2] = (float)cz;
                expanded[expanded_count].atomic_number = znum;
                snprintf(expanded[expanded_count].label, sizeof(expanded[expanded_count].label), "%s", at[i].label);
                expanded_count++;
            }
        }

        dedup_free_labels(ht, ht_size);
        free(ht);
        for (int k = 0; k < natoms; k++) free(at[k].label);
        free(at);
        at = NULL;
        natoms = expanded_count;
        completeness = 0;  /* complete */

        MolEnvScene *s = new_scene(path);
        if (!s) { free(expanded); return NULL; }
        s->symmetry_completeness = completeness;
        s->atoms = expanded;
        s->natoms = natoms;
        s->is_crystal = 1;
        s->periodic_dim = 3;
        memcpy(s->cell, cell, sizeof(s->cell));
        snprintf(s->title, sizeof(s->title), "%s", title);
        s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
        return s;
    }

    /* No expansion: convert fractional to Cartesian (if cell available). */
    if (saw_cell) {
        if (len_a <= 0 || len_b <= 0 || len_c <= 0 ||
            !isfinite(len_a) || !isfinite(len_b) || !isfinite(len_c)) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "non-positive or non-finite cell length"); return NULL;
        }
        if (cif_build_cell(len_a, len_b, len_c, al_deg, be_deg, ga_deg, cell) < 0) {
            for (int k = 0; k < natoms; k++) free(at[k].label);
            free(at); set_error(path, 0, "non-finite cell components"); return NULL;
        }
        {
            double matrix[3][3];
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) matrix[i][j] = cell[i][j];
            if (!cell_rank_usable(matrix, 3)) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); set_error(path, 0, "singular CIF cell"); return NULL;
            }
        }
        for (int i = 0; i < natoms; i++) {
            if (!at[i].frac) continue;
            double fx = at[i].coord[0], fy = at[i].coord[1], fz = at[i].coord[2];
            double dx = fx*cell[0][0] + fy*cell[1][0] + fz*cell[2][0];
            double dy = fx*cell[0][1] + fy*cell[1][1] + fz*cell[2][1];
            double dz = fx*cell[0][2] + fy*cell[1][2] + fz*cell[2][2];
            if (!in_float_range(dx) || !in_float_range(dy) || !in_float_range(dz)) {
                for (int k = 0; k < natoms; k++) free(at[k].label);
                free(at); set_error(path, 0, "non-finite Cartesian coordinate"); return NULL;
            }
            at[i].coord[0] = dx;
            at[i].coord[1] = dy;
            at[i].coord[2] = dz;
        }
    }

    MolEnvScene *s = new_scene(path);
    if (!s) {
        for (int k = 0; k < natoms; k++) free(at[k].label);
        free(at); return NULL;
    }
    s->symmetry_completeness = completeness;
    s->atoms = calloc(natoms, sizeof(MolEnvAtom));
    if (!s->atoms) {
        for (int k = 0; k < natoms; k++) free(at[k].label);
        free(at); set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL;
    }
    for (int i = 0; i < natoms; i++) {
        s->atoms[i].coord[0] = at[i].coord[0];
        s->atoms[i].coord[1] = at[i].coord[1];
        s->atoms[i].coord[2] = at[i].coord[2];
        s->atoms[i].atomic_number = at[i].atomic_number;
        snprintf(s->atoms[i].label, sizeof(s->atoms[i].label), "%s", at[i].label);
    }
    for (int k = 0; k < natoms; k++) free(at[k].label);
    free(at);
    s->natoms = natoms;
    snprintf(s->title, sizeof(s->title), "%s", title);

    if (saw_cell) {
        memcpy(s->cell, cell, sizeof(s->cell));
        s->is_crystal = 1;
        s->periodic_dim = 3;
    } else {
        s->is_crystal = 0;
        s->periodic_dim = 0;
    }

    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- POSCAR / CONTCAR / VASP ----- */

/* Strictly parse a non-negative decimal integer token. Returns 1 on success
   (value written to *out), 0 on any malformed / non-integer / negative /
   out-of-range input. A token like "1abc" or "1.5" is rejected (must be
   fully consumed). */
static int parse_nonneg_int(const char *tok, int *out) {
    char *endp = NULL;
    long v = strtol(tok, &endp, 10);
    if (endp == tok || *endp != '\0') return 0;       /* not a pure integer */
    if (v < 0) return 0;                               /* negative count */
    if (v > 500000L) return 0;                          /* per-species cap */
    *out = (int)v;
    return 1;
}

static int parse_finite_double(const char *tok, double *out) {
    char *endp = NULL;
    double v = strtod(tok, &endp);
    if (endp == tok || *endp != '\0' || !isfinite(v)) return 0;
    *out = v;
    return 1;
}

MolEnvScene* parse_poscar(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    char line[1024], title[256] = {0};
    int ln = 0;

    /* line 1: comment / title */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp); set_error(path, 1, "unexpected end of file"); return NULL;
    }
    ln++;
    size_t tlen = strlen(line);
    while (tlen > 0 && (line[tlen-1] == '\n' || line[tlen-1] == '\r' || line[tlen-1] == ' ')) line[--tlen] = '\0';
    snprintf(title, sizeof(title), "%s", line);

    /* line 2: scaling factor */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp); set_error(path, ln, "unexpected end at scaling factor"); return NULL;
    }
    ln++;
    double scale = 1.0;
    char *scale_tok[2];
    int scale_nt = split_tokens(line, scale_tok, 2);
    if (scale_nt < 1 || !parse_finite_double(scale_tok[0], &scale) || scale == 0.0) {
        fclose(fp); set_error(path, ln, "malformed scaling factor"); return NULL;
    }

    /* lines 3-5: lattice vectors, read RAW (unscaled) so we can apply the VASP
       volume convention uniformly. */
    double cellv[3][3];
    for (int r = 0; r < 3; r++) {
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp); set_error(path, ln, "unexpected end in lattice"); return NULL;
        }
        ln++;
        double u, v, w;
        if (sscanf(line, "%lf %lf %lf", &u, &v, &w) < 3 ||
            !isfinite(u) || !isfinite(v) || !isfinite(w)) {
            fclose(fp); set_error(path, ln, "malformed lattice vector"); return NULL;
        }
        cellv[r][0] = u; cellv[r][1] = v; cellv[r][2] = w;
    }

    /* Resolve the effective (always-positive) per-axis lattice scale.
       VASP convention: a negative scaling factor is the target CELL VOLUME,
       not a negative multiplier. We scale the lattice so that det(cell) equals
       the desired volume: s = (|targetVol| / |det(raw)|)^(1/3). A positive
       factor stays a uniform multiplicative scale as before. */
    double latScale = scale;
    if (scale < 0.0) {
        double det = cellv[0][0] * (cellv[1][1] * cellv[2][2] - cellv[2][1] * cellv[1][2])
                   - cellv[0][1] * (cellv[1][0] * cellv[2][2] - cellv[2][0] * cellv[1][2])
                   + cellv[0][2] * (cellv[1][0] * cellv[2][1] - cellv[2][0] * cellv[1][1]);
        double v0 = fabs(det);
        if (!isfinite(v0) || v0 <= 0.0) {
            fclose(fp); set_error(path, ln, "negative POSCAR scale requires a non-singular lattice"); return NULL;
        }
        latScale = cbrt(fabs(scale) / v0);
    }
    /* Validate latScale: cbrt of a non-finite or negative value can produce NaN/inf
       which silently corrupts the cell. */
    if (!isfinite(latScale) || latScale <= 0.0) {
        fclose(fp); set_error(path, ln, "non-finite lattice scale in POSCAR"); return NULL;
    }
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) {
            cellv[r][c] *= latScale;
            if (!in_float_range(cellv[r][c])) {
                fclose(fp); set_error(path, ln, "non-finite cell vector in POSCAR"); return NULL;
            }
        }
    if (!cell_rank_usable(cellv, 3)) {
        fclose(fp); set_error(path, ln, "singular cell in POSCAR"); return NULL;
    }

    /* line 6: element symbols (VASP 5+) or counts (VASP 4). Strict 32-token
       cap: the species/counts arrays are fixed at 32, so a surplus-token line is
       malformed input, not silently truncated data. */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp); set_error(path, ln, "unexpected end at species"); return NULL;
    }
    ln++;
    char *stoks[64];
    int snt = split_tokens(line, stoks, 64);
    if (snt > 32) {
        fclose(fp); set_error(path, ln, "too many species tokens in POSCAR (max 32)"); return NULL;
    }
    int vasp5 = 0;
    char species[32][8];
    int nspecies = 0;
    int counts[32] = {0};
    int ncounts = 0;

    /* VASP 5 carries a species line of non-numeric tokens; VASP 4 is all ints. */
    if (snt > 0 && !(snt == 1 && isdigit((unsigned char)stoks[0][0]))) {
        /* Heuristic: if the first token parses as a bare integer AND the line is
           the only species line, treat it as VASP 4 counts instead. */
        char *end = NULL;
        long test = strtol(stoks[0], &end, 10);
        (void)test;
        if (end && *end == '\0') {
            /* first token is a pure integer: VASP 4 counts line */
            vasp5 = 0;
        } else {
            vasp5 = 1;
        }
    }

    if (vasp5) {
        for (int i = 0; i < snt && i < 32; i++) {
            snprintf(species[i], sizeof(species[0]), "%s", stoks[i]);
            nspecies++;
        }
        /* read the counts line */
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp); set_error(path, ln, "unexpected end at counts"); return NULL;
        }
        ln++;
        int nt = split_tokens(line, stoks, 64);
        /* VASP5 cardinality: counts must match the number of declared species. */
        if (nt != nspecies) {
            fclose(fp); set_error(path, ln, "POSCAR species/count mismatch"); return NULL;
        }
        for (int i = 0; i < nt && i < 32; i++) {
            int c;
            if (!parse_nonneg_int(stoks[i], &c)) {
                fclose(fp); set_error(path, ln, "malformed POSCAR species count"); return NULL;
            }
            counts[i] = c; ncounts++;
        }
    } else {
        for (int i = 0; i < snt && i < 32; i++) {
            int c;
            if (!parse_nonneg_int(stoks[i], &c)) {
                fclose(fp); set_error(path, ln, "malformed POSCAR species count"); return NULL;
            }
            counts[i] = c; ncounts++;
        };
    }

    long long total = 0;
    for (int i = 0; i < ncounts; i++) total += counts[i];
    if (total <= 0 || total > 500000LL) {
        fclose(fp); set_error(path, ln, "unreasonable atom count in POSCAR"); return NULL;
    }

    /* Optional "Selective dynamics" line, then the coordinate mode line. */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp); set_error(path, ln, "unexpected end at coord mode"); return NULL;
    }
    ln++;
    {
        char *q = line;
        while (*q == ' ' || *q == '\t') q++;
        if (*q == 'S' || *q == 's') { /* Selective dynamics -> next line is mode */
            if (!fgets(line, sizeof(line), fp)) {
                fclose(fp); set_error(path, ln, "unexpected end at coord mode"); return NULL;
            }
            ln++;
        }
        q = line;
        while (*q == ' ' || *q == '\t') q++;
        if (!((*q == 'D' || *q == 'd' || *q == 'F' || *q == 'f') ||
              *q == 'C' || *q == 'c' || *q == 'K' || *q == 'k')) {
            fclose(fp); set_error(path, ln, "malformed POSCAR coordinate mode"); return NULL;
        }
    }
    int is_frac = 1;
    {
        char *q = line;
        while (*q == ' ' || *q == '\t') q++;
        if (*q == 'C' || *q == 'c' || *q == 'K' || *q == 'k') is_frac = 0; /* Cartesian */
        /* D/d/F/f or anything else => fractional (Direct) */
    }

    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    s->atoms = calloc(total, sizeof(MolEnvAtom));
    if (!s->atoms) { fclose(fp); set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL; }
    snprintf(s->title, sizeof(s->title), "%s", title);
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) s->cell[i][j] = (float)cellv[i][j];
    s->is_crystal = 1;
    s->periodic_dim = 3;

    int ai = 0;
    for (int sp = 0; sp < ncounts; sp++) {
        for (int k = 0; k < counts[sp]; k++) {
            if (!fgets(line, sizeof(line), fp)) {
                fclose(fp); set_error(path, ln, "unexpected end in coordinates");
                molenv_scene_free(s); return NULL;
            }
            ln++;
            char *ctoks[8];
            int nt = split_tokens(line, ctoks, 8);
            if (nt < 3) {
                fclose(fp); set_error(path, ln, "malformed coordinate");
                molenv_scene_free(s); return NULL;
            }
            double px, py, pz;
            if (!parse_finite_double(ctoks[0], &px) ||
                !parse_finite_double(ctoks[1], &py) ||
                !parse_finite_double(ctoks[2], &pz)) {
                fclose(fp); set_error(path, ln, "malformed coordinate");
                molenv_scene_free(s); return NULL;
            }
            double cx, cy, cz;
            if (is_frac) {
                cx = px*cellv[0][0] + py*cellv[1][0] + pz*cellv[2][0];
                cy = px*cellv[0][1] + py*cellv[1][1] + pz*cellv[2][1];
                cz = px*cellv[0][2] + py*cellv[1][2] + pz*cellv[2][2];
            } else {
                // Cartesian: scaled by the same positive lattice factor (the raw
                // `scale` may be negative under the volume convention, hence
                // latScale, which is always the effective positive multiplier).
                cx = px * latScale; cy = py * latScale; cz = pz * latScale;
            }
            if (!in_float_range(cx) || !in_float_range(cy) || !in_float_range(cz)) {
                fclose(fp); set_error(path, ln, "non-finite atom coordinate in POSCAR");
                molenv_scene_free(s); return NULL;
            }
            MolEnvAtom *a = &s->atoms[ai];
            a->coord[0] = (float)cx; a->coord[1] = (float)cy; a->coord[2] = (float)cz;
            if (vasp5 && sp < nspecies) {
                snprintf(a->label, sizeof(a->label), "%s", species[sp]);
                a->atomic_number = molenv_symbol_to_z(species[sp]);
            } else {
                snprintf(a->label, sizeof(a->label), "atom_%d", ai + 1);
                a->atomic_number = 0;
            }
            ai++;
        }
    }
    fclose(fp);
    s->natoms = ai;
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- XYZ (unchanged except make_bonds now does real work) ----- */

static MolEnvScene* parse_xyz_impl(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    char line[256];
    int na = 0;

    /* line 1: number of atoms. Strict parse: strtol + full-consumption + range
       cap. sscanf("%d") on an overflowed integer is implementation-defined and
       can silently produce a wrong atom count; strtol with endp rejects that. */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp); set_error(path, 1, "unexpected end of file"); return NULL;
    }
    char *endp = NULL;
    long na_long = strtol(line, &endp, 10);
    while (endp && (*endp == ' ' || *endp == '\t' || *endp == '\r' || *endp == '\n')) endp++;
    if (endp == line || (endp && *endp != '\0') || na_long < 1 || na_long > 500000) {
        fclose(fp); set_error(path, 1, "unreasonable atom count in XYZ"); return NULL;
    }
    na = (int)na_long;

    /* line 2: comment/title */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp); set_error(path, 2, "unexpected end of file"); return NULL;
    }
    /* trim trailing \r\n */
    size_t len = strlen(line);
    while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';

    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }

    s->atoms = calloc(na, sizeof(MolEnvAtom));
    if (!s->atoms) {
        fclose(fp); set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL;
    }
    snprintf(s->title, sizeof(s->title), "%s", line);

    int i;
    for (i = 0; i < na; i++) {
        if (fgets(line, sizeof(line), fp) == NULL) {
            fclose(fp); set_error(path, i + 3, "unexpected end of file"); molenv_scene_free(s); return NULL;
        }
        char sym[16];
        double x, y, z;
        if (sscanf(line, "%15s %lf %lf %lf", sym, &x, &y, &z) < 4) {
            fclose(fp); set_error(path, i + 3, "malformed atom line"); molenv_scene_free(s); return NULL;
        }
        if (!in_float_range(x) || !in_float_range(y) || !in_float_range(z)) {
            fclose(fp); set_error(path, i + 3, "non-finite atom coordinate"); molenv_scene_free(s); return NULL;
        }
        MolEnvAtom *a = &s->atoms[i];
        a->coord[0] = (float)x;
        a->coord[1] = (float)y;
        a->coord[2] = (float)z;
        a->atomic_number = molenv_symbol_to_z(sym);
        snprintf(a->label, sizeof(a->label), "%s", sym);
    }
    fclose(fp);

    s->natoms = na;
    s->is_crystal = 0;
    s->periodic_dim = 0;

    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);

    return s;
}
