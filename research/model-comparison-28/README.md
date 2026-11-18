# Нативное сравнение мультиязычных моделей (#28, часть #13)

На фиксированном русском synthetic наборе E5-small нашла релевантный первый
фрагмент в 17 из 20 вопросов, MiniLM — в 14. Macro recall@5 составил 100% и
83,75%. Это проверка двух конкретных комплектов в одном research harness,
а не оценка рабочего архива. Пользовательская модель приложения остаётся E5-small.

## Результаты

Apple M4 Pro (Mac16,7), 24 GiB RAM, macOS 27.0.1. Три отдельных последовательных
процесса на модель, CPU intra-op=2, batch=1, idle spinning выключен. Все шесть
процессов использовали **один бинарник** и профиль `deny network*`.
В ячейках — медиана трёх process-level значений; в скобках min–max.

| Метрика | E5-small | paraphrase-multilingual-MiniLM-L12-v2 |
|---|---:|---:|
| Top1 | 17/20, 85% во всех процессах | 14/20, 70% во всех процессах |
| Macro recall@5 | 100% во всех процессах | 83,75% во всех процессах |
| Init: local tokenizer + ORT session, с | 1,715 (1,699–1,856) | 1,705 (1,703–1,746) |
| Первая ORT query, мс | 4,759 (4,430–4,824) | 4,134 (4,034–4,184) |
| Embed query median, мс | 4,229 (4,212–4,241) | 4,081 (4,036–4,122) |
| Embed query p95, мс | 4,772 (4,730–4,798) | 4,632 (4,581–4,680) |
| Индексация коротких фрагментов, шт./с | 149,62 (148,68–149,92) | 152,26 (152,09–153,87) |
| Индексация токенов, ток./с | 6115,52 (6077,45–6128,12) | 5919,02 (5912,63–5981,50) |
| Peak RSS всего CLI, MiB | 1816,05 (1343,34–1823,33) | 1812,78 (1810,36–1830,42) |
| Необходимые файлы, байт | 487 352 505 | 479 384 538 |
| Лимит контекста, токены | 512 | 128 |

Публикуются все три повтора, а не лучшие времена. Строка p95 — медиана трёх
p95, не объединённый p95 по всем процессам. На процесс приходится 200 замеров
(10 раундов × 20 вопросов); median — среднее двух центральных наблюдений,
p95 — nearest rank. Query latency включает токенизацию, ORT, pooling/L2 и
освобождение временных объектов; cosine scan/sort, верификация файлов и JSON
в неё не входят. Индексация здесь — embedding 48 текстов, без OCR/SQLite/import.
Разные токенизаторы и E5-prefix дают разное число токенов на тот же текст,
поэтому ток./с нельзя трактовать как равный объём семантической работы.

В этом наборе MiniLM чуть быстрее и меньше на 7 967 967 байт (около 1,6%),
но потеряла часть релевантных фрагментов. E5 имеет лучший результат retrieval
на этой синтетике, при этом её top1 тоже ошибочен в трёх вопросах. Например,
на вопрос о возврате «Лиры» она первой выбрала отменённый регламент блокировки,
а правильные фрагменты нашла в top5. MiniLM первой выбрала отклонённый облачный
прототип на вопрос о локальном импорте «Атласа». Cosine не подтверждает
актуальность или истинность источника. Сравнение не обосновывает автоматическую
замену модели, не закрывает #13/#4 целиком и не доказывает качество 2–3 проектов.

## Корпус и определения

[corpus.json](corpus.json): 48 фрагментов шести вымышленных проектов, 20
перефразированных вопросов, архивные/отклонённые решения и соседние продукты
как distractors. Обычный вопрос имеет 2 релевантных фрагмента, два
межпроектных — по 4. Все 48 фрагментов участвуют в каждом поиске, без фильтра
по имени проекта/дате. Порядок и разметка фиксированы до первой inference:

- [PROTOCOL.md](PROTOCOL.md), preregistration commit
  `3961bd25521eea6bae6fa124b9e28f85ce57d8a9`;
- SHA-256 корпуса: `1e1173bfa57d645539117f3752ba54b00c82670980c88b5026a42aa764eeb5a0`.

