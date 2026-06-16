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

extern int sv_mode;
extern int sv_modified;
extern int sv_visual_anchor;
extern int sv_visual_active;
extern char *sv_yank;

void sv_set_mode(int m);
int sv_get_mode(void);

void sv_enter_visual(void);
void sv_exit_visual(void);

void gb_init(void);
void gb_free(void);
void gb_load_text(const char *text);
char *gb_serialize(void);
size_t gb_len(void);
int gb_line_count(void);
const char *gb_get_line(int idx);
int gb_line_len_at(int idx);
int sv_line_len(int idx);
void gb_rowcol_from_cursor(int *row, int *col);
size_t gb_cursor_from_rowcol(int row, int col);
void gb_move_to_rowcol(int row, int col);
void gb_insert_char(char c);
void gb_newline(void);
void gb_backspace(void);

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

void sv_move_left(void);
void sv_move_right(void);
void sv_move_up(void);
void sv_move_down(void);
void sv_goto_top(void);
void sv_goto_bottom(void);
void sv_line_start(void);
void sv_line_end(void);

int sv_file_load(const char *path);
int sv_file_save(const char *path);
int sv_file_save_async(const char *path);
int sv_async_busy(void);
const char *sv_async_status(void);
void sv_async_wait(void);

int sv_doc_line_count(void);
int sv_doc_row(void);
int sv_doc_col(void);
int sv_doc_is_modified(void);
const char *sv_doc_get_yank(void);
const char *sv_get_line(int idx);

#endif
EOF

cat > core/gapbuffer.c << 'EOF'
#include "supervim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *gb = NULL;
static size_t gb_cap = 0;
static size_t gb_start = 0;
static size_t gb_end = 0;

static char *line_buf = NULL;
static size_t line_buf_cap = 0;

int sv_mode = MODE_NORMAL;
int sv_modified = 0;
int sv_visual_anchor = 0;
int sv_visual_active = 0;
char *sv_yank = NULL;

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) { perror("malloc"); exit(1); }
    return p;
}

static void *xcalloc(size_t n, size_t s) {
    void *p = calloc(n ? n : 1, s ? s : 1);
    if (!p) { perror("calloc"); exit(1); }
    return p;
}

static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) { perror("realloc"); exit(1); }
    return q;
}

static char *xstrdup0(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)xmalloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

static size_t gb_gap_size(void) {
    return gb_end > gb_start ? (gb_end - gb_start) : 0;
}

size_t gb_len(void) {
    if (!gb) return 0;
    return gb_cap - gb_gap_size();
}

static char gb_char_at(size_t pos) {
    if (pos < gb_start) return gb[pos];
    return gb[gb_end + (pos - gb_start)];
}

static void ensure_gap(size_t need) {
    if (gb_gap_size() >= need) return;

    size_t left = gb_start;
    size_t right = gb_cap - gb_end;
    size_t new_cap = gb_cap ? gb_cap * 2 : 1024;
    while (new_cap < left + right + need + 64) new_cap *= 2;

    char *n = (char *)xcalloc(new_cap, 1);
    size_t new_end = new_cap - right;

    if (left) memcpy(n, gb, left);
    if (right) memcpy(n + new_end, gb + gb_end, right);

    free(gb);
    gb = n;
    gb_cap = new_cap;
    gb_start = left;
    gb_end = new_end;
}

static void move_gap(size_t pos) {
    size_t len = gb_len();
    if (pos > len) pos = len;

    if (pos < gb_start) {
        size_t move = gb_start - pos;
        memmove(gb + gb_end - move, gb + pos, move);
        gb_end -= move;
        gb_start = pos;
    } else if (pos > gb_start) {
        size_t move = pos - gb_start;
        memmove(gb + gb_start, gb + gb_end, move);
        gb_start += move;
        gb_end += move;
    }
}

void gb_free(void) {
    free(gb);
    gb = NULL;
    gb_cap = 0;
    gb_start = 0;
    gb_end = 0;
}

