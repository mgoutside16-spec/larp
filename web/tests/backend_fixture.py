"""Offline Supabase *transport* fixture for browser acceptance tests.

The production SDK, auth forms, IndexedDB cache, uploads and UI are unchanged.
Only external HTTP/WebSocket traffic is intercepted. Shared fixture state models
server persistence between independent browser contexts, never sends auth mail,
and checks access/CAS for realistic frontend responses. This is not an RLS test:
PostgreSQL policies and validation are covered by backend/test-policies.sql.
"""
import base64
import atexit
from copy import deepcopy
from email import policy
from email.parser import BytesParser
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
from threading import Thread
import time
from urllib.parse import parse_qs, unquote, urlparse

from playwright.sync_api import expect

PASSWORD = 'Browser-test-password-42'


def _encoded(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')


class BackendFixture:
    def __init__(self):
        self.users = {}
        for number, (name, admin) in enumerate([('admin', True), ('master', False), ('colleague', False)], 1):
            self.users[name] = {'user_id': f'00000000-0000-4000-8000-{number:012d}',
                                'email': f'{name}@example.test', 'display_name': name.title(), 'is_admin': admin}
        self.projects = {}
        self.memberships = {}
        self.invites = {}
        self.media = {}
        self.player_archives = {}
        self.player_releases = {}
        self.player_updates_available = True
        self.player_auto_sync_available = False
        self.players = {}
        self.requests = []
        self.unhandled = []
        self.auth_mail_requests = []
        self.hold_next_identity = False
        self.pending_identities = []
        fixture = self
        class UploadHandler(BaseHTTPRequestHandler):
            # Chromium's intercepted postData omits file-backed FormData bytes.
            # Receive uploads over real loopback HTTP so the production File and
            # Blob paths both preserve their exact bytes. No external server/mail.
            def log_message(self, *args):
                pass

            def do_POST(self):
                path = unquote(urlparse(self.path).path)
                bucket = next((b for b in ('workshop-media', 'player-releases') if path.startswith('/storage/v1/object/' + b + '/')), None)
                if not bucket:
                    self.send_error(404)
                    return
                prefix = '/storage/v1/object/' + bucket + '/'
                key = path.removeprefix(prefix)
                content_type = self.headers.get('content-type', 'application/octet-stream')
                expected_length = int(self.headers.get('content-length', '0'))
                raw = self.rfile.read(expected_length)
                if len(raw) != expected_length:
                    # A cancelled browser upload closes the socket mid-body.
                    # It must not create an object or write an error to that socket.
                    return
                if content_type.startswith('multipart/form-data'):
                    message = BytesParser(policy=policy.default).parsebytes(b'Content-Type: ' + content_type.encode() + b'\r\nMIME-Version: 1.0\r\n\r\n' + raw)
                    parts = [part for part in message.iter_parts() if part.get_filename() is not None]
                    if len(parts) != 1:
                        self.send_error(400)
                        return
                    raw, content_type = parts[0].get_payload(decode=True), parts[0].get_content_type()
                expected = key.rsplit('/', 1)[-1].split('.')[0]
                if not raw or hashlib.sha256(raw).hexdigest() != expected:
                    self.send_error(400, 'Upload bytes differ from content-addressed filename')
                    return
                objects = fixture.media if bucket == 'workshop-media' else fixture.player_archives
                objects[key] = (raw, content_type)
                result = json.dumps({'Key': bucket + '/' + key, 'Id': key}).encode()
                self.send_response(200)
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)
        server = ThreadingHTTPServer(('127.0.0.1', 0), UploadHandler)
        Thread(target=server.serve_forever, daemon=True).start()
        atexit.register(server.server_close)
        self.backend = f'http://127.0.0.1:{server.server_port}'

    def grant_membership(self, project_id, user='colleague'):
        self.memberships.setdefault(project_id, set()).add(self.users[user]['user_id'])

    def install(self, context):
        context.route('**/config.json', lambda route: route.fulfill(json={
            'supabaseUrl': self.backend, 'supabasePublishableKey': 'sb_publishable_browser_fixture_only'}))
        context.route(f'{self.backend}/**', self._route)
        # Phoenix protocol response: no socket leaves the test runner or fake DNS.
        def socket(ws):
            def receive(raw):
                message = json.loads(raw)
                if isinstance(message, list):
                    join_ref, ref, topic, event, payload = message
                    if event in ('phx_join', 'heartbeat', 'phx_leave'):
                        ws.send(json.dumps([join_ref, ref, topic, 'phx_reply', {'status': 'ok', 'response': {'postgres_changes': []}}]))
                elif message.get('event') in ('phx_join', 'heartbeat', 'phx_leave'):
                    ws.send(json.dumps({'ref': message.get('ref'), 'topic': message['topic'], 'event': 'phx_reply',
                                        'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}))
            ws.on_message(receive)
        context.route_web_socket(self.backend.replace('http:', 'ws:') + '/**', socket)

    def login(self, page, email='admin@example.test', password=PASSWORD):
        expect(page.locator('#account-form')).to_be_visible()
        page.locator('#account-form [name=email]').fill(email)
        page.locator('#account-form [name=password]').fill(password)
        page.get_by_role('button', name='Войти', exact=True).click()
        expect(page.locator('#project-switch')).to_be_visible()
        expect(page.locator('#account-form')).to_have_count(0)

    def release_identities(self):
        pending, self.pending_identities = self.pending_identities, []
        for reply in pending:
            reply()

    def _user(self, request):
        try:
            payload = request.headers.get('authorization', '').split(' ')[1].split('.')[1]
            uid = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))['sub']
            return next(user for user in self.users.values() if user['user_id'] == uid)
        except (IndexError, KeyError, ValueError, StopIteration):
            return None

    def _session(self, user):
        stamp = int(time.time())
        auth_user = {'id': user['user_id'], 'aud': 'authenticated', 'role': 'authenticated', 'email': user['email'],
                     'email_confirmed_at': '2026-01-01T00:00:00Z', 'confirmed_at': '2026-01-01T00:00:00Z',
                     'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z',
                     'app_metadata': {'provider': 'email', 'providers': ['email']},
                     'user_metadata': {'display_name': user.get('auth_display_name',user['display_name'])}, 'identities': [], 'is_anonymous': False}
        token = '.'.join([_encoded({'alg': 'HS256', 'typ': 'JWT'}), _encoded({
            'sub': user['user_id'], 'aud': 'authenticated', 'role': 'authenticated', 'email': user['email'],
            'iat': stamp, 'exp': stamp + 3600, 'iss': self.backend + '/auth/v1', 'session_id': 'browser-fixture'}), _encoded('test-signature')])
        return {'access_token': token, 'token_type': 'bearer', 'expires_in': 3600, 'expires_at': stamp + 3600,
                'refresh_token': 'refresh-' + user['user_id'], 'user': auth_user}

    def _access(self, user, pid, manage=False):
        row = self.projects.get(pid)
        return bool(user and row and (user['is_admin'] or row['owner_id'] == user['user_id'] or
                    (not manage and user['user_id'] in self.memberships.get(pid, set()))))

    def _route(self, route):
        request = route.request
        parsed = urlparse(request.url)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)
        self.requests.append((request.method, path))
        def respond(value=None, status=200, **kwargs):
            route.fulfill(status=status, headers={'access-control-allow-origin': '*'},
                          **({'json': value} if not kwargs else kwargs))
        def denied(message='Проект недоступен.', code='42501', status=403):
            respond({'message': message, 'code': code}, status)
        if request.method == 'OPTIONS':
            route.fulfill(status=204, headers={'access-control-allow-origin': '*', 'access-control-allow-headers': '*',
                                              'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS'})
            return
        body = request.post_data_json if request.headers.get('content-type', '').startswith('application/json') and request.post_data else {}
        user = self._user(request)
        if path == '/auth/v1/token':
            if query.get('grant_type') == ['refresh_token']:
                user = next((u for u in self.users.values() if body.get('refresh_token') == 'refresh-' + u['user_id']), None)
            else:
                user = next((u for u in self.users.values() if u['email'] == body.get('email')), None)
                if body.get('password') != PASSWORD:
                    user = None
            if user:
                respond(self._session(user))
            else:
                respond({'code': 'invalid_credentials', 'msg': 'Invalid login credentials'}, 400)
            return
        if path == '/auth/v1/user':
            respond(self._session(user)['user']) if user else denied('Invalid JWT')
            return
        if path == '/auth/v1/logout':
            respond({}, 200)
            return
        if path in ('/auth/v1/recover', '/auth/v1/signup'):
            self.auth_mail_requests.append(path)
            respond({})
            return
        if path == '/rest/v1/rpc/get_player_release':
            if not self.player_updates_available:
                denied('Could not find the function get_player_release', 'PGRST202', 404)
            else:
                respond(self.player_releases.get(body.get('p_game_id')))
            return
        if path.startswith('/storage/v1/object/player-releases/'):
            key = path.removeprefix('/storage/v1/object/player-releases/')
            pid = key.split('/')[0]
            if request.method == 'POST' and self._access(user, pid, True):
                if key in self.player_archives:
                    respond({'message': 'The resource already exists', 'statusCode': '409'}, 409)
                else:
                    route.continue_()
            elif request.method == 'GET' and any(r['download_path'] == key for r in self.player_releases.values()):
                raw, content_type = self.player_archives[key]
                respond(body=raw, content_type=content_type)
            else:
                denied()
            return
        if not user:
            denied('Необходим вход в аккаунт.')
            return
        if path == '/rest/v1/workshop_projects':
            rows = [deepcopy(row) for pid, row in self.projects.items() if self._access(user, pid)]
            for field in ('id', 'status'):
                if field in query:
                    value = query[field][0].removeprefix('eq.')
                    rows = [row for row in rows if str(row[field]) == value]
            single = 'application/vnd.pgrst.object+json' in request.headers.get('accept', '')
            respond((rows[0] if rows else None) if single else rows)
            return
        if path.startswith('/storage/v1/object/'):
            key = path.split('/storage/v1/object/', 1)[1].removeprefix('authenticated/').removeprefix('workshop-media/')
            pid = key.split('/')[0]
            if not self._access(user, pid):
                denied()
                return
            if request.method == 'POST':
                if key in self.media:
                    respond({'statusCode': '409', 'message': 'The resource already exists'}, 409)
                    return
                route.continue_()
            elif request.method == 'GET' and key in self.media:
                raw, content_type = self.media[key]
                respond(body=raw, content_type=content_type)
            else:
                respond({'message': 'Object not found', 'statusCode': '404'}, 404)
            return
        if path.startswith('/rest/v1/rpc/'):
            rpc = path.rsplit('/', 1)[1]
            pid = body.get('p_project_id', body.get('p_id'))
            if rpc == 'claim_workshop_invites':
                for invite_pid, invites in self.invites.items():
                    if any(i['email'] == user['email'] for i in invites):
                        self.memberships.setdefault(invite_pid, set()).add(user['user_id'])
                        self.invites[invite_pid] = [i for i in invites if i['email'] != user['email']]
                respond(None)
            elif rpc == 'get_workshop_identity':
                if self.hold_next_identity:
                    self.hold_next_identity = False
                    identity = deepcopy(user)
                    self.pending_identities.append(lambda: respond(identity))
                else:
                    respond(user)
            elif rpc == 'set_workshop_display_name':
                user['display_name'] = body['p_name'].strip()
                respond(user)
            elif rpc == 'list_workshop_users':
                respond(list(self.users.values())) if user['is_admin'] else denied()
            elif rpc == 'set_workshop_admin':
                if not user['is_admin']:
                    denied()
                else:
                    target = next(u for u in self.users.values() if u['user_id'] == body['p_user_id'])
                    target['is_admin'] = body['p_admin']
                    respond(None)
            elif rpc in ('get_player_source_version', 'list_game_players'):
                if not self.player_auto_sync_available:
                    denied('Automatic sync migration not installed', 'PGRST202', 404)
                elif not self._access(user, pid):
                    denied()
                elif rpc == 'get_player_source_version':
                    respond(self.projects[pid]['player_version'])
                else:
                    respond(self.players.get(pid, []))
            elif rpc == 'save_workshop_project':
                document = body['p_document']
                pid = document['id']
                row = self.projects.get(pid)
                if row and not self._access(user, pid):
                    denied()
                elif body['p_expected_revision'] != (row['revision'] if row else 0):
                    denied('Проект изменён.', '40001', 409)
                else:
                    source_fields = ('packageId', 'name', 'description', 'locations', 'records', 'reserved_codes')
                    changed = not row or any(row['document'].get(key) != document.get(key) for key in source_fields)
                    player_version = max((row or {}).get('player_version', 0) + int(changed), document['version'])
                    row = {'id': pid, 'owner_id': row['owner_id'] if row else user['user_id'],
                           'revision': row['revision'] + 1 if row else 1, 'document': deepcopy(document),
                           'status': 'active' if body.get('p_activate', True) or (row and row['status'] == 'active') else 'importing'}
                    row['player_version'] = player_version
                    self.projects[pid] = row
                    respond(deepcopy(row))
            elif rpc == 'delete_workshop_project':
                if not self._access(user, pid, True):
                    denied()
                elif self.projects[pid]['revision'] != body['p_expected_revision']:
                    denied('Проект изменён.', '40001', 409)
                else:
                    del self.projects[pid]
                    respond(None)
            elif rpc == 'publish_player_release':
                if not self._access(user, pid, True):
                    denied()
                elif self.projects[pid]['revision'] != body['p_expected_revision']:
                    denied('Проект изменился.', '40001', 409)
                else:
                    document = self.projects[pid]['document']
                    key = body['p_path']
                    archive = self.player_archives.get(key)
                    if not archive or len(archive[0]) != body['p_size'] or hashlib.sha256(archive[0]).hexdigest() != body['p_sha256'] or document['version'] != body['p_version']:
                        denied('Некорректный игровой пакет.', '23514', 400)
                    else:
                        release = {'game_id': document['packageId'], 'name': document['name'], 'version': body['p_version'],
                                   'sha256': body['p_sha256'], 'size': body['p_size'], 'download_path': key, 'created_at': '2026-10-25T00:00:00Z'}
                        self.player_releases[document['packageId']] = release
                        respond(release)
            elif rpc == 'list_workshop_members':
                if not self._access(user, pid):
                    denied()
                else:
                    row = self.projects[pid]
                    respond([{**u, 'is_owner': u['user_id'] == row['owner_id']} for u in self.users.values()
                             if u['user_id'] == row['owner_id'] or u['user_id'] in self.memberships.get(pid, set())])
            elif rpc == 'list_workshop_invites':
                respond(self.invites.get(pid, [])) if self._access(user, pid, True) else denied()
            elif rpc == 'add_workshop_member':
                if not self._access(user, pid, True):
                    denied()
                else:
                    target = next((u for u in self.users.values() if u['email'] == body['p_email']), None)
                    if target:
                        self.memberships.setdefault(pid, set()).add(target['user_id'])
                    else:
                        self.invites.setdefault(pid, []).append({'email': body['p_email'], 'created_at': '2026-01-01T00:00:00Z'})
                    respond({'status': 'added' if target else 'invited'})
            elif rpc in ('remove_workshop_member', 'remove_workshop_invite'):
                if not self._access(user, pid, True):
                    denied()
                else:
                    if rpc.endswith('_member'):
                        self.memberships.setdefault(pid, set()).discard(body['p_user_id'])
                    else:
                        self.invites[pid] = [i for i in self.invites.get(pid, []) if i['email'] != body['p_email']]
                    respond(None)
            else:
                self.unhandled.append(path)
                respond({'message': 'Unhandled fixture RPC: ' + rpc}, 500)
            return
        self.unhandled.append(path)
        respond({'message': 'Unhandled fixture request: ' + path}, 500)
