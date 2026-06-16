#!/bin/sh
set -e

rm -rf core py build
mkdir -p core py build

cat > core/supervim.h << 'EOF'
#ifndef SUPERVIM_H
#define SUPERVIM_H

#include <stddef.h>

typedef enum {
    MODE_NORMAL = 0,
    MODE_INSERT = 1,
    MODE_VISUAL = 2
} Mode;

extern char **sv_lines;
extern int sv_line_count;
extern int sv_line_cap;
extern int sv_row;
extern int sv_col;
extern int sv_pref_col;
extern int sv_mode;
extern int sv_modified;
extern int sv_visual_anchor;
extern int sv_visual_active;
extern char *sv_yank;

void sv_init(void);
void sv_free_doc(void);
void sv_ensure_nonempty(void);
void sv_clamp_cursor(void);
int sv_line_len(int idx);
const char *sv_get_line(int idx);
char *sv_serialize(void);
void sv_load_text(const char *text);

void sv_insert_line_at(int idx, char *line);
void sv_delete_line_at(int idx);
void sv_insert_char_at(int row, int col, char c);
void sv_delete_char_at(int row, int col);
void sv_split_line_at(int row, int col);
int sv_merge_with_prev(int row);
char *sv_join_lines(int start, int end);
void sv_delete_range_lines(int start, int end);

void sv_move_left(void);
void sv_move_right(void);
void sv_move_up(void);
void sv_move_down(void);
void sv_goto_top(void);
void sv_goto_bottom(void);
void sv_line_start(void);
void sv_line_end(void);

void sv_set_mode(int m);
int sv_get_mode(void);
void sv_enter_visual(void);
void sv_exit_visual(void);

int sv_file_load(const char *path);
int sv_file_save(const char *path);

void sv_doc_init(void);
void sv_doc_undo(void);
void sv_doc_redo(void);

void sv_doc_insert_char(char c);
void sv_doc_newline(void);
void sv_doc_backspace(void);
void sv_doc_open_below(void);
void sv_doc_open_above(void);
void sv_doc_append(void);
void sv_doc_insert_mode(void);
void sv_doc_normal_mode(void);
void sv_doc_enter_visual(void);
void sv_doc_exit_visual(void);

void sv_doc_visual_yank(void);
void sv_doc_visual_delete(void);
void sv_doc_yank_current_line(void);
void sv_doc_delete_current_line(void);
void sv_doc_paste(void);

int sv_doc_line_count(void);
int sv_doc_row(void);
int sv_doc_col(void);
int sv_doc_is_modified(void);
const char *sv_doc_get_yank(void);

#endif
EOF

cat > core/buffer.c << 'EOF'
#include "supervim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char **sv_lines = NULL;
int sv_line_count = 0;
int sv_line_cap = 0;
int sv_row = 0;
int sv_col = 0;
int sv_pref_col = 0;
int sv_mode = MODE_NORMAL;
int sv_modified = 0;
int sv_visual_anchor = 0;
int sv_visual_active = 0;
char *sv_yank = NULL;

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        perror("malloc");
        exit(1);
    }
    return p;
}

static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) {
        perror("realloc");
        exit(1);
    }
    return q;
}

static char *xstrdup0(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)xmalloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

void sv_free_doc(void) {
    for (int i = 0; i < sv_line_count; i++) {
        free(sv_lines[i]);
    }
    free(sv_lines);
    sv_lines = NULL;
    sv_line_count = 0;
    sv_line_cap = 0;
    sv_row = 0;
    sv_col = 0;
    sv_pref_col = 0;
}

static void ensure_cap(int want) {
    if (want <= sv_line_cap) return;
    int ncap = sv_line_cap ? sv_line_cap : 8;
    while (ncap < want) ncap *= 2;
    sv_lines = (char **)xrealloc(sv_lines, sizeof(char *) * ncap);
    sv_line_cap = ncap;
}