void gb_init(void) {
    gb_free();
    gb_cap = 1024;
    gb = (char *)xcalloc(gb_cap, 1);
    gb_start = 0;
    gb_end = gb_cap;
}

void gb_load_text(const char *text) {
    gb_free();
    if (!text) text = "";
    size_t n = strlen(text);

    gb_cap = n + 1024;
    if (gb_cap < 1024) gb_cap = 1024;
    gb = (char *)xcalloc(gb_cap, 1);

    gb_start = 0;
    gb_end = gb_cap - n;
    if (n) memcpy(gb + gb_end, text, n);
}

char *gb_serialize(void) {
    size_t n = gb_len();
    char *out = (char *)xmalloc(n + 1);
    if (gb_start) memcpy(out, gb, gb_start);
    size_t right = gb_cap - gb_end;
    if (right) memcpy(out + gb_start, gb + gb_end, right);
    out[n] = '\0';
    return out;
}

int gb_line_count(void) {
    size_t n = gb_len();
    if (n == 0) return 1;
    int lines = 1;
    for (size_t i = 0; i < n; i++) {
        if (gb_char_at(i) == '\n') lines++;
    }
    return lines;
}

void gb_rowcol_from_cursor(int *row, int *col) {
    if (!row || !col) return;
    *row = 0;
    *col = 0;
    for (size_t i = 0; i < gb_start; i++) {
        char c = gb_char_at(i);
        if (c == '\n') { (*row)++; *col = 0; }
        else (*col)++;
    }
}

size_t gb_cursor_from_rowcol(int row, int col) {
    if (row < 0) row = 0;
    if (col < 0) col = 0;

    size_t len = gb_len();
    int cur_row = 0;
    int cur_col = 0;

    for (size_t pos = 0; pos < len; pos++) {
        if (cur_row == row && cur_col == col) return pos;
        char c = gb_char_at(pos);
        if (c == '\n') { cur_row++; cur_col = 0; }
        else cur_col++;
    }
    return len;
}

void gb_move_to_rowcol(int row, int col) {
    size_t pos = gb_cursor_from_rowcol(row, col);
    move_gap(pos);
}

int gb_line_len_at(int idx) {
    if (idx < 0) return 0;
    int cur = 0;
    int len = 0;
    size_t n = gb_len();

    for (size_t i = 0; i < n; i++) {
        char c = gb_char_at(i);
        if (cur == idx) {
            if (c == '\n') break;
            len++;
        } else if (c == '\n') {
            cur++;
        }
    }
    return len;
}

int sv_line_len(int idx) {
    return gb_line_len_at(idx);
}

const char *gb_get_line(int idx) {
    if (idx < 0) return "";
    int cur = 0;
    size_t n = gb_len();
    size_t out = 0;

    if (line_buf_cap < 128) {
        line_buf_cap = 128;
        line_buf = (char *)xrealloc(line_buf, line_buf_cap);
    }

    for (size_t i = 0; i < n; i++) {
        char c = gb_char_at(i);
        if (cur == idx) {
            if (c == '\n') break;
            if (out + 2 > line_buf_cap) {
                line_buf_cap *= 2;
                line_buf = (char *)xrealloc(line_buf, line_buf_cap);
            }
            line_buf[out++] = c;
        } else if (c == '\n') {
            cur++;
        }
    }

    line_buf[out] = '\0';
    if (idx == 0 && n == 0) line_buf[0] = '\0';
    return line_buf;
}

void gb_insert_char(char c) {
    ensure_gap(1);
    gb[gb_start++] = c;
}

void gb_newline(void) {
    gb_insert_char('\n');
}

void gb_backspace(void) {
    if (gb_start == 0) return;
    gb_start--;
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
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    sv_visual_anchor = row;
}

void sv_exit_visual(void) {
    sv_mode = MODE_NORMAL;
    sv_visual_active = 0;
}
EOF

cat > core/cursor.c << 'EOF'
#include "supervim.h"

