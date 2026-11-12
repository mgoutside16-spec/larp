"""Real PostgreSQL 17 first-install/backfill/idempotence test, synthetic data only.

python backend/test-player-auto-migration.py --docker larp-account-tests
Creates and drops its own temporary database inside the disposable test container.
Without --docker, uses PG* environment variables against disposable PostgreSQL only.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--docker', choices=['larp-account-tests'])
args = parser.parse_args()
DB = 'larp_auto_test_' + uuid.uuid4().hex
BASE = (['docker', 'exec', '-i', args.docker, 'psql', '-U', 'postgres'] if args.docker else ['psql']) + ['-X', '-Atq', '-v', 'ON_ERROR_STOP=1']
BACKEND = Path(__file__).resolve().parent
OWNER = '11111111-1111-4111-8111-111111111111'
A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
D = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
E = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
GAME = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
AUTH = f"set role authenticated; set request.jwt.claim.sub='{OWNER}';"


def run(sql, database=DB):
    r = subprocess.run(BASE + ['-d', database], input=sql, text=True, capture_output=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def doc(pid, gid=GAME, version=0, created='2026-10-25T00:00:00Z'):
    return dict(id=pid, packageId=gid, version=version, created=created, modified=created,
                name='Synthetic migration fixture', description='', locations=[], records=[],
                reserved_codes=[], builds=[])


def save(d, revision, activate=True):
    literal = json.dumps(d).replace("'", "''")
    return f"select (public.save_workshop_project('{literal}'::jsonb,{revision},{str(activate).lower()})).revision;"


def publish(pid, gid, version, revision):
    path = f'{pid}/{version}/' + 'a' * 64 + '.rpgpack'
    return AUTH + f"""insert into storage.objects(bucket_id,name,metadata)
