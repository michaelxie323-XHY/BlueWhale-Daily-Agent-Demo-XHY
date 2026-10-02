"""AMap adapter: only provider-returned places and route durations, no LLM estimates."""
import json, math, os, re, urllib.request
from urllib.parse import urlencode
from datetime import datetime, timezone

class TravelError(ValueError): pass

def text(value, name):
    if not isinstance(value, str) or not value.strip() or len(value) > 100:
        raise TravelError('请填写有效的' + name)
    return value.strip()

def coordinates(value):
    if not isinstance(value, str) or not re.fullmatch(r'-?\d{1,3}(?:\.\d{1,6})?,-?\d{1,2}(?:\.\d{1,6})?', value):
        raise TravelError('地点坐标无效，请重新选择地点')
    lon, lat = map(float, value.split(','))
    if not (-180 <= lon <= 180 and -90 <= lat <= 90): raise TravelError('坐标超出范围')
    return value

def amap(path, params):
    key = os.getenv('AMAP_API_KEY')
    if not key: raise TravelError('尚未配置高德 Web 服务 Key。请在 Mac 双击 configure.command，选择高德并保存，然后重启服务。')
    url = 'https://restapi.amap.com' + path + '?' + urlencode({**params, 'key': key, 'output': 'JSON'})
    try:
        with urllib.request.urlopen(url, timeout=25) as response: data = json.load(response)
    except Exception:
        raise TravelError('高德服务暂时无法连接，请稍后重试') from None
    if str(data.get('status')) != '1':
        # Never propagate raw provider errors or request URLs containing credentials.
        code = str(data.get('infocode', 'unknown'))
        raise TravelError('高德拒绝请求，请核对 Key 权限或配额（错误码 ' + (code if code.isdigit() else 'unknown') + '）')
    return data

def places(body):
    data = amap('/v3/place/text', {'keywords': text(body.get('query'), '地点名称'),
        'city': text(body.get('city'), '城市'), 'citylimit': 'true', 'offset': 8, 'extensions': 'all'})
    result = []
    for poi in data.get('pois', []):
        if not isinstance(poi.get('citycode'), str) or not poi['citycode']: continue
        try: location = coordinates(poi.get('location'))
        except TravelError: continue
        result.append({'id': poi['id'], 'name': poi['name'], 'location': location,
            'citycode': poi['citycode'], 'address': ''.join(x for x in [poi.get('cityname'), poi.get('adname'), poi.get('address')] if isinstance(x, str))})
    return {'places': result}

def meaningful(value):
    if isinstance(value, dict): return any(meaningful(v) for v in value.values())
    if isinstance(value, list): return any(meaningful(v) for v in value)
    return value not in (None, '', '0', 0)

def normalize_paths(data):
    result = []
    for path in data.get('route', {}).get('paths', []):
        try: seconds = float(path['duration'])
        except (KeyError, TypeError, ValueError): continue
        if not math.isfinite(seconds) or seconds <= 0: continue
        steps = [step['instruction'] for step in path.get('steps', []) if isinstance(step.get('instruction'), str) and step['instruction']]
        if not steps: continue
        result.append({'id': str(len(result)), 'minutes': math.ceil(seconds / 60), 'steps': steps})
        if len(result) == 3: break
    return result

def normalize_routes(data):
    result = []
    for transit in data.get('route', {}).get('transits', []):
        try: seconds = float(transit['duration'])
        except (KeyError, TypeError, ValueError): continue
        if not math.isfinite(seconds) or seconds <= 0: continue
        if any(meaningful(segment.get('railway')) or meaningful(segment.get('taxi')) for segment in transit.get('segments', [])):
            continue  # First release displays complete walking/bus/metro routes only.
        steps = []
        for segment in transit.get('segments', []):
            walking = segment.get('walking')
            if isinstance(walking, dict):
                for step in walking.get('steps', []):
                    if isinstance(step.get('instruction'), str): steps.append(step['instruction'])
            bus = segment.get('bus')
            if isinstance(bus, dict):
                lines = bus.get('buslines', [])
                if lines:
                    line = lines[0]
                    steps.append(f"{line.get('name', '')}：{line.get('departure_stop', {}).get('name', '')} → {line.get('arrival_stop', {}).get('name', '')}")
        if not steps: continue
        result.append({'id': str(len(result)), 'minutes': math.ceil(seconds / 60), 'steps': steps})
        if len(result) == 3: break
    return result

def route(body):
    origin, destination = body.get('origin', {}), body.get('destination', {})
    if not isinstance(origin, dict) or not isinstance(destination, dict): raise TravelError('请先选择起点和终点')
    mode = body.get('mode', 'transit')
    if mode not in ('transit', 'driving', 'walking'): raise TravelError('请选择公交、驾车或步行')
    params = {'origin': coordinates(origin.get('location')), 'destination': coordinates(destination.get('location'))}
    if mode == 'transit':
        params.update({'city': text(origin.get('citycode'), '起点城市'),
            'cityd': text(destination.get('citycode'), '终点城市'), 'strategy': 0, 'nightflag': 1, 'extensions': 'base'})
        path = '/v3/direction/transit/integrated'
    else:
        path = '/v3/direction/' + mode
        if mode == 'driving': params.update({'strategy': 0, 'extensions': 'base'})
    data = amap(path, params)
    raw = data.get('route', {}).get('transits' if mode == 'transit' else 'paths', [])
    routes = normalize_routes(data) if mode == 'transit' else normalize_paths(data)
    empty = ''
    if not routes:
        empty = ('高德接口返回了方案，但当前版本无法完整展示该路线。请换一种出行方式。' if raw else
                 '高德接口本次未返回方案（不代表高德 App 一定无路线）。可调整地点或切换出行方式。')
    return {'routes': routes, 'queriedAt': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'source': '高德地图', 'notice': '当前查询的预计耗时，不保证未来路况或班次；出发前请重新核对。',
        'emptyReason': empty, 'mode': mode}
