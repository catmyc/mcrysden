#include "molenv_parse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static __thread char last_error[512];

const char* molenv_last_error(void) { return last_error; }

static void set_error(const char *path, int line, const char *reason) {
    if (line > 0) snprintf(last_error, sizeof(last_error), "%s:%d: %s", path, line, reason);
    else          snprintf(last_error, sizeof(last_error), "%s: %s", path, reason);
}

void molenv_scene_free(MolEnvScene *s) {
    if (!s) return;
    free(s->atoms);
    free(s->bonds);
    free(s);
}

static MolEnvScene* new_scene(const char *path) {
    MolEnvScene *s = calloc(1, sizeof(MolEnvScene));
    if (!s) { set_error(path, 0, "out of memory"); return NULL; }
    s->periodic_dim = 3;
    return s;
}

static MolEnvScene* parse_xyz_impl(const char *path);

MolEnvScene* parse_xsf(const char *path)  { set_error(path, 0, "XSF not implemented"); return NULL; }
MolEnvScene* parse_axsf(const char *path, int f) { (void)f; set_error(path, 0, "AXSF not implemented"); return NULL; }
MolEnvScene* parse_xyz(const char *path) { return parse_xyz_impl(path); }
MolEnvScene* parse_pdb(const char *path) { set_error(path, 0, "PDB not implemented"); return NULL; }

static MolEnvScene* parse_xyz_impl(const char *path) {
    set_error(path, 0, "XYZ not implemented");
    return NULL;
}
