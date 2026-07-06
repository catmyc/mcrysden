#include "molenv_parse.h"
#include <ctype.h>
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

/* Covalent-radius bond heuristic, operating purely on a MolEnvScene. */
static MolEnvBond* make_bonds(const MolEnvScene *s, float factor, int *out_nbonds) {
    static float cov[119];
    static int ready = 0;
    if (!ready) {
        for (int i=0;i<119;i++) cov[i]=1.5f;
        cov[1]=0.31f; cov[6]=0.76f; cov[7]=0.71f; cov[8]=0.66f; cov[14]=1.11f;
        cov[15]=1.07f; cov[16]=1.05f; cov[17]=1.02f; cov[35]=1.14f; cov[53]=1.33f;
        ready = 1;
    }
    int cap = s->natoms * 4, nb = 0;
    if (cap < 4) cap = 4;
    MolEnvBond *b = calloc(cap, sizeof(MolEnvBond));
    for (int i=0;i<s->natoms;i++) for (int j=i+1;j<s->natoms;j++) {
        if (s->atoms[i].atomic_number==0 || s->atoms[j].atomic_number==0) continue;
        float dx=s->atoms[i].coord[0]-s->atoms[j].coord[0],
              dy=s->atoms[i].coord[1]-s->atoms[j].coord[1],
              dz=s->atoms[i].coord[2]-s->atoms[j].coord[2];
        float d2=dx*dx+dy*dy+dz*dz;
        float r=cov[s->atoms[i].atomic_number]+cov[s->atoms[j].atomic_number];
        if (d2 <= (r*factor)*(r*factor)) {
            if (nb>=cap) { cap*=2; b=realloc(b,cap*sizeof(MolEnvBond)); }
            b[nb].i=i; b[nb].j=j; nb++;
        }
    }
    *out_nbonds = nb;
    return b;
}

static MolEnvScene* parse_xyz_impl(const char *path);

MolEnvScene* parse_xyz(const char *path) { return parse_xyz_impl(path); }

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

/* Read one PRIMCOORD structure chunk from the current file position.
   Reads an optional preceding structure keyword + PRIMVEC. Returns atom
   count on success, -1 on error. `*atoms` is reallocated; any prior value
   is freed (so callers can iterate frames on a single buffer). */
static int read_chunk(FILE *fp, float cell[3][3], int *pd, int *have_cell,
                      MolEnvAtom **atoms, int *natoms, const char *path, int *ln) {
    char line[256], tok[64];
    int saw_primcoord = 0;
    while (fgets(line, sizeof(line), fp)) {
        (*ln)++;
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
        if (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
            strncmp(tok,"DATAGRID_",8)==0 ||
            strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
            strcmp(tok,"DATAGRID3D")==0 || strcmp(tok,"DATAGRID2D")==0 ||
            strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0) {
            set_error(path,*ln,"DATAGRID not supported in v1");
            return -1;
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
    FILE *fp = fopen(path, "r");
    if (!fp) { set_error(path, 0, "cannot open file"); return NULL; }
    MolEnvScene *s = new_scene(path);
    if (!s) { fclose(fp); return NULL; }
    float cell[3][3]={{0}}; int pd=3, have_cell=0, ln=0;
    MolEnvAtom *atoms=NULL; int natoms=0;
    int rc = read_chunk(fp, cell,&pd,&have_cell,&atoms,&natoms,path,&ln);
    if (rc < 0) { fclose(fp); molenv_scene_free(s); return NULL; }
    s->atoms = atoms; s->natoms = natoms;
    memcpy(s->cell, cell, sizeof(s->cell));
    s->periodic_dim = pd;
    s->is_crystal = have_cell ? 1 : 0;

    /* Scan the remainder for DATAGRID blocks (v2; v1 must reject). */
    char line[256], tok[64];
    while (fgets(line,sizeof(line),fp)) {
        ln++;
        if (first_tok(line,tok,sizeof(tok))>0 && tok[0]!='#' &&
            (strncmp(tok,"BEGIN_DATAGRID",14)==0 ||
             strncmp(tok,"DATAGRID_",8)==0 ||
             strcmp(tok,"DATAGRID_3D")==0 || strcmp(tok,"DATAGRID_2D")==0 ||
             strcmp(tok,"DATAGRID3D")==0 || strcmp(tok,"DATAGRID2D")==0 ||
             strncmp(tok,"BEGIN_BLOCK_DATAGRID",20)==0)) {
            fclose(fp); set_error(path,ln,"DATAGRID not supported in v1");
            molenv_scene_free(s); return NULL;
        }
    }
    fclose(fp);

    s->bonds = make_bonds(s, 1.3f, &s->nbonds);
    return s;
}

MolEnvScene* parse_axsf(const char *path, int frame_index) {
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
    int current = 0;
    while (current <= frame_index) {
        int rc = read_chunk(fp, cell,&pd,&have_cell,&atoms,&natoms,path,&lnb);
        if (rc < 0) { fclose(fp); molenv_scene_free(s); return NULL; }
        if (current == frame_index) break;
        /* discard this frame's atoms; keep cell/is_crystal */
        free(atoms); atoms=NULL; natoms=0;
        current++;
    }
    fclose(fp);
    s->atoms = atoms; s->natoms = natoms;
    memcpy(s->cell, cell, sizeof(s->cell));
    s->periodic_dim = pd;
    s->is_crystal = have_cell ? 1 : 0;
    s->bonds = make_bonds(s, 1.3f, &s->nbonds);
    return s;
}

/* ----- PDB ----- */

MolEnvScene* parse_pdb(const char *path) {
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
        char c0 = line[12], c1 = line[13];
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
    s->bonds = make_bonds(s, 1.3f, &s->nbonds);
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

    s->bonds = make_bonds(s, 1.3f, &s->nbonds);

    return s;
}