void sv_ensure_nonempty(void) {
    if (sv_line_count == 0) {
        ensure_cap(1);
        sv_lines[0] = xstrdup0("");
        sv_line_count = 1;
    }
}

int sv_line_len(int idx) {
    if (idx < 0 || idx >= sv_line_count || !sv_lines[idx]) return 0;
    return (int)strlen(sv_lines[idx]);
}

const char *sv_get_line(int idx) {
    if (idx < 0 || idx >= sv_line_count) return "";
    return sv_lines[idx] ? sv_lines[idx] : "";
}

void sv_clamp_cursor(void) {
    sv_ensure_nonempty();
    if (sv_row < 0) sv_row = 0;
    if (sv_row >= sv_line_count) sv_row = sv_line_count - 1;
    int len = sv_line_len(sv_row);
    if (sv_col < 0) sv_col = 0;
    if (sv_col > len) sv_col = len;
    if (sv_pref_col < 0) sv_pref_col = 0;
}

static char *serialize_lines(void) {
    sv_ensure_nonempty();
    size_t total = 1;
    for (int i = 0; i < sv_line_count; i++) {
        total += strlen(sv_lines[i]);
        if (i + 1 < sv_line_count) total += 1;
    }
    char *out = (char *)xmalloc(total);
    char *p = out;
    for (int i = 0; i < sv_line_count; i++) {
        size_t n = strlen(sv_lines[i]);
        memcpy(p, sv_lines[i], n);
        p += n;
        if (i + 1 < sv_line_count) *p++ = '\n';
    }
    *p = '\0';
    return out;
}

char *sv_serialize(void) {
    return serialize_lines();
}

void sv_load_text(const char *text) {
    sv_free_doc();
    if (!text || !*text) {
        sv_ensure_nonempty();
        sv_clamp_cursor();
        return;
    }

    const char *start = text;
    const char *p = text;
    while (1) {
        if (*p == '\n' || *p == '\0') {
            size_t n = (size_t)(p - start);
            ensure_cap(sv_line_count + 1);
            char *line = (char *)xmalloc(n + 1);
            memcpy(line, start, n);
            line[n] = '\0';
            sv_lines[sv_line_count++] = line;
            if (*p == '\0') break;
            start = p + 1;
        }
        p++;
    }

    if (sv_line_count == 0) sv_ensure_nonempty();
    sv_row = 0;
    sv_col = 0;
    sv_pref_col = 0;
    sv_clamp_cursor();
}

void sv_init(void) {
    sv_free_doc();
    sv_load_text("");
    sv_mode = MODE_NORMAL;
    sv_modified = 0;
    sv_visual_anchor = 0;
    sv_visual_active = 0;
    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }
}

void sv_insert_line_at(int idx, char *line) {
    sv_ensure_nonempty();
    ensure_cap(sv_line_count + 1);
    if (idx < 0) idx = 0;
    if (idx > sv_line_count) idx = sv_line_count;
    for (int i = sv_line_count; i > idx; i--) {
        sv_lines[i] = sv_lines[i - 1];
    }
    sv_lines[idx] = line;
    sv_line_count++;
}

void sv_delete_line_at(int idx) {
    if (idx < 0 || idx >= sv_line_count) return;
    free(sv_lines[idx]);
    for (int i = idx; i + 1 < sv_line_count; i++) {
        sv_lines[i] = sv_lines[i + 1];
    }
    sv_line_count--;
    if (sv_line_count == 0) sv_ensure_nonempty();
}

void sv_insert_char_at(int row, int col, char c) {
    sv_ensure_nonempty();
    if (row < 0) row = 0;
    if (row >= sv_line_count) row = sv_line_count - 1;

    char *line = sv_lines[row];
    int len = (int)strlen(line);
    if (col < 0) col = 0;
    if (col > len) col = len;

    char *nl = (char *)xmalloc((size_t)len + 2);
    memcpy(nl, line, (size_t)col);
    nl[col] = c;
    memcpy(nl + col + 1, line + col, (size_t)(len - col + 1));
    free(line);
    sv_lines[row] = nl;
}

