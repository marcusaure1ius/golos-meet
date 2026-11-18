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
 let root=URL(fileURLWithPath:"/tmp/review54-"+UUID().uuidString),adapter=Adapter54()
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
@main @MainActor struct Ancestor54 {
 static func main()async throws {
  let f=try Fixture54(),p=try await f.project("Dependency")
  try await f.meeting("a-parent",1,[p]);try await f.meeting("b-dependent",1,[p]);try await f.ready()
  let search=KnowledgeSearchService(store:f.store,meetingsRoot:f.root.appendingPathComponent("meetings"),documentsRoot:f.root.appendingPathComponent("copies"),queryEmbedding:{_ in throw LocalIndexingError.missingModel})
  let hp=try await search.search("релиз",scope:.project(p)).hits.first{$0.source.key.externalID=="a-parent"}!
  let history=ProjectMemoryHistoryService(store:f.store,meetingsRoot:f.root.appendingPathComponent("meetings"),documentsRoot:f.root.appendingPathComponent("copies"))
  let l=try await history.begin(projectID:p,producerKey:"seed-parent",hits:[hp])
  let original=try await history.publish([.init(statement:.init(subject:"plan",kind:.agreement,conditions:[:],text:"PARENT_OLD"),evidenceChunkIDs:[hp.id])],lease:l).eventIDs[0]
  let worker=f.worker();await worker.changed()
  let parentJob=try await f.job("a-parent");try await f.store.cancelMemoryQueue(parentJob.sequence)
  await worker.start();await worker.waitUntilIdle()
  let before=try await f.job("b-dependent")
  require54(before.completeCoverage && f.adapter.calls==1)
  let dependent=try await history.history(projectID:p).entries.first{$0.event.parentEventIDs.contains(original)}!.event
  require54(dependent.sources.count==2)
  try await f.meeting("c-replacement",1,[p]);try await f.ready()
  f.adapter.hook={_ in
   f.adapter.forcedReply=nil
   let payload=f.adapter.payloads.last!
   if payload.contains("c-replacement_MARKER") {
    let object=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any],ms=object["memories"] as! [[String:Any]],ss=object["fragments"] as! [[String:Any]]
    let target=ms.first{($0["statement"] as! [String:Any])["subject"] as? String=="plan"}!["label"] as! String
    let fact:[String:Any]=["subject":"plan","kind":"agreement","conditions":[:],"text":"PARENT_NEW","action":"assertion","deadline":NSNull(),"decisionDate":NSNull(),"evidence":[["source":"S1","quote":ss[0]["text"] as! String]],"links":[["target":target,"kind":"replaces"]]]
    f.adapter.forcedReply=String(decoding:try JSONSerialization.data(withJSONObject:["insufficientEvidence":false,"facts":[fact]]),as:UTF8.self)
   }
  }
  await worker.changed();await worker.waitUntilIdle()
  let after=try await f.job("b-dependent")
  let db=try f.db();let superseded=try db.rows("SELECT event_id FROM memory_links WHERE target_id=? AND kind='replaces'",bindings:[original.uuidString])
  require54(superseded.count==1)
  require54(before.cycle != after.cycle && after.completeCoverage && f.adapter.calls==3)
  require54(before.input==after.input)
  let historyCount=try db.rows("SELECT COUNT(*) FROM memory_events")[0][0]
  let ownBefore=try await f.job("c-replacement")
  for _ in 0..<3 {await worker.changed();await worker.waitUntilIdle()}
  let ownAfter=try await f.job("c-replacement");require54(f.adapter.calls==3 && ownAfter.cycle==ownBefore.cycle)
  await worker.stop();await worker.waitUntilIdle()
  let restarted=f.worker();await restarted.start();await restarted.waitUntilIdle()
  let afterRestart=try await f.job("b-dependent");require54(f.adapter.calls==3 && afterRestart.cycle==after.cycle)
  require54(try db.rows("SELECT COUNT(*) FROM memory_events")[0][0]==historyCount)
  require54(try db.rows("SELECT COUNT(*) FROM memory_queue_batches WHERE cycle=?",bindings:[before.cycle])==[["1"]])
  await restarted.stop()
  let service=ProjectMemoryUpdateService(store:f.store,meetingsRoot:f.root.appendingPathComponent("meetings"),documentsRoot:f.root.appendingPathComponent("copies"),client:f.adapter,model:"fake54")
  let hd=try await search.search("релиз",scope:.project(p)).hits.first{$0.source.key.externalID=="b-dependent"}!
  do{_=try await service.prepare(projectID:p,hits:[hd],parentEventIDs:[dependent.id]);fatalError("Expected stale derivedroot")}
  catch MemoryUpdateError.stale {}
  note54("FIXED actual reviewer scenario: a-parent replaced by c-replacement; dependent newcycle/recomputed complete; own replacer stays samecycle; history+old batch preserved; repeat events/restart quiet; old derivedevent still rejected as stale; calls",f.adapter.calls,"oldcycle",before.cycle,"aftercycle",after.cycle,"ROOT",f.root.path)
  await worker.stop()
 }
}
