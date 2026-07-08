#ifndef MOLENV_PARSE_H
#define MOLENV_PARSE_H

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

typedef struct {
    int        natoms;
    MolEnvAtom *atoms;
    int        nbonds;
    MolEnvBond *bonds;
    float      cell[3][3];   // row-major; all zeros for molecules
    int        is_crystal;   // 1 if cell is set
    int        periodic_dim; // 0..3
    char       title[256];
} MolEnvScene;

MolEnvScene* parse_xsf  (const char *path);
MolEnvScene* parse_axsf (const char *path, int frame_index);
MolEnvScene* parse_xyz  (const char *path);
MolEnvScene* parse_pdb  (const char *path);
MolEnvScene* parse_pwi  (const char *path);
MolEnvBond*  molenv_make_bonds(const MolEnvScene *scene, float factor, int *out_nbonds);
void         molenv_free_bonds(MolEnvBond *bonds);
void         molenv_scene_free(MolEnvScene*);
const char*  molenv_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