void sv_delete_char_at(int row, int col) {
    if (row < 0 || row >= sv_line_count) return;
    char *line = sv_lines[row];
    int len = (int)strlen(line);
    if (col < 0 || col >= len) return;
    memmove(line + col, line + col + 1, (size_t)(len - col));
}

void sv_split_line_at(int row, int col) {
    if (row < 0 || row >= sv_line_count) return;
    char *line = sv_lines[row];
    int len = (int)strlen(line);
    if (col < 0) col = 0;
    if (col > len) col = len;

    char *left = (char *)xmalloc((size_t)col + 1);
    memcpy(left, line, (size_t)col);
    left[col] = '\0';

    char *right = xstrdup0(line + col);
    free(line);
    sv_lines[row] = left;
    sv_insert_line_at(row + 1, right);
}

int sv_merge_with_prev(int row) {
    if (row <= 0 || row >= sv_line_count) return 0;
    int prevlen = (int)strlen(sv_lines[row - 1]);
    int curlen = (int)strlen(sv_lines[row]);

    char *prev = sv_lines[row - 1];
    char *cur = sv_lines[row];

    prev = (char *)xrealloc(prev, (size_t)prevlen + curlen + 1);
    memcpy(prev + prevlen, cur, (size_t)curlen + 1);
    free(cur);
    sv_lines[row - 1] = prev;

    for (int i = row; i + 1 < sv_line_count; i++) {
        sv_lines[i] = sv_lines[i + 1];
    }
    sv_line_count--;
    if (sv_line_count == 0) sv_ensure_nonempty();
    return prevlen;
}

char *sv_join_lines(int start, int end) {
    if (sv_line_count == 0) return xstrdup0("");
    if (start < 0) start = 0;
    if (end >= sv_line_count) end = sv_line_count - 1;
    if (start > end) {
        int t = start;
        start = end;
        end = t;
    }
    size_t total = 1;
    for (int i = start; i <= end; i++) {
        total += strlen(sv_lines[i]);
        if (i < end) total += 1;
    }
    char *out = (char *)xmalloc(total);
    char *p = out;
    for (int i = start; i <= end; i++) {
        size_t n = strlen(sv_lines[i]);
        memcpy(p, sv_lines[i], n);
        p += n;
        if (i < end) *p++ = '\n';
    }
    *p = '\0';
    return out;
}

void sv_delete_range_lines(int start, int end) {
    if (sv_line_count == 0) {
        sv_ensure_nonempty();
        return;
    }
    if (start < 0) start = 0;
    if (end >= sv_line_count) end = sv_line_count - 1;
    if (start > end) {
        int t = start;
        start = end;
        end = t;
    }

    for (int i = start; i <= end; i++) {
        free(sv_lines[i]);
    }
    int shift = end - start + 1;
    for (int i = start; i + shift < sv_line_count; i++) {
        sv_lines[i] = sv_lines[i + shift];
    }
    sv_line_count -= shift;
    if (sv_line_count <= 0) {
        sv_line_count = 0;
        sv_ensure_nonempty();
    }

    sv_row = start;
    if (sv_row >= sv_line_count) sv_row = sv_line_count - 1;
    sv_col = 0;
    sv_pref_col = 0;
    sv_clamp_cursor();
}

EOF

cat > core/cursor.c << 'EOF'
#include "supervim.h"

void sv_move_left(void) {
    if (sv_col > 0) {
        sv_col--;
    } else if (sv_row > 0) {
        sv_row--;
        sv_col = sv_line_len(sv_row);
    }
    sv_pref_col = sv_col;
}

void sv_move_right(void) {
    int len = sv_line_len(sv_row);
    if (sv_col < len) {
        sv_col++;
    } else if (sv_row + 1 < sv_line_count) {
        sv_row++;
        sv_col = 0;
    }
    sv_pref_col = sv_col;
}

