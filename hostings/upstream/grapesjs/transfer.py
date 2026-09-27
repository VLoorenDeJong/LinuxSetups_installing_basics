#!/usr/bin/env python3
"""GrapesJS <-> site bundle (upstream/README.md, "Moving a site").

  transfer.py export --data <row data folder> --bundle <dir>
  transfer.py import --data <row data folder> --bundle <dir> --name <site name>

The wrapper holds ONE project. Export reads data/export.json, which the editor
writes on every save. Import replaces the project; the one it replaces is kept
beside it as project.json.<timestamp>.
"""
import argparse, json, os, re, shutil, sys, time

BODY = re.compile(r'^\s*<body[^>]*>(.*)</body>\s*$', re.S | re.I)


def export(data, bundle):
    src = os.path.join(data, 'data', 'export.json')
    project = os.path.join(data, 'data', 'project.json')
    if os.path.isfile(src):
        pages = json.load(open(src))['pages']
    elif os.path.isfile(project):
        # Imported but not opened since: its pages are still the HTML the
        # import wrote, which is exactly what a bundle needs.
        pages = []
        for i, p in enumerate(json.load(open(project)).get('pages', [])):
            comp = (p.get('frames') or [{}])[0].get('component')
            if not isinstance(comp, str):
                sys.exit('This GrapesJS project has not been saved as HTML yet: open the editor once, then try again.')
            m = re.match(r'\s*<style>(.*?)</style>(.*)', comp, re.S)
            pages.append({'title': p.get('name') or f'Page {i + 1}', 'slug': re.sub(r'[^a-z0-9]+', '-', (p.get('name') or 'page').lower()).strip('-') or 'page',
                          'order': i, 'html': m.group(2) if m else comp, 'css': m.group(1) if m else ''})
    else:
        sys.exit('Nothing saved in this GrapesJS yet: change something in the editor first.')
    os.makedirs(os.path.join(bundle, 'pages'), exist_ok=True)
    site = {'name': 'GrapesJS site', 'pages': []}
    seen = set()
    for p in sorted(pages, key=lambda p: p['order']):
        s = p['slug']
        while s in seen:
            s += '-2'
        seen.add(s)
        m = BODY.match(p['html'])
        open(os.path.join(bundle, 'pages', s + '.html'), 'w', encoding='utf-8').write(m.group(1) if m else p['html'])
        open(os.path.join(bundle, 'pages', s + '.css'), 'w', encoding='utf-8').write(p.get('css', ''))
        site['pages'].append({'title': p['title'], 'slug': s, 'order': len(site['pages'])})
    json.dump(site, open(os.path.join(bundle, 'site.json'), 'w'), indent=1)
    print(f'Exported {len(site["pages"])} page(s) from GrapesJS.')


def import_(data, bundle, name):
    site = json.load(open(os.path.join(bundle, 'site.json')))
    folder = os.path.join(data, 'data')
    os.makedirs(folder, exist_ok=True)
    project = os.path.join(folder, 'project.json')
    if os.path.isfile(project):
        shutil.copy2(project, f'{project}.{time.strftime("%Y%m%d%H%M%S")}')
    if os.path.isdir(os.path.join(bundle, 'assets')):
        shutil.copytree(os.path.join(bundle, 'assets'), os.path.join(folder, 'assets'), dirs_exist_ok=True)
    pages = []
    for p in sorted(site['pages'], key=lambda p: p['order']):
        html = open(os.path.join(bundle, 'pages', p['slug'] + '.html'), encoding='utf-8').read()
        css_file = os.path.join(bundle, 'pages', p['slug'] + '.css')
        css = open(css_file, encoding='utf-8').read() if os.path.isfile(css_file) else ''
        html = re.sub(r'(["(])assets/', r'\1data/assets/', html)
        component = (f'<style>{css}</style>' if css.strip() else '') + html
        pages.append({'id': f'{p["slug"]}-{len(pages)}', 'name': p['title'], 'frames': [{'component': component}]})
    json.dump({'pages': pages, 'styles': [], 'assets': []}, open(project, 'w'))
    # Stale until the editor saves again, and export would read it.
    stale = os.path.join(folder, 'export.json')
    if os.path.isfile(stale):
        os.remove(stale)
    # nginx owns the folder and must be able to overwrite what was put in it.
    st = os.stat(folder)
    for root, dirs, files in os.walk(folder):
        for n in dirs + files:
            os.chown(os.path.join(root, n), st.st_uid, st.st_gid)
    print(f'Imported {len(pages)} page(s) into GrapesJS as "{name}"; open the editor once to save it.')


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
