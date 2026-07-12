#include "molenv_parse.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef PI
#define PI 3.14159265358979323846
#endif

static __thread char last_error[512];

const char* molenv_last_error(void) { return last_error; }

static void set_error(const char *path, int line, const char *reason) {
    if (line > 0) snprintf(last_error, sizeof(last_error), "%s:%d: %s", path, line, reason);
    else          snprintf(last_error, sizeof(last_error), "%s: %s", path, reason);
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
    char t[4]={0}; for(int i=0;i<3 && s[i]; i++) t[i]=s[i];
    for (size_t i=0;i<sizeof(el)/sizeof(el[0]);i++) if(strcmp(t,el[i].sym)==0) return el[i].z;
    return 0;
}

/* Covalent-radius bond heuristic, operating purely on a MolEnvScene. */
static MolEnvBond* make_bonds(const MolEnvScene *s, const char *path, float factor, int *out_nbonds) {
    /* Covalent radii, ported verbatim from XCrySDen's rcovdef[] (atoms.h).
       Index = atomic number (0..MAXNAT=100). Scaled by DEF_RCOVF (1.05), the
       same way XCrySDen computes rcov[i] = DEF_RCOVF * rcovdef[i]. */
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
    static float cov[119];
    static int ready = 0;
    if (!ready) {
        int n = (int)(sizeof(rcovdef)/sizeof(rcovdef[0]));
        for (int i = 0; i < 119; i++) cov[i] = (i < n) ? 1.05f * rcovdef[i] : 0.0f;
        ready = 1;
    }
    int cap = s->natoms * 4, nb = 0;
    if (cap < 4) cap = 4;
    MolEnvBond *b = calloc(cap, sizeof(MolEnvBond));
    if (!b) { set_error(path,0,"out of memory"); *out_nbonds=0; return NULL; }
    for (int i=0;i<s->natoms;i++) for (int j=i+1;j<s->natoms;j++) {
        int zi=s->atoms[i].atomic_number, zj=s->atoms[j].atomic_number;
        if (zi<=0 || zi>118 || zj<=0 || zj>118) continue;
        float dx=s->atoms[i].coord[0]-s->atoms[j].coord[0],
              dy=s->atoms[i].coord[1]-s->atoms[j].coord[1],
              dz=s->atoms[i].coord[2]-s->atoms[j].coord[2];
        float d2=dx*dx+dy*dy+dz*dz;
        float r=cov[zi]+cov[zj];
        if (d2 <= (r*factor)*(r*factor)) {
            if (nb>=cap) {
                cap*=2;
                MolEnvBond *t=realloc(b,cap*sizeof(MolEnvBond));
                if (!t) { free(b); set_error(path,0,"out of memory"); *out_nbonds=0; return NULL; }
                b=t;
            }
            b[nb].i=i; b[nb].j=j; nb++;
        }
    }
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

/* True if line looks like an atom record: first non-blank token starts with
   a digit, '+' or '-' (Z number). Used to know when an ATOMS/ATOMS_FRAC block ends. */
static int atom_line_p(const char *line) {
    while (*line==' '||*line=='	') line++;
    char c=*line;
    return (c>='0'&&c<='9') || c=='+' || c=='-';
}

/* Read a single DATAGRID block's body. On entry `fp` is positioned right after
   the BEGIN_BLOCK_DATAGRID_3D/2D line (the caller consumes that keyword). The
   body is:
        <comment line>
        BEGIN_DATAGRID_3D_<ident>   (or _2D)
        nx ny nz
        ox oy oz                   (origin)
        v0x v0y v0z                (i-axis span)
        v1x v1y v1z                (j-axis span)
        v2x v2y v2z                (k-axis span; for 2D == 0,0,0)
        <nx*ny*nz floats, x-fastest>
        END_DATAGRID_3D
   Returns 0 and fills `g` on success, -1 on failure (error set). The grid is left
   in `g` as-is on failure (caller frees in molenv_scene_free). */
static int read_datagrid_block(FILE *fp, MolEnvGrid *g, const char *path, int *ln) {
    char line[256], tok[64];
    memset(g, 0, sizeof(*g));
    g->dim = 3;

    /* comment line */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    snprintf(g->ident, sizeof(g->ident), "%.*s", (int)(sizeof(g->ident)-1), line);
    g->ident[strcspn(g->ident,"\r\n")] = '\0';

    /* BEGIN_DATAGRID_3D_<ident> */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    if (first_tok(line, tok, sizeof(tok))==0 || strncmp(tok,"BEGIN_DATAGRID",14)!=0) {
        set_error(path,*ln,"expected BEGIN_DATAGRID_3D"); return -1;
    }
    if (strstr(tok,"_2D")!=0) g->dim = 2;

    /* dimensions */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    {
        int nx=0, ny=0, nz=0;
        if (sscanf(line,"%d %d %d",&nx,&ny,&nz)<1) { set_error(path,*ln,"malformed DATAGRID dims"); return -1; }
        if (g->dim==2) { g->n[0]=nx>0?nx:1; g->n[1]=ny>0?ny:1; g->n[2]=1; }
        else           { g->n[0]=nx>0?nx:1; g->n[1]=ny>0?ny:1; g->n[2]=nz>0?nz:1; }
    }

    /* origin */
    if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
    (*ln)++;
    if (sscanf(line,"%f %f %f",&g->orig[0],&g->orig[1],&g->orig[2])<3) {
        set_error(path,*ln,"malformed DATAGRID origin"); return -1;
    }

    /* three span vectors */
    for (int ax=0; ax<3; ax++) {
        if (!fgets(line, sizeof(line), fp)) { set_error(path,*ln,"unexpected end in DATAGRID"); return -1; }
        (*ln)++;
        if (sscanf(line,"%f %f %f",&g->vec[ax][0],&g->vec[ax][1],&g->vec[ax][2])<3) {
            set_error(path,*ln,"malformed DATAGRID vector"); return -1;
        }
    }

    /* values — x-fastest, any whitespace run. Read with fscanf so line breaks
       don't matter (grid may be a single long line or many). */
    long count = (long)g->n[0]*g->n[1]*g->n[2];
    g->values = malloc(count * sizeof(float));
    if (!g->values) { set_error(path,*ln,"out of memory for DATAGRID values"); return -1; }
    g->minval = FLT_MAX; g->maxval = -FLT_MAX;
    for (long i=0; i<count; i++) {
        float v;
        if (fscanf(fp, "%f", &v)!=1) { set_error(path,*ln,"short DATAGRID values"); return -1; }
        g->values[i] = v;
        if (v < g->minval) g->minval = v;
        if (v > g->maxval) g->maxval = v;
    }

    /* advance to END_DATAGRID_3D line */
    while (fgets(line, sizeof(line), fp)) {
        (*ln)++;
        first_tok(line, tok, sizeof(tok));
        if (strcmp(tok,"END_DATAGRID_3D")==0 || strcmp(tok,"END_DATAGRID_2D")==0) break;
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
                if (!fgets(line,sizeof(line),fp)) { set_error(path,*ln,"unexpected end in PRIMVEC"); return -1; }
                (*ln)++;
                double a,b,c;
                if (sscanf(line,"%lf %lf %lf",&a,&b,&c)<3) { set_error(path,*ln,"malformed PRIMVEC row"); return -1; }
                cell[r][0]=(float)a; cell[r][1]=(float)b; cell[r][2]=(float)c;
            }
            *have_cell = 1;
            continue;
        }
        if (strcmp(tok,"CONVCOORD")==0) {
            int na=0, nc=0;
            if (!fgets(line,sizeof(line),fp)) return -1; (*ln)++;
            if (sscanf(line,"%d %d",&na,&nc)<1) { set_error(path,*ln,"malformed CONVCOORD header"); return -1; }
            if (na<1) { set_error(path,*ln,"no atoms in CONVCOORD"); return -1; }
            for (int i=0;i<na*nc;i++) { if(!fgets(line,sizeof(line),fp)) return -1; (*ln)++; }
            continue;
        }
        if (strcmp(tok,"PRIMCOORD")==0) {
            int na=0;
            if (!fgets(line,sizeof(line),fp)) { set_error(path,*ln,"unexpected end after PRIMCOORD"); return -1; }
            (*ln)++;
            if (sscanf(line,"%d",&na)<1 || na<1) { set_error(path,*ln,"malformed PRIMCOORD header"); return -1; }
            MolEnvAtom *at = calloc(na, sizeof(MolEnvAtom));
            if (!at) { set_error(path,*ln,"out of memory"); return -1; }
            for (int i=0;i<na;i++) {
                if (!fgets(line,sizeof(line),fp)) { free(at); set_error(path,*ln,"unexpected end in PRIMCOORD"); return -1; }
                (*ln)++;
                double Z,x,y,z;
                if (sscanf(line,"%lf %lf %lf %lf",&Z,&x,&y,&z)<4) { free(at); set_error(path,*ln,"malformed PRIMCOORD atom"); return -1; }
                at[i].atomic_number = (int)Z;
                at[i].coord[0]=(float)x; at[i].coord[1]=(float)y; at[i].coord[2]=(float)z;
                snprintf(at[i].label,sizeof(at[i].label),"%d",(int)Z);
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
                double Z,x,y,z;
                if (sscanf(line,"%lf %lf %lf %lf",&Z,&x,&y,&z)<4) continue;
                if (na>=acap) { acap = acap?acap*2:16; MolEnvAtom *t=realloc(at,acap*sizeof(MolEnvAtom)); if(!t){free(at);set_error(path,*ln,"out of memory");return -1;} at=t; }
                int zi=(int)Z; if(zi<0)zi=0; if(zi>118)zi=118;
                float fx=(float)x, fy=(float)y, fz=(float)z;
                if (frac) {
                    at[na].coord[0] = fx*cell[0][0]+fy*cell[1][0]+fz*cell[2][0];
                    at[na].coord[1] = fx*cell[0][1]+fy*cell[1][1]+fz*cell[2][1];
                    at[na].coord[2] = fx*cell[0][2]+fy*cell[1][2]+fz*cell[2][2];
                } else {
                    at[na].coord[0]=fx; at[na].coord[1]=fy; at[na].coord[2]=fz;
                }
                at[na].atomic_number=zi;
                snprintf(at[na].label,sizeof(at[na].label),"%d",zi);
                na++;
            }
            free(*atoms);
            *atoms = at; *natoms = na;
            saw_primcoord = 1;
            break;
        }
        if (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
            strncmp(tok,"DATAGRID_",8)==0 ||
            strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
            strcmp(tok,"DATAGRID3D")==0 || strcmp(tok,"DATAGRID2D")==0 ||
            strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
            /* Capture the first DATAGRID block into the scene (subsequent ones
               are skipped by advancing past the END_DATAGRID line). */
            if (gridOut && *gridOut == NULL) {
                MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
                if (!g) { set_error(path,*ln,"out of memory for DATAGRID"); return -1; }
                if (read_datagrid_block(fp, g, path, ln) < 0) { free(g); return -1; }
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
    if (rc < 0) { fclose(fp); molenv_scene_free(s); return NULL; }
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
                strncmp(tok,"DATAGRID_",8)==0 ||
                strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
                strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
                MolEnvGrid *g = calloc(1, sizeof(MolEnvGrid));
                if (!g) { fclose(fp); set_error(path,ln,"out of memory for DATAGRID");
                           molenv_scene_free(s); return NULL; }
                if (read_datagrid_block(fp, g, path, &ln) < 0) { free(g);
                    fclose(fp); molenv_scene_free(s); return NULL; }
                s->grid = g;
                break;
            }
        }
    }
    fclose(fp);

    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
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
            int n = 0;
            /* token already consumed; re-scan the raw line for the integer */
            if (sscanf(line, "%*s %d", &n) >= 1 && n > 0) nframes = n;
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
        if (rc < 0) { fclose(fp); molenv_scene_free(s); return NULL; }
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
            int n = 0;
            if (sscanf(line, "%*s %d", &n) >= 1 && n > 0) nframes = n;
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
    int count = 0, ln = 0, got_title = 0;
    char title[256] = {0};

    /* First pass: count atoms + capture an optional title. */
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
    rewind(fp);

    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    if (!got_title) snprintf(title,sizeof(title),"%s","PDB structure");

    s->atoms = calloc(count, sizeof(MolEnvAtom));
    if (!s->atoms || count==0) {
        if (count==0) set_error(path,ln,"no atoms found"); else set_error(path,0,"out of memory");
        fclose(fp); molenv_scene_free(s); return NULL;
    }

    int i = 0;
    while (fgets(line,sizeof(line),fp) && i < count) {
        if (strncmp(line,"ATOM",4)!=0 && strncmp(line,"HETATM",6)!=0) continue;
        if (strncmp(line,"END",3)==0 || strncmp(line,"ENDMDL",6)==0) break;
        double x=0,y=0,z=0;
        /* Columns 31-38,39-46,47-54 (1-based) == line[30..], using 8-char fields. */
        char xs[9]={0}, ys[9]={0}, zs[9]={0};
        if ((int)strlen(line) >= 54) {
            memcpy(xs, line+30, 8); xs[8]='\0';
            memcpy(ys, line+38, 8); ys[8]='\0';
            memcpy(zs, line+46, 8); zs[8]='\0';
            sscanf(xs,"%lf",&x); sscanf(ys,"%lf",&y); sscanf(zs,"%lf",&z);
        }
        /* Atom name: PDB cols 13-16 (line[12..15]); resolve element symbol. */
        char sym[4]={0};
        char c0 = '\0', c1 = '\0';
        if ((int)strlen(line) >= 14) { c0 = line[12]; c1 = line[13]; }
        if (c0==' ') {              /* single-letter element, e.g. " N " */
            sym[0]=c1; sym[1]='\0';
        } else if (c0!='\0') {      /* two-letter, e.g. "CA " */
            sym[0]=toupper((unsigned char)c0);
            sym[1]=tolower((unsigned char)c1);
            sym[2]='\0';
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
    case 5: { /* trigonal R, 3-fold along (111) */
        t = sqrt((1.0 - cosbc) / 3.0);
        cell[0][0] = a * t;
        cell[0][1] = a * t / sqrt3;
        cell[0][2] = a * sqrt(1.0 - 2.0*cosbc*cosbc) / sqrt3;
        cell[1][0] = -a * t;
        cell[1][1] = a * t / sqrt3;
        cell[1][2] = a * sqrt(1.0 - 2.0*cosbc*cosbc) / sqrt3;
        cell[2][0] = -a * t;
        cell[2][1] = -a * t / sqrt3;
        cell[2][2] = a * sqrt(1.0 - 2.0*cosbc*cosbc) / sqrt3;
        /* rotate so 3-fold is along c: standard QE convention */
        break;
    }
    case -5: { /* trigonal R, 3-fold along <111> (reverse) */
        t = sqrt((1.0 - cosbc) / 3.0);
        cell[0][0] = a * t * 2.0 / sqrt3;
        cell[0][1] = 0.0;
        cell[0][2] = a * sqrt(1.0 - cosbc*cosbc) / sqrt3;
        cell[1][0] = -a * t / sqrt3;
        cell[1][1] = a * t * sqrt(2.0);
        cell[1][2] = a * sqrt(1.0 - cosbc*cosbc) / sqrt3;
        cell[2][0] = -a * t / sqrt3;
        cell[2][1] = -a * t * sqrt(2.0);
        cell[2][2] = a * sqrt(1.0 - cosbc*cosbc) / sqrt3;
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
        cell[1][0] =  b/2; cell[1][2] = -c/2;
        cell[2][0] =  b/2; cell[2][2] =  c/2; break;
    case 10: /* orthorhombic face-centered */
        cell[0][0] =  a/2; cell[0][2] =  c/2;
        cell[1][0] =  a/2; cell[1][1] =  b/2;
        cell[2][1] =  b/2; cell[2][2] =  c/2; break;
    case 11: /* orthorhombic body-centered */
        cell[0][0] =  a/2; cell[0][1] =  b/2; cell[0][2] =  c/2;
        cell[1][0] = -a/2; cell[1][1] =  b/2; cell[1][2] =  c/2;
        cell[2][0] = -a/2; cell[2][1] = -b/2; cell[2][2] =  c/2; break;
    case 12: /* monoclinic P, unique axis c */
        cell[0][0] = a; cell[1][1] = b;
        cell[2][0] = c * cosab; cell[2][2] = c * sin(acos(cosab)); break;
    case -12: /* monoclinic P, unique axis b */
        cell[0][0] = a; cell[2][2] = c;
        cell[1][0] = b * cosab; cell[1][1] = b * sin(acos(cosab)); break;
    case 13: /* monoclinic base-centered, unique axis c */
        cell[0][0] =  a/2; cell[1][1] =  b/2;
        cell[2][0] = -a/2; cell[2][1] =  b/2;
        cell[2][0] = c * cosab; cell[2][2] = c * sin(acos(cosab)); break;
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

/* Parse a celldm(N) key. Returns the index (1..6) or 0 if not celldm. */
static int celldm_index(const char *key) {
    if (strncmp(key, "celldm(", 7) != 0) return 0;
    return atoi(key + 7);
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
            /* key = value */
            char *eq = strchr(p, '=');
            if (!eq) continue;
            char key[64];
            int klen = (int)(eq - p);
            if (klen >= (int)sizeof(key)) klen = (int)sizeof(key) - 1;
            memcpy(key, p, klen); key[klen] = '\0';
            while (klen > 0 && key[klen-1] == ' ') key[--klen] = '\0';
            char *vp = eq + 1;
            while (*vp == ' ') vp++;
            size_t vlen = strlen(vp);
            if (vlen >= 2 && ((vp[0]=='\'' && vp[vlen-1]=='\'') || (vp[0]=='"' && vp[vlen-1]=='"'))) {
                vp[vlen-1] = '\0'; vp++;
            }

            int ci = celldm_index(key);
            if (ci >= 1 && ci <= 6) {
                celldm[ci] = atof(vp);
            } else if (strcmp(key, "ibrav") == 0) {
                ibrav = atoi(vp);
            } else if (strcmp(key, "nat") == 0) {
                nat = atoi(vp);
            } else if (strcmp(key, "ntyp") == 0) {
                ntyp = atoi(vp);
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
                snprintf(species_sym[nspecies], sizeof(species_sym[0]), "%s", sym);
                char el[4]; qe_element(sym, el);
                species_z[nspecies] = molenv_symbol_to_z(el[0] ? el : sym);
                nspecies++;
            }
            continue;
        }

        if (strncmp(p, "ATOMIC_POSITIONS", 16) == 0) {
            /* optional {unit} */
            char *b = strchr(p, '{');
            if (b) {
                char *be = strchr(b, '}');
                if (be) { *be = '\0'; snprintf(pos_unit, sizeof(pos_unit), "%s", b + 1); trim_in_place(pos_unit); }
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
                    cap *= 2;
                    double *tx = realloc(ax, cap * sizeof(double));
                    double *ty = realloc(ay, cap * sizeof(double));
                    double *tz = realloc(az, cap * sizeof(double));
                    char (*ts)[8] = realloc(asym, cap * sizeof(*asym));
                    if (!tx || !ty || !tz || !ts) {
                        free(tx ? tx : ax); free(ty ? ty : ay);
                        free(tz ? tz : az); free(ts ? ts : asym);
                        free(ax); free(ay); free(az); free(asym);
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    ax = tx; ay = ty; az = tz; asym = ts;
                }
                snprintf(asym[natoms], sizeof(asym[0]), "%s", sym);
                ax[natoms] = x; ay[natoms] = y; az[natoms] = z;
                natoms++;
            }
            continue;
        }

        if (strncasecmp(p, "CELL_PARAMETERS", 15) == 0) {
            char *b = strchr(p, '{');
            if (b) {
                char *be = strchr(b, '}');
                if (be) { *be = '\0'; snprintf(cell_unit, sizeof(cell_unit), "%s", b + 1); trim_in_place(cell_unit); }
            } else {
                /* bare form: CELL_PARAMETERS bohr / angstrom / alat */
                char *u = p + 15;
                while (*u == ' ' || *u == '\t') u++;
                char *e = u;
                while (*e && *e != ' ' && *e != '\t') e++;
                *e = '\0';
                if (*u) snprintf(cell_unit, sizeof(cell_unit), "%s", u);
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
        /* cellpar is in cell_unit; convert to Ang. */
        float scale = 1.0f;
        if (strcmp(cell_unit, "bohr") == 0) scale = BOHR_TO_ANG;
        else if (strcmp(cell_unit, "alat") == 0) scale = (float)(celldm[1] * BOHR_TO_ANG);
        /* angstrom: scale=1 */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) cell[i][j] = cellpar[i][j] * scale;
    } else {
        if (latgen(ibrav, celldm, cell) != 0) {
            char buf[128]; snprintf(buf, sizeof(buf), "unsupported ibrav=%d", ibrav);
            free(ax); free(ay); free(az); free(asym);
            set_error(path, 0, buf); return NULL;
        }
        /* latgen returns Bohr -> convert to Ang. */
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) cell[i][j] *= BOHR_TO_ANG;
    }

    /* Convert atom positions to Cartesian Angstroms. */
    float pos_scale = 1.0f;
    int frac = 0;
    if (strcmp(pos_unit, "bohr") == 0) pos_scale = BOHR_TO_ANG;
    else if (strcmp(pos_unit, "alat") == 0) pos_scale = (float)(celldm[1] * BOHR_TO_ANG);
    else if (strcmp(pos_unit, "crystal") == 0) frac = 1;
    /* angstrom: scale=1 */

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
   success, -1 if fewer than 3 valid rows were found. */
static int read_3x3(FILE *fp, double m[3][3], int *ln) {
    int r = 0;
    char line[1024];
    while (r < 3 && fgets(line, sizeof(line), fp)) {
        (*ln)++;
        double a, b, c;
        if (sscanf(line, "%lf %lf %lf", &a, &b, &c) < 3) continue;
        m[r][0] = a; m[r][1] = b; m[r][2] = c;
        r++;
    }
    return (r == 3) ? 0 : -1;
}

/* Dispatch a unit token (alat|angstrom|bohr|crystal). Sets *scale (multiplier to
   Angstroms) and, for crystal, *frac=1. alat scales by alat_ang (Bohr->Å). */
static void unit_scales(const char *unit, double alat_ang, double *scale, int *frac) {
    *scale = 1.0; *frac = 0;
    if (strcmp(unit, "bohr") == 0) *scale = BOHR_TO_ANG;
    else if (strcmp(unit, "alat") == 0) *scale = alat_ang;
    else if (strcmp(unit, "crystal") == 0) { *scale = 1.0; *frac = 1; }
    /* angstrom: scale already 1 */
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
            if (eq) alat_bohr = atof(eq + 1);
            have_alat = 1;
            continue;
        }
        if (strncmp(p, "number of atoms/cell", 20) == 0) {
            nat = atoi(strrchr(p, '=') ? strrchr(p, '=') + 1 : "0");
            continue;
        }

        /* Initial lattice from crystal axes (alat units). */
        if (strncmp(p, "crystal axes", 12) == 0) {
            if (read_3x3(fp, cell, &ln) == 0 && have_alat) {
                double alat_ang = alat_bohr * (double)BOHR_TO_ANG;
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++)
                        cell[i][j] *= alat_ang;
                have_cell = 1;
            }
            continue;
        }

        /* CELL_PARAMETERS block: latest overrides current cell. */
        if (strncmp(p, "CELL_PARAMETERS", 15) == 0) {
            char unit[16] = "alat";
            char *op = strchr(p, '(');
            if (op) {
                char *cp = strchr(op, ')');
                if (cp) { *cp = '\0'; snprintf(unit, sizeof(unit), "%s", op + 1); }
            }
            double raw[3][3];
            if (read_3x3(fp, raw, &ln) == 0) {
                double scale = 1.0; int frac_dummy = 0;
                double alat_ang = have_alat ? alat_bohr * (double)BOHR_TO_ANG : 0.0;
                unit_scales(unit, alat_ang, &scale, &frac_dummy);
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++)
                        cell[i][j] = raw[i][j] * scale;
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
                if (cp) { *cp = '\0'; snprintf(unit, sizeof(unit), "%s", op + 1); }
            }
            double scale = 1.0; int frac = 0;
            double alat_ang = have_alat ? alat_bohr * (double)BOHR_TO_ANG : 0.0;
            unit_scales(unit, alat_ang, &scale, &frac);

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
                if (got >= cap) {
                    cap *= 2;
                    double *tx = realloc(ax, cap * sizeof(double));
                    double *ty = realloc(ay, cap * sizeof(double));
                    double *tz = realloc(az, cap * sizeof(double));
                    char (*ts)[8] = realloc(asym, cap * sizeof(*asym));
                    if (!tx || !ty || !tz || !ts) {
                        free(tx?tx:ax); free(ty?ty:ay); free(tz?tz:az); free(ts?ts:asym);
                        free(ax); free(ay); free(az); free(asym);
                        fclose(fp); set_error(path, 0, "out of memory"); return NULL;
                    }
                    ax = tx; ay = ty; az = tz; asym = ts;
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
                got++;
            }
            if (is_target) { natoms = got; target_done = 1; break; }
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
    }
    s->is_crystal = have_cell;
    s->periodic_dim = 3;
    snprintf(s->title, sizeof(s->title), "%s", "QE PWscf output");
    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);
    return s;
}

