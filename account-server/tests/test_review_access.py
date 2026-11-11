from dataclasses import replace
import pytest
from smooth_accounts.security import digest
from tests.test_accounts import env, login

EMAIL = 'store-review@review.smoothplayer.invalid'
CODE = '58371942'  # Local test fixture only; never a production credential.

def enable(env):
    env[1].c = replace(env[1].c, review_email=EMAIL, review_code_digest=digest(CODE))
    env[1].c.validate()

def sign_in(env, code=CODE):
    response = env[0].post('/v1/auth/code', json={'email': EMAIL})
    assert response.status_code == 200
    return env[0].post('/v1/auth/verify', json={'challengeId': response.json()['challengeId'], 'code': code})

def test_disabled_by_default(env):
    assert env[0].post('/v1/auth/code', json={'email': EMAIL}).status_code == 400

def test_demo_reusable_no_mail_and_no_admin(env):
    enable(env)
    a=sign_in(env); assert a.status_code == 200
    assert EMAIL not in env[2].codes
    headers={'Authorization':'Bearer '+a.json()['token']}
    assert env[0].get('/v1/me',headers=headers).json()['isAdmin'] is False
    assert env[0].get('/v1/admin/overview',headers=headers).status_code == 403
    env[4][0]+=61
    b=sign_in(env); assert b.status_code==200
    assert b.json()['userId']==a.json()['userId']

def test_review_code_never_authenticates_real_account(env):
    enable(env)
    ch=env[0].post('/v1/auth/code',json={'email':'normal@example.test'}).json()['challengeId']
    assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':CODE}).status_code==401
    assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':env[2].codes['normal@example.test']}).status_code==200

def test_lockout_expiry_single_use_and_no_random_otp_fallback(env):
    enable(env)
    ch=env[0].post('/v1/auth/code',json={'email':EMAIL}).json()['challengeId']
    for _ in range(5):assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':'00000000'}).status_code==401
    assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':CODE}).status_code==401
    env[4][0]+=61
    ch=env[0].post('/v1/auth/code',json={'email':EMAIL}).json()['challengeId']
    env[4][0]+=601
    assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':CODE}).status_code==401
    ch=env[0].post('/v1/auth/code',json={'email':EMAIL}).json()['challengeId']
    body={'challengeId':ch,'code':CODE}
    assert env[0].post('/v1/auth/verify',json=body).status_code==200
    assert env[0].post('/v1/auth/verify',json=body).status_code==401

def test_disable_revokes_session_and_outstanding_challenge(env):
    enable(env);a=sign_in(env).json();env[4][0]+=61
    ch=env[0].post('/v1/auth/code',json={'email':EMAIL}).json()['challengeId']
    env[1].c=replace(env[1].c,review_email='',review_code_digest='')
    assert env[0].get('/v1/me',headers={'Authorization':'Bearer '+a['token']}).status_code==401
    assert env[0].post('/v1/auth/verify',json={'challengeId':ch,'code':CODE}).status_code==401

def test_regular_user_data_is_isolated_and_demo_deletion_works(env):
    normal, original=login(env)
    enable(env);a=sign_in(env).json()
    assert a['userId']!=original['userId']
    headers={'Authorization':'Bearer '+a['token']}
    assert env[0].delete('/v1/account',headers=headers).status_code==200
    assert env[0].get('/v1/me',headers=normal).status_code==200
    env[4][0]+=61
    assert sign_in(env).status_code==200

@pytest.mark.parametrize('changes',[{'review_email':'owner@gmail.com'},{'review_email':'UPPER@review.smoothplayer.invalid'},{'review_code_digest':'bad'},{'review_code_digest':''}])
def test_invalid_review_configuration(env,changes):
    c=replace(env[1].c,review_email=EMAIL,review_code_digest=digest(CODE))
    with pytest.raises(ValueError):replace(c,**changes).validate()