void sv_move_left(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    if (row == 0 && col == 0) return;

    if (col > 0) {
        col--;
    } else {
        row--;
        col = sv_line_len(row);
    }
    gb_move_to_rowcol(row, col);
}

void sv_move_right(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    int len = sv_line_len(row);

    if (col < len) {
        col++;
    } else if (row + 1 < sv_doc_line_count()) {
        row++;
        col = 0;
    }

    gb_move_to_rowcol(row, col);
}

void sv_move_up(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    if (row <= 0) return;

    row--;
    int len = sv_line_len(row);
    if (col > len) col = len;
    gb_move_to_rowcol(row, col);
}

void sv_move_down(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    int count = sv_doc_line_count();
    if (row + 1 >= count) return;

    row++;
    int len = sv_line_len(row);
    if (col > len) col = len;
    gb_move_to_rowcol(row, col);
}

void sv_goto_top(void) {
    gb_move_to_rowcol(0, 0);
}

void sv_goto_bottom(void) {
    int last = sv_doc_line_count() - 1;
    if (last < 0) last = 0;
    gb_move_to_rowcol(last, 0);
}

void sv_line_start(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    gb_move_to_rowcol(row, 0);
}

void sv_line_end(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    gb_move_to_rowcol(row, sv_line_len(row));
}
EOF

cat > core/async.c << 'EOF'
#include "supervim.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *path;
    char *text;
} Job;

static pthread_t th;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int started = 0;
static int busy = 0;
static int queued = 0;
static int stop_flag = 0;
static Job job = {0};
static char status_msg[128] = "idle";

static char *xstrdup0(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) { perror("malloc"); exit(1); }
    memcpy(p, s, n + 1);
    return p;
}

static void *worker_main(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&mu);
        while (!queued && !stop_flag) pthread_cond_wait(&cv, &mu);
        if (stop_flag) {
            pthread_mutex_unlock(&mu);
            break;
        }

        Job local = job;
        job.path = NULL;
        job.text = NULL;
        queued = 0;
        snprintf(status_msg, sizeof(status_msg), "saving...");
        pthread_mutex_unlock(&mu);

        int ok = 0;
        if (local.path && local.text) {
            FILE *f = fopen(local.path, "w");
            if (f) {
                size_t n = strlen(local.text);
                fwrite(local.text, 1, n, f);
                fclose(f);
                ok = 1;
            }
        }

        free(local.path);
        free(local.text);

        pthread_mutex_lock(&mu);
        busy = 0;
        if (ok) {
            sv_modified = 0;
            snprintf(status_msg, sizeof(status_msg), "saved");
        } else {
            snprintf(status_msg, sizeof(status_msg), "save failed");
        }
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&mu);
    }
    return NULL;
}

static void ensure_started(void) {
    pthread_mutex_lock(&mu);
    if (!started) {
        started = 1;
        pthread_create(&th, NULL, worker_main, NULL);
    }
    pthread_mutex_unlock(&mu);
}

int sv_async_queue_save(const char *path, const char *text) {
    ensure_started();

    pthread_mutex_lock(&mu);
    if (busy || queued) {
        pthread_mutex_unlock(&mu);
        return 0;
    }

    job.path = xstrdup0(path);
    job.text = xstrdup0(text);
    busy = 1;
    queued = 1;
    snprintf(status_msg, sizeof(status_msg), "queued");
    pthread_cond_signal(&cv);
    pthread_mutex_unlock(&mu);
    return 1;
}

int sv_async_busy(void) {
    pthread_mutex_lock(&mu);
    int r = busy || queued;
    pthread_mutex_unlock(&mu);
    return r;
}

const char *sv_async_status(void) {
    return status_msg;
}

void sv_async_wait(void) {
    pthread_mutex_lock(&mu);
    while (busy || queued) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
}
EOF

cat > core/fileio.c << 'EOF'
#include "supervim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int sv_async_queue_save(const char *path, const char *text);

