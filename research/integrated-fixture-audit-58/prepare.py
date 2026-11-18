#!/usr/bin/env python3
"""Read-only provenance/criteria preparation. No build, model load or network."""
from pathlib import Path
import hashlib,json,subprocess,datetime
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
base='e9990685bdcf334039cbce7edbfb245750b0154a';tree='4284d8f240fd40d2abdd2efbd4968973a0d12df0'
prs=[
 (59,'2a5907a79c21f8ad8e394961fa68b9275609c1a3','9dfdf8feecf83e94782c0e78acfdd0b2d920a37e',['memory-update','index-hooks','assignment-runtime','native-index-queue'],['ProjectMemoryUpdateTests','ProjectMemoryQueueTests','IndexingProductionHooksTests','MeetingAssignmentRuntimeTests','LocalIndexingNativeTests'],'fixture-lifecycle-58'),
 (60,'ceeb98b5dd1c39dc774c810c82e834ae38fdfc72','fc2a92956fd50bd791e4926d5b388c8fe39f84d4',['question-service','memory-history'],['KnowledgeQuestionServiceTests','ProjectMemoryHistoryTests'],'question-history-fixtures-58'),
 (62,'c9831bc4e15aecd42f95f11454e1b19f34a9ae63','7be254c4a1eceb28755ad60d718a4ed72cb21179',['assignment-fixture'],['MeetingAssignmentTests'],'assignment-fixtures-58'),
 (64,'3561d0cbd81a9a48284274d746b5e1541128d53d','ec77fea89c480eb1d0db7a5cbc2a1ff452d5bc46',['questions-ui'],['KnowledgeQuestionModelTests'],'question-ui-fixtures-58'),
 (65,'dcdbf7aca8c98c637c6e1650141d258df55e9210',base,['knowledge-search','index-service'],['KnowledgeSearchTests','LocalIndexingServiceTests'],'search-index-fixtures-58')]
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
assert git('rev-parse',base+'^{tree}')==tree
accepted=[]
for n,sha,merge,roots,suites,folder in prs:
 subprocess.run(['git','merge-base','--is-ancestor',sha,base],check=True)
 subprocess.run(['git','merge-base','--is-ancestor',merge,base],check=True)
 report=f'research/{folder}/README.md';assert Path(report).is_file()
 accepted.append(dict(pr=n,checked_sha=sha,merge_sha=merge,roots=roots,suites=suites,report=report,url=f'https://github.com/marcusaure1ius/golos-meet/pull/{n}'))
checked63='9134715492c4f02664d5160ed4576e84173bfeab';subprocess.run(['git','merge-base','--is-ancestor',checked63,base],check=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
source={p:sha(Path(p).read_bytes()) for p in git('ls-files','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile').splitlines() if Path(p).is_file()}
proof=dict(base=base,expected_combined_tree=tree,actual_base_tree=git('rev-parse',base+'^{tree}'),head=git('rev-parse','HEAD'),branch=git('branch','--show-current'),checked63=checked63,components=accepted,root_prefixes=10,suite_count=11,source_sha256=source,utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
(r/'accepted-provenance.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
criteria=[
 dict(id=1,criterion='Реальная причина unlink сопоставлена с fixture/resource path без приписывания OCR',status='supported for observed families',proof_prs=[59,60,62,64,65],limits='Не universal lifetime proof всех объектов/будущих interleavings'),
 dict(id=2,criterion='Before/control/after live handles/task drain; отсутствие6922/rollback при фактической очистке',status='component evidence accepted; combined outcome pending',proof_prs=[59,60,62,64,65],limits='Сохранять intended native faults и negative controls; runtimeWarnings0 не означает stderr0'),
 dict(id=3,criterion='Предсказуемый unlink после освобождения resources, без retain-all-roots/hangs masking',status='supported for registered roots; combined audit pending',proof_prs=[59,60,62,64,65],limits='Child body cancel не parent scope/process death;8s начинается после cleanup requests'),
 dict(id=4,criterion='make check и native/fixture controls пройдены; raw failures/stdout сохранены',status='NOT yet satisfied for accepted combined tree',proof_prs=[63,65],limits='Предыдущий453/649fullFailed на#61 относится к65/baseec77fea, не accepted63+65; interrupted отдельно'),
 dict(id=5,criterion='Отдельные PR вpreview, независимый exact review, merge root',status='components accepted; new audit PR/review pending',proof_prs=[59,60,62,64,65],limits='Эта author matrix не independent verdict; новый artifact SHA требует своего review')]
(r/'criteria-mapping.json').write_text(json.dumps(criteria,ensure_ascii=False,indent=2)+'\n')
print('Prepared accepted ancestry/tree/source receipts,10prefixes/11suites and5criteria; no tests/models executed')
