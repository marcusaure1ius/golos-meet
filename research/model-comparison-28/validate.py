"""Independent arithmetic validation of native rankings/vectors and latency stats."""
import argparse,hashlib,json,math,statistics
from pathlib import Path
RESEARCH=Path(__file__).resolve().parent

def retrieval_metrics(rankings, queries):
    assert set(rankings)=={q['id'] for q in queries}
    top1=0;recall=[]
    for query in queries:
        ids=rankings[query['id']]; relevant=set(query['relevant_ids'])
        assert relevant and len(relevant)==len(query['relevant_ids'])
        assert ids and len(ids)==len(set(ids))
        top1+=int(ids[0] in relevant)
        recall.append(len(set(ids[:5]) & relevant)/len(relevant))
    return top1/len(queries),statistics.mean(recall)

def validate(directory):
    corpus=json.loads((RESEARCH/'corpus.json').read_text())
    corpus_hash=hashlib.sha256((RESEARCH/'corpus.json').read_bytes()).hexdigest()
    assert corpus_hash=='1e1173bfa57d645539117f3752ba54b00c82670980c88b5026a42aa764eeb5a0'
    ids=[p['id'] for p in corpus['passages']];assert len(ids)==len(set(ids))==48
    assert len(corpus['queries'])==20
    for q in corpus['queries']:assert set(q['relevant_ids']).issubset(ids) and len(q['relevant_ids']) in {2,4}
    summary={}
    for model in ['e5-small','minilm']:
        reports=[]
        for repetition in range(3):
            report=json.loads((directory/f'{model}-{repetition}.json').read_text())
            assert report['corpus_sha256']==corpus_hash and report['threads_intra_op']==2
            assert len(report['query_ms'])==200 and all(x>0 for x in report['query_ms'])
            assert report['tokenizer_parity_checked'] and report['mask_pooling_l2_self_test']
            assert abs(statistics.median(report['query_ms'])-report['query_median_ms'])<1e-9
            assert abs(sorted(report['query_ms'])[189]-report['query_p95_ms'])<1e-9
            rankings={q['query_id']:[r['id'] for r in q['ranking']] for q in report['queries']}
            assert all(set(r)==set(ids) for r in rankings.values())
            top1,recall=retrieval_metrics(rankings,corpus['queries'])
            assert abs(top1-report['top1'])<1e-12 and abs(recall-report['recall_at_5_macro'])<1e-12
            for query in report['queries']:
                relevant=next(q['relevant_ids'] for q in corpus['queries'] if q['id']==query['query_id'])
                assert query['hits_at_5']==len(set(rankings[query['query_id']][:5]) & set(relevant))
                assert query['relevant_count']==len(relevant)
            # Recompute every cosine and ranking independently from the first run's full vectors.
            if repetition==0:
                vectors=json.loads((directory/f'{model}-0-vectors.json').read_text())
                assert vectors['passage_ids']==ids and vectors['query_ids']==[q['id'] for q in corpus['queries']]
                assert vectors['corpus_sha256']==corpus_hash
                for vector in vectors['passage_vectors']+vectors['query_vectors']:
                    assert len(vector)==384 and all(math.isfinite(x) for x in vector)
                    assert abs(sum(x*x for x in vector)-1)<2e-6
                for index,query in enumerate(report['queries']):
                    q=vectors['query_vectors'][index]
                    scores={pid:sum(x*y for x,y in zip(q,v)) for pid,v in zip(ids,vectors['passage_vectors'])}
                    assert rankings[query['query_id']]==sorted(ids,key=lambda pid:(-scores[pid],pid))
                    for row in query['ranking']:assert abs(scores[row['id']]-row['cosine'])<2e-6
            reports.append(report)
        fields=['initialization_seconds','first_query_ms','query_median_ms','query_p95_ms','index_passages_per_second','index_tokens_per_second','peak_process_rss_bytes','required_model_bytes','top1','recall_at_5_macro']
        summary[model]={field:{'median':statistics.median(r[field] for r in reports),'min':min(r[field] for r in reports),'max':max(r[field] for r in reports)} for field in fields}
    return {'corpus_sha256':corpus_hash,'passages':48,'queries':20,'processes_per_model':3,'validation':'All rankings/denominators/stats checked; all first-run cosine scores independently recomputed from native vectors','summary':summary}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--results',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    result=validate(a.results);a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False,indent=2))