int sv_file_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        sv_doc_init();
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

    gb_load_text(buf);
    free(buf);

    sv_modified = 0;
    sv_set_mode(MODE_NORMAL);
    return 1;
}

int sv_file_save(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return 0;

    char *txt = gb_serialize();
    size_t n = strlen(txt);
    fwrite(txt, 1, n, f);
    fclose(f);
    free(txt);

    sv_modified = 0;
    return 1;
}

int sv_file_save_async(const char *path) {
    char *txt = gb_serialize();
    int ok = sv_async_queue_save(path, txt);
    free(txt);
    return ok;
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

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) { perror("malloc"); exit(1); }
    return p;
}

static char *xstrdup0(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)xmalloc(n + 1);
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
    for (int i = 0; i < *top; i++) free_snapshot(&stack[i]);
    *top = 0;
}

static void push_stack(Snapshot *stack, int *top, const char *text, int row, int col, int mode) {
    if (*top == MAX_STACK) {
        free_snapshot(&stack[0]);
        memmove(&stack[0], &stack[1], sizeof(Snapshot) * (MAX_STACK - 1));
        *top = MAX_STACK - 1;
    }
    stack[*top].text = xstrdup0(text);
    stack[*top].row = row;
    stack[*top].col = col;
    stack[*top].mode = mode;
    (*top)++;
}

static void begin_edit(void) {
    char *snap = gb_serialize();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    push_stack(undo_stack, &undo_top, snap, row, col, sv_mode);
    free(snap);
    clear_stack(redo_stack, &redo_top);
}

static void restore_snapshot(Snapshot *s) {
    gb_load_text(s->text);
    gb_move_to_rowcol(s->row, s->col);
    sv_set_mode(s->mode);
    sv_modified = 1;
}

static void free_lines(char **lines, int count) {
    if (!lines) return;
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
}

static char **split_text(const char *text, int *count) {
    int cap = 8;
    *count = 0;
    char **arr = (char **)xmalloc(sizeof(char *) * cap);

    if (!text || !*text) {
        arr[(*count)++] = xstrdup0("");
        return arr;
    }

    const char *start = text;
    for (const char *p = text;; p++) {
        if (*p == '\n' || *p == '\0') {
            size_t n = (size_t)(p - start);
            if (*count == cap) {
                cap *= 2;
                arr = (char **)realloc(arr, sizeof(char *) * cap);
                if (!arr) { perror("realloc"); exit(1); }
            }
            char *line = (char *)xmalloc(n + 1);
            memcpy(line, start, n);
            line[n] = '\0';
            arr[(*count)++] = line;
            if (*p == '\0') break;
            start = p + 1;
        }
    }
    return arr;
}

static char *join_lines(char **lines, int count) {
    size_t total = 1;
    for (int i = 0; i < count; i++) {
        total += strlen(lines[i]);
        if (i + 1 < count) total += 1;
    }

    char *out = (char *)xmalloc(total);
    char *p = out;
    for (int i = 0; i < count; i++) {
        size_t n = strlen(lines[i]);
        memcpy(p, lines[i], n);
        p += n;
        if (i + 1 < count) *p++ = '\n';
    }
    *p = '\0';
    return out;
}

static void reload_lines(char **lines, int count, int row, int col) {
    char *txt = join_lines(lines, count);
    gb_load_text(txt);
    gb_move_to_rowcol(row, col);
    free(txt);
}

void sv_doc_init(void) {
    gb_init();
    sv_set_mode(MODE_NORMAL);
    sv_modified = 0;
    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }
    clear_stack(undo_stack, &undo_top);
    clear_stack(redo_stack, &redo_top);
}

void sv_doc_undo(void) {
    if (undo_top <= 0) return;
    char *current = gb_serialize();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    push_stack(redo_stack, &redo_top, current, row, col, sv_mode);
    free(current);

    Snapshot s = undo_stack[--undo_top];
    restore_snapshot(&s);
    free_snapshot(&s);
}