void sv_move_up(void) {
    if (sv_row > 0) {
        sv_row--;
        int len = sv_line_len(sv_row);
        sv_col = sv_pref_col > len ? len : sv_pref_col;
    }
}

void sv_move_down(void) {
    if (sv_row + 1 < sv_line_count) {
        sv_row++;
        int len = sv_line_len(sv_row);
        sv_col = sv_pref_col > len ? len : sv_pref_col;
    }
}

void sv_goto_top(void) {
    sv_row = 0;
    sv_col = 0;
    sv_pref_col = 0;
}

void sv_goto_bottom(void) {
    sv_row = sv_line_count - 1;
    sv_col = 0;
    sv_pref_col = 0;
}

void sv_line_start(void) {
    sv_col = 0;
    sv_pref_col = 0;
}

void sv_line_end(void) {
    sv_col = sv_line_len(sv_row);
    sv_pref_col = sv_col;
}

EOF

cat > core/mode.c << 'EOF'
#include "supervim.h"

void sv_set_mode(int m) {
    sv_mode = m;
}

int sv_get_mode(void) {
    return sv_mode;
}

void sv_enter_visual(void) {
    sv_mode = MODE_VISUAL;
    sv_visual_active = 1;
    sv_visual_anchor = sv_row;
}

void sv_exit_visual(void) {
    sv_mode = MODE_NORMAL;
    sv_visual_active = 0;
}

EOF

cat > core/fileio.c << 'EOF'
#include "supervim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int sv_file_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        sv_init();
        return 0;
    }

    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        perror("malloc");
        exit(1);
    }

    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = '\0';
    fclose(f);

    sv_load_text(buf);
    free(buf);

    sv_modified = 0;
    sv_set_mode(MODE_NORMAL);
    return 1;
}

int sv_file_save(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return 0;

    char *txt = sv_serialize();
    size_t n = strlen(txt);
    fwrite(txt, 1, n, f);
    fclose(f);
    free(txt);

    sv_modified = 0;
    return 1;
}

EOF

cat > core/ops.c << 'EOF'
#include "supervim.h"
#include <stdlib.h>
#include <string.h>

#define MAX_STACK 64

typedef struct {
    char *text;
    int row;
    int col;
    int mode;
} Snapshot;

static Snapshot undo_stack[MAX_STACK];
static Snapshot redo_stack[MAX_STACK];
static int undo_top = 0;
static int redo_top = 0;

static void *xmalloc2(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        perror("malloc");
        exit(1);
    }
    return p;
}

static char *xstrdup2(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)xmalloc2(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

static void free_snapshot(Snapshot *s) {
    if (s->text) {
        free(s->text);
        s->text = NULL;
    }
}

static void clear_stack(Snapshot *stack, int *top) {
    for (int i = 0; i < *top; i++) {
        free_snapshot(&stack[i]);
    }
    *top = 0;
}

static void push_stack(Snapshot *stack, int *top, const char *text, int row, int col, int mode) {
    if (*top == MAX_STACK) {
        free_snapshot(&stack[0]);
        memmove(&stack[0], &stack[1], sizeof(Snapshot) * (MAX_STACK - 1));
        *top = MAX_STACK - 1;
    }
    stack[*top].text = xstrdup2(text);
    stack[*top].row = row;
    stack[*top].col = col;
    stack[*top].mode = mode;
    (*top)++;
}

static void begin_edit(void) {
    char *snap = sv_serialize();
    push_stack(undo_stack, &undo_top, snap, sv_row, sv_col, sv_mode);
    free(snap);
    clear_stack(redo_stack, &redo_top);
}

static void restore_snapshot(Snapshot *s) {
    sv_load_text(s->text);
    sv_row = s->row;
    sv_col = s->col;
    sv_pref_col = sv_col;
    sv_set_mode(s->mode);
    sv_clamp_cursor();
}

static void set_modified(void) {
    sv_modified = 1;
}

static void ensure_yank_free(void) {
    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }
}

