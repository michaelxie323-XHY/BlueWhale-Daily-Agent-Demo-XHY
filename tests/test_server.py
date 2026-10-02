import unittest
from server.server import build_request, extract_plan, validate_metadata, validate_plan
class ResponseTests(unittest.TestCase):
    def test_plan_bounds(self):
        import copy
        plan={'start':'2026-10-02T09:00:00+08:00','deadline':'2026-10-02T12:00:00+08:00','items':[{'id':'a','title':'会议','minutes':30,'windows':[{'start':'2026-10-02T10:00:00+08:00','end':'2026-10-02T11:00:00+08:00'}],'fixedStart':'2026-10-02T10:00:00+08:00','travelMinutes':20,'reminderMinutes':[10,30]}]}
        now='2026-10-01T12:00:00+08:00'
        self.assertEqual(validate_plan(copy.deepcopy(plan),'会议',now)['items'][0]['id'],'0')
        for field,value in [('reminderMinutes',[-1]),('travelMinutes',300),('windows',[]),('fixedStart','2026-10-02T11:00:00+08:00')]:
            bad=copy.deepcopy(plan); bad['items'][0][field]=value
            with self.assertRaises(ValueError): validate_plan(bad,'会议',now)
        with self.assertRaises(ValueError): validate_plan(plan,'会议','2026-10-03T12:00:00+08:00')
    def test_links(self):
        validate_metadata({'url':'https://example.com/meeting?a=1', 'notes':'带作品集'}, '会议 https://example.com/meeting?a=1')
        with self.assertRaises(ValueError): validate_metadata({'url':'https://evil.example'}, '会议 https://example.com')
        with self.assertRaises(ValueError): validate_metadata({'notes':'访问 https://evil.example'}, '没有链接')
    def test_structured_request(self):
        request=build_request({'instruction':'明天复习'})
        self.assertNotIn('temperature', request)
        self.assertFalse(request['store'])
        self.assertTrue(request['text']['format']['strict'])
    def test_reasoning_before_message(self):
        result={'status':'completed','output':[{'type':'reasoning'}, {'type':'message','content':[{'type':'output_text','text':'{"items":[]}'}]}]}
        self.assertEqual(extract_plan(result), {'items':[]})
    def test_incomplete_and_refusal(self):
        for result in [{'status':'incomplete'}, {'status':'completed','output':[{'content':[{'type':'refusal'}]}]}]:
            with self.assertRaises(ValueError): extract_plan(result)
if __name__ == '__main__': unittest.main()
