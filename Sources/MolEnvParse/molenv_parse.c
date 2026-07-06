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

/* Symbol -> atomic number (H..Og). C-local table; returns 0 if not found. */
static const struct { const char* sym; int z; } el[] = {
  {"H",1},{"He",2},{"Li",3},{"Be",4},{"B",5},{"C",6},{"N",7},{"O",8},{"F",9},{"Ne",10},
  {"Na",11},{"Mg",12},{"Al",13},{"Si",14},{"P",15},{"S",16},{"Cl",17},{"Ar",18},{"K",19},{"Ca",20},
  {"Ti",22},{"V",23},{"Cr",24},{"Mn",25},{"Fe",26},{"Co",27},{"Ni",28},{"Cu",29},{"Zn",30},
  {"Ga",31},{"Ge",32},{"As",33},{"Se",34},{"Br",35},{"Kr",36},{"Zr",40},{"Nb",41},{"Mo",42},
  {"Tc",43},{"Ru",44},{"Rh",45},{"Pd",46},{"Ag",47},{"Cd",48},{"In",49},{"Sn",50},{"Sb",51},
  {"Te",52},{"I",53},{"Xe",54},{"Pt",78},{"Au",79},{"Hg",80},{"Tl",81},{"Pb",82},{"Bi",83},{"U",92}
};
static int molenv_symbol_to_z(const char *s) {
    char t[4]={0}; for(int i=0;i<3 && s[i]; i++) t[i]=s[i];
    for (size_t i=0;i<sizeof(el)/sizeof(el[0]);i++) if(strcmp(t,el[i].sym)==0) return el[i].z;
    return 0;
}

/* Task 5 will implement real bonding; for now report zero bonds. */
static MolEnvBond* make_bonds(const MolEnvScene *s, float factor, int *out_nbonds);

static MolEnvScene* parse_xyz_impl(const char *path);

MolEnvScene* parse_xsf(const char *path)  { set_error(path, 0, "XSF not implemented"); return NULL; }
MolEnvScene* parse_axsf(const char *path, int f) { (void)f; set_error(path, 0, "AXSF not implemented"); return NULL; }
MolEnvScene* parse_xyz(const char *path) { return parse_xyz_impl(path); }
MolEnvScene* parse_pdb(const char *path) { set_error(path, 0, "PDB not implemented"); return NULL; }

static MolEnvScene* parse_xyz_impl(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    char line[256];
    int na = 0;

    /* line 1: number of atoms */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp); set_error(path, 1, "unexpected end of file"); return NULL;
    }
    if (sscanf(line, "%d", &na) != 1 || na < 1) {
        fclose(fp); set_error(path, 1, "number of atoms lower than one"); return NULL;
    }

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

    s->bonds = make_bonds(s, 1.3f, &s->nbonds);

    return s;
}

static MolEnvBond* make_bonds(const MolEnvScene *s, float factor, int *out_nbonds) {
    (void)s; (void)factor; *out_nbonds = 0; return NULL;
}
