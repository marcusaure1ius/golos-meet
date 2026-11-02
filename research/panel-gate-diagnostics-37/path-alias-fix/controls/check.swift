import Foundation

// Shared verbatim by the diagnostic executable and the Foundation-only controls.
nonisolated struct DiagnosticPathFault: Error, CustomStringConvertible, Sendable {
    let code, detail: String
    var description: String { "\(code): \(detail)" }
}
nonisolated struct DiagnosticDirectoryIdentity: Codable, Equatable, Sendable {
    let device, inode, owner: UInt64
}
nonisolated struct DiagnosticPathResolution: Codable, Sendable {
    let library: URL
    let configuredPath, temporaryPath, canonicalTemporary, canonicalOutput: String
    let temporaryIdentity, outputIdentity: DiagnosticDirectoryIdentity
}
nonisolated enum DiagnosticGatePaths {
    private static func fault(_ code: String, _ detail: String) -> DiagnosticPathFault {
        DiagnosticPathFault(code:code,detail:detail)
    }
    private static func components(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator:"/").contains(where:{ $0 == "." || $0 == ".." }) else {
            throw fault("invalidConfiguration","absolute path without dot traversal required")
        }
        return ["/"] + path.split(separator:"/").map(String.init)
    }
    // Only the OS /var <-> /private/var alias is accepted, not arbitrary symlinks.
    private static func varAlias(_ parts: [String]) -> [String] {
        if Array(parts.prefix(4)) == ["/","private","var","folders"] {
            return ["/"] + Array(parts.dropFirst(2))
        }
        return parts
    }
    private static func directory(_ url: URL) throws -> DiagnosticDirectoryIdentity {
        let attributes: [FileAttributeKey:Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath:url.path) }
        catch { throw fault("missingDirectory","\(url.path): \(error)") }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw fault("symlink","\(url.path)") }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw fault("notDirectory","\(url.path)") }
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber else { throw fault("identityUnavailable",url.path) }
        return .init(device:device.uint64Value,inode:inode.uint64Value,owner:owner.uint64Value)
    }
    private static func requireAbsent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw fault("symlink",url.path) }
            throw fault("reusedLibrary",url.path)
        } catch let error as DiagnosticPathFault { throw error }
        catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain,
                  [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) else { throw fault("absenceCheck",error.description) }
        }
    }
    static func validate(configuredPath: String?, temporaryPath: String) throws -> DiagnosticPathResolution {
        guard let configuredPath else { throw fault("invalidConfiguration","SyntheticRoot missing or not a string") }
        let raw = try components(configuredPath), temporary = try components(temporaryPath)
        let normalizedTemporary = varAlias(temporary)
        guard Array(normalizedTemporary.prefix(3)) == ["/","var","folders"], normalizedTemporary.last == "T" else {
            throw fault("invalidTemporary","current per-user /var/folders/.../T required")
        }
        guard raw.last == "library" else { throw fault("invalidLeaf","library leaf required") }
        let outputParts = Array(raw.dropLast())
        guard varAlias(Array(outputParts.dropLast())) == normalizedTemporary else { throw fault("outsideTemporary","different temp parent") }
        let name = outputParts.last ?? "", prefix = "golos-memory-gate37-"
        let suffix = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : ""
        guard suffix.count == 32, suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw fault("invalidOutputName","unique diagnostic UUID directory required")
        }
        let tempURL = URL(fileURLWithPath:temporaryPath,isDirectory:true)
        // Inspect every existing component BELOW the OS alias, rejecting custom links.
        var checked = URL(fileURLWithPath:"/var/folders",isDirectory:true)
        for part in normalizedTemporary.dropFirst(3) { checked.appendPathComponent(part,isDirectory:true); _ = try directory(checked) }
        let tempIdentity = try directory(tempURL)
        let rawOutput = URL(fileURLWithPath:(configuredPath as NSString).deletingLastPathComponent,isDirectory:true)
        let parentIdentity = try directory(rawOutput.deletingLastPathComponent())
        guard parentIdentity == tempIdentity else { throw fault("outsideTemporary","temp device/inode/owner mismatch") }
        let outputIdentity = try directory(rawOutput)
        guard outputIdentity.owner == tempIdentity.owner else { throw fault("ownerMismatch",rawOutput.path) }
        let canonicalTemp = tempURL.resolvingSymlinksInPath()
        let canonicalOutput = rawOutput.resolvingSymlinksInPath()
        guard try directory(canonicalTemp) == tempIdentity,
              try directory(canonicalOutput) == outputIdentity,
              try directory(canonicalOutput.deletingLastPathComponent()) == tempIdentity else { throw fault("identityChanged","existing parent changed during validation") }
        let library = canonicalOutput.appendingPathComponent("library",isDirectory:true)
        try requireAbsent(URL(fileURLWithPath:configuredPath,isDirectory:true))
        try requireAbsent(library)
        return .init(library:library,configuredPath:configuredPath,temporaryPath:temporaryPath,
                     canonicalTemporary:canonicalTemp.path,canonicalOutput:canonicalOutput.path,
                     temporaryIdentity:tempIdentity,outputIdentity:outputIdentity)
    }
}

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