void sv_doc_init(void) {
    sv_init();
    clear_stack(undo_stack, &undo_top);
    clear_stack(redo_stack, &redo_top);
}

void sv_doc_undo(void) {
    if (undo_top <= 0) return;
    char *current = sv_serialize();
    push_stack(redo_stack, &redo_top, current, sv_row, sv_col, sv_mode);
    free(current);

    Snapshot s = undo_stack[--undo_top];
    restore_snapshot(&s);
    free_snapshot(&s);
    sv_modified = 1;
}

void sv_doc_redo(void) {
    if (redo_top <= 0) return;
    char *current = sv_serialize();
    push_stack(undo_stack, &undo_top, current, sv_row, sv_col, sv_mode);
    free(current);

    Snapshot s = redo_stack[--redo_top];
    restore_snapshot(&s);
    free_snapshot(&s);
    sv_modified = 1;
}

void sv_doc_insert_char(char c) {
    begin_edit();
    sv_insert_char_at(sv_row, sv_col, c);
    sv_col++;
    sv_pref_col = sv_col;
    set_modified();
}

void sv_doc_newline(void) {
    begin_edit();
    sv_split_line_at(sv_row, sv_col);
    sv_row++;
    sv_col = 0;
    sv_pref_col = 0;
    set_modified();
}

void sv_doc_backspace(void) {
    begin_edit();
    if (sv_col > 0) {
        sv_delete_char_at(sv_row, sv_col - 1);
        sv_col--;
        sv_pref_col = sv_col;
    } else if (sv_row > 0) {
        int newcol = sv_merge_with_prev(sv_row);
        sv_row--;
        sv_col = newcol;
        sv_pref_col = sv_col;
    }
    set_modified();
}

void sv_doc_open_below(void) {
    begin_edit();
    sv_insert_line_at(sv_row + 1, xstrdup2(""));
    sv_row++;
    sv_col = 0;
    sv_pref_col = 0;
    sv_set_mode(MODE_INSERT);
    set_modified();
}

void sv_doc_open_above(void) {
    begin_edit();
    sv_insert_line_at(sv_row, xstrdup2(""));
    sv_col = 0;
    sv_pref_col = 0;
    sv_set_mode(MODE_INSERT);
    set_modified();
}

void sv_doc_append(void) {
    sv_line_end();
    if (sv_col < sv_line_len(sv_row)) sv_col++;
    sv_set_mode(MODE_INSERT);
}

void sv_doc_insert_mode(void) {
    sv_set_mode(MODE_INSERT);
}

void sv_doc_normal_mode(void) {
    sv_set_mode(MODE_NORMAL);
    sv_visual_active = 0;
}

void sv_doc_enter_visual(void) {
    sv_enter_visual();
}

void sv_doc_exit_visual(void) {
    sv_exit_visual();
}

void sv_doc_visual_yank(void) {
    if (!sv_visual_active) return;
    ensure_yank_free();
    int a = sv_visual_anchor;
    int b = sv_row;
    if (a > b) {
        int t = a;
        a = b;
        b = t;
    }
    sv_yank = sv_join_lines(a, b);
    sv_exit_visual();
}

void sv_doc_visual_delete(void) {
    if (!sv_visual_active) return;
    begin_edit();
    ensure_yank_free();

    int a = sv_visual_anchor;
    int b = sv_row;
    if (a > b) {
        int t = a;
        a = b;
        b = t;
    }

    sv_yank = sv_join_lines(a, b);
    sv_delete_range_lines(a, b);
    sv_exit_visual();
    set_modified();
}

void sv_doc_yank_current_line(void) {
    ensure_yank_free();
    sv_yank = xstrdup2(sv_get_line(sv_row));
}

