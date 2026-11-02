# Confirmed diagnostic host startup P2 · exact acfe44fb

Independent reviewer `/root/review43`, non-implementer. Source **acfe44fb379a9ba8de3c0aa5de7fefb9c93bd28f**, compiled **2febb801cd211db850eb3ce8dba70741a526d5a0**; production feature source24b unchanged. No sourcefix/build/host/CUA/actualcase/reset was performed in this audit. Exactly ONE root-authorized Foundation-only CLI check was run, described below. Raw IPS remain LOCAL untracked review evidence; not uploaded to Apple/GitHub.

## Finding P2 — AppPaths guard rejects the configured owned root through path aliases

`research/MemoryPanelGateDiagnostics.swift:13` compares canonical-looking strings from two different Foundation URL transformations: configured non-existing library stays `/private/var/folders/.../T/golos-memory-gate37-.../library`, while existing NSTemporaryDirectory resolves to `/var/folders/.../T`. The comparison `root.path.hasPrefix(temporary.path + "/golos-memory-gate37-")` is false. The host calls precondition before GateLog/store/setup, so it traps without creating runtime library or usable diagnostic UI/evidence. This is a host-only startup blocker; no production cancellation/privacy defect or signature cause is inferred.

### Actual LaunchServices/startup evidence

Two exact-bundle crash files were independently read/copied/hashed:

- 223214 ips, SHA **519057daabb5e3517ab07a56063d0f4ef9e0179372bec565546fd1cea7004e77**; launch22:32:13.7223+0300, capture22:32:13.9123. Root separately recorded explicit OS open after human readiness and process exit/library absent.
- 195650 ips, SHA **a2ee377ba28e403fb0650dd3e4f83d8700116afb1a42aa87bf3c585708e20706**; launch19:56:47.0435+0300, capture19:56:48.2594. Correlation with prior CUA getApp is possible but NOT asserted as established causality.

Both identify bundle **com.golos.memory-gate37.e09a046874694f3ba87b32616c963c6f**, Mach-O UUID **8a8bd768-b064-3414-a074-b3ec59215734**, SIGTRAP/EXC_BREAKPOINT, identical AppPaths initialization closure imageOffset3934024/symbolLocation1528, then GateDiagnosticCoordinator.init. Current binary SHA **ae7f8d0e29241bf61deaa0c95cc5829f3f08c4b08ead04d2fdc07d25b6043094** and parsed UUID match; Info/source/compiled source unchanged, actual codesign strict verify still0, library absent.

IPS DO NOT capture NSTemporaryDirectory/root URL values inside the app process. Therefore the precise LaunchServices string values are not presented as directly observed. The crash proves AppPaths assertion; the separate exact-expression CLI repro demonstrates the configured guard defect and concrete alias mechanism. Earlier static source/signature acceptance did not cover successful runtime startup and is superseded on that point by this actual failure.

### ONE minimal Foundation-only reproduction

Root explicitly authorized one <=60s value check; actual command in foundation-check/receipt.json. `/usr/bin/sandbox-exec` deny-network → `/usr/bin/swift -module-cache-path <ownTEMP>/module-cache <ownTEMP>/check.swift`; import Foundation ONLY, exact current plist SyntheticRoot and exact AppPaths URL transforms/predicates. No AppKit/app/database/model/network/CUA/host launch. Exit0, monotonic elapsed2.20716625s, stderr empty. Free before87620481024B/after87589769216B, no repeat. The modulecache remains only in task-owned TEMP; source/stdout/stderr/receipt copied durably here. receipt.startedUTC was generated after execution by the helper; it is not an exact process-start timestamp. The monotonic elapsed is the measured duration.

Actual JSON values:

- rootPath: `/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T/golos-memory-gate37-a19e1b2b2d6b4518abd9614c7f16130f/library`
- temporaryPath: `/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T`
- expectedPrefix: `/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T/golos-memory-gate37-`
- privateVarPrefix=true; dynamicTempPrefix=false; compoundPreconditionLine13=false; leafPreconditionLine14=true; temporaryPathHasSuffixSlash=false.

**Trailing slash hypothesis is rejected for this observed reproduction.** CLI environment may differ from LaunchServices; this single check does not inspect or simulate the app launch environment. Nevertheless it directly reproduces false predicate13 from the actual configured path, without app code execution. No matrix/random reruns were used.

## Narrow correction recommendation

Author should correct diagnostic host path validation ONLY. Canonicalize existing parent directories consistently using filesystem identity/realpath (including /var versus /private/var aliases), compare the owned temp parent/unique output directory by components/identity, then append/validate the as-yet-nonexistent leaf `library`. Preserve fail-closed owned-temp containment, required unique `golos-memory-gate37-*` directory, library leaf, symlink/outside rejection and no completed-library reuse. Do not weaken to arbitrary `/tmp` or broad string prefix and do not modify production paths/privacy/deadlines. A typed local setup failure/INCONCLUSIVE before database access is preferable to an unlogged fatal trap for configuration mismatch. No implementation provided here.

Before another host launch, a different author implements the narrow fix, records bounded path-value controls for accepted/rejected aliases/outside roots without app/full/OCR/matrix, rebuilds only as separately authorized, and returns new exactSHA/binary/config receipts for independent review. Root decides further actions; this finding does not authorize a new launch. Current55/37/5 UI gate remains unpassed.