values('player-releases','{path}','{{"size":123}}');
select public.publish_player_release('{pid}',{revision},{version},'{path}','{'a'*64}',123);"""


processes = []


def start(sql):
    process = subprocess.Popen(BASE + ['-d', DB], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    processes.append(process)
    process.stdin.write("\\set VERBOSITY verbose\n" + sql + '\n')
    process.stdin.flush()
    return process


def finish(process, suffix=''):
    out, err = process.communicate(suffix, timeout=15)
    return process.returncode, out, err


def blocked(name):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if run(f"select count(*) from pg_stat_activity where datname='{DB}' and application_name='{name}' and wait_event_type='Lock';") == '1':
            return
        time.sleep(0.02)
    raise AssertionError('concurrent connection did not reach real lock barrier')


try:
    run(f'create database {DB};', 'postgres')
    bootstrap = (BACKEND / 'test-bootstrap.sql').read_text()
    bootstrap = bootstrap.replace('create role anon nologin;', '').replace('create role authenticated nologin;', '')
    run(bootstrap)
    for name in ['schema.sql', 'account-update.sql', 'player-updates.sql']:
        run((BACKEND / name).read_text())
    run(f"insert into auth.users(id,email,email_confirmed_at) values('{OWNER}','migration@example.test',now());")
    run(AUTH + save(doc(A, created='2020-01-01T00:00:00Z'), 0))
    run(AUTH + save(doc(B, version=5), 0))
    run(publish(B, GAME, 5, 1))
    for revision in range(1, 8):
        run(AUTH + save(doc(B), revision))
    run(AUTH + save(doc(C, C, version=50), 0))
    run(AUTH + save({**doc(C, C, version=50), 'name': 'Edited after manual package version 50'}, 1))
    run(AUTH + save(doc(D, D), 0, False))
    run(AUTH + save(doc(E, E, version=3), 0))
    run(publish(E, E, 3, 1))
    run(AUTH + f"select public.delete_workshop_project('{E}',1);")
    migration = (BACKEND / 'player-auto-sync.sql').read_text()
    run(AUTH + save(doc(C, C, version=9007199254740991), 2))
    limit_result = subprocess.run(BASE + ['-d', DB], input="\\set VERBOSITY verbose\n" + migration,
                                  text=True, capture_output=True, timeout=30)
    assert limit_result.returncode != 0 and '23514:' in limit_result.stderr, limit_result.stderr
    assert run("select count(*) from information_schema.columns where table_schema='public' and table_name='workshop_projects' and column_name='player_version';") == '0'
    print('PASS exhausted version ceiling aborts first migration atomically with clear error')
    run(AUTH + save({**doc(C, C, version=50), 'name': 'Edited after manual package version 50'}, 3))
    run(migration)
    assert run(f"select project_id from public.player_auto_sources where game_id='{GAME}';") == B
    print('PASS existing publisher owns game before older imported active project')
    assert run(f"select player_version from public.workshop_projects where id='{B}';") == '9'
    assert run(f"select player_version from public.workshop_projects where id='{C}';") == '51'
    print('PASS initial migration version strictly exceeds old package/published versions including edited document v50')
    assert run(f"select project_id from public.player_auto_sources where game_id='{E}';") == E
    print('PASS historical deleted publisher gets permanent source tombstone')
    assert run(f"set role anon; select jsonb_array_length(public.get_player_catalog());") == '2'
    assert run(f"set role anon; select public.get_player_snapshot('{GAME}')->>'version';") == '9'
    print('PASS existing active project available immediately with no browser save/publication')
    assert run(f"select count(*) from public.player_auto_sources where game_id='{D}';") == '0'
    run(AUTH + save({**doc(B), 'printTemplates': {'private': 'updated'}}, 8))
    run(migration)
    assert run(f"select player_version from public.workshop_projects where id='{B}';") == '9'
    assert run(f"select count(*) from public.player_auto_sources where game_id='{GAME}' and project_id='{B}';") == '1'
    print('PASS rerunning migration preserves version despite master-only revision increase')
    run(AUTH + save(doc(D, D), 1))
    assert run(f"select player_version from public.workshop_projects where id='{D}';") == '3'
    assert run(f"select count(*) from public.player_auto_sources where game_id='{D}';") == '1'
    print('PASS activation binds unpublished staged source and increments version')
    run(f"update public.workshop_projects set status='importing' where id='{D}';")
    assert run(f"select player_version from public.workshop_projects where id='{D}';") == '4'
    assert run(f"set role anon; select public.get_player_snapshot('{D}') is null;") == 't'
    print('PASS deactivation increments version and immediately hides player snapshot')

    first = start(AUTH + 'begin;' + save({**doc(B), 'name': 'Concurrent first'}, 9) + "select 'ready';")
    assert first.stdout.readline().strip() == '10'
    assert first.stdout.readline().strip() == 'ready'
    second = start(AUTH + "set application_name='auto-save-cas';" + save({**doc(B), 'name': 'Concurrent second'}, 9))
    blocked('auto-save-cas')
    assert finish(first, 'commit;')[0] == 0
    result = finish(second)
    assert result[0] != 0 and '40001:' in result[2], result
    assert run(f"select player_version from public.workshop_projects where id='{B}';") == '10'
    print('PASS concurrent stale saves cannot lose or duplicate player version increments')

    race_game, race_a, race_b = (str(uuid.uuid4()) for _ in range(3))
    first = start(AUTH + 'begin;' + save(doc(race_a, race_game), 0) + "select 'ready';")
    assert first.stdout.readline().strip() == '1'
    assert first.stdout.readline().strip() == 'ready'
    second = start(AUTH + "set application_name='auto-source-race';" + save(doc(race_b, race_game), 0))
    blocked('auto-source-race')
    assert finish(first, 'commit;')[0] == 0
    assert finish(second)[0] == 0
    assert run(f"select project_id from public.player_auto_sources where game_id='{race_game}';") == race_a
    assert run(f"select count(*) from public.workshop_projects where (document->>'packageId')::uuid='{race_game}';") == '2'
    print('PASS concurrent imported copies retain one canonical auto source')

    register = f"select public.register_player('{race_game}','Concurrent character','{'b'*64}')->>'participant_id';"
    first = start('set role anon; begin;' + register + "select 'ready';")
    participant = first.stdout.readline().strip()
    assert first.stdout.readline().strip() == 'ready'
    second = start("set role anon; set application_name='auto-player-race';" + register)
    blocked('auto-player-race')
    assert finish(first, 'commit;')[0] == 0
    result = finish(second)
    assert result[0] == 0 and result[1].strip() == participant, result
    assert run(f"select count(*) from public.player_participants where game_id='{race_game}';") == '1'
    print('PASS simultaneous registration retries produce exactly one participant')
finally:
    for process in processes:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    run(f'drop database if exists {DB} with (force);', 'postgres')
