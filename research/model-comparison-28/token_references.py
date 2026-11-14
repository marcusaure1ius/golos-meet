"""Independent tokenizer-only fixtures. No Python model/session/inference."""
import argparse,json
from pathlib import Path
from tokenizers import Tokenizer
p=argparse.ArgumentParser();p.add_argument('--e5-folder',type=Path,required=True);p.add_argument('--minilm-folder',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
examples=[('query','Почему перенесли запуск?'),('passage','Решение: бюджет 200 000 рублей, срок — ноябрь.'),('query','Ёлка и ЙОГУРТ; API v2.0 👩🏽‍💻')]
corpus=json.loads(Path(__file__).with_name('corpus.json').read_text())
examples += [('passage',x['text']) for x in corpus['passages']] + [('query',x['text']) for x in corpus['queries']]
result={'reference_runtime':'Hugging Face tokenizers 0.23.3; tokenizer JSON only, no model inference','fixtures':{}}
for name,folder in [('e5-small',a.e5_folder),('minilm',a.minilm_folder)]:
    tokenizer=Tokenizer.from_file(str(folder/'tokenizer.json'));tokenizer.no_truncation();tokenizer.no_padding()
    result['fixtures'][name]=[{'text':text,'purpose':purpose,'ids':tokenizer.encode((purpose+': ' if name=='e5-small' else '')+text).ids} for purpose,text in examples]
a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
