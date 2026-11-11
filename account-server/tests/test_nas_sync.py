import copy
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
import pytest
from .test_accounts import env, login

S = 'server:11111111-1111-1111-1111-111111111111'
R = 'recent:22222222-2222-2222-2222-222222222222'
SERVER = dict(kind='server', name='fixture NAS', protocol='ftp', host='nas.example.test', port=21,
              share='', rootPath='/', username='fixture-member', password='fixture-secret-한글', domain='', ftpEncoding='automatic')
RECENT = dict(kind='recent', connectionID=S[7:], path='/Movies/한글.mkv', encodedPath=None, name='한글.mkv',
              position=12.5, duration=80.0, fileSize=4000, modifiedAt=None, openedAt=1790000000.5)

def change(key, value, version=0):
    return dict(id=key, value=copy.deepcopy(value), baseVersion=version)

def sync(env, headers, changes=(), youtube=False):
    body = {'schema': 1, 'changes': list(changes)}
    if youtube:
        body['includeYouTube'] = True
    return env[0].post('/v1/nas/sync', headers=headers, json=body)

def records(response):
    assert response.status_code == 200, response.text
    return {r['id']: r for r in response.json()['records']}

def test_credentials_encrypted_and_account_isolated(env):
    a, session = login(env); b, _ = login(env, 'other@example.test')
    result = records(sync(env, a, [change(S, SERVER), change(R, RECENT)]))
    assert result[S]['value'] == SERVER and result[R]['value'] == RECENT
    raw = env[1].db.one('SELECT state FROM nas_sync WHERE user_id=?', (session['userId'],))[0]
    assert SERVER['password'] not in raw and SERVER['username'] not in raw and RECENT['path'] not in raw
    assert json.loads(env[1].secrets.decrypt(raw))['owner'] == session['userId']
    assert records(sync(env, b)) == {}
    env[4][0] += 61
    same, _ = login(env)
    assert records(sync(env, same)) == result
    assert sync(env, {}).status_code == 401

def test_cas_retry_delete_and_stale_device(env):
    h, _ = login(env)
    initial = [change(S, SERVER), change(R, RECENT)]
    records(sync(env, h, initial))
    assert records(sync(env, h, initial))[S]['version'] == 1
    updated = dict(SERVER, password='new fixture password')
    records(sync(env, h, [change(S, updated, 1)]))
    stale = sync(env, h, [change(S, SERVER, 1)])
    assert stale.json()['conflicts'] == [S] and records(stale)[S]['value'] == updated
    deleted = records(sync(env, h, [change(S, None, 2)]))
    assert deleted[S]['value'] is None and deleted[R]['value'] is None
    stale = sync(env, h, initial)
    assert set(stale.json()['conflicts']) == {S, R}
    assert records(stale)[S]['value'] is None

def test_concurrent_writers_do_not_lose_other_records(env):
    h, _ = login(env)
    keys = ['server:' + str(uuid.uuid4()) for _ in range(8)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda k: sync(env, h, [change(k, SERVER)]), keys))
    assert all(r.status_code == 200 for r in results)
    assert set(records(sync(env, h))) == set(keys)

def test_duplicate_connection_migration_is_retryable_and_stale_device_cannot_resurrect_it(env):
    h, _ = login(env)
    duplicate = 'server:33333333-3333-3333-3333-333333333333'
    old_recent = 'recent:44444444-4444-4444-4444-444444444444'
    previous = dict(RECENT, connectionID=duplicate[7:], position=0, openedAt=RECENT['openedAt'] + 10)
    initial = [change(S, SERVER), change(duplicate, SERVER), change(R, RECENT), change(old_recent, previous)]
    records(sync(env, h, initial))
    # A single client batch re-keys history before the server removes dangling references.
    migration = [change(duplicate, None, 1), change(old_recent, None, 1),
                 change(R, dict(previous, connectionID=S[7:]), 1)]
    result = records(sync(env, h, migration))
    assert result[R]['value']['position'] == 0
    assert result[duplicate]['value'] is None and result[old_recent]['value'] is None
    assert records(sync(env, h, migration)) == result
    stale = sync(env, h, initial)
    assert set(stale.json()['conflicts']) == {duplicate, R, old_recent}
    assert records(stale) == result

@pytest.mark.parametrize('key,value', [
    (R, dict(RECENT, path='file:///private/movie.mkv')),
    (R, dict(RECENT, path='/../movie.mkv', name='movie.mkv')),
    (R, dict(RECENT, encodedPath='/%2e%2e/movie.mkv')),
    (R, dict(RECENT, position=1000)),
    (R, dict(RECENT, bookmark='local-security-bookmark')),
    (S, dict(SERVER, host='member:password@host')),
    (S, dict(SERVER, protocol='file')),
    ('hidden:33333333-3333-3333-3333-333333333333', dict(kind='hidden', scope='file', path='/private', name='secret')),
])
def test_local_data_and_invalid_values_rejected_atomically(env, key, value):
    h, _ = login(env)
    assert sync(env, h, [change(key, value)]).status_code == 400
    assert records(sync(env, h)) == {}

def test_swift_omitted_null_fields_and_hidden_rules(env):
    h, _ = login(env)
    r = {k:v for k,v in RECENT.items() if v is not None}
    key = 'hidden:33333333-3333-3333-3333-333333333333'
    hidden = dict(kind='hidden', scope='ftp://nas.example.test:21', path='/private', name='private')
    result = records(sync(env, h, [change(S, SERVER), change(R, r), change(key, hidden)]))
    assert result[R]['value'] == RECENT and result[key]['value'] == hidden