void sv_doc_redo(void) {
    if (redo_top <= 0) return;
    char *current = gb_serialize();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    push_stack(undo_stack, &undo_top, current, row, col, sv_mode);
    free(current);

    Snapshot s = redo_stack[--redo_top];
    restore_snapshot(&s);
    free_snapshot(&s);
}

void sv_doc_insert_char(char c) {
    begin_edit();
    gb_insert_char(c);
    sv_modified = 1;
}

void sv_doc_newline(void) {
    begin_edit();
    gb_newline();
    sv_modified = 1;
}

void sv_doc_backspace(void) {
    begin_edit();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);

    if (col > 0) {
        gb_backspace();
    } else if (row > 0) {
        char *txt = gb_serialize();
        int count = 0;
        char **lines = split_text(txt, &count);
        free(txt);

        if (row < count && row > 0) {
            int prev_len = (int)strlen(lines[row - 1]);
            char *merged = (char *)xmalloc((size_t)prev_len + strlen(lines[row]) + 1);
            strcpy(merged, lines[row - 1]);
            strcat(merged, lines[row]);
            free(lines[row - 1]);
            free(lines[row]);
            lines[row - 1] = merged;

            for (int i = row; i + 1 < count; i++) lines[i] = lines[i + 1];
            count--;

            reload_lines(lines, count, row - 1, prev_len);
            lines = NULL;
        }

        free_lines(lines, count);
    }

    sv_modified = 1;
}

void sv_doc_open_below(void) {
    begin_edit();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    if (count <= 0) {
        free_lines(lines, count);
        gb_load_text("\n");
        gb_move_to_rowcol(1, 0);
        sv_set_mode(MODE_INSERT);
        sv_modified = 1;
        return;
    }

    if (row < 0) row = 0;
    if (row >= count) row = count - 1;

    char **n = (char **)xmalloc(sizeof(char *) * (count + 1));
    int k = 0;
    for (int i = 0; i < count; i++) {
        n[k++] = xstrdup0(lines[i]);
        if (i == row) n[k++] = xstrdup0("");
    }
    if (row == count - 1) n[k++] = xstrdup0("");

    reload_lines(n, count + 1, row + 1, 0);
    free_lines(lines, count);

    sv_set_mode(MODE_INSERT);
    sv_modified = 1;
}

void sv_doc_open_above(void) {
    begin_edit();
    int row, col;
    gb_rowcol_from_cursor(&row, &col);

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    if (count <= 0) {
        free_lines(lines, count);
        gb_load_text("\n");
        gb_move_to_rowcol(0, 0);
        sv_set_mode(MODE_INSERT);
        sv_modified = 1;
        return;
    }

    if (row < 0) row = 0;
    if (row >= count) row = count - 1;

    char **n = (char **)xmalloc(sizeof(char *) * (count + 1));
    int k = 0;
    for (int i = 0; i < count; i++) {
        if (i == row) n[k++] = xstrdup0("");
        n[k++] = xstrdup0(lines[i]);
    }
    if (row == count) n[k++] = xstrdup0("");

    reload_lines(n, count + 1, row, 0);
    free_lines(lines, count);

    sv_set_mode(MODE_INSERT);
    sv_modified = 1;
}

void sv_doc_append(void) {
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    gb_move_to_rowcol(row, sv_line_len(row));
    sv_set_mode(MODE_INSERT);
}

void sv_doc_insert_mode(void) {
    sv_set_mode(MODE_INSERT);
}

void sv_doc_normal_mode(void) {
    sv_set_mode(MODE_NORMAL);
}

void sv_doc_enter_visual(void) {
    sv_enter_visual();
}

void sv_doc_exit_visual(void) {
    sv_exit_visual();
}

