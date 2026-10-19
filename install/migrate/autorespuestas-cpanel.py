#!/usr/bin/env python3
# Lee las respuestas automaticas de cPanel (homedir/.autorespond) y escribe
# una linea por respuesta:
#   cuenta<TAB>dominio<TAB>estado<TAB>mensaje_en_base64
# estado: "ok" o "caducada" (tenia fecha de fin y ya paso).
# cPanel guarda cada una en .autorespond/cuenta@dominio (cabeceras, linea en
# blanco y el texto) y las fechas en cuenta@dominio.json. QemuCP solo admite
# texto: si la respuesta era HTML se convierte a texto.
import base64, html, json, os, re, sys, time

d = sys.argv[1]
for f in sorted(os.listdir(d)):
    p = os.path.join(d, f)
    if '@' not in f or f.endswith(('.json', '.conf', '.db')) or not os.path.isfile(p):
        continue
    raw = open(p, 'rb').read().decode('utf-8', 'replace').replace('\r\n', '\n')
    head, _, body = raw.partition('\n\n')
    hdr = {}
    for l in head.split('\n'):
        if ':' in l:
            k, v = l.split(':', 1)
            hdr[k.strip().lower()] = v.strip()
    if 'html' in hdr.get('content-type', '').lower() or re.search(r'(?i)<(html|body|p|div|br)\b', body):
        body = re.sub(r'(?is)<(script|style)\b.*?</\1>', '', body)
        body = re.sub(r'(?i)<br\s*/?>|</p>|</div>|</li>|</tr>', '\n', body)
        body = html.unescape(re.sub(r'<[^>]+>', '', body))
    body = re.sub(r'[ \t]+\n', '\n', body)
    body = re.sub(r'\n{3,}', '\n\n', body).strip()
    if not body:
        continue
    estado = 'ok'
    for j in (p + '.json', p + '.conf'):
        if not os.path.exists(j):
            continue
        try:
            txt = open(j).read()
            c = json.loads(txt) if j.endswith('.json') else dict(
                l.split('=', 1) for l in txt.splitlines() if '=' in l)
            stop = c.get('stop') or c.get('STOP') or c.get('end')
            if stop and str(stop).strip().isdigit() and 0 < int(stop) < time.time():
                estado = 'caducada'
        except Exception:
            pass
    acc, dom = f.rsplit('@', 1)
    print('\t'.join([acc.lower(), dom.lower(), estado,
                     base64.b64encode(body[:10000].encode()).decode()]))
