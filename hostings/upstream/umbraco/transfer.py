#!/usr/bin/env python3
"""Umbraco <-> site bundle (upstream/README.md, "Moving a site").

  transfer.py export --data <row data folder> --bundle <dir>
  transfer.py import --data <row data folder> --bundle <dir> --name <site name>

Talks to Umbraco's Management API on its local port (UPSTREAM_PORT), signed in
as the unattended Admin: e-mail from the unit (UPSTREAM_UNIT), password from
the row's secrets (UPSTREAM_SECRETS). The sign-in is the backoffice's own
flow: login, authorize with PKCE, token.

Import makes, once, a document type "Transfer page" with one rich-text field
and a template that prints it, then one published page per bundle page.
Export reads every document's text and rich-text values.
"""
import argparse, base64, hashlib, http.cookiejar, json, os, re, secrets, sys, urllib.error, urllib.parse, urllib.request, uuid

API = '/umbraco/management/api/v1'
DOCTYPE_ALIAS = 'transferPage'
TEMPLATE = """@inherits Umbraco.Cms.Web.Common.Views.UmbracoViewPage
@{ Layout = null; }
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>@Model.Name</title></head>
<body>@Model.Value("body")</body></html>
"""


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', (s or 'page').lower()).strip('-')
    return s or 'page'


class Umbraco:
    def __init__(self):
        port = os.environ.get('UPSTREAM_PORT')
        if not port:
            sys.exit('UPSTREAM_PORT is not set: run this through upstream_transfer.sh.')
        self.base = f'http://127.0.0.1:{port}'
        jar = http.cookiejar.CookieJar()

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        self.web = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)
        self.token = None

    def call(self, method, path, body=None, form=None, auth=True):
        headers = {'Accept': 'application/json'}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        elif form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        if auth and self.token:
            headers['Authorization'] = f'Bearer {self.token}'
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            r = self.web.open(req, timeout=60)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303):
                return e.code, e.headers, b''
            raise SystemExit(f'Umbraco {method} {path}: HTTP {e.code} {e.read()[:600].decode(errors="replace")}')
        return r.status, r.headers, r.read()

    def sign_in(self):
        unit = open(os.environ['UPSTREAM_UNIT']).read()
        email = re.search(r'UnattendedUserEmail=([^"\s]+)', unit).group(1)
        password = next(l.split('=', 1)[1].strip() for l in open(os.environ['UPSTREAM_SECRETS'])
                        if l.startswith('Umbraco__CMS__Unattended__UnattendedUserPassword='))
        self.call('POST', f'{API}/security/back-office/login', {'username': email, 'password': password}, auth=False)
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        redirect = f'{self.base}/umbraco/oauth_complete'
        q = urllib.parse.urlencode({'client_id': 'umbraco-back-office', 'response_type': 'code', 'redirect_uri': redirect,
                                    'code_challenge': challenge, 'code_challenge_method': 'S256', 'scope': 'offline_access'})
        code, headers, _ = self.call('GET', f'{API}/security/back-office/authorize?{q}', auth=False)
        loc = headers.get('Location', '') if code in (301, 302, 303) else ''
        got = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get('code')
        if not got:
            sys.exit(f'Umbraco did not hand out a sign-in code (redirected to {loc or "nowhere"}).')
        _, _, body = self.call('POST', f'{API}/security/back-office/token', form={
            'grant_type': 'authorization_code', 'client_id': 'umbraco-back-office', 'code': got[0],
            'redirect_uri': redirect, 'code_verifier': verifier}, auth=False)
        self.token = json.loads(body)['access_token']

    def get(self, path):
        return json.loads(self.call('GET', API + path)[2] or b'null')

    def create(self, path, body):
        _, headers, _ = self.call('POST', API + path, body)
        return headers.get('Location', '').rstrip('/').split('/')[-1]


