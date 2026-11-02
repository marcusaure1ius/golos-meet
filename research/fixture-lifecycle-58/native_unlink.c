#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

/* Synthetic, single-process comparison of exactly the same late SQL write.
   The legacy control unlinks before the live connection writes. The safe
   control writes, closes, then unlinks. No VFS, busy handler or return override. */
static int run(int early) {
    char root[] = "/private/tmp/golos58-native-XXXXXX";
    if (!mkdtemp(root)) return 2;
    char path[512]; snprintf(path, sizeof path, "%s/library.sqlite", root);
    sqlite3 *db = NULL;
    int opened = sqlite3_open(path, &db);
    if (opened != SQLITE_OK) return 3;
    int setup = sqlite3_exec(db, "CREATE TABLE sentinel(value INTEGER); INSERT INTO sentinel VALUES(1)", NULL, NULL, NULL);
    if (setup != SQLITE_OK) return 4;
    if (early && (unlink(path) || rmdir(root))) return 5;
    int begin = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    int begin_extended = sqlite3_extended_errcode(db);
    int write = begin == SQLITE_OK ? sqlite3_exec(db, "INSERT INTO sentinel VALUES(2)", NULL, NULL, NULL) : -1;
    int write_extended = write >= 0 ? sqlite3_extended_errcode(db) : -1;
    int finish = sqlite3_exec(db, begin == SQLITE_OK && write == SQLITE_OK ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    int finish_extended = sqlite3_extended_errcode(db);
    int count = -1; sqlite3_stmt *stmt = NULL;
    if (!early && sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sentinel", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
        sqlite3_finalize(stmt);
    }
    int closed = sqlite3_close(db);
    if (!early && (unlink(path) || rmdir(root))) return 6;
    printf("{\"early_unlink\":%s,\"begin\":%d,\"begin_extended\":%d,\"write\":%d,\"write_extended\":%d,\"finish\":%d,\"finish_extended\":%d,\"close\":%d,\"rows_before_cleanup\":%d,\"root_exists\":%s,\"sqlite\":\"%s\"}\n",early?"true":"false",begin,begin_extended,write,write_extended,finish,finish_extended,closed,count,access(root,F_OK)==0?"true":"false",sqlite3_libversion());
    return early ? (begin != SQLITE_OK || write_extended != SQLITE_READONLY_DBMOVED || closed != SQLITE_OK) : (begin || write || finish || closed || count != 2);
}
int main(void) { int legacy=run(1); int safe=run(0); return legacy || safe; }
