import Foundation
import Combine
nonisolated enum Trace61 {
 static let lock=NSLock(); nonisolated(unsafe) static var events:[[String:Any]]=[];static let epoch=ProcessInfo.processInfo.systemUptime
 static func mark(_ stage:String,_ detail:String=""){lock.lock();events.append(["stage":stage,"detail":detail,"ms":(ProcessInfo.processInfo.systemUptime-epoch)*1000]);lock.unlock()}
 static func dump()->[[String:Any]]{lock.lock();defer{lock.unlock()};return events}
}
@MainActor enum Hooks61 {
 static var gate:Gate54?;static var entered=false;static var acked=false
 static func pauseStartup()async {if let gate{entered=true;Trace61.mark("startup.gate.enter");await gate.wait();Trace61.mark("startup.gate.return")}}
}
@main @MainActor struct Driver61 {
 static var results:[[String:Any]]=[]
 static func wait(_ label:String,_ seconds:Double=5,_ condition:()async throws->Bool)async throws{
  let end=ProcessInfo.processInfo.systemUptime+seconds;Trace61.mark(label+".begin")
  while try await !condition(){if ProcessInfo.processInfo.systemUptime>end{Trace61.mark(label+".timeout");throw NSError(domain:"review61."+label,code:1)};try await Task.sleep(for:.milliseconds(5))}
  Trace61.mark(label+".end")
 }
 static func durable(_ f:Fixture54)async throws->[[String:String]]{try await f.store.memoryQueueSnapshot().jobs.map{["source":$0.source.externalID,"state":$0.state.rawValue,"cursor":String($0.completedChunks),"total":String($0.totalChunks),"complete":String($0.completeCoverage)]}}
 static func one(_ name:String)async throws {
  Trace61.mark("case.begin",name);Hooks61.gate=nil;Hooks61.entered=false;Hooks61.acked=false
  let f=try Fixture54(),p=try await f.project("review61-"+name),w=f.worker(),center=NotificationCenter()
  var bridge:KnowledgeMemoryQueue?=KnowledgeMemoryQueue(worker:w,center:center,model:"fake54");weak var weakBridge=bridge
  let gate=Gate54();if name=="startup-gate"{Hooks61.gate=gate}
  f.adapter.hook={i in Trace61.mark("physical.call",String(i))}
  bridge!.start();try await wait("revision"){w.snapshot().revision>0}
  let revisionState=w.diagnostic61()
  if name=="startup-gate"{try await wait("startup.paused"){Hooks61.entered};precondition(!Hooks61.acked)}
  else{try await wait("startup.acked"){Hooks61.acked}}
  var releaseObserved=false
  if name=="owner-release"{bridge=nil;try await wait("owner.released"){weakBridge==nil};releaseObserved=true;try await wait("worker.stopped"){(w.diagnostic61()["started"] as? Bool)==false}}
  try await f.meeting("late",1,[p]);try await f.ready();Trace61.mark("input.ready")
  KnowledgeIndexEvents.post(.meeting("late"),center:center);Trace61.mark("event.posted")
  var gateState:[String:Any]=[:]
  if name=="startup-gate"{try await Task.sleep(for:.milliseconds(500));gateState=w.diagnostic61();gateState["calls"]=f.adapter.calls;gateState["durable"]=try await durable(f);precondition(!Hooks61.acked);await gate.release();Hooks61.gate=nil}
  if name=="owner-release"{
   try await Task.sleep(for:.milliseconds(500));precondition(f.adapter.calls==0);let unownedJobs=try await f.store.memoryQueueSnapshot();precondition(unownedJobs.jobs.first{$0.source.externalID=="late"}?.completeCoverage != true)
   gateState=w.diagnostic61();gateState["durable"]=try await durable(f);Trace61.mark("recovery.direct.start");await w.start()
  }
  try await wait("coverage"){try await f.store.memoryQueueSnapshot().jobs.first{$0.source.externalID=="late"}?.completeCoverage==true}
  precondition(f.adapter.calls==1 && f.adapter.maxPhysical==1)
  let final=try await durable(f);results.append(["name":name,"calls":f.adapter.calls,"maxPhysical":f.adapter.maxPhysical,"revisionState":revisionState,"controlState":gateState,"finalDurable":final,"bridgeAliveBeforeExplicitStop":weakBridge != nil,"releaseObserved":releaseObserved])
  bridge?.stop();await w.stop();await w.waitUntilIdle();bridge=nil;f.adapter.hook=nil
  Trace61.mark("case.joined",name)
 }
 static func main()async {
  var failure:String?;await ProjectDatabase.$lifecycleObserver.withValue({event in Trace61.mark("sqlite.lifecycle",String(describing:event))}) { do {for name in ["baseline","startup-gate","owner-release"]{try await one(name)}}catch{failure=String(describing:error);Trace61.mark("driver.failure",failure!)} }
  let data:[String:Any]=["source":"fc2a92956fd50bd791e4926d5b388c8fe39f84d4","results":results,"events":Trace61.dump(),"failure":failure as Any? ?? NSNull()]
  do{try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:"/tmp/review61-bridge/result.json"),options:.atomic)}catch{print("TRACE_WRITE_ERROR",error)}
  print("CASES",results.count,"FAILURE",failure ?? "none")
 }
}
