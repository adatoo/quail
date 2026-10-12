# ADR-0068: Load and Unload by hand stop a busy model's requests

**Date:** 2026-09-30 · **Status:** Accepted

**Situation:** with one model loaded at a time, loading another while the chat page was still streaming a reply left the new model at "Loading…" for as long as the reply ran, with nothing saying why. The router never takes a model out from under a request (ADR-0011's router semantics), so it waited. With a slow thinking model and no length limit, that's many minutes. Unload waited the same way. And the page kept its own choice of model, so its next message could reload the old model and push the new one out.

**Decision:**
- **Loads and unloads asked for by hand don't wait.** `POST /models/load` and `POST /models/unload` are what Quail's Load and Unload buttons send, and the chat page's. They stop the requests on a model that has to go, and each of those requests ends with a 503 `unavailable_error`: "Stopped: *A* was unloaded to load *B*." A stream gets it as its last event. For a load, the busy model stopped is the least recently used one, and only if every model in the way is busy.
- **A load a request needs still waits.** A request for another model, from any client, never stops someone else's reply.
- **The wait shows.** While a load waits, `GET /models` gives the model's status a `waiting_for` list, and so does its `GET /slots` entry. The Models page and the Activity window say "Waiting for *A* to finish", the menu's model line says the load comes once *A* finishes its requests, and the chat page says so too.
- **The chat page follows a switch made elsewhere.** It refreshes its list when it comes back into view. Before it sends to a model that isn't loaded, when loading it would unload another (`max_instances` in `/props`), it offers the loaded model instead: "Use *B*" or "Load *A*". Load is a hand load, as above.

**Details:**
- Each load of a model gets a fresh interrupter. A request registers with it while it generates, and one that registers after an interruption is stopped at once.
- A model stopped for a load that another model then made room for (it finished first) gets a new interrupter, so its next requests run.
- So does a model whose unload is cancelled by loading it again.

**Alternatives:**
- **Always stop, like a llama-server router ending a child process:** a load that one client's request needs would cut off another client's reply. Rejected.
- **A grace period before stopping:** the owner already chose, and a reply can outlast any fixed wait.
- **Only show the wait:** it names the problem without fixing it; Unload still wouldn't free the model.

**Revisit if:** clients other than Quail's own call `/models/load` while others are generating, and being stopped surprises them. An opt-out field on the request would then do.
