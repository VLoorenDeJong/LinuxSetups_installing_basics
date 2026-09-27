#!/usr/bin/env python3
"""Silex <-> site bundle (upstream/README.md, "Moving a site").

  transfer.py export --data <row data folder> --bundle <dir>
  transfer.py import --data <row data folder> --bundle <dir> --name <site name>

Export reads what Silex last PUBLISHED into hosting/, because that is Silex's
own rendering of the pages. Silex publishes every site of an editor into the
same folder, so it is the site published last.
Import adds a new site to storage/, which the dashboard lists at once.
"""
import argparse, json, os, re, shutil, sys, time

BODY = re.compile(r'<body[^>]*>(.*)</body>', re.S | re.I)
TITLE = re.compile(r'<title>(.*?)</title>', re.S | re.I)
CSS_LINK = re.compile(r'<link[^>]+href="(/css/[^"]+\.css)"', re.I)


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', (s or 'page').lower()).strip('-')
    return s or 'page'


def export(data, bundle):
    hosting = os.path.join(data, 'hosting')
    pages_html = sorted(f for f in os.listdir(hosting) if f.endswith('.html')) if os.path.isdir(hosting) else []
    if not pages_html:
        sys.exit('Nothing published in this Silex yet: press Publish in the editor first.')
    # Home first, then alphabetical: the published files carry no order.
    pages_html.sort(key=lambda f: (f not in ('index.html', 'home.html'), f))
    os.makedirs(os.path.join(bundle, 'pages'), exist_ok=True)
    site = {'name': 'Silex site', 'pages': []}
    for order, f in enumerate(pages_html):
        text = open(os.path.join(hosting, f), encoding='utf-8').read()
        name = f[:-5]
        title_m = TITLE.search(text)
        title = (title_m.group(1).strip() if title_m and title_m.group(1).strip() else name.replace('-', ' ').title())
        body = BODY.search(text)
        html = body.group(1).strip() if body else text
        html = html.replace('"/assets/', '"assets/')
        css = ''
        for href in CSS_LINK.findall(text):
            p = os.path.join(hosting, href.lstrip('/'))
            if os.path.isfile(p):
                css += open(p, encoding='utf-8').read() + '\n'
        s = slug(name)
        open(os.path.join(bundle, 'pages', s + '.html'), 'w', encoding='utf-8').write(html)
        open(os.path.join(bundle, 'pages', s + '.css'), 'w', encoding='utf-8').write(css)
        site['pages'].append({'title': title, 'slug': s, 'order': order})
    if os.path.isdir(os.path.join(hosting, 'assets')):
        shutil.copytree(os.path.join(hosting, 'assets'), os.path.join(bundle, 'assets'), dirs_exist_ok=True)
    json.dump(site, open(os.path.join(bundle, 'site.json'), 'w'), indent=1)
    print(f'Exported {len(site["pages"])} page(s) from the last Silex publish.')


def import_(data, bundle, name):
    site = json.load(open(os.path.join(bundle, 'site.json')))
    site_id = f'{slug(name)}-{time.strftime("%Y%m%d%H%M%S")}'
    target = os.path.join(data, 'storage', site_id)
    os.makedirs(os.path.join(target, 'assets'))
    asset_url = f'/api/website/assets/{{}}?websiteId={site_id}&connectorId=fs-storage'
    if os.path.isdir(os.path.join(bundle, 'assets')):
        shutil.copytree(os.path.join(bundle, 'assets'), os.path.join(target, 'assets'), dirs_exist_ok=True)
    pages = []
    for p in sorted(site['pages'], key=lambda p: p['order']):
        html = open(os.path.join(bundle, 'pages', p['slug'] + '.html'), encoding='utf-8').read()
        css_file = os.path.join(bundle, 'pages', p['slug'] + '.css')
        css = open(css_file, encoding='utf-8').read() if os.path.isfile(css_file) else ''
        html = re.sub(r'(["(])assets/([^"?)]+)', lambda m: m.group(1) + asset_url.format(m.group(2)), html)
        component = (f'<style>{css}</style>' if css.strip() else '') + html
        pages.append({'id': f'{p["slug"]}-{len(pages)}', 'name': p['title'], 'frames': [{'component': component}]})
    json.dump({'pages': pages, 'styles': [], 'assets': []}, open(os.path.join(target, 'website.json'), 'w'))
    json.dump({'name': name, 'connectorUserSettings': {}}, open(os.path.join(target, 'meta.json'), 'w'))
    print(f'Imported {len(pages)} page(s) into Silex as the site "{name}" ({site_id}).')


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
