"""Local prototype gateway. Start on a trusted LAN; never expose this port publicly."""
import json, os, re, urllib.request
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timedelta

PLAN_SCHEMA = {
    'type': 'object', 'additionalProperties': False,
    'properties': {
        'items': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'properties': {'id': {'type': 'string'}, 'title': {'type': 'string'}, 'minutes': {'type': 'integer'}, 'notes': {'type': ['string', 'null']}, 'url': {'type': ['string', 'null']}, 'fixedStart': {'type': ['string', 'null']}},
            'required': ['id', 'title', 'minutes', 'notes', 'url', 'fixedStart']}},
        'start': {'type': 'string'}, 'deadline': {'type': 'string'}},
    'required': ['items', 'start', 'deadline']}

ITEM_PROPERTIES = PLAN_SCHEMA['properties']['items']['items']['properties']
ITEM_PROPERTIES.update({
    'windows': {'type': 'array', 'items': {'type': 'object', 'additionalProperties': False,
        'properties': {'start': {'type': 'string'}, 'end': {'type': 'string'}}, 'required': ['start','end']}},
    'location': {'type': ['string','null']},
    'reminderMinutes': {'type': 'array', 'items': {'type': 'integer'}},
    'travelMinutes': {'type': 'integer'}})
PLAN_SCHEMA['properties']['items']['items']['required'] = list(ITEM_PROPERTIES)

def date_value(value):
    date = datetime.fromisoformat(value.replace('Z','+00:00'))
    if date.tzinfo is None: raise ValueError('Date requires timezone')
    return date

def validate_plan(plan, instruction, now):
    start, end = date_value(plan['start']), date_value(plan['deadline'])
    if start >= end or end-start > timedelta(days=31) or start < date_value(now):
        raise ValueError('Invalid or past planning window')
    items = plan['items']
    if not 1 <= len(items) <= 20: raise ValueError('Invalid item count')
    for i, item in enumerate(items):
        if type(item['minutes']) is not int or not 1 <= item['minutes'] <= 480: raise ValueError('Invalid duration')
        if not isinstance(item['title'],str) or not item['title'].strip(): raise ValueError('Invalid title')
        validate_metadata(item,instruction)
        travel=item.get('travelMinutes',0)
        if type(travel) is not int or not 0 <= travel <= 240: raise ValueError('Invalid travel time')
        alarms=item.get('reminderMinutes',[])
        if not isinstance(alarms,list) or len(alarms)>2 or any(type(x) is not int or not 0<=x<=10080 for x in alarms): raise ValueError('Invalid reminders')
        if item.get('location') is not None and (not isinstance(item['location'],str) or len(item['location'])>1000): raise ValueError('Invalid location')
        windows=item.get('windows',[])
        if not 1 <= len(windows) <= 31: raise ValueError('Missing per-task windows')
        for window in windows:
            a,b=date_value(window['start']),date_value(window['end'])
            if not start<=a<b<=end: raise ValueError('Invalid task window')
        if item.get('fixedStart'):
            fixed=date_value(item['fixedStart']); finish=fixed+timedelta(minutes=item['minutes'])
            if fixed-timedelta(minutes=travel)<start or not any(date_value(w['start'])<=fixed and finish<=date_value(w['end']) for w in windows): raise ValueError('Invalid fixed meeting window')
        item['id']=str(i)
    return plan

