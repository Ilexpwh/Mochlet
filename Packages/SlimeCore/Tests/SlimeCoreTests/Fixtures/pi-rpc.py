#!/usr/bin/python3
"""Deterministic Pi 1.4.0 RPC peer; never invokes a model or executes tools."""
import json
import os
import sys
import uuid

if '--version' in sys.argv:
    print('1.4.0')
    sys.exit(0)

for flag in ['--offline', '--no-extensions', '--no-mcp', '--no-skills', '--no-approve']:
    assert flag in sys.argv
assert os.path.isfile(sys.argv[sys.argv.index('-e') + 1])
mode = os.environ.get('MOCHLET_PI_FIXTURE', 'normal')
folder = sys.argv[sys.argv.index('--session-dir') + 1]
sid = str(uuid.uuid4())
file = os.path.join(folder, sid + '.jsonl')
if '--session' in sys.argv:
    file = sys.argv[sys.argv.index('--session') + 1]
    with open(file) as source:
        header = json.loads(source.readline())
    sid = header['id']
    assert header['cwd'] == os.getcwd()
cleared = False

def emit(value):
    data = json.dumps(value) + '\n'
    for offset in range(0, len(data), 3):
        sys.stdout.write(data[offset:offset + 3])
        sys.stdout.flush()

def reply(command, data):
    emit(dict(type='response', id=command['id'], command=command['type'], success=True, data=data))

def finish():
    emit(dict(type='message_update', assistantMessageEvent=dict(type='text_delta', contentIndex=0, delta='provisional')))
    emit(dict(type='message_end', message=dict(role='assistant', content=[dict(type='text', text='PI_FIXTURE_OK')], stopReason='stop')))
    emit(dict(type='agent_end'))
    emit(dict(type='agent_settled', aborted=False))
    emit(dict(type='agent_settled', aborted=False))  # terminal duplicates are inert

for line in sys.stdin:
    command = json.loads(line)
    if os.environ.get('MOCHLET_PI_TRACE'):
        with open(os.environ['MOCHLET_PI_TRACE'], 'a') as trace:
            trace.write(json.dumps(command) + '\n')
    kind = command['type']
    if kind == 'get_state':
        reply(command, dict(sessionId=sid, sessionFile=file, isStreaming=False, isCompacting=False, pendingMessageCount=0))
    elif kind == 'prompt' and command['message'].startswith('/mochlet-guard-check '):
        if mode != 'missing_guard':
            guard = dict(mochletGuard=1, nonce=os.environ['MOCHLET_PI_NONCE'], cwd='/Users' if mode == 'wrong_cwd' else os.getcwd(),
                         sessionID=sid, sessionFile=file, tools=sys.argv[sys.argv.index('--tools') + 1].split(','),
                         readOnly=os.environ['MOCHLET_PI_READ_ONLY'] == '1')
            emit(dict(type='extension_ui_request', method='notify', message=json.dumps(guard)))
        reply(command, dict(disposition='handled'))
    elif kind == 'prompt':
        if mode == 'crash':
            sys.exit(9)
        with open(file, 'a') as session:
            if session.tell() == 0:
                session.write(json.dumps(dict(type='session', version=3, id=sid, cwd=os.getcwd())) + '\n')
        reply(command, dict(disposition='started'))
        emit(dict(type='extension_ui_request', id='approval', method='confirm', title='Fixture approval', message='echo fixture', timeout=30000))
    elif kind == 'extension_ui_response':
        if mode == 'cancel':
            assert command.get('cancelled') is True
        elif command['id'] == 'approval':
            assert command.get('confirmed') is False
            emit(dict(type='extension_ui_request', id='choice', method='select', title='Choose a fixture destination', options=['Mochlet', 'Other project']))
        else:
            assert command['id'] == 'choice' and command['value'] == 'Mochlet'
            finish()
    elif kind == 'get_session_stats':
        if mode == 'no_stats':
            continue  # timeout must not erase a completed turn
        reply(command, dict(tokens=dict(input=12, output=3), cost=0.001))
    elif kind == 'clear_queue':
        cleared = True
        reply(command, dict(steering=['Keep this unsent instruction'], followUp=[]))
    elif kind == 'abort':
        assert cleared
        reply(command, {})
        emit(dict(type='agent_settled', aborted=True))
    else:
        raise AssertionError(kind)
