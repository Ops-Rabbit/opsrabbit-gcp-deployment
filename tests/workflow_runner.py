"""Offline interpreter for the small Workflows subset used by our backup YAML.

Runs the actual workflow definition, not a second copy of its backup policy.
HTTP and sleep are injected fakes. This is not a Google Workflows emulator or
an API compatibility test; unsupported steps fail closed.
"""
import datetime
import json
import re
import subprocess
import tempfile
from types import SimpleNamespace


class Map(dict):
    def __getattr__(self, key):
        return self[key]


def wrap(value):
    if isinstance(value, dict):
        return Map({key: wrap(item) for key, item in value.items()})
    if isinstance(value, list):
        return [wrap(item) for item in value]
    return value


def map_get(value, keys):
    for key in keys if isinstance(keys, list) else [keys]:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def read_workflow(path):
    # Terraform supplies the YAML parser; use an empty directory so console
    # cannot load the repository's backend, providers, variables, or state.
    with tempfile.TemporaryDirectory() as directory:
        result = subprocess.run(
            ['terraform', 'console', '-no-color'], cwd=directory,
            input=f'jsonencode(yamldecode(file({json.dumps(str(path))})))\n',
            text=True, capture_output=True, check=True, timeout=30,
        )
    return json.loads(json.loads(result.stdout))


class Returned(Exception):
    def __init__(self, value):
        self.value = value


class WorkflowFailure(Exception):
    pass


class Runner:
    def __init__(self, definition, http, env, now):
        self.definition, self.http, self.env, self.now = definition, http, env, now
        self.sleeps = []
        self.steps_run = 0

    def evaluate(self, value, scope):
        if isinstance(value, str) and value.startswith('${') and value.endswith('}'):
            expression = re.sub(r'\b(null|true|false)\b',
                                lambda m: {'null': 'None', 'true': 'True', 'false': 'False'}[m[0]], value[2:-1])
            functions = {
                'sys': SimpleNamespace(now=lambda: self.now, get_env=self.env.__getitem__),
                'map': SimpleNamespace(get=map_get),
                'list': SimpleNamespace(concat=lambda items, item: items + [item]),
                'time': SimpleNamespace(parse=lambda text: datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()),
                'default': lambda item, fallback: fallback if item is None else item,
                'int': int, 'string': str,
            }
            return wrap(eval(expression, {'__builtins__': {}}, functions | scope))
        if isinstance(value, dict):
            return {key: self.evaluate(item, scope) for key, item in value.items()}
        if isinstance(value, list):
            return [self.evaluate(item, scope) for item in value]
        return value

    def run(self, name='main', args=None):
        try:
            self.steps(self.definition[name]['steps'], dict(args or {}))
        except Returned as result:
            return result.value

    def steps(self, steps, scope):
        indices = {next(iter(step)): i for i, step in enumerate(steps)}
        index = 0
        while index < len(steps):
            self.steps_run += 1
            if self.steps_run > 10000:
                raise AssertionError('Workflow exceeded offline execution budget')
            body = next(iter(steps[index].values()))
            next_step = self.step(body, scope)
            index = indices[next_step] if next_step else index + 1

    def step(self, body, scope):
        if 'assign' in body:
            for assignment in body['assign']:
                for key, value in assignment.items():
                    scope[key] = self.evaluate(value, scope)
        elif 'call' in body:
            args = self.evaluate(body.get('args', {}), scope)
            call = body['call']
            if call in ('http.get', 'http.post', 'http.delete'):
                value = wrap(self.http(call, args))
            elif call == 'sys.sleep':
                self.sleeps.append(args['seconds'])
                value = None
            elif call in self.definition:
                value = self.run(call, args)
            else:
                raise AssertionError(f'Unsupported call: {call}')
            if 'result' in body:
                scope[body['result']] = value
        elif 'switch' in body:
            for branch in body['switch']:
                if self.evaluate(branch['condition'], scope):
                    return self.step({k: v for k, v in branch.items() if k != 'condition'}, scope)
        elif 'for' in body:
            loop = body['for']
            for value in self.evaluate(loop['in'], scope):
                scope[loop['value']] = value
                self.steps(loop['steps'], scope)
        elif 'steps' in body:
            self.steps(body['steps'], scope)
        elif 'raise' in body:
            raise WorkflowFailure(self.evaluate(body['raise'], scope))
        elif 'return' in body:
            raise Returned(self.evaluate(body['return'], scope))
        elif set(body) != {'next'}:
            raise AssertionError(f'Unsupported step: {body}')
        return body.get('next')