def build_request(body):
    return {'model': os.environ.get('MODEL_NAME', 'gpt-5'),
        'store': False, 'reasoning': {'effort': 'low'}, 'max_output_tokens': 8000,
        'instructions': ('Extract a calendar plan from the user request. Dates must be ISO8601 with explicit timezone offset and whole seconds. '
            'Resolve relative dates from now and timezone. Never schedule in the past. '
            'Return up to 20 tasks with duration 1..480 minutes. Default unspecified hours to 09:00..18:00. '
            'Each item has windows: a nonempty array of allowed start/end windows, with explicit timezone offsets. '
            'Respect each task date and deadline independently. For flexible multi-day work list separate daytime windows; NEVER use one overnight window unless asked. '
            'Default unspecified daytime hours to 09:00..18:00. Expand bounded repetitions (e.g. next week Mon/Wed/Fri) into individual dated items, max 20. '
            'Next week means next calendar Monday through Sunday in the user timezone. Explicit dates override relative defaults. '
            'The overall start/deadline encompasses all item windows AND travel blocks; start must not be before now. '
            'location is user supplied place text or null. reminderMinutes is up to 2 lead times before event start in minutes (0 means at start); empty if not requested. '
            'travelMinutes is user supplied travel duration 0..240, zero if absent. Do not estimate traffic. It creates a separate departure block immediately before the event. '

            'If the request requires search, sending messages, unbounded recurrence, or other unsupported actions, return an empty items array; never pretend to execute them. '
            'Do not invent requested tasks. Existing calendar conflicts are handled on the phone. '
            'For each item preserve user-provided meeting details in notes and an exact supplied http/https link in url. '
            'Never invent, shorten, or visit links. Additional supplied links can remain in notes. Use null when absent. '
            'For a meeting at an explicit time set fixedStart (ISO8601 with offset, whole seconds), never move it. '
            'Use null for fixedStart for flexible work. If duration is missing use 30 minutes and state this assumption in notes. '
            'Order items chronologically with fixed meetings first where relevant. Include all fixed meetings in the overall window.'),
        'input': json.dumps(body, ensure_ascii=False),
        'text': {'format': {'type': 'json_schema', 'name': 'calendar_plan', 'strict': True, 'schema': PLAN_SCHEMA}}}

def extract_plan(result):
    if result.get('status') != 'completed': raise ValueError('Incomplete model response')
    parts = [part for item in result.get('output', []) for part in item.get('content', [])]
    if any(part.get('type') == 'refusal' for part in parts): raise ValueError('Model declined request')
    text = ''.join(part.get('text', '') for part in parts if part.get('type') == 'output_text')
    return json.loads(text)


def validate_metadata(item, instruction):
    notes = item.get('notes')
    if notes is not None and (not isinstance(notes, str) or len(notes) > 10000): raise ValueError('Invalid notes')
    links = re.findall(r'https?://[^\s<>"，。；）]+', instruction)
    for link in ([item['url']] if item.get('url') else []) + re.findall(r'https?://[^\s<>"，。；）]+', notes or ''):
        parsed = urlsplit(link)
        if link not in links or parsed.scheme not in ('http', 'https') or not parsed.hostname:
            raise ValueError('Link must be copied exactly from user input')


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/health'):
            self.send_error(404); return
        data = json.dumps({'status': 'ok', 'service': 'WhaleCompanion', 'message': 'Local connection works; model access is not tested.'}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def travel_request(self):
        import travel
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 20000: raise travel.TravelError('请求长度无效')
            body = json.loads(self.rfile.read(length))
            result = travel.places(body) if self.path.endswith('/places') else travel.route(body)
            status = 200
        except travel.TravelError as exc:
            status, result = 400, {'error': str(exc)}
        except Exception:
            status, result = 502, {'error': '出行查询失败，请核对输入后重试'}
        data = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path in ('/travel/places', '/travel/route'):
            self.travel_request()
            return
        if self.path != '/plan':
            self.send_error(404); return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 20000: raise ValueError('Invalid payload size')
            body = json.loads(self.rfile.read(length))
            instruction = body['instruction']
            if not isinstance(instruction, str) or not instruction.strip(): raise ValueError('Missing instruction')
            print('Received planning request; contacting model.', flush=True)
            payload = build_request(body)
            req = urllib.request.Request(os.environ.get('MODEL_BASE_URL', 'https://api.openai.com/v1').rstrip('/') + '/responses',
                data=json.dumps(payload).encode(), headers={'Authorization':'Bearer '+os.environ['MODEL_API_KEY'],'Content-Type':'application/json'})
            with urllib.request.urlopen(req, timeout=75) as response: result=json.load(response)
            plan=extract_plan(result)
            plan=validate_plan(plan, instruction, body['now'])
            data=json.dumps(plan,ensure_ascii=False).encode()
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
        except Exception as exc:
            print('Planning failed:', type(exc).__name__, 'HTTP status:', getattr(exc, 'code', '-'), flush=True)
            self.send_error(502, 'Planning failed; check model configuration')

if __name__ == '__main__':
    for key in ('MODEL_BASE_URL','MODEL_NAME','MODEL_API_KEY'):
        if not os.getenv(key): raise SystemExit('Missing environment variable: '+key)
    print('Listening on :8765. Trusted LAN only.',flush=True)
    ThreadingHTTPServer(('0.0.0.0',8765),Handler).serve_forever()