void sv_doc_delete_current_line(void) {
    begin_edit();
    ensure_yank_free();
    sv_yank = xstrdup2(sv_get_line(sv_row));
    sv_delete_range_lines(sv_row, sv_row);
    set_modified();
}

void sv_doc_paste(void) {
    if (!sv_yank || !*sv_yank) return;
    begin_edit();

    char *tmp = xstrdup2(sv_yank);
    int insert_at = sv_row + 1;
    char *save = NULL;
    char *tok = strtok_r(tmp, "\n", &save);
    while (tok) {
        sv_insert_line_at(insert_at++, xstrdup2(tok));
        tok = strtok_r(NULL, "\n", &save);
    }
    free(tmp);

    sv_row = insert_at - 1;
    sv_col = 0;
    sv_pref_col = 0;
    set_modified();
}

int sv_doc_line_count(void) { return sv_line_count; }
int sv_doc_row(void) { return sv_row; }
int sv_doc_col(void) { return sv_col; }
int sv_doc_is_modified(void) { return sv_modified; }
const char *sv_doc_get_yank(void) { return sv_yank ? sv_yank : ""; }

EOF

gcc -O2 -fPIC -shared core/*.c -o build/libsupervim.so -march=armv8-a

cat > py/__init__.py << 'EOF'
EOF

cat > py/ffi.py << 'EOF'
import ctypes
import os

BASE = os.path.dirname(__file__)
lib = ctypes.CDLL(os.path.join(BASE, "../build/libsupervim.so"))

lib.sv_doc_init.restype = None
lib.sv_file_load.argtypes = [ctypes.c_char_p]
lib.sv_file_load.restype = ctypes.c_int
lib.sv_file_save.argtypes = [ctypes.c_char_p]
lib.sv_file_save.restype = ctypes.c_int

lib.sv_doc_undo.restype = None
lib.sv_doc_redo.restype = None

lib.sv_doc_insert_char.argtypes = [ctypes.c_char]
lib.sv_doc_newline.restype = None
lib.sv_doc_backspace.restype = None
lib.sv_doc_open_below.restype = None
lib.sv_doc_open_above.restype = None
lib.sv_doc_append.restype = None
lib.sv_doc_insert_mode.restype = None
lib.sv_doc_normal_mode.restype = None
lib.sv_doc_enter_visual.restype = None
lib.sv_doc_exit_visual.restype = None
lib.sv_doc_visual_yank.restype = None
lib.sv_doc_visual_delete.restype = None
lib.sv_doc_yank_current_line.restype = None
lib.sv_doc_delete_current_line.restype = None
lib.sv_doc_paste.restype = None

lib.sv_move_left.restype = None
lib.sv_move_right.restype = None
lib.sv_move_up.restype = None
lib.sv_move_down.restype = None
lib.sv_goto_top.restype = None
lib.sv_goto_bottom.restype = None
lib.sv_line_start.restype = None
lib.sv_line_end.restype = None

lib.sv_get_line.argtypes = [ctypes.c_int]
lib.sv_get_line.restype = ctypes.c_char_p
lib.sv_doc_line_count.restype = ctypes.c_int
lib.sv_doc_row.restype = ctypes.c_int
lib.sv_doc_col.restype = ctypes.c_int
lib.sv_doc_is_modified.restype = ctypes.c_int
lib.sv_get_mode.restype = ctypes.c_int
lib.sv_doc_get_yank.restype = ctypes.c_char_p

EOF

cat > py/input.py << 'EOF'
import sys
import termios
import tty

def get_key():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        c1 = sys.stdin.read(1)

        if c1 != "\x1b":
            return c1

        c2 = sys.stdin.read(1)
        if c2 == "[":
            c3 = sys.stdin.read(1)
            if c3 == "A":
                return "<UP>"
            if c3 == "B":
                return "<DOWN>"
            if c3 == "C":
                return "<RIGHT>"
            if c3 == "D":
                return "<LEFT>"
            if c3 == "H":
                return "<HOME>"
            if c3 == "F":
                return "<END>"
            return "<ESC>"
        if c2 == "O":
            c3 = sys.stdin.read(1)
            if c3 == "H":
                return "<HOME>"
            if c3 == "F":
                return "<END>"
            return "<ESC>"

        return "<ESC>"
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
EOF

cat > py/render.py << 'EOF'
import shutil
import sys
from .ffi import lib

MODE_NAMES = {0: "NORMAL", 1: "INSERT", 2: "VISUAL"}
HELP_TEXT = "i insert | a append | o/O open | ESC normal | V visual | y/d line ops | p paste | u undo | Ctrl-R redo | :w :q :wq :e"

def line_text(i):
    raw = lib.sv_get_line(i)
    return raw.decode("utf-8", "replace") if raw else ""

def visible_cursor_line(text, col):
    if col < 0:
        col = 0
    if col > len(text):
        col = len(text)
    return text[:col] + "█" + text[col:]

def render(filename, message=""):
    cols, rows = shutil.get_terminal_size((80, 24))
    mode = MODE_NAMES.get(lib.sv_get_mode(), "?")
    cur_row = lib.sv_doc_row()
    cur_col = lib.sv_doc_col()
    count = lib.sv_doc_line_count()
    modified = " [+]" if lib.sv_doc_is_modified() else ""
    name = filename if filename else "[No Name]"

    print("\033[H\033[J", end="")

    viewport = max(0, cur_row - (rows // 2))
    display_lines = rows - 4

    for screen_i in range(display_lines):
        src_i = viewport + screen_i
        if src_i < count:
            text = line_text(src_i)
            prefix = ">" if src_i == cur_row else " "
            shown = visible_cursor_line(text, cur_col) if src_i == cur_row else text
            print(f"{prefix}{src_i + 1:>4} {shown}")
        else:
            print("~")

    status = f"SUPERVIM GAP OFF {mode}{modified} | {name} | {cur_row + 1},{cur_col + 1}"
    if message:
        status += f" | {message}"
    print(status[:cols])
    print(HELP_TEXT[:cols])
    sys.stdout.flush()
EOF

cat > py/editor.py << 'EOF'
from .ffi import lib
from .input import get_key
from .render import render

def run(filename=None):
    current = filename

    if filename:
        ok = lib.sv_file_load(filename.encode("utf-8"))
        if not ok:
            lib.sv_doc_init()
    else:
        lib.sv_doc_init()

    message = "ready"
    operator = None

    while True:
        render(current, message)
        message = ""
        key = get_key()

        if key == "\x03":
            break

        mode = lib.sv_get_mode()

        if mode == 1:
            if key == "<ESC>":
                lib.sv_doc_normal_mode()
            elif key == "\r":
                lib.sv_doc_newline()
            elif key == "\x7f":
                lib.sv_doc_backspace()
            elif key == "<LEFT>":
                lib.sv_move_left()
            elif key == "<RIGHT>":
                lib.sv_move_right()
            elif key == "<UP>":
                lib.sv_move_up()
            elif key == "<DOWN>":
                lib.sv_move_down()
            elif key == "<HOME>":
                lib.sv_line_start()
            elif key == "<END>":
                lib.sv_line_end()
            else:
                for b in key.encode("utf-8", "ignore"):
                    lib.sv_doc_insert_char(bytes([b]))

        elif mode == 2:
            if key == "<ESC>":
                lib.sv_doc_exit_visual()
            elif key in ("h", "<LEFT>"):
                lib.sv_move_left()
            elif key in ("l", "<RIGHT>"):
                lib.sv_move_right()
            elif key in ("j", "<DOWN>"):
                lib.sv_move_down()
            elif key in ("k", "<UP>"):
                lib.sv_move_up()
            elif key in ("0", "<HOME>"):
                lib.sv_line_start()
            elif key in ("$", "<END>"):
                lib.sv_line_end()
            elif key == "y":
                lib.sv_doc_visual_yank()
                lib.sv_doc_normal_mode()
                message = "yanked"
            elif key == "d":
                lib.sv_doc_visual_delete()
                lib.sv_doc_normal_mode()
                message = "deleted"
            elif key == "p":
                lib.sv_doc_paste()
                lib.sv_doc_normal_mode()
                message = "pasted"
            elif key == "V":
                lib.sv_doc_normal_mode()

        else:
            if operator == "y":
                operator = None
                if key == "y":
                    lib.sv_doc_yank_current_line()
                    message = "yanked line"
                continue

            if operator == "d":
                operator = None
                if key == "d":
                    lib.sv_doc_delete_current_line()
                    message = "deleted line"
                continue

            if key == "i":
                lib.sv_doc_insert_mode()
            elif key == "a":
                lib.sv_doc_append()
            elif key == "A":
                lib.sv_line_end()
                lib.sv_doc_insert_mode()
            elif key == "I":
                lib.sv_line_start()
                lib.sv_doc_insert_mode()
            elif key == "o":
                lib.sv_doc_open_below()
            elif key == "O":
                lib.sv_doc_open_above()
            elif key == "V":
                lib.sv_doc_enter_visual()
            elif key in ("h", "<LEFT>"):
                lib.sv_move_left()
            elif key in ("l", "<RIGHT>"):
                lib.sv_move_right()
            elif key in ("j", "<DOWN>"):
                lib.sv_move_down()
            elif key in ("k", "<UP>"):
                lib.sv_move_up()
            elif key in ("0", "<HOME>"):
                lib.sv_line_start()
            elif key in ("$", "<END>"):
                lib.sv_line_end()
            elif key == "g":
                nxt = get_key()
                if nxt == "g":
                    lib.sv_goto_top()
            elif key == "G":
                lib.sv_goto_bottom()
            elif key == "y":
                operator = "y"
            elif key == "d":
                operator = "d"
            elif key == "p":
                lib.sv_doc_paste()
                message = "pasted"
            elif key == "u":
                lib.sv_doc_undo()
                message = "undo"
            elif key == "\x12":
                lib.sv_doc_redo()
                message = "redo"
            elif key == ":":
                cmd = input(":").strip()
                if cmd == "q":
                    if lib.sv_doc_is_modified():
                        message = "No write since last change : use :q!"
                    else:
                        break
                elif cmd == "q!":
                    break
                elif cmd == "w":
                    if current:
                        if lib.sv_file_save(current.encode("utf-8")):
                            message = f"wrote {current}"
                        else:
                            message = f"cannot write {current}"
                    else:
                        message = "No file name"
                elif cmd.startswith("w "):
                    current = cmd[2:].strip()
                    if current and lib.sv_file_save(current.encode("utf-8")):
                        message = f"wrote {current}"
                    else:
                        message = "cannot write"
                elif cmd.startswith("e "):
                    current = cmd[2:].strip()
                    if current:
                        if lib.sv_file_load(current.encode("utf-8")):
                            message = f"loaded {current}"
                        else:
                            lib.sv_doc_init()
                            message = f"new file {current}"
                elif cmd == "wq":
                    if current and lib.sv_file_save(current.encode("utf-8")):
                        break
                    elif current:
                        message = f"cannot write {current}"
                    else:
                        message = "No file name"
                elif cmd == "help":
                    message = "i insert | a append | o/O open | ESC normal | V visual | y/d line ops | p paste | u undo | Ctrl-R redo | :w :q :wq :e"
                else:
                    message = f"unknown command: {cmd}"

    print("\033[0m\033[?25h", end="")
EOF

cat > run.py << 'EOF'
import sys
from py.editor import run

filename = sys.argv[1] if len(sys.argv) > 1 else None
run(filename)
EOF

echo "Build done."
echo "Run: python3 run.py [file]"
