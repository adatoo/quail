# ADR-0059: Moving in models other apps downloaded (Phase 4 step 2)

**Date:** 2026-09-28 · **Status:** Accepted

**Situation:** people arrive with models already downloaded by llama.cpp (`-hf`), LM Studio, the Hugging Face cache (mlx-lm and others) or oMLX. Re-downloading tens of gigabytes is slow, and keeping two copies wastes disk space. ARCHITECTURE §6 said to offer to move them on first run, never symlink.

**Decision:** `ModelImporter` scans four places and names each model as the store does:
- `~/.cache/llama.cpp`: flat `owner_repo_file.gguf`, with the `owner_repo_…mmproj…` projector;
- `~/.lmstudio/models/<publisher>/<repo>/`: GGUF files, or an MLX folder named `publisher--repo`;
- `~/.cache/huggingface/hub/models--owner--name/snapshots/<refs/main>/`: an MLX folder `owner--name`, or GGUF files. Its entries are links to blobs, so the blobs move and the links go;
- `~/.omlx/models/<name>/`: MLX folders.

It skips anything whose name is already in the store, and an MLX folder missing a shard its `model.safetensors.index.json` names (an unfinished download).

**How a move works:** all or nothing.
- The files go into a staging folder in the store: renamed if they're on the same disk, copied if not.
- The staging folder then takes the model's place, and only after that are the originals removed.
- A failure part-way puts renamed files back.

**The offer** is a banner at the top of the Models pane, shown until it's answered either way (`Config.importOffered`); Review… opens the list with a checkbox per model. Storage's menu reopens the list at any time.

**Differences from the plan:**
- A banner instead of a sheet that opens by itself on first launch. A menu-bar app opening a window unasked is intrusive, and the Models pane is where the result shows.
- Moves go through a staging folder, so a failure never leaves half a model.

**Checked:** a fixture with a model in each place, including a Hugging Face snapshot of links and a llama.cpp projector. Tests cover that each is found and named, moved and removed at the source (blobs and links too), not found again afterwards, and refused when already in the store. A failure part-way puts the model back, and an unfinished download is skipped. Snapshots `import-offer` and `import-sheet`.

**Alternatives:** copy (doubles the space); symlink (llama-server and MLX treat links inconsistently, ARCHITECTURE §6); point Quail at the other folders in place (the store's single-writer rule and presets assume one folder).
