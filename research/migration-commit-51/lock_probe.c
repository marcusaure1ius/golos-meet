// Synthetic, process-local VFS probe. No production code, busy-handler change,
// SQL values, paths or pointer addresses are included in its JSON output.
#include <sqlite3.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static sqlite3_vfs *parent;
typedef struct { sqlite3_file file; sqlite3_file *real; } ProbeFile;
static _Thread_local int peer;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int entries, captured, capturedPeer, capturedState, resumePeer;
static int exec(sqlite3 *db, const char *sql) { return sqlite3_exec(db, sql, 0, 0, 0); }
#define REAL(f) (((ProbeFile *)(f))->real)
static int closeFile(sqlite3_file *f) { return REAL(f)->pMethods->xClose(REAL(f)); }
static int readFile(sqlite3_file *f,void *p,int n,sqlite3_int64 o) {return REAL(f)->pMethods->xRead(REAL(f),p,n,o);}
static int writeFile(sqlite3_file *f,const void *p,int n,sqlite3_int64 o) {return REAL(f)->pMethods->xWrite(REAL(f),p,n,o);}
static int truncateFile(sqlite3_file *f,sqlite3_int64 n) {return REAL(f)->pMethods->xTruncate(REAL(f),n);}
static int syncFile(sqlite3_file *f,int flags) {return REAL(f)->pMethods->xSync(REAL(f),flags);}
static int sizeFile(sqlite3_file *f,sqlite3_int64 *n) {return REAL(f)->pMethods->xFileSize(REAL(f),n);}
static int lockFile(sqlite3_file *f,int level) {
    int rc=REAL(f)->pMethods->xLock(REAL(f),level);
    pthread_mutex_lock(&mutex);
    if(peer && entries==2 && level==SQLITE_LOCK_SHARED && rc==SQLITE_OK && !captured) {
        captured=1; capturedPeer=peer; capturedState=-1;
        if(REAL(f)->pMethods->xFileControl(REAL(f),SQLITE_FCNTL_LOCKSTATE,&capturedState)!=SQLITE_OK)abort();
        pthread_cond_broadcast(&condition);
        // Keep an ACTUAL native SHARED lock until main attempts release.
        // Do not fabricate a return code or alter the native busy handler.
        while(!resumePeer) pthread_cond_wait(&condition,&mutex);
    }
    pthread_mutex_unlock(&mutex);
    return rc;
}
static int unlockFile(sqlite3_file *f,int level) {return REAL(f)->pMethods->xUnlock(REAL(f),level);}
static int reservedFile(sqlite3_file *f,int *n) {return REAL(f)->pMethods->xCheckReservedLock(REAL(f),n);}
static int controlFile(sqlite3_file *f,int op,void *p) {return REAL(f)->pMethods->xFileControl(REAL(f),op,p);}
static int sectorFile(sqlite3_file *f) {return REAL(f)->pMethods->xSectorSize(REAL(f));}
static int deviceFile(sqlite3_file *f) {return REAL(f)->pMethods->xDeviceCharacteristics(REAL(f));}
static int mapFile(sqlite3_file *f,int a,int b,int c,void volatile **p) {return REAL(f)->pMethods->xShmMap(REAL(f),a,b,c,p);}
static int shmLockFile(sqlite3_file *f,int a,int b,int c) {return REAL(f)->pMethods->xShmLock(REAL(f),a,b,c);}
static void barrierFile(sqlite3_file *f) {REAL(f)->pMethods->xShmBarrier(REAL(f));}
static int unmapFile(sqlite3_file *f,int a) {return REAL(f)->pMethods->xShmUnmap(REAL(f),a);}
static int fetchFile(sqlite3_file *f,sqlite3_int64 a,int b,void **p) {return REAL(f)->pMethods->xFetch(REAL(f),a,b,p);}
static int unfetchFile(sqlite3_file *f,sqlite3_int64 a,void *p) {return REAL(f)->pMethods->xUnfetch(REAL(f),a,p);}
static const sqlite3_io_methods methods={3,closeFile,readFile,writeFile,truncateFile,syncFile,sizeFile,lockFile,unlockFile,reservedFile,controlFile,sectorFile,deviceFile,mapFile,shmLockFile,barrierFile,unmapFile,fetchFile,unfetchFile};
static int openFile(sqlite3_vfs *v,const char *z,sqlite3_file *f,int flags,int *out) {
    (void)v; ProbeFile *p=(ProbeFile *)f; memset(p,0,sizeof(*p));p->real=(sqlite3_file *)(p+1);
    int rc=parent->xOpen(parent,z,p->real,flags,out);
    if(rc==SQLITE_OK)p->file.pMethods=&methods;
    return rc;
}
static void require(int yes) {if(!yes){fprintf(stderr,"probe invariant failed\n");exit(1);}}
static int trace(unsigned type,void *context,void *statement,void *unused) {
    (void)context;(void)unused;
    if(type==SQLITE_TRACE_STMT && strcmp(sqlite3_sql(statement),"BEGIN IMMEDIATE")==0) {
        pthread_mutex_lock(&mutex);entries++;pthread_cond_broadcast(&condition);
        while(entries<2)pthread_cond_wait(&condition,&mutex);
        pthread_mutex_unlock(&mutex);
    }return 0;
}
typedef struct {const char *path;int id,begin,commit,close;} Peer;
static void *contend(void *arg) {
    Peer *p=arg;peer=p->id;sqlite3 *db=0;
    require(sqlite3_open_v2(p->path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,"golos51-probe")==SQLITE_OK);
    require(sqlite3_busy_timeout(db,2000)==SQLITE_OK);
    require(sqlite3_trace_v2(db,SQLITE_TRACE_STMT,trace,0)==SQLITE_OK);
    p->begin=exec(db,"BEGIN IMMEDIATE");
    if(p->begin==SQLITE_OK) {
        require(exec(db,"CREATE TABLE IF NOT EXISTS synthetic(value)")==SQLITE_OK);
        p->commit=exec(db,"COMMIT");
    }
    p->close=sqlite3_close(db);return 0;
}
int main(void) {
    alarm(15); // Bound the diagnostic process if an invariant stalls.
    parent=sqlite3_vfs_find(0);require(parent!=0);sqlite3_vfs vfs=*parent;
    vfs.zName="golos51-probe";vfs.szOsFile=(int)sizeof(ProbeFile)+parent->szOsFile;vfs.xOpen=openFile;
    require(sqlite3_vfs_register(&vfs,0)==SQLITE_OK);
    for(int initialized=0;initialized<2;initialized++)for(int rollback=0;rollback<2;rollback++) {
        entries=captured=capturedPeer=resumePeer=0;capturedState=-1;
        char path[]="/private/tmp/golos51-vfs-XXXXXX";int fd=mkstemp(path);require(fd>=0);close(fd);
        sqlite3 *held=0;require(sqlite3_open_v2(path,&held,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,"golos51-probe")==SQLITE_OK);
        if(initialized)require(exec(held,"CREATE TABLE sentinel(value); DROP TABLE sentinel")==SQLITE_OK);
        require(exec(held,"BEGIN IMMEDIATE")==SQLITE_OK);
        Peer a={path,1,-1,-1,-1},b={path,2,-1,-1,-1};pthread_t one,two;
        require(pthread_create(&one,0,contend,&a)==0);require(pthread_create(&two,0,contend,&b)==0);
        pthread_mutex_lock(&mutex);while(!captured)pthread_cond_wait(&condition,&mutex);pthread_mutex_unlock(&mutex);
        int before=-1,after=-1;require(sqlite3_file_control(held,"main",SQLITE_FCNTL_LOCKSTATE,&before)==SQLITE_OK);
        int result=exec(held,rollback?"ROLLBACK":"COMMIT"),extended=sqlite3_extended_errcode(held);
        require(sqlite3_file_control(held,"main",SQLITE_FCNTL_LOCKSTATE,&after)==SQLITE_OK);
        int cleanup=rollback?-1:exec(held,"ROLLBACK");int closed=sqlite3_close(held);
        pthread_mutex_lock(&mutex);resumePeer=1;pthread_cond_broadcast(&condition);pthread_mutex_unlock(&mutex);
        require(pthread_join(one,0)==0);require(pthread_join(two,0)==0);
        printf("{\"sqlite\":\"%s\",\"initialized\":%d,\"action\":\"%s\",\"sqlite_begin_entries\":%d,\"native_shared_holder\":%d,\"native_shared_state\":%d,\"writer_lock_before\":%d,\"writer_lock_after\":%d,\"result\":%d,\"extended\":%d,\"cleanup\":%d,\"close\":%d,\"peer_begin\":[%d,%d],\"peer_commit\":[%d,%d],\"peer_close\":[%d,%d]}\n",sqlite3_libversion(),initialized,rollback?"rollback":"commit",entries,capturedPeer,capturedState,before,after,result,extended,cleanup,closed,a.begin,b.begin,a.commit,b.commit,a.close,b.close);
        fflush(stdout);
        require(capturedState==SQLITE_LOCK_SHARED);require(result==(rollback?SQLITE_OK:SQLITE_BUSY));require(rollback||cleanup==SQLITE_OK);
        require(closed==SQLITE_OK && a.begin==SQLITE_OK && b.begin==SQLITE_OK && a.commit==SQLITE_OK && b.commit==SQLITE_OK && a.close==SQLITE_OK && b.close==SQLITE_OK);
        unlink(path);
    }
    require(sqlite3_vfs_unregister(&vfs)==SQLITE_OK);return 0;
}
