"""Offline arithmetic/provenance check of authored synthetic assignment reports."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent
for name, digest in json.loads((root / 'corpus-sha256.json').read_text()).items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
freeze = json.loads((root / 'policy-v4-freeze.json').read_text())
assert hashlib.sha256((root / 'final-evaluation.json').read_bytes()).hexdigest() == freeze['fresh_evaluation_sha256']
for path in sorted(root.glob('*.json')):
    report = json.loads(path.read_text())
    if 'true_positive_links' not in report:
        continue
    corpus = ('final-evaluation.json' if path.name.startswith('final-evaluation') else
              'calibration.json' if path.name.startswith('calibration') else
              'regression.json' if path.name.startswith('regression') else 'evaluation.json')
    assert hashlib.sha256((root / corpus).read_bytes()).hexdigest() == report['corpus_sha256'], path.name
    expected_cases = {c['id']: c for c in json.loads((root / corpus).read_text())['cases']}
    tp = fp = fn = exact = automatic = proposals = novel = correct_positive = positive = 0
    for case in report['cases']:
        expected, actual = set(case['expected']), set(case['actual'])
        assert expected == set(expected_cases[case['id']]['expected'])
        tp += len(expected & actual)
        fp += len(actual - expected)
        fn += len(expected - actual)
        exact += expected == actual
        automatic += bool(actual)
        proposals += not actual and bool(case['scores'])
        novel += not case['scores']
        positive += bool(expected)
        correct_positive += bool(expected) and actual == expected
        if report['algorithm'] == 'trusted-aliases-margin-e5-v4':
            assert actual == {s['project'] for s in case['scores'] if s['automatic']}
    for key, value in [('true_positive_links', tp), ('false_positive_links', fp), ('missed_links', fn),
                       ('exact_match_meetings', exact), ('automatic_meetings', automatic),
                       ('proposal_meetings', proposals), ('new_topic_meetings', novel),
                       ('expected_positive_meetings', positive), ('correct_automatic_meetings', correct_positive)]:
        assert report[key] == value, (path.name, key, report[key], value)
    print(f'{path.name}: TP={tp} FP={fp} FN={fn}, exact={exact}/{len(report["cases"])}; auto={automatic}, proposals={proposals}, new={novel}')
