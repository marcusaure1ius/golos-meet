import Foundation
import Combine
func require54(_ condition:Bool){precondition(condition)}
func note54(_ values:Any...){FileHandle.standardOutput.write(Data((values.map{String(describing:$0)}.joined(separator:" ")+"\n").utf8))}
actor Gate54 {
 var opened=false;var waiters:[CheckedContinuation<Void,Never>]=[]
 func wait()async{if !opened{await withCheckedContinuation{waiters.append($0)}}}
 func release(){opened=true;waiters.forEach{$0.resume()};waiters=[]}
}
nonisolated final class BeginCounter54:@unchecked Sendable {
 let lock=NSLock();var count=0
 func bump(){lock.lock();count+=1;lock.unlock()}
 func read()->Int{lock.lock();defer{lock.unlock()};return count}
}
@MainActor final class Adapter54:ChatCompleter {
 var calls=0,physical=0,maxPhysical=0;var counts:[Int]=[],models:[String]=[],payloads:[String]=[]
 var forcedReply:String?=nil;var insufficient=false;var hook:((Int)async throws->Void)?
 nonisolated func complete(model:String,messages:[ChatMessage],responseFormat:ResponseFormat?)async throws->String{try await send(model,messages)}
 func send(_ model:String,_ messages:[ChatMessage])async throws->String {
  physical+=1;maxPhysical=max(maxPhysical,physical);defer{physical-=1}
  calls+=1;models.append(model);let payload=messages.last!.content;payloads.append(payload)
  let object=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any],fragments=object["fragments"] as! [[String:Any]];counts.append(fragments.count)
  let facts:[[String:Any]]=try fragments.map{let text=$0["text"] as! String,label=$0["label"] as! String;return ["subject":"fact:"+MemoryEncoding.hash(text),"kind":"agreement","conditions":[:],"text":text,"action":"assertion","deadline":NSNull(),"decisionDate":NSNull(),"evidence":[["source":label,"quote":String(text.prefix(1000))]],"links":[]]}
  let result=String(decoding:try JSONSerialization.data(withJSONObject:["insufficientEvidence":insufficient,"facts":insufficient ? []:facts]),as:UTF8.self)
  try await hook?(calls) // deliberately noncooperative gates ignore Task cancellation
  return forcedReply ?? result
 }
}
@MainActor final class Fixture54 {
 let root=URL(fileURLWithPath:"/tmp/review61-bridge/source-"+UUID().uuidString),adapter=Adapter54()
 let store:ProjectStore;let model=EmbeddingIndexModel(id:"synthetic-review54",dimensions:2)
 init()throws{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);store=ProjectStore(url:root.appendingPathComponent("knowledge.sqlite"))}
 func project(_ name:String,_ policy:ProjectCloudPolicy = .allowSelectedContext)async throws->UUID{let p=try await store.createProject(name:name);try await store.setCloudPolicy(policy,for:p.id);return p.id}
 func meeting(_ id:String,_ count:Int,_ owners:Set<UUID>,quoted:Bool=false)async throws{
  let folder=root.appendingPathComponent("meetings/"+id);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let segments=(0..<count).map{["start":Double($0*20),"end":Double($0*20+10),"text":"релиз \(id)_MARKER_\($0)"+(quoted ? String(repeating:"\"",count:1000):"")] as [String:Any]}
  try JSONSerialization.data(withJSONObject:["meetingId":id,"segments":segments]).write(to:folder.appendingPathComponent("transcript.json"))
  _=try await MeetingEmbeddingSnapshotReader(root:root.appendingPathComponent("meetings")).synchronize(meetingID:id,store:store)
  try await store.assignMeeting(id,to:owners)
 }
 func ready()async throws{
  if try await store.knowledgeSearchModel().model != model{try await store.activateEmbeddingModel(model)}
  while let l=try await store.claimEmbeddingJob(){let v=try l.snapshot.chunks.map{IndexedChunkVectors(chunkID:$0.id,bodyTokenCount:1,windows:[.init(tokenStart:0,tokenCount:1,vector:try KnowledgeVector(modelID:model.id,values:[1,0]))])};require54(try await store.publishEmbeddingVectors(v,lease:l))}
 }
 func worker(_ model:String="fake54")->ProjectMemoryQueueWorker{.init(store:store,meetingsRoot:root.appendingPathComponent("meetings"),documentsRoot:root.appendingPathComponent("copies"),client:adapter,model:model)}
 func job(_ id:String)async throws->MemoryQueueJob{try await store.memoryQueueSnapshot().jobs.first{$0.source.externalID==id}!}
 func db()throws->ProjectDatabase{try ProjectDatabase(url:root.appendingPathComponent("knowledge.sqlite"))}
 func until(_ check:()async throws->Bool)async throws{for _ in 0..<1600{if try await check(){return};try await Task.sleep(for:.milliseconds(5))};fatalError("fixture wait timeout")}
}