`recall@5(q) = |top5(q) ∩ relevant(q)| / |relevant(q)|`; результат — среднее по
20 вопросам. Один из четырёх найденных релевантных даёт 0,25, не единицу.
E5 нашла 44 из 44 размеченных связей, MiniLM — 35 из 44; последнее отношение
является micro recall и **не равно** публикуемому macro recall 83,75%.
У MiniLM хотя бы один релевантный результат был в 19/20 вопросах, полный набор
релевантных в top5 — в 15/20. Top1 считает релевантность только первого места.
Равные cosine разрешаются стабильным id. [validate.py](validate.py) независимо
пересчитывает знаменатели/метрики всех шести запусков, все первые-run cosine
и rankings — по полным сохранённым векторам; [test_metrics.py](test_metrics.py)
проверяет дробный recall, дубли и недопустимый пустой ground truth.

Набор мал, написан одним автором и содержит близкие пары. Явные имена проектов
могут облегчать поиск; тексты не прошли независимую экспертную разметку.
Нет длинных документов, шума ASR/OCR, пользовательских запросов или confidence
intervals для генеральной совокупности. Три performance-повтора — не три
независимых набора качества. Максимум фрагментов: 50 токенов E5 / 48 MiniLM,
вопросов: 30 / 27; ни один вход не усечён. Качество у границы 128/512 не измерялось.

## Комплекты и нативная корректность

[models.json](models.json) закрепляет revisions, размеры и SHA-256 каждого
файла. Веса лежат только в /tmp; необходимых inference-файлов по пять.
Дополнительные MiniLM metadata/карточка отмечены отдельно и не включены в
размер необходимых файлов. Лицензии и первичные спецификации:

