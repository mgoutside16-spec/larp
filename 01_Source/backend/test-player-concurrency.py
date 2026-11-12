"""Disposable PostgreSQL 17 only: real separate connections, locks and races.

CI: python backend/test-player-concurrency.py (uses normal PG* variables).
Local: python backend/test-player-concurrency.py --docker larp-account-tests
"""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--docker')
args = parser.parse_args()
PSQL = (['docker', 'exec', '-i', args.docker, 'psql', '-U', 'postgres'] if args.docker else ['psql']) + ['-X', '-Atq', '-v', 'ON_ERROR_STOP=1']
OWNER = '99999999-1111-4111-8111-111111111111'
PROJECT = '99999999-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
GAME = '99999999-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
DOCUMENT = {'id': PROJECT, 'packageId': GAME, 'name': 'Race fixture', 'description': '',
            'created': '2026-10-25T00:00:00Z', 'modified': '2026-10-25T00:00:00Z',
            'version': 1, 'locations': [], 'records': [], 'reserved_codes': [], 'builds': []}
AUTH = f"set role authenticated; set request.jwt.claim.sub='{OWNER}';"


def run(sql):
    result = subprocess.run(PSQL, input=sql, text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def start(sql):
    process = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    process.stdin.write("\\set VERBOSITY verbose\n" + sql + '\n')
    process.stdin.flush()
    return process


def ready(process):
    assert process.stdout.readline().strip() == 'ready', 'connection did not reach its lock barrier'


def finish(process, suffix=''):
    stdout, stderr = process.communicate(suffix, timeout=15)
    return process.returncode, stdout, stderr


def blocked(*names):
    deadline = time.monotonic() + 10
    quoted = ','.join("'" + name + "'" for name in names)
    while time.monotonic() < deadline:
        count = run(f"select count(*) from pg_stat_activity where application_name in ({quoted}) and wait_event_type='Lock'")
        if int(count) == len(names):
            return
        time.sleep(0.02)
    raise AssertionError('concurrent connections did not contend for real PostgreSQL locks')


def publish(version, revision):
    return f"select public.publish_player_release('{PROJECT}',{revision},{version},'{PROJECT}/{version}/{'a'*64}.rpgpack','{'a'*64}',123);"


def stage(version):
    run(AUTH + f"insert into storage.objects(bucket_id,name,metadata) values('player-releases','{PROJECT}/{version}/{'a'*64}.rpgpack','{{\"size\":123}}');")


def save(version, revision):
    document = {**DOCUMENT, 'version': version}
    return f"select public.save_workshop_project('{json.dumps(document)}'::jsonb,{revision});"


processes = []
try:
    run(f"insert into auth.users(id,email,email_confirmed_at) values('{OWNER}','race-fixture@example.test',now());" + AUTH + save(1, 0))
    stage(2)
    locker = start(f"set request.jwt.claim.sub='{OWNER}'; begin; select 1 from public.workshop_projects where id='{PROJECT}' for update; select 'ready';")
    processes.append(locker)
    # The row-lock SELECT prints 1 before the marker.
    first = locker.stdout.readline().strip()
    assert first == '1', (first, locker.stderr.read() if locker.poll() is not None else '')
    ready(locker)
    stale = start(AUTH + "set application_name='player-test-stale';" + publish(2, 1))
    processes.append(stale)
    blocked('player-test-stale')
    result = finish(locker, save(2, 1) + 'commit;')
    assert result[0] == 0, result
    result = finish(stale)
    assert result[0] != 0 and '40001:' in result[2], result
    print('PASS concurrent save wins project revision; queued stale publication fails CAS')

    locker = start(f"begin; select 1 from public.workshop_projects where id='{PROJECT}' for update; select 'ready';")
    processes.append(locker)
    first = locker.stdout.readline().strip()
    assert first == '1', (first, locker.stderr.read() if locker.poll() is not None else '')
    ready(locker)
    publishers = [start(AUTH + f"set application_name='player-test-pub-{i}';" + publish(2, 2)) for i in range(2)]
    processes.extend(publishers)
    blocked('player-test-pub-0', 'player-test-pub-1')
    assert finish(locker, 'commit;')[0] == 0
    results = [finish(process) for process in publishers]
    assert sorted(result[0] == 0 for result in results) == [False, True], results
    assert '23514:' in next(result[2] for result in results if result[0] != 0), results
    assert run(f"select count(*) from public.player_releases where game_id='{GAME}'") == '1'
    print('PASS simultaneous publications: exactly one immutable version is published')

    run(AUTH + save(3, 2))
    stage(3)
    publisher = start(AUTH + 'begin;' + publish(3, 3) + "select 'ready';")
    processes.append(publisher)
    assert json.loads(publisher.stdout.readline())['version'] == 3
    ready(publisher)
    deletion = start(AUTH + "set application_name='player-test-delete'; set storage.operation='storage.object.delete';"
                     + f"delete from storage.objects where bucket_id='player-releases' and name='{PROJECT}/3/{'a'*64}.rpgpack';")
    processes.append(deletion)
    blocked('player-test-delete')
    assert finish(publisher, 'commit;')[0] == 0
    result = finish(deletion)
    assert result[0] != 0 and '23514:' in result[2], result
    assert run(f"select count(*) from storage.objects where bucket_id='player-releases' and name='{PROJECT}/3/{'a'*64}.rpgpack'") == '1'
    print('PASS staged delete racing publication cannot delete newly published bytes')
finally:
    for process in processes:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    # Only this disposable fixture's synthetic rows are removed. History first
    # lets the immutable-object trigger distinguish fixture teardown from clients.
    run(f"delete from public.player_releases where game_id='{GAME}'; delete from storage.objects where bucket_id='player-releases' and name like '{PROJECT}/%'; delete from public.workshop_projects where id='{PROJECT}'; delete from auth.users where id='{OWNER}';")
