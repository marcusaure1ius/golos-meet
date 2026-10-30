"""Download only pinned public files into /tmp. No ML libraries or inference."""
import argparse,hashlib,json,urllib.request
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--model',choices=['e5-small','minilm'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
folder=a.output.resolve()
assert folder.is_relative_to(Path('/private/tmp').resolve()),'Research weights must stay in /tmp on macOS'
model=next(m for m in json.loads(Path(__file__).with_name('models.json').read_text())['models'] if m['id']==a.model)
folder.mkdir(parents=True,exist_ok=True)
def digest(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        while block:=stream.read(1024*1024):h.update(block)
    return h.hexdigest()
for asset in model['files']:
    file=folder/asset['path'];file.parent.mkdir(parents=True,exist_ok=True)
    if file.exists():
        assert file.is_file() and not file.is_symlink() and file.stat().st_size==asset['bytes'] and digest(file)==asset['sha256'],f'Existing file differs; choose a fresh folder: {file}'
    else:
        url=f"https://huggingface.co/{model['repository']}/resolve/{model['revision']}/{asset['path']}?download=true"
        temporary=file.with_suffix(file.suffix+'.partial')
        request=urllib.request.Request(url,headers={'User-Agent':'GolosMeet-Research-28'})
        with urllib.request.urlopen(request,timeout=180) as response,temporary.open('xb') as output:
            while block:=response.read(1024*1024):output.write(block)
        assert temporary.stat().st_size==asset['bytes'] and digest(temporary)==asset['sha256'],asset['path']
        temporary.replace(file)
    print(asset['path'],asset['bytes'],asset['sha256'],flush=True)