- [E5-small, MIT, фиксированный revision](https://huggingface.co/intfloat/multilingual-e5-small/tree/fd1525a9fd15316a2d503bf26ab031a61d056e98):
  384 измерения, `query: ` / `passage: ` для соответствующих входов,
  attention-mask mean pooling, L2, максимум 512;
- [MiniLM, Apache-2.0, фиксированный revision](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/tree/e8f8c211226b894fcb81acc59f3b34ba3efd5f42):
  карточка явно включает русский; `sentence_bert_config.json` задаёт 128,
  `1_Pooling/config.json` — mean, не CLS/max. Prefix не добавляется.

[Compare.swift](Compare.swift) использует Swift Transformers 1.3.5 и ONNX Runtime
1.24.2 из закреплённого Package.resolved принятой базы
`1a73669e8d9284d466bb4d9fec472202fd85ac05`. Оба официальных float32 ONNX дают
`last_hidden_state [1,T,384]`, входы `input_ids/attention_mask/token_type_ids`.
Batch=1 без padding; mean берётся по attention mask, затем L2. Toy self-test
проверяет masked pooling с padding, норму, dot и median. Формы, пределы, hash и
размеры проверяются перед/при inference; длинный вход отклоняется.

Оба токенизатора загружаются одинаковым локальным JSON-loader, без Hub loader.
Официальный MiniLM `PreTrainedTokenizerFast` — обобщённая метка, не зарегистрированная
в Swift Transformers. Только в памяти research CLI она направляется в
зарегистрированный `XLMRobertaTokenizer`/Unigram factory. Сам Unigram JSON,
normalizer, post-processor и словарь не меняются. Перед inference каждая модель
проверяет **71** token-ID fixture: все 68 текстов корпуса плюс три русских/Unicode
примера. Независимые [token-fixtures.json](token-fixtures.json) получены локальной
Hugging Face tokenizers 0.23.3 по официальным JSON; это Python tokenizer-only,
не Python inference. Нативный код вычисляет все сравниваемые векторы.
Паритет на этих строках не доказывает паритет любого возможного Unicode ввода.

## Граница измерения и отладочные прогоны

Это **общий исследовательский CLI**, не production `E5TextEmbedding`, app или
XCTest. CLI собран с default Swift `-Onone`, зависимостями SwiftPM из Debug,
одним способом загрузки JSON и per-embed autoreleasepool для обеих моделей.
Эти изменения в app не переносились и не доказывают снижение RSS/латентности
приложения. Результаты прежнего native E5 smoke/XCTest нельзя напрямую сравнивать
с этим harness. Init включает local tokenizer + ORT session, но не запуск
процесса/dyld и не хеширование файлов. Первое ORT query выполняется после
проверки токенизации; warmed query — после первой inference и индексации.

Peak RSS — максимум всего отдельного процесса, с верификацией файлов, загрузкой
JSON/ORT, индексом и сериализацией векторов, не steady-state/model-only memory.
Публикуются также `phase_peak_rss_bytes`. Уже фаза верификации давала около
499/491 MB RSS; у E5 один процесс имел существенно меньший общий пик. Причина
этого разброса не доказана. Диапазоны памяти перекрываются, устойчивого
преимущества одной модели по RSS здесь нет. Не измерялась совместная нагрузка
с записью/ASR. Кеш ОС не сбрасывался; чтение хешей прогревает файлы ещё до init.
CPU frequency/affinity, фоновые чужие процессы и давление памяти не контролировались.

Два предварительных полных набора не включены в результаты: сначала выявлено
нестандартное определение median, затем унифицирован путь local tokenizer loading
для обеих моделей и lifetime временных объектов. Это исправления измерительного
CLI. Корпус, разметка, revisions, prefixes, pooling и лимиты оставались неизменными.
Опубликованы **все шесть** процессов одного окончательного бинарника, а не выбранные
лучшие попытки. Порядок: E5/MiniLM, MiniLM/E5, E5/MiniLM.

## Воспроизведение

Из корня репозитория на Apple Silicon Mac с Xcode/Python toolchain:

```sh
make check DERIVED_DATA=/private/tmp/golos-28-derived
python3 research/model-comparison-28/prepare.py --model e5-small --output /tmp/golos-compare28/e5
python3 research/model-comparison-28/prepare.py --model minilm --output /tmp/golos-compare28/minilm
python3 research/model-comparison-28/build.py --derived-data /private/tmp/golos-28-derived --output /tmp/golos-compare28/compare
sandbox-exec -p '(version 1)(allow default)(deny network*)' /tmp/golos-compare28/compare --self-test
python3 research/model-comparison-28/run.py --binary /tmp/golos-compare28/compare --e5-folder /tmp/golos-compare28/e5 --minilm-folder /tmp/golos-compare28/minilm --output /tmp/golos-compare28/new-results
python3 -B research/model-comparison-28/validate.py --results /tmp/golos-compare28/new-results --output /tmp/golos-compare28/summary.json
python3 -B research/model-comparison-28/test_metrics.py
```

`prepare.py` — отдельный явный сетевой этап только для публичных файлов.
Он не делает inference и отказывается перезаписывать несовпадающий файл;
для повторного запуска используйте новый каталог либо совпадающий cache.
E5 в выполненном эксперименте прочитана из предоставленного
`/tmp/golos-embedding-native/e5-small`, MiniLM — из `/private/tmp/golos-model-comparison-28/minilm`.
Все конкретные argv, binary/source hashes и среда — в
[results/environment.json](results/environment.json). Готовый корпус/fixture
уже включены. Для независимого пересоздания token-ID reference (до offline inference):

```sh
uv run --no-project --with tokenizers==0.23.3 python research/model-comparison-28/token_references.py --e5-folder /tmp/golos-compare28/e5 --minilm-folder /tmp/golos-compare28/minilm --output /tmp/golos-compare28/token-fixtures-check.json
```

Сравните с версионированным fixture. Запуски inference всегда выполняются
внутри deny-network профиля; app/ASR/Keychain/рабочая библиотека не подключаются.
В git сохранены 6 reports с сырыми 200 query times и полными rankings,
полные векторы первого процесса каждой модели, environment и summary.
Runner пишет векторы во всех шести процессах для одинаковой RSS-нагрузки;
повторные векторы остаются только во временном output.

Проверки: `make check` — 244 теста успешно (278 запусков с параметрами),
4 gated-теста пропущены, ошибок 0; настоящий ASR E2E исключён. Native self-test
под deny-network, 3 Python metric-теста и полная независимая валидация JSON
успешны. Это самопроверка автора; PR требует отдельного ревью по точному SHA.