void sv_doc_visual_yank(void) {
    if (!sv_visual_active) return;
    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    int a = sv_visual_anchor;
    int b = row;
    if (a > b) { int t = a; a = b; b = t; }

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    a = a < 0 ? 0 : a;
    b = b >= count ? count - 1 : b;
    sv_yank = (a <= b) ? join_lines(lines + a, b - a + 1) : xstrdup0("");
    free_lines(lines, count);
    sv_exit_visual();
}

void sv_doc_visual_delete(void) {
    if (!sv_visual_active) return;
    begin_edit();

    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }

    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    int a = sv_visual_anchor;
    int b = row;
    if (a > b) { int t = a; a = b; b = t; }

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    a = a < 0 ? 0 : a;
    b = b >= count ? count - 1 : b;

    if (a <= b) {
        sv_yank = join_lines(lines + a, b - a + 1);

        int newcount = count - (b - a + 1);
        if (newcount <= 0) {
            gb_load_text("");
            gb_move_to_rowcol(0, 0);
        } else {
            char **n = (char **)xmalloc(sizeof(char *) * newcount);
            int k = 0;
            for (int i = 0; i < count; i++) {
                if (i < a || i > b) n[k++] = xstrdup0(lines[i]);
            }
            reload_lines(n, newcount, a < newcount ? a : newcount - 1, 0);
            free_lines(n, newcount);
        }
    }

    free_lines(lines, count);
    sv_exit_visual();
    sv_modified = 1;
}

void sv_doc_yank_current_line(void) {
    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }
    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    sv_yank = xstrdup0(gb_get_line(row));
}

void sv_doc_delete_current_line(void) {
    begin_edit();

    if (sv_yank) {
        free(sv_yank);
        sv_yank = NULL;
    }

    int row, col;
    gb_rowcol_from_cursor(&row, &col);
    sv_yank = xstrdup0(gb_get_line(row));

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    if (count <= 1) {
        gb_load_text("");
        gb_move_to_rowcol(0, 0);
        free_lines(lines, count);
    } else {
        char **n = (char **)xmalloc(sizeof(char *) * (count - 1));
        int k = 0;
        for (int i = 0; i < count; i++) {
            if (i != row) n[k++] = xstrdup0(lines[i]);
        }
        reload_lines(n, count - 1, row < count - 1 ? row : count - 2, 0);
        free_lines(lines, count);
    }

    sv_modified = 1;
}

void sv_doc_paste(void) {
    if (!sv_yank || !*sv_yank) return;

    int row, col;
    gb_rowcol_from_cursor(&row, &col);

    char *txt = gb_serialize();
    int count = 0;
    char **lines = split_text(txt, &count);
    free(txt);

    int ycount = 0;
    char **ylines = split_text(sv_yank, &ycount);

    char **n = (char **)xmalloc(sizeof(char *) * (count + ycount));
    int k = 0;
    for (int i = 0; i < count; i++) {
        n[k++] = xstrdup0(lines[i]);
        if (i == row) {
            for (int j = 0; j < ycount; j++) n[k++] = xstrdup0(ylines[j]);
        }
    }
    if (row >= count - 1) {
        for (int j = 0; j < ycount; j++) n[k++] = xstrdup0(ylines[j]);
    }

    int new_row = row + 1;
    if (new_row > count + ycount - 1) new_row = count + ycount - 1;

    reload_lines(n, count + ycount, new_row, 0);
    free_lines(lines, count);
    free_lines(ylines, ycount);

    sv_modified = 1;
}

int sv_doc_line_count(void) {
    return gb_line_count();
}

int sv_doc_row(void) {
    int r, c;
    gb_rowcol_from_cursor(&r, &c);
    return r;
}

int sv_doc_col(void) {
    int r, c;
    gb_rowcol_from_cursor(&r, &c);
    return c;
}

int sv_doc_is_modified(void) {
    return sv_modified;
}

const char *sv_doc_get_yank(void) {
    return sv_yank ? sv_yank : "";
}
EOF

cat > core/extra.c << 'EOF'
#include "supervim.h"

