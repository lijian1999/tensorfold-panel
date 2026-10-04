import sys, time
t = time.time()
print("hook loaded at startup:", "tfpanel_hook" in sys.modules, "| torch loaded:", "torch" in sys.modules)
import tensorfold.cuda.health as h
print("import health: %.2fs | torch loaded: %s" % (time.time() - t, "torch" in sys.modules))
from types import SimpleNamespace as N
dec = N(streams={3: N(sid=3, prompt=[0] * 18420, cached=16384, out=[1] * 312)},
        filling=[N(sid=4, prompt=[0] * 24615, cached=2048)], fills={4: [None, None, 10240, None]})
app = N(engine=N(scheduler=N(decoder=dec, max_streams=5)), effective_context_window=262144)
print(h.of(app).snapshot(app))
