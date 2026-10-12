# ADR-0049: Model downloads queue, one at a time

**Date:** 2026-09-26 · **Status:** Accepted

**Decision:** `ModelInstallController` runs one download and queues the rest, starting each in order when the running one finishes, fails or is cancelled. The Add Model sheet shows the running download (which model and quantization, progress, Cancel) and the queue (with Remove) above whatever model is selected, and its button reads **Add to Queue** while something downloads; list rows mark a model that is downloading or queued. `recent` keeps how the last few ended, so `quail pull` reads its own result even when a queued download has already started, and `installedCount` tells views to reload.
**Why:** reported: while a download ran, the sheet replaced the model details with a progress bar that didn't say what was downloading, yet the list still let you pick other models. Freezing the list would make you wait for a large download before choosing the next.
**Alternatives:** Simultaneous downloads (they share one connection's bandwidth, so each finishes later; `HFDownloader` fetches one file at a time by design, ADR-0015). Locking the sheet while downloading.
**Revisit if:** people want to reorder the queue or pause, or a download source where parallel transfers are faster.