def test_delete_account_erases_nas_credentials(env):
    h, session = login(env)
    records(sync(env, h, [change(S, SERVER)]))
    assert env[0].delete('/v1/account', headers=h).status_code == 200
    assert env[1].db.one('SELECT state FROM nas_sync WHERE user_id=?', (session['userId'],)) is None
    assert sync(env, h).status_code == 401

def test_limits_and_no_orphan_recents(env):
    h, _ = login(env)
    assert sync(env, h, [change(R, RECENT)]).status_code == 400
    assert sync(env, h, [change(S, SERVER), change(S, SERVER)]).status_code == 400
    big = [change('server:' + str(uuid.uuid4()), dict(SERVER, password='x' * 4096)) for _ in range(128)]
    assert sync(env, h, big).status_code == 413
    assert records(sync(env, h)) == {}


def test_history_capacity_creates_tombstones_and_keeps_latest(env):
    h, _ = login(env)
    changes = [change(S, SERVER)]
    for i in range(501):
        changes.append(change('recent:' + str(uuid.uuid4()), dict(RECENT, path=f'/movie{i}.mkv', name=f'movie{i}.mkv', openedAt=i)))
    values = records(sync(env, h, changes))
    active = [r['value'] for r in values.values() if r['value'] and r['value']['kind'] == 'recent']
    assert len(active) == 500 and min(r['openedAt'] for r in active) == 1
    assert sum(r['value'] is None for r in values.values()) == 1

@pytest.mark.parametrize('wire', ['/%00/movie.mkv', '/%5c/movie.mkv', '/%0a/movie.mkv'])
def test_encoded_control_paths_are_rejected(env, wire):
    h, _ = login(env)
    assert sync(env, h, [change(S, SERVER), change(R, dict(RECENT, encodedPath=wire))]).status_code == 400
    assert records(sync(env, h)) == {}

def test_privacy_link_matches_current_credential_processing(env):
    response = env[0].get('/privacy.html')
    assert response.status_code == 200
    assert 'NAS 동기화에는' in response.text and '암호화해 저장' in response.text

Y = 'youtube:e6e1747c-f18e-9fee-550d-d248701467c8'
YOUTUBE = dict(kind='youtube', videoID='aDlDyJM5fd8', title='한글 공개 영상', position=37.5, duration=196, openedAt=1790000001)

def test_youtube_cross_device_and_legacy_clients_are_isolated(env):
    a, session = login(env)
    b, _ = login(env, 'other@example.test')
    result = records(sync(env, a, [change(S, SERVER), change(Y, YOUTUBE)], youtube=True))
    assert result[Y]['value'] == YOUTUBE
    assert set(records(sync(env, a))) == {S}  # old Mac/iPad/Android never see a new kind
    records(sync(env, a, [change(S, dict(SERVER, name='Legacy edit'), 1)]))
    assert records(sync(env, a, youtube=True))[Y] == result[Y]
    assert records(sync(env, b, youtube=True)) == {}
    assert sync(env, a, [change(Y, None, 1)]).status_code == 400
    raw = env[1].db.one('SELECT state FROM nas_sync WHERE user_id=?', (session['userId'],))[0]
    assert YOUTUBE['videoID'] not in raw and YOUTUBE['title'] not in raw

def test_youtube_latest_watch_wins_but_deletion_blocks_stale_resurrection(env):
    h, _ = login(env)
    records(sync(env, h, [change(Y, YOUTUBE)], youtube=True))
    finished = dict(YOUTUBE, position=0, openedAt=YOUTUBE['openedAt'] + 20)
    result = records(sync(env, h, [change(Y, finished)], youtube=True))
    assert result[Y]['value'] == finished and result[Y]['version'] == 2
    stale = sync(env, h, [change(Y, YOUTUBE, 1)], youtube=True)
    assert stale.json()['conflicts'] == [Y] and records(stale)[Y]['value'] == finished
    result = records(sync(env, h, [change(Y, None, 2)], youtube=True))
    assert result[Y]['value'] is None
    assert records(sync(env, h, [change(Y, dict(finished, openedAt=finished['openedAt'] + 1), 2)], youtube=True))[Y]['value'] is None
    assert records(sync(env, h)) == {}
    assert env[0].delete('/v1/account', headers=h).status_code == 200
    assert sync(env, h, youtube=True).status_code == 401

@pytest.mark.parametrize('value', [dict(YOUTUBE, videoID='../private!'), dict(YOUTUBE, videoID='bbbbbbbbbbb'),
    dict(YOUTUBE, position=200), dict(YOUTUBE, duration=0), dict(YOUTUBE, url='https://signed.googlevideo.com/private')])
def test_youtube_rejects_noncanonical_or_private_payloads(env, value):
    h, _ = login(env)
    assert sync(env, h, [change(Y, value)], youtube=True).status_code == 400
    assert records(sync(env, h, youtube=True)) == {}

def test_youtube_retention_is_separate_from_nas(env):
    import hashlib
    h, _ = login(env)
    changes = [change(S, SERVER), change(R, RECENT)]
    for i in range(101):
        video = f'{i:011d}'
        key = 'youtube:' + str(uuid.UUID(bytes=hashlib.sha256(video.encode()).digest()[:16]))
        changes.append(change(key, dict(YOUTUBE, videoID=video, openedAt=i)))
    result = records(sync(env, h, changes, youtube=True))
    active = [r['value'] for r in result.values() if r['value'] and r['value']['kind'] == 'youtube']
    assert len(active) == 100 and min(r['openedAt'] for r in active) == 1
    assert result[R]['value'] == RECENT
