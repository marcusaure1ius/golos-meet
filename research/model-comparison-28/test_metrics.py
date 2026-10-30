import unittest
from validate import retrieval_metrics
class Metrics(unittest.TestCase):
    def test_recall_counts_all_relevant_not_just_any_hit(self):
        queries=[{'id':'q1','relevant_ids':['a','b','c','d']},{'id':'q2','relevant_ids':['e','f']}]
        ranking={'q1':['a','x','b','y','z','c','d'],'q2':['x','e','f','y','z']}
        self.assertEqual(retrieval_metrics(ranking,queries),(0.5,0.75))
    def test_duplicate_results_cannot_inflate_recall(self):
        with self.assertRaises(AssertionError):retrieval_metrics({'q':['a','a']},[{'id':'q','relevant_ids':['a','b']}])
    def test_zero_relevance_is_invalid_not_a_zero_or_success(self):
        with self.assertRaises(AssertionError):retrieval_metrics({'q':['a']},[{'id':'q','relevant_ids':[]}])
if __name__=='__main__':unittest.main()
