import sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import travel

class TravelTests(unittest.TestCase):
    def test_missing_key(self):
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaisesRegex(travel.TravelError, '尚未配置'):
                travel.places({'city':'上海','query':'人民广场'})
    def test_reject_invalid_coordinates(self):
        for coord in ('181,45','10,91','x,y','1,2&key=secret',None):
            with self.assertRaises(travel.TravelError): travel.coordinates(coord)
    def test_no_invented_duration(self):
        self.assertEqual(travel.normalize_routes({'route':{'transits':[{'duration':[], 'segments':[]}]}}), [])
    def test_route_rounds_up_and_keeps_stops(self):
        payload = {'route':{'transits':[{'duration':'601','segments':[
            {'walking':{'steps':[{'instruction':'步行至车站'}]},'bus':{'buslines':[
                {'name':'地铁2号线','departure_stop':{'name':'A站'},'arrival_stop':{'name':'B站'}}]}}]}]}}
        result=travel.normalize_routes(payload)
        self.assertEqual(result[0]['minutes'],11)
        self.assertEqual(result[0]['steps'],['步行至车站','地铁2号线：A站 → B站'])
    def test_empty_transport_objects_do_not_hide_bus(self):
        payload = {'route':{'transits':[{'duration':'120','segments':[{
            'railway':{'id':[], 'name':[], 'spaces':[]}, 'taxi':{'origin':[], 'destination':[]},
            'bus':{'buslines':[{'name':'夜宵线','departure_stop':{'name':'A'},'arrival_stop':{'name':'B'}}]}
        }]}]}}
        self.assertEqual(len(travel.normalize_routes(payload)),1)
        payload['route']['transits'][0]['segments'][0]['railway']['name']='高铁'
        self.assertEqual(travel.normalize_routes(payload),[])
    def test_modes_and_night_routes(self):
        point={'location':'121,31','citycode':'021'}
        with patch.object(travel,'amap',return_value={'route':{}}) as mock:
            travel.route({'origin':point,'destination':point})
            self.assertEqual(mock.call_args.args[1]['nightflag'],1)
            for mode in ('driving','walking'):
                travel.route({'origin':point,'destination':point,'mode':mode})
                self.assertEqual(mock.call_args.args[0],'/v3/direction/'+mode)
        with self.assertRaises(travel.TravelError):
            travel.route({'origin':point,'destination':point,'mode':'unknown'})
    def test_path_duration(self):
        paths={'route':{'paths':[{'duration':'121','steps':[{'instruction':'沿道路向东步行'}]}]}}
        self.assertEqual(travel.normalize_paths(paths)[0]['minutes'],3)

    def test_city_scoped_search(self):
        with patch.object(travel, 'amap', return_value={'pois':[{'id':'p','name':'站点','location':'121,31','citycode':'021','address':[],'cityname':'上海'}]}) as mock:
            self.assertEqual(travel.places({'city':'上海','query':'站点'})['places'][0]['address'],'上海')
            self.assertEqual(mock.call_args.args[1]['citylimit'],'true')

if __name__ == '__main__': unittest.main()
