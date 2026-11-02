#!/usr/bin/env python3
from pathlib import Path
import argparse,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--copy',type=Path,required=True);a=p.parse_args()
file=a.copy/'golos-meet/Util/SQLiteDiagnostics56.swift';s=file.read_text()
# Distinguish deletion of the DB file from deletion of its enclosing directory.
s=s.replace('"exists":FileManager.default.fileExists(atPath:root.path)', '"exists":FileManager.default.fileExists(atPath:root.path),"databaseExists":FileManager.default.fileExists(atPath:root.appendingPathComponent("knowledge.sqlite").path)')
idx=s.rfind('\n}')
s=s[:idx]+'''
    static func removeOrRetain(_ root: URL) {
        if ProcessInfo.processInfo.environment["GOLOS_SQLITE_RETAIN_56"] == "1", allowed(root) {
            lock.lock(); defer { lock.unlock() }
            write(["stage":"fixture-retained","root":root.lastPathComponent,"test":tests[root.lastPathComponent] ?? "unknown"])
            return
        }
        try? FileManager.default.removeItem(at: root)
        removed(root)
    }
''' +s[idx:];file.write_text(s)
updates={}
for rel in ['golos-meetTests/ProjectMemoryUpdateTests.swift','golos-meetTests/IndexingProductionHooksTests.swift']:
 p=a.copy/rel;s=p.read_text();updates[rel]={'before_sha256':hashlib.sha256(s.encode()).hexdigest(),'replacements':s.count('try? FileManager.default.removeItem(at: root)')}
 s=s.replace('try? FileManager.default.removeItem(at: root); SQLiteDiag56.removed(root)','SQLiteDiag56.removeOrRetain(root)')
 s=s.replace('try? FileManager.default.removeItem(at: root)','SQLiteDiag56.removeOrRetain(root)');p.write_text(s)
(a.copy/'sqlite-retention-control.json').write_text(json.dumps(updates,indent=2)+'\n')
