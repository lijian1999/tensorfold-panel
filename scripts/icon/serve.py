# 图标预览服务：静态托管本目录，POST /save/<name>.png 把画布导出的 PNG 写到 out/。
import http.server, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def do_POST(self):
        m = re.fullmatch(r"/save/([\w.-]+\.png)", self.path)
        if not m:
            self.send_error(404)
            return
        data = self.rfile.read(int(self.headers["Content-Length"]))
        os.makedirs(os.path.join(ROOT, "out"), exist_ok=True)
        with open(os.path.join(ROOT, "out", m.group(1)), "wb") as f:
            f.write(data)
        self.send_response(204)
        self.end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