const char *sv_get_line(int idx) {
    return gb_get_line(idx);
}
EOF

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
lib.sv_file_save_async.argtypes = [ctypes.c_char_p]
lib.sv_file_save_async.restype = ctypes.c_int
lib.sv_async_busy.restype = ctypes.c_int
lib.sv_async_status.restype = ctypes.c_char_p
lib.sv_async_wait.restype = None

lib.sv_doc_undo.restype = None
lib.sv_doc_redo.restype = None

lib.sv_doc_insert_char.argtypes = [ctypes.c_char]
lib.sv_doc_insert_char.restype = None
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

HELP_TEXT = "i insert | a append | o/O open | ESC normal | yy/dd/p | h j k l arrows | :w :q :wq :e"
MODE_NAMES = {0: "NORMAL", 1: "INSERT", 2: "VISUAL"}

def line_text(i):
    raw = lib.sv_get_line(i)
    return raw.decode("utf-8", "replace") if raw else ""

def cursor_line(text, col):
    if col < 0:
        col = 0
    if col > len(text):
        col = len(text)
    return text[:col] + "█" + text[col:]

def render(filename, message=""):
    cols, rows = shutil.get_terminal_size((80, 24))
    mode = MODE_NAMES.get(lib.sv_get_mode(), "?")
    row = lib.sv_doc_row()
    col = lib.sv_doc_col()
    count = lib.sv_doc_line_count()
    modified = " [+]" if lib.sv_doc_is_modified() else ""
    name = filename if filename else "[No Name]"
    async_msg = ""
    if lib.sv_async_busy():
        st = lib.sv_async_status()
        async_msg = f" | {st.decode('utf-8', 'replace') if st else 'saving'}"

    print("\033[H\033[J", end="")

    viewport = max(0, row - (rows // 2))
    body = rows - 4

    for i in range(body):
        src = viewport + i
        if src < count:
            t = line_text(src)
            prefix = ">" if src == row else " "
            if src == row:
                t = cursor_line(t, col)
            print(f"{prefix}{src + 1:>4} {t}")
        else:
            print("~")

    status = f"SUPERVIM stable {mode}{modified} | {name} | {row + 1},{col + 1}{async_msg}"
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
                data = key.encode("utf-8", "ignore")
                for b in data:
                    lib.sv_doc_insert_char(bytes([b]))

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
            elif key == "V":
                lib.sv_doc_enter_visual()
            elif key == ":":
                cmd = input(":").strip()
                if cmd == "q":
                    if lib.sv_doc_is_modified() or lib.sv_async_busy():
                        message = "No write since last change : use :q!"
                    else:
                        break
                elif cmd == "q!":
                    break
                elif cmd == "w":
                    if current:
                        if lib.sv_file_save_async(current.encode("utf-8")):
                            message = f"queued save {current}"
                        else:
                            message = "save busy"
                    else:
                        message = "No file name"
                elif cmd.startswith("w "):
                    current = cmd[2:].strip()
                    if current and lib.sv_file_save_async(current.encode("utf-8")):
                        message = f"queued save {current}"
                    else:
                        message = "save busy / invalid name"
                elif cmd.startswith("e "):
                    current = cmd[2:].strip()
                    if current:
                        if lib.sv_file_load(current.encode("utf-8")):
                            message = f"loaded {current}"
                        else:
                            lib.sv_doc_init()
                            message = f"new file {current}"
                elif cmd == "wq":
                    if current and lib.sv_file_save_async(current.encode("utf-8")):
                        lib.sv_async_wait()
                        break
                    elif current:
                        message = "save busy"
                    else:
                        message = "No file name"
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

ls core/*.c | xargs -I{} sh -c '
  clang -fPIC -c "{}" -o "build/$(basename "{}" .c).o"
'

clang -shared \
    build/*.o \
    -o build/libsupervim.so \
    -lpthread

echo "Build done."
echo "Run:"
#echo "  chmod +x build.sh"
#echo "  ./build.sh"
echo "  python3 run.py [file]"
