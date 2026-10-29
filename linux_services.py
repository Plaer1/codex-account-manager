"""Linux account presentation and read-only usage service."""
import base64
import json
import os
import sqlite3
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

USAGE_URL = 'https://chatgpt.com/backend-api/wham/usage'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None

def open_usage(request):
    # Never forward a bearer token to a redirect destination.
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=15)

def read_auth(path):
    try:
        with open(path, encoding='utf-8') as f: value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError): return {}

def claims(token):
    try:
        payload = token.split('.')[1]
        value = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        return value if isinstance(value, dict) else {}
    except (ValueError, IndexError, TypeError): return {}

def metadata(path):
    auth = read_auth(path)
    tokens = auth.get('tokens') if isinstance(auth.get('tokens'), dict) else {}
    info = claims(tokens.get('id_token') or tokens.get('idToken') or '')
    access = claims(tokens.get('access_token') or tokens.get('accessToken') or '')
    account = info.get('https://api.openai.com/auth') or access.get('https://api.openai.com/auth') or {}
    if not isinstance(account, dict): account = {}
    return {'email': info.get('email') or access.get('email') or access.get('https://api.openai.com/profile/email') or '',
            'plan': account.get('chatgpt_plan_type') or info.get('chatgpt_plan_type') or '',
            'subject': info.get('sub') or access.get('sub') or '',
            'account': tokens.get('account_id') or tokens.get('accountId') or account.get('chatgpt_account_id') or '',
            'workspace': account.get('workspace_label') or account.get('workspace_name') or account.get('organization_name') or '',
            'workspace_id': account.get('workspace_id') or account.get('chatgpt_workspace_id') or account.get('organization_id') or '',
            'seat': account.get('seat_type') or account.get('chatgpt_seat_type') or '',
            'auth_mode': auth.get('auth_mode') or '',
            'last_refresh': auth.get('last_refresh') or '',
            'expires': access.get('exp'),
            'has_auth': bool(tokens or auth.get('OPENAI_API_KEY'))}