def export(data, bundle):
    u = Umbraco()
    u.sign_in()
    os.makedirs(os.path.join(bundle, 'pages'), exist_ok=True)
    site = {'name': 'Umbraco site', 'pages': []}
    seen = set()

    def walk(parent):
        path = '/tree/document/root?skip=0&take=500' if parent is None else f'/tree/document/children?parentId={parent}&skip=0&take=500'
        for item in u.get(path)['items']:
            doc = u.get(f'/document/{item["id"]}')
            name = (doc.get('variants') or [{}])[0].get('name') or 'Page'
            parts = []
            for v in doc.get('values', []):
                val = v.get('value')
                if isinstance(val, dict) and isinstance(val.get('markup'), str):
                    parts.append(val['markup'])
                elif isinstance(val, str) and val.strip() and not re.fullmatch(r'[0-9a-f-]{36}', val):
                    parts.append(val if val.lstrip().startswith('<') else f'<p>{val}</p>')
            s, n = slug(name), 2
            while s in seen:
                s, n = f'{slug(name)}-{n}', n + 1
            seen.add(s)
            open(os.path.join(bundle, 'pages', s + '.html'), 'w', encoding='utf-8').write('\n'.join(parts))
            site['pages'].append({'title': name, 'slug': s, 'order': len(site['pages'])})
            if item.get('hasChildren'):
                walk(item['id'])
    walk(None)
    json.dump(site, open(os.path.join(bundle, 'site.json'), 'w'), indent=1)
    print(f'Exported {len(site["pages"])} page(s) from Umbraco. Media stays in Umbraco and is linked, not copied.')


def ensure_page_type(u):
    for item in u.get('/tree/document-type/root?skip=0&take=500').get('items', []):
        if item.get('isFolder'):
            continue
        dt = u.get(f'/document-type/{item["id"]}')
        if dt.get('alias') == DOCTYPE_ALIAS:
            return dt['id'], (dt.get('defaultTemplate') or {}).get('id')
    template_id = u.create('/template', {'name': 'Transfer page', 'alias': DOCTYPE_ALIAS, 'content': TEMPLATE})
    rte = next((d for d in u.get('/filter/data-type?skip=0&take=100&name=Rich')['items']
                if d.get('editorAlias') == 'Umbraco.RichText'), None)
    if not rte:
        sys.exit('Umbraco has no rich-text data type to build the page type on.')
    tab = str(uuid.uuid4())
    dt_id = u.create('/document-type', {
        'alias': DOCTYPE_ALIAS, 'name': 'Transfer page', 'icon': 'icon-document',
        'allowedAsRoot': True, 'variesByCulture': False, 'variesBySegment': False, 'isElement': False,
        'containers': [{'id': tab, 'name': 'Content', 'type': 'Tab', 'sortOrder': 0}],
        'properties': [{'id': str(uuid.uuid4()), 'container': {'id': tab}, 'sortOrder': 0, 'alias': 'body',
                        'name': 'Body', 'dataType': {'id': rte['id']}, 'variesByCulture': False, 'variesBySegment': False,
                        'validation': {'mandatory': False}, 'appearance': {'labelOnTop': False}}],
        'allowedTemplates': [{'id': template_id}], 'defaultTemplate': {'id': template_id},
        'cleanup': {'preventCleanup': False}, 'allowedDocumentTypes': [], 'compositions': [],
    })
    return dt_id, template_id


def import_(data, bundle, name):
    site = json.load(open(os.path.join(bundle, 'site.json')))
    u = Umbraco()
    u.sign_in()
    dt_id, template_id = ensure_page_type(u)
    for p in sorted(site['pages'], key=lambda p: p['order']):
        html = open(os.path.join(bundle, 'pages', p['slug'] + '.html'), encoding='utf-8').read()
        css_file = os.path.join(bundle, 'pages', p['slug'] + '.css')
        css = open(css_file, encoding='utf-8').read() if os.path.isfile(css_file) else ''
        markup = (f'<style>{css}</style>' if css.strip() else '') + html
        doc_id = u.create('/document', {
            'parent': None, 'documentType': {'id': dt_id}, 'template': {'id': template_id},
            'values': [{'alias': 'body', 'culture': None, 'segment': None, 'value': {'markup': markup, 'blocks': None}}],
            'variants': [{'culture': None, 'segment': None, 'name': p['title']}],
        })
        u.call('PUT', f'{API}/document/{doc_id}/publish', {'publishSchedules': [{'culture': None}]})
    print(f'Imported {len(site["pages"])} page(s) into Umbraco as published "Transfer page" documents (from "{name}").')


def main():
    a = argparse.ArgumentParser()
    a.add_argument('verb', choices=['export', 'import'])
    a.add_argument('--data', required=True)
    a.add_argument('--bundle', required=True)
    a.add_argument('--name', default='Imported site')
    o = a.parse_args()
    export(o.data, o.bundle) if o.verb == 'export' else import_(o.data, o.bundle, o.name)


if __name__ == '__main__':
    main()