/* ----- CIF ----- */

/* Split a line into whitespace-delimited tokens, respecting single- and
   double-quoted strings (a quoted value never splits on internal spaces).
   Tokens point into the (mutated) line buffer. Returns token count. */
static int split_tokens(char *p, char **toks, int maxtoks) {
    int n = 0;
    while (*p && n < maxtoks) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == '\0') break;
        char *start;
        if (*p == '\'' || *p == '"') {
            char q = *p++; start = p;
            while (*p && *p != q && *p != '\n' && *p != '\r') p++;
            if (*p == q) *p++ = '\0';
        } else {
            start = p;
            while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
            if (*p) { *p++ = '\0'; }
        }
        toks[n++] = start;
    }
    return n;
}

/* Parse a CIF numeric value, stripping a trailing esd "(12)" if present. */
static double cif_float(const char *s) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%s", s);
    char *op = strchr(buf, '(');
    if (op) *op = '\0';
    return atof(buf);
}

/* Resolve an element symbol for a CIF atom label (e.g. "Fe1" -> "Fe",
   "CA" -> "Ca"). Writes the canonical symbol into el (cap 4) and returns
   its atomic number via molenv_symbol_to_z. Unknown -> el empty, Z 0. */
static int cif_resolve_z(const char *label, char *el) {
    char t[8] = {0};
    int i = 0;
    while (label[i] && i < 6) { t[i] = label[i]; i++; }
    t[i] = '\0';
    while (i > 0 && t[i - 1] >= '0' && t[i - 1] <= '9') t[--i] = '\0';
    if (i == 0) { el[0] = '\0'; return 0; }
    el[0] = (char)toupper((unsigned char)t[0]);
    for (int k = 1; k < i; k++) el[k] = (char)tolower((unsigned char)t[k]);
    el[i] = '\0';
    return molenv_symbol_to_z(el);
}

