#!/usr/bin/env python3
"""Oqtane <-> site bundle (upstream/README.md, "Moving a site").

  transfer.py export --data <row data folder> --bundle <dir>
  transfer.py import --data <row data folder> --bundle <dir> --name <site name>

Works on Oqtane's own SQLite database, data/Oqtane.db, while the container is
running; upstream_transfer.sh restarts it afterwards (TRANSFER_RESTART) because
Oqtane caches pages. A page's content is its text modules (HtmlText) in order.
Import adds one page per bundle page, each with one text module, copying the
home page's settings and permissions, so it is visible to whoever sees Home.
"""
import argparse, base64, datetime, json, mimetypes, os, re, sqlite3, sys

HTMLTEXT = 'Oqtane.Modules.HtmlText, Oqtane.Client'


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', (s or 'page').lower()).strip('-')
    return s or 'page'


def db(data):
    path = os.path.join(data, 'data', 'Oqtane.db')
    if not os.path.isfile(path):
        sys.exit(f'No Oqtane database at {path}: has this Oqtane finished installing?')
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    return c


def export(data, bundle):
    c = db(data)
    os.makedirs(os.path.join(bundle, 'pages'), exist_ok=True)
    site = {'name': c.execute('select Name from Site order by SiteId').fetchone()[0], 'pages': []}
    pages = c.execute("""select PageId, Name, Path from Page
                         where SiteId = 1 and IsDeleted = 0 and IsNavigation = 1 and Path not like 'admin%'
                         order by [Order]""").fetchall()
    seen = set()
    for p in pages:
        parts = []
        for m in c.execute("""select pm.Title, h.Content from PageModule pm
                              join Module m on m.ModuleId = pm.ModuleId
                              join HtmlText h on h.ModuleId = m.ModuleId
                              where pm.PageId = ? and pm.IsDeleted = 0 and m.ModuleDefinitionName = ?
                              and h.HtmlTextId = (select max(HtmlTextId) from HtmlText where ModuleId = m.ModuleId)
                              order by pm.Pane, pm.[Order]""", (p['PageId'], HTMLTEXT)):
            heading = m['Title'] if m['Title'] and m['Title'] != p['Name'] else ''
            parts.append((f'<h2>{heading}</h2>' if heading else '') + (m['Content'] or ''))
        s, n = slug(p['Path'] or 'home'), 2
        while s in seen:
            s, n = f'{slug(p["Path"] or "home")}-{n}', n + 1
        seen.add(s)
        open(os.path.join(bundle, 'pages', s + '.html'), 'w', encoding='utf-8').write('\n'.join(parts))
        site['pages'].append({'title': p['Name'], 'slug': s, 'order': len(site['pages'])})
    json.dump(site, open(os.path.join(bundle, 'site.json'), 'w'), indent=1)
    print(f'Exported {len(site["pages"])} page(s) from Oqtane. Images stay on the Oqtane site and are linked, not copied.')


def inline_assets(html, bundle):
    # Oqtane keeps files in its own file manager, which a text module cannot
    # write into; small images travel inside the page instead.
    def repl(m):
        p = os.path.join(bundle, 'assets', m.group(2))
        if not os.path.isfile(p) or os.path.getsize(p) > 2_000_000:
            return m.group(0)
        mime = mimetypes.guess_type(p)[0] or 'application/octet-stream'
        return m.group(1) + f'data:{mime};base64,' + base64.b64encode(open(p, 'rb').read()).decode()
    return re.sub(r'(["(])assets/([^"?)]+)', repl, html)


def copy_row(c, table, row, **changes):
    cols = [k for k in row.keys() if k != f'{table}Id']
    vals = [changes.get(k, row[k]) for k in cols]
    cur = c.execute(f'insert into [{table}] ({",".join(f"[{k}]" for k in cols)}) values ({",".join("?" * len(cols))})', vals)
    return cur.lastrowid


def import_(data, bundle, name):
    site = json.load(open(os.path.join(bundle, 'site.json')))
    c = db(data)
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S.%f')
    home = c.execute("select * from Page where SiteId = 1 and Path = '' and IsDeleted = 0").fetchone()
    home_pm = c.execute("""select pm.* from PageModule pm join Module m on m.ModuleId = pm.ModuleId
                           where pm.PageId = ? and m.ModuleDefinitionName = ? order by pm.[Order]""",
                        (home['PageId'], HTMLTEXT)).fetchone()
    if not home or not home_pm:
        sys.exit('This Oqtane has no Home page with a text module to copy settings from.')
    home_mod = c.execute('select * from Module where ModuleId = ?', (home_pm['ModuleId'],)).fetchone()
    page_perms = c.execute("select * from Permission where EntityName = 'Page' and EntityId = ?", (home['PageId'],)).fetchall()
    mod_perms = c.execute("select * from Permission where EntityName = 'Module' and EntityId = ?", (home_mod['ModuleId'],)).fetchall()
    taken = {r[0] for r in c.execute('select Path from Page where SiteId = 1')}
    order = (c.execute('select max([Order]) from Page where SiteId = 1 and ParentId is null and Path not like ?', ('admin%',)).fetchone()[0] or 0)

    for p in sorted(site['pages'], key=lambda p: p['order']):
        html = open(os.path.join(bundle, 'pages', p['slug'] + '.html'), encoding='utf-8').read()
        css_file = os.path.join(bundle, 'pages', p['slug'] + '.css')
        css = open(css_file, encoding='utf-8').read() if os.path.isfile(css_file) else ''
        content = (f'<style>{css}</style>' if css.strip() else '') + inline_assets(html, bundle)
        path, n = p['slug'], 2
        while path in taken:
            path, n = f'{p["slug"]}-{n}', n + 1
        taken.add(path)
        order += 2
        page_id = copy_row(c, 'Page', home, Name=p['title'], Path=path, Order=order, ParentId=None, Title=None,
                           IsNavigation=1, IsPersonalizable=0, CreatedOn=now, ModifiedOn=now, IsDeleted=0)
        module_id = copy_row(c, 'Module', home_mod, CreatedOn=now, ModifiedOn=now, AllPages=0)
        copy_row(c, 'PageModule', home_pm, PageId=page_id, ModuleId=module_id, Title=p['title'], Order=1,
                 CreatedOn=now, ModifiedOn=now, IsDeleted=0)
        c.execute('insert into HtmlText (ModuleId, Content, CreatedBy, CreatedOn, ModifiedBy, ModifiedOn) values (?, ?, ?, ?, ?, ?)',
                  (module_id, content, '', now, '', now))
        for r in page_perms:
            copy_row(c, 'Permission', r, EntityId=page_id, CreatedOn=now, ModifiedOn=now)
        for r in mod_perms:
            copy_row(c, 'Permission', r, EntityId=module_id, CreatedOn=now, ModifiedOn=now)
    c.commit()
    print(f'Imported {len(site["pages"])} page(s) into Oqtane as new pages (from "{name}").')


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
