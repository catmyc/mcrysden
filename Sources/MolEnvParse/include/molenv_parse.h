#ifndef MOLENV_PARSE_H
#define MOLENV_PARSE_H

#include <float.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float coord[3];          // Cartesian or fractional
    int   atomic_number;
    char  label[8];
} MolEnvAtom;

typedef struct {
    int i;                   // index into atoms[]
    int j;
} MolEnvBond;

/* A rectilinear scalar grid (XCrySDen `DATAGRID_3D`/`DATAGRID_2D` block as read
   from an XSF file). The grid occupies world (Cartesian, Å) space: sample
   (i,j,k) sits at origin + vec[0]*i/(nx-1) + vec[1]*j/(ny-1) + vec[2]*k/(nz-1),
   with `values` in x-fastest order (index = i + nx*(j + ny*k)). A scene carries
   at most one grid (the first DATAGRID block wins); `values == NULL` means none. */
typedef struct {
    int    dim;              // 3 for DATAGRID_3D, 2 for DATAGRID_2D
    int    n[3];             // sample counts (for dim==2, n[2]==1)
    float  orig[3];          // world-space origin corner
    float  vec[3][3];        // [axis][xyz]; axis vectors spanning the grid
    float  *values;          // nx*ny*nz floats, x-fastest; NULL if no grid
    float  minval, maxval;   // value range for UI normalization
    char   ident[64];        // human-readable label from the block header
} MolEnvGrid;

typedef struct {
    int        natoms;
    MolEnvAtom *atoms;
    int        nbonds;
    MolEnvBond *bonds;
    float      cell[3][3];   // row-major; all zeros for molecules
    int        is_crystal;   // 1 if cell is set
    int        periodic_dim; // 0..3
    char       title[256];
    MolEnvGrid *grid;        // first DATAGRID block, or NULL
} MolEnvScene;

MolEnvScene* parse_xsf   (const char *path);
MolEnvScene* parse_axsf  (const char *path, int frame_index);
/// Read the ANIMSTEPS count from an AXSF file's header WITHOUT loading a frame.
/// Returns the frame count, or 0 if the file is not a valid/animated AXSF.
/// Used by the GUI to size the animation scrubber and by --frame validation.
int         molenv_axsf_frame_count(const char *path);
MolEnvScene* parse_xyz   (const char *path);
MolEnvScene* parse_pdb   (const char *path);
MolEnvScene* parse_pwi   (const char *path);
/// Read a single ionic step (0-based `frame_index`) from a QE PWscf .pwo output.
/// Each ATOMIC_POSITIONS block is one frame; the latest CELL_PARAMETERS/crystal
/// axes block supplies its cell. Returns NULL on failure (see molenv_last_error).
MolEnvScene* parse_pwo   (const char *path, int frame_index);
/// Number of ionic steps (ATOMIC_POSITIONS blocks) in a .pwo file, or 0 if the
/// file is not a valid/parseable PWscf output. Sizes the animation scrubber.
int          molenv_pwo_frame_count(const char *path);
MolEnvScene* parse_cif   (const char *path);
MolEnvScene* parse_poscar(const char *path);
MolEnvBond*  molenv_make_bonds(const MolEnvScene *scene, float factor, int *out_nbonds);
void         molenv_free_bonds(MolEnvBond *bonds);
void         molenv_grid_free(MolEnvGrid *g);
void         molenv_scene_free(MolEnvScene*);
const char*  molenv_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