def usage(path):
    auth = read_auth(path)
    tokens = auth.get('tokens') if isinstance(auth.get('tokens'), dict) else {}
    token = tokens.get('access_token') or tokens.get('accessToken')
    if not token: return {'error': 'No access token'}
    expiry = claims(token).get('exp')
    if isinstance(expiry, (int, float)) and expiry <= time.time(): return {'error': 'Access token expired'}
    request = urllib.request.Request(USAGE_URL, headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json'})
    try:
        with open_usage(request) as response:
            raw = json.load(response)
        if not isinstance(raw, dict): return {'error': 'Usage response was invalid'}
        rate = raw.get('rate_limit') or {}
        if not isinstance(rate, dict): rate = {}
        windows = []
        for key in ('primary_window', 'secondary_window'):
            item = rate.get(key)
            if isinstance(item, dict) and isinstance(item.get('used_percent'), (int, float)):
                seconds = item.get('limit_window_seconds') or item.get('window_seconds') or (604800 if key == 'secondary_window' else 18000)
                if not isinstance(seconds, (int, float)): seconds = 604800 if key == 'secondary_window' else 18000
                windows.append({'left': max(0, min(100, 100 - item['used_percent'])),
                                'seconds': seconds,
                                'reset': item.get('reset_at')})
        return {'windows': windows, 'observed': time.time()} if windows else {'error': 'Usage unavailable'}
    except urllib.error.HTTPError as e: return {'error': 'Login rejected (401)' if e.code == 401 else f'Usage service HTTP {e.code}'}
    except (OSError, ValueError, TypeError): return {'error': 'Usage service unavailable'}

def validate(path):
    auth = read_auth(path)
    tokens = auth.get('tokens') if isinstance(auth.get('tokens'), dict) else {}
    token = tokens.get('access_token') or tokens.get('accessToken')
    if not token: return {'error': 'The new login has no access token.'}
    request = urllib.request.Request(USAGE_URL, headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json'})
    try:
        with open_usage(request) as response:
            return {'ok': 200 <= response.status < 300}
    except urllib.error.HTTPError as e: return {'error': f'Login verification failed (HTTP {e.code}).'}
    except OSError: return {'error': 'Login verification could not reach the usage service.'}

def local_usage(root, min_time=0):
    db = Path(root) / 'logs_2.sqlite'
    if not db.is_file(): return {'error': 'No recorded usage'}
    try:
        with sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True, timeout=3) as connection:
            row = connection.execute("select ts, feedback_log_body from logs where ts >= ? and feedback_log_body like ? order by ts desc, ts_nanos desc, id desc limit 1", (int(min_time), '%"type":"codex.rate_limits"%')).fetchone()
        if not row: return {'error': 'No recorded usage'}
        position = row[1].find('{"type":"codex.rate_limits"')
        raw, _ = json.JSONDecoder().raw_decode(row[1][position:])
        limits = raw.get('rate_limits') or {}; windows = []
        for key in ('primary', 'secondary'):
            item = limits.get(key) or {}
            used, minutes = item.get('used_percent'), item.get('window_minutes')
            if isinstance(used, (int, float)) and isinstance(minutes, (int, float)):
                windows.append({'left': max(0, min(100, 100-used)), 'seconds': minutes*60, 'reset': item.get('reset_at')})
        return {'windows': windows, 'observed': row[0], 'recorded': True} if windows else {'error': 'No recorded usage'}
    except (sqlite3.Error, OSError, ValueError, TypeError, AttributeError): return {'error': 'Recorded usage unavailable'}

def nickname(profile):
    try:
        for line in (profile / 'profile.env').read_text(encoding='utf-8').splitlines():
            if line.startswith('local_nickname='): return line.partition('=')[2]
    except OSError: pass
    return ''

def set_nickname(profile, value):
    if '\n' in value or '\r' in value: raise ValueError('Nickname cannot contain line breaks')
    path = profile / 'profile.env'
    lines = path.read_text(encoding='utf-8').splitlines() if path.exists() else []
    lines = [line for line in lines if not line.startswith('local_nickname=')]
    if value: lines.append('local_nickname=' + value)
    fd, tmp = tempfile.mkstemp(prefix='.profile-', dir=profile, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f: f.write('\n'.join(lines) + '\n')
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def load_usage_cache(store):
    try:
        value = json.loads((store / 'usage-cache-linux.json').read_text(encoding='utf-8'))
        if isinstance(value, dict):
            return {name: dict(snapshot, stale=True) for name, snapshot in value.items() if isinstance(snapshot, dict) and snapshot.get('windows')}
    except (OSError, ValueError, TypeError): pass
    return {}

def save_usage_cache(store, snapshots):
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.usage-', dir=store, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump({name: data for name, data in snapshots.items() if isinstance(data, dict) and data.get('windows')}, f)
        os.replace(tmp, store / 'usage-cache-linux.json')
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def token_statuses(path):
    auth = read_auth(path); tokens = auth.get('tokens') if isinstance(auth.get('tokens'), dict) else {}
    result = []
    for label, keys in [('Access', ('access_token', 'accessToken')), ('ID', ('id_token', 'idToken')), ('Refresh', ('refresh_token', 'refreshToken'))]:
        token = next((tokens.get(key) for key in keys if tokens.get(key)), None)
        if not token: result.append(f'{label}: missing'); continue
        expiry = claims(token).get('exp') if label != 'Refresh' else None
        if isinstance(expiry, (int, float)):
            try: status = 'expired' if expiry <= time.time() else 'expires ' + time.strftime('%Y-%m-%d %H:%M', time.localtime(expiry))
            except (OverflowError, ValueError, OSError): status = 'expiry unavailable'
            result.append(f'{label}: ' + status)
        else: result.append(f'{label}: saved')
    return result
