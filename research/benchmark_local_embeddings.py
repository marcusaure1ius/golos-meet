"""Local E5 feasibility check; only public weights are downloaded.

Run in an isolated environment, for example:
  uv run --no-project --with numpy --with tokenizers --with onnxruntime \
    --with huggingface-hub python research/benchmark_local_embeddings.py \
    --cache-dir /tmp/golos-e5 --output /tmp/golos-e5-results.json

All questions/passages below are synthetic. This is a smoke test, not a
representative retrieval-quality benchmark for the user's project archive.
"""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import time

os.environ["HF_HUB_DISABLE_XET"] = "1"

MODEL = "intfloat/multilingual-e5-small"
REVISION = "fd1525a9fd15316a2d503bf26ab031a61d056e98"
PASSAGES = [
    "Запуск пилота перенесли с ноября на декабрь: команда не успевает завершить интеграционные испытания.",
    "Для оценки пилота сравниваем конверсию тестовой и контрольной групп. Группы должны быть сопоставимы.",
    "Бюджет на вычисления согласован: двести тысяч рублей в месяц. Превышение нужно согласовать отдельно.",
    "Пользователи жалуются на онбординг. Новый сценарий регистрации сократит число обязательных полей.",
    "После встречи Анна должна подготовить описание API и отправить его команде разработки до пятницы.",
    "Аудио встречи и расшифровка хранятся на компьютере. Облачная модель получает только разрешённые фрагменты.",
    "Во время переподключения запись не должна разбиваться на несколько встреч. События API могут дублироваться.",
    "Документы нужно распознавать локально: сканы через OCR, PDF по страницам, Word с сохранением абзацев.",
    "В кафе рядом с офисом изменилось меню. На обед сегодня овощной суп и салат.",
    "При выборе шрифта для интерфейса важно проверить читаемость русских букв в тёмной теме.",
]
QUESTIONS = [
    ("Почему изменили срок начала эксперимента?", 0),
    ("Как измеряется эффект внедрения?", 1),
    ("Какой лимит расходов на инфраструктуру?", 2),
    ("Что хотят упростить для новых пользователей?", 3),
    ("Кому поручили прислать техническую документацию?", 4),
    ("Какая информация отправляется за пределы устройства?", 5),
    ("Как избежать нескольких записей из-за обрыва соединения?", 6),
    ("Как обрабатывать файлы разных форматов?", 7),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--offline", action="store_true", help="Use cached weights without network access")
    args = parser.parse_args()
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    # Imports are deliberately inside main: reviewing this file needs no ML runtime.
    import numpy as np
    import onnxruntime as ort
    from huggingface_hub import hf_hub_download
    from tokenizers import Tokenizer

    start = time.perf_counter()
    files = {name: hf_hub_download(MODEL, name, revision=REVISION, cache_dir=args.cache_dir,
                                  local_files_only=args.offline)
             for name in ["onnx/model.onnx", "tokenizer.json"]}
    download_seconds = time.perf_counter() - start
    tokenizer = Tokenizer.from_file(files["tokenizer.json"])
    tokenizer.enable_truncation(max_length=512)
    tokenizer.enable_padding(pad_id=1, pad_token="<pad>")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    start = time.perf_counter()
    session = ort.InferenceSession(files["onnx/model.onnx"], options, providers=["CPUExecutionProvider"])
    load_seconds = time.perf_counter() - start
    input_names = {item.name for item in session.get_inputs()}

    def embed(texts, prefix):
        batch = tokenizer.encode_batch([prefix + text for text in texts])
        inputs = {
            "input_ids": np.asarray([e.ids for e in batch], dtype=np.int64),
            "attention_mask": np.asarray([e.attention_mask for e in batch], dtype=np.int64),
            "token_type_ids": np.asarray([e.type_ids for e in batch], dtype=np.int64),
        }
        output = session.run(None, {k: v for k, v in inputs.items() if k in input_names})[0]
        if output.ndim == 3:
            mask = inputs["attention_mask"][..., None]
            output = (output * mask).sum(axis=1) / mask.sum(axis=1)
        return output / np.linalg.norm(output, axis=1, keepdims=True)

    start = time.perf_counter()
    passages = embed(PASSAGES, "passage: ")
    index_seconds = time.perf_counter() - start
    latencies = []
    top1 = top5 = 0
    for question, expected in QUESTIONS:
        start = time.perf_counter()
        query = embed([question], "query: ")[0]
        ranking = np.argsort(-(passages @ query)).tolist()
        latencies.append(time.perf_counter() - start)
        top1 += ranking[0] == expected
        top5 += expected in ranking[:5]
    report = {
        "model": MODEL, "revision": REVISION, "runtime": "onnxruntime CPU, 4 threads",
        "platform": platform.platform(), "machine": platform.machine(),
        "packages": {p: importlib.metadata.version(p) for p in ["numpy", "onnxruntime", "tokenizers", "huggingface-hub"]},
        "dimensions": int(passages.shape[1]),
        "public_weights_bytes": sum(Path(p).stat().st_size for p in files.values()),
        "download_or_cache_seconds": download_seconds, "session_load_seconds": load_seconds,
        "index_passages": len(PASSAGES), "index_seconds": index_seconds,
        "query_median_ms": statistics.median(latencies) * 1000,
        "query_max_ms": max(latencies) * 1000,
        "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024),
        "synthetic_questions": len(QUESTIONS), "top1_hits": top1, "top5_hits": top5,
        "scope": "Synthetic feasibility smoke test; no production quality claim; no user data transmitted.",
        "offline": args.offline,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
