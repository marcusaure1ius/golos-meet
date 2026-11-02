// Appended to the exact Foundation-only DiagnosticGatePaths.swift, ONE process.
let fm = FileManager.default
let controlsRoot = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let temporary = URL(fileURLWithPath:NSTemporaryDirectory(),isDirectory:true)
func alias(_ path:String, privateVar:Bool) -> String {
    if privateVar, path.hasPrefix("/var/") { return "/private" + path }
    if !privateVar, path.hasPrefix("/private/var/") { return String(path.dropFirst(8)) }
    return path
}
func freshOutput() throws -> URL {
    let url = temporary.appendingPathComponent("golos-memory-gate37-"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),isDirectory:true)
    try fm.createDirectory(at:url,withIntermediateDirectories:false)
    return url
}
struct PathControl: Codable {
    let name, expected, actual: String
    let passed: Bool
    let configuredPath: String?
    let temporaryPath: String
    let resolution: DiagnosticPathResolution?
    let detail: String?
}
var controls: [PathControl] = []
func check(_ name:String, raw:String?, temp:String, expected:String) {
    do {
        let resolution = try DiagnosticGatePaths.validate(configuredPath:raw,temporaryPath:temp)
        controls.append(.init(name:name,expected:expected,actual:"accepted",passed:expected == "accepted",configuredPath:raw,temporaryPath:temp,resolution:resolution,detail:nil))
    } catch {
        let actual = (error as? DiagnosticPathFault)?.code ?? "untyped-error"
        controls.append(.init(name:name,expected:expected,actual:actual,passed:actual == expected,configuredPath:raw,temporaryPath:temp,resolution:nil,detail:String(describing:error)))
    }
}
let good = try freshOutput(), raw = good.appendingPathComponent("library").path
check("native aliases",raw:raw,temp:temporary.path,expected:"accepted")
check("private root with var temp",raw:alias(raw,privateVar:true),temp:alias(temporary.path,privateVar:false),expected:"accepted")
check("var root with private temp",raw:alias(raw,privateVar:false),temp:alias(temporary.path,privateVar:true),expected:"accepted")
check("missing config",raw:nil,temp:temporary.path,expected:"invalidConfiguration")
check("wrong leaf",raw:good.appendingPathComponent("other").path,temp:temporary.path,expected:"invalidLeaf")
check("wrong name prefix",raw:temporary.appendingPathComponent("foreign-output/library").path,temp:temporary.path,expected:"invalidOutputName")
check("prefix suffix attack",raw:good.path+"extra/library",temp:temporary.path,expected:"invalidOutputName")
check("outside current temp",raw:controlsRoot.appendingPathComponent("golos-memory-gate37-"+String(repeating:"a",count:32)+"/library").path,temp:temporary.path,expected:"outsideTemporary")
check("nested output",raw:good.appendingPathComponent("nested/library").path,temp:temporary.path,expected:"outsideTemporary")
check("dot traversal",raw:good.path+"/../other/library",temp:temporary.path,expected:"invalidConfiguration")
check("broad tmp forbidden",raw:raw,temp:"/private/tmp",expected:"invalidTemporary")
let absent = temporary.appendingPathComponent("golos-memory-gate37-"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()+"/library")
check("missing output directory",raw:absent.path,temp:temporary.path,expected:"missingDirectory")
let reused = try freshOutput();try fm.createDirectory(at:reused.appendingPathComponent("library"),withIntermediateDirectories:false)
check("existing library",raw:reused.appendingPathComponent("library").path,temp:temporary.path,expected:"reusedLibrary")
let linkRoot = temporary.appendingPathComponent("golos-memory-gate37-"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
try fm.createSymbolicLink(at:linkRoot,withDestinationURL:good)
check("output symlink",raw:linkRoot.appendingPathComponent("library").path,temp:temporary.path,expected:"symlink")
let leafLink = try freshOutput()
try fm.createSymbolicLink(at:leafLink.appendingPathComponent("library"),withDestinationURL:controlsRoot.appendingPathComponent("missing-target"))
check("dangling library symlink",raw:leafLink.appendingPathComponent("library").path,temp:temporary.path,expected:"symlink")
let foreignLink = temporary.appendingPathComponent("golos-memory-gate37-"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
try fm.createSymbolicLink(at:foreignLink,withDestinationURL:controlsRoot)
check("output symlink outside temp direct child",raw:foreignLink.appendingPathComponent("library").path,temp:temporary.path,expected:"symlink")
let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
let encoded = try encoder.encode(controls)
try encoded.write(to:controlsRoot.appendingPathComponent("control-results.json"),options:.withoutOverwriting)
print(String(decoding:encoded,as:UTF8.self))
let positives = controls.compactMap(\.resolution)
let identitiesMatch = positives.count == 3 && positives.allSatisfy { $0.temporaryIdentity == positives[0].temporaryIdentity && $0.outputIdentity == positives[0].outputIdentity && $0.library == positives[0].library }
print("Foundation-only controls: \(controls.count); allPassed=\(controls.allSatisfy(\.passed)); aliasIdentitiesMatch=\(identitiesMatch). Not a LaunchServices environment capture.")
exit(controls.allSatisfy(\.passed) && identitiesMatch ? 0 : 1)