/* Build a row-major 3x3 lattice from a,b,c,alpha,beta,gamma (degrees):
   a along x, b in the xy-plane. */
static void cif_build_cell(double a, double b, double c,
                           double alpha, double beta, double gamma,
                           float cell[3][3]) {
    double gal = gamma * PI / 180.0;
    double alr = alpha * PI / 180.0;
    double ber = beta * PI / 180.0;
    double cgal = cos(gal), sg = sin(gal), cber = cos(ber), cal = cos(alr);
    if (sg < 1e-12) sg = 1e-12; /* guard a degenerate gamma */
    double cx = c * cber;
    double cy = c * (cal - cber * cgal) / sg;
    double cz = sqrt(fmax(0.0, c * c - cx * cx - cy * cy));
    cell[0][0] = (float)a; cell[0][1] = 0.0f; cell[0][2] = 0.0f;
    cell[1][0] = (float)(b * cgal); cell[1][1] = (float)(b * sg); cell[1][2] = 0.0f;
    cell[2][0] = (float)cx; cell[2][1] = (float)cy; cell[2][2] = (float)cz;
}

MolEnvScene* parse_cif(const char *path) {
    last_error[0] = '\0';
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }

    double len_a = 0, len_b = 0, len_c = 0;
    double al_deg = 90.0, be_deg = 90.0, ga_deg = 90.0;
    int in_block = 0;

    /* Working atom buffer. We record a per-atom `frac` flag and the raw
       (fractional) coordinates, then convert to Cartesian in a second pass
       once the cell parameters are known — the cell tags can legally appear
       before or after the atom loop. */
    typedef struct { float coord[3]; int atomic_number; char label[8]; int frac; } Catom;
    Catom *at = NULL;
    int natoms = 0, acap = 0;
    char title[256] = {0};

    char line[2048], held[2048];
    int have_held = 0, ln = 0;

    enum { NORM, LOOP_HDRS, LOOP_DATA };
    int state = NORM;
    int col_label = -1, col_type = -1;
    int col_fx = -1, col_fy = -1, col_fz = -1;
    int col_cx = -1, col_cy = -1, col_cz = -1;
    int ncols = 0;
    int atom_loop = 0;

    while (1) {
        if (have_held) { strcpy(line, held); have_held = 0; }
        else if (!fgets(line, sizeof(line), fp)) break;
        ln++;

        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == ' ' || line[len-1] == '\t' ||
                           line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;

        if (*p == '#') continue;
        if (*p == '\0') { if (state == LOOP_DATA) state = NORM; continue; }

        if (state == NORM) {
            if (strncmp(p, "data_", 5) == 0) {
                if (!in_block) {
                    in_block = 1;
                    snprintf(title, sizeof(title), "%s", p + 5);
                } else {
                    break; /* stop after the first data_ block */
                }
                continue;
            }
            if (!in_block) continue;               /* skip preamble */
            if (strncmp(p, "loop_", 5) == 0) {
                state = LOOP_HDRS;
                col_label = col_type = -1;
                col_fx = col_fy = col_fz = -1;
                col_cx = col_cy = col_cz = -1;
                ncols = 0;
                atom_loop = 0;
                continue;
            }
            /* single tag value: _tag value */
            if (*p == '_') {
                char *toks[4];
                int nt = split_tokens(p, toks, 4);
                if (nt >= 2) {
                    double v = cif_float(toks[1]);
                    if (strcmp(toks[0], "_cell_length_a") == 0)        len_a = v;
                    else if (strcmp(toks[0], "_cell_length_b") == 0)   len_b = v;
                    else if (strcmp(toks[0], "_cell_length_c") == 0)   len_c = v;
                    else if (strcmp(toks[0], "_cell_angle_alpha") == 0) al_deg = v;
                    else if (strcmp(toks[0], "_cell_angle_beta") == 0)  be_deg = v;
                    else if (strcmp(toks[0], "_cell_angle_gamma") == 0) ga_deg = v;
                }
                continue;
            }
            continue;
        }

        if (state == LOOP_HDRS) {
            if (*p == '_') {
                ncols++;
                if (strcmp(p, "_atom_site_label") == 0)            col_label = ncols - 1;
                else if (strcmp(p, "_atom_site_type_symbol") == 0) col_type = ncols - 1;
                else if (strcmp(p, "_atom_site_fract_x") == 0)     col_fx = ncols - 1;
                else if (strcmp(p, "_atom_site_fract_y") == 0)     col_fy = ncols - 1;
                else if (strcmp(p, "_atom_site_fract_z") == 0)     col_fz = ncols - 1;
                else if (strcmp(p, "_atom_site_Cartn_x") == 0)     col_cx = ncols - 1;
                else if (strcmp(p, "_atom_site_Cartn_y") == 0)     col_cy = ncols - 1;
                else if (strcmp(p, "_atom_site_Cartn_z") == 0)     col_cz = ncols - 1;
                continue;
            }
            /* first non-header line -> this is the start of loop data. */
            atom_loop = (col_label >= 0 || col_type >= 0) &&
                        ((col_fx >= 0 && col_fy >= 0 && col_fz >= 0) ||
                         (col_cx >= 0 && col_cy >= 0 && col_cz >= 0));
            state = LOOP_DATA;
            /* fall through into LOOP_DATA handling for this same line */
        }

        if (state == LOOP_DATA) {
            char *toks[64];
            int nt = split_tokens(p, toks, 64);
            if (nt != ncols || ncols == 0) {            /* loop ended */
                state = NORM;
                if (natoms > 0) break;
                strcpy(held, line); have_held = 1;      /* re-dispatch in NORM */
                continue;
            }
            if (atom_loop && (col_fx >= 0 || col_cx >= 0)) {
                int is_frac = (col_fx >= 0);
                int ci = is_frac ? col_fx : col_cx;
                if (ci >= 0 && ci + 2 < nt) {
                    double fx = cif_float(toks[ci]);
                    double fy = cif_float(toks[ci + 1]);
                    double fz = cif_float(toks[ci + 2]);
                    const char *lbl = NULL;
                    if (col_label >= 0 && col_label < nt) lbl = toks[col_label];
                    char el[4] = {0};
                    int z = lbl ? cif_resolve_z(lbl, el) : 0;
                    if (z == 0 && col_type >= 0 && col_type < nt)
                        z = cif_resolve_z(toks[col_type], el);
                    if (natoms >= acap) {
                        acap = acap ? acap * 2 : 16;
                        Catom *t = realloc(at, acap * sizeof(Catom));
                        if (!t) { free(at); fclose(fp); set_error(path, ln, "out of memory"); return NULL; }
                        at = t;
                    }
                    Catom *a = &at[natoms];
                    a->coord[0] = (float)fx;
                    a->coord[1] = (float)fy;
                    a->coord[2] = (float)fz;
                    a->frac = is_frac;
                    a->atomic_number = z;
                    snprintf(a->label, sizeof(a->label), "%s", el[0] ? el : (lbl ? lbl : ""));
                    natoms++;
                }
            }
        }
    }
    fclose(fp);

    if (natoms == 0) {
        free(at);
        set_error(path, 0, "no atom sites found");
        return NULL;
    }

    int saw_cell = (len_a > 0 && len_b > 0 && len_c > 0);

    /* Convert any fractional coordinates to Cartesian now that the cell is
       known (cell tags may have come before or after the atom loop). */
    float cell[3][3] = {{0}};
    if (saw_cell) {
        cif_build_cell(len_a, len_b, len_c, al_deg, be_deg, ga_deg, cell);
        for (int i = 0; i < natoms; i++) {
            if (!at[i].frac) continue;
            double fx = at[i].coord[0], fy = at[i].coord[1], fz = at[i].coord[2];
            at[i].coord[0] = (float)(fx*cell[0][0] + fy*cell[1][0] + fz*cell[2][0]);
            at[i].coord[1] = (float)(fx*cell[0][1] + fy*cell[1][1] + fz*cell[2][1]);
            at[i].coord[2] = (float)(fx*cell[0][2] + fy*cell[1][2] + fz*cell[2][2]);
        }
    }

    MolEnvScene *s = new_scene(path);
    if (!s) { free(at); return NULL; }
    s->atoms = calloc(natoms, sizeof(MolEnvAtom));
    if (!s->atoms) { free(at); set_error(path, 0, "out of memory"); molenv_scene_free(s); return NULL; }
    for (int i = 0; i < natoms; i++) {
        s->atoms[i].coord[0] = at[i].coord[0];
        s->atoms[i].coord[1] = at[i].coord[1];
        s->atoms[i].coord[2] = at[i].coord[2];
        s->atoms[i].atomic_number = at[i].atomic_number;
        memcpy(s->atoms[i].label, at[i].label, sizeof(s->atoms[i].label));
    }
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
    sscanf(line, "%lf", &scale);

    /* lines 3-5: lattice vectors, read RAW (unscaled) so we can apply the VASP
       volume convention uniformly. */
    double cellv[3][3];
    for (int r = 0; r < 3; r++) {
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp); set_error(path, ln, "unexpected end in lattice"); return NULL;
        }
        ln++;
        double u, v, w;
        if (sscanf(line, "%lf %lf %lf", &u, &v, &w) < 3) {
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
        latScale = (v0 > 0.0) ? cbrt(fabs(scale) / v0) : 1.0;
    }
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            cellv[r][c] *= latScale;

    /* line 6: element symbols (VASP 5+) or counts (VASP 4) */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp); set_error(path, ln, "unexpected end at species"); return NULL;
    }
    ln++;
    char *stoks[64];
    int snt = split_tokens(line, stoks, 64);
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
        for (int i = 0; i < nt && i < 32; i++) { counts[i] = atoi(stoks[i]); ncounts++; }
    } else {
        for (int i = 0; i < snt && i < 32; i++) { counts[i] = atoi(stoks[i]); ncounts++; };
    }

    int total = 0;
    for (int i = 0; i < ncounts; i++) total += counts[i];
    if (total <= 0) {
        fclose(fp); set_error(path, ln, "no atoms in POSCAR"); return NULL;
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
            double px = atof(ctoks[0]), py = atof(ctoks[1]), pz = atof(ctoks[2]);
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

    s->bonds = make_bonds(s, path, 1.0f, &s->nbonds);

    return s;
}
