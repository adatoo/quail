extension WebUI {
    /// The page's own code: conversations in IndexedDB, settings in localStorage, the model picker, the
    /// chat stream, and the sign-in ticket from the Quail app (ADR D-042). Every request goes through `api`,
    /// to a path on this server.
    static let app = #"""

    const $ = (id) => document.getElementById(id);
    const els = {};
    for (const id of ["sidebar", "new-chat", "search", "conversations", "export", "import", "import-file",
                      "toggle-sidebar", "build", "key", "key-toggle", "key-panel", "model", "model-dot", "model-action",
                      "model-button", "model-name", "model-meta", "model-list",
                      "refresh", "open-settings", "system", "system-toggle", "system-panel",
                      "log", "status", "form", "input", "send", "stop", "timings",
                      "attachments", "attach", "attach-file",
                      "settings", "settings-fields", "settings-reset", "settings-close", "settings-x"]) {
      els[id] = $(id);
    }
    const store = {
      get(name) { try { return localStorage.getItem(name) || ""; } catch (e) { return ""; } },
      set(name, value) { try { localStorage.setItem(name, value); } catch (e) { /* private window */ } },
    };
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const make = (tag, className, text) => {
      const element = document.createElement(tag);
      if (className) { element.className = className; }
      if (text !== undefined) { element.textContent = text; }
      return element;
    };
    const button = (text, title, onClick) => {
      const b = make("button", "", text);
      b.type = "button";
      if (title) { b.title = title; }
      b.addEventListener("click", onClick);
      return b;
    };

    let models = [];          // from /v1/models
    let conversations = [];   // every chat, newest first
    let current = null;       // the chat on screen
    let controller = null;    // the reply being streamed

    function setStatus(text, isError) {
      els.status.textContent = text || "";
      els.status.className = isError ? "error" : "";
    }

    async function api(path, options) {
      const init = Object.assign({ credentials: "omit", cache: "no-store" }, options);
      init.headers = {};
      const key = els.key.value.trim();
      if (key) { init.headers["Authorization"] = "Bearer " + key; }
      if (init.body) { init.headers["Content-Type"] = "application/json"; }
      const res = await fetch(path, init);
      if (!res.ok) {
        let message = res.status + " " + res.statusText;
        try {
          const body = await res.json();
          if (body.error && body.error.message) { message = body.error.message; }
        } catch (e) { /* not JSON */ }
        const error = new Error(message);
        error.status = res.status;
        throw error;
      }
      return res;
    }

    function fail(error) {
      if (error.status === 401) {
        setStatus("This server needs its API key. Open the chat from Quail's menu, or paste the key.", true);
        showPanel("key", true);
        els.key.focus();
      } else {
        setStatus(error.message, true);
      }
    }

    async function copyText(text, from) {
      try {
        await navigator.clipboard.writeText(text);
        if (from) { const was = from.textContent; from.textContent = "Copied"; setTimeout(() => { from.textContent = was; }, 1200); }
      } catch (e) { setStatus("Couldn't copy: the browser didn't allow it.", true); }
    }

    // MARK: saved chats (IndexedDB, or memory if the browser won't give us any)

    const db = (() => {
      let opened = null;
      let memory = null;
      function open() {
        if (!opened) {
          opened = new Promise((resolve, reject) => {
            let request;
            try { request = indexedDB.open("quail", 1); } catch (e) { reject(e); return; }
            request.onupgradeneeded = () => request.result.createObjectStore("conversations", { keyPath: "id" });
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
          });
        }
        return opened;
      }
      async function run(mode, action) {
        if (memory) { return action(null); }
        let database;
        try { database = await open(); } catch (e) {
          memory = new Map();
          setStatus("This browser won't keep chats (private window?); they last until the page closes.", false);
          return action(null);
        }
        return new Promise((resolve, reject) => {
          const transaction = database.transaction("conversations", mode);
          const request = action(transaction.objectStore("conversations"));
          transaction.oncomplete = () => resolve(request ? request.result : undefined);
          transaction.onerror = () => reject(transaction.error);
        });
      }
      return {
        all: () => run("readonly", (s) => s ? s.getAll() : { result: [...memory.values()] }),
        put: (c) => run("readwrite", (s) => { if (s) { return s.put(c); } memory.set(c.id, c); return null; }),
        remove: (id) => run("readwrite", (s) => { if (s) { return s.delete(id); } memory.delete(id); return null; }),
      };
    })();

    const newID = () => Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);

    function blankConversation() {
      return { id: newID(), title: "New chat", model: els.model.value || store.get("quail.model"), system: "",
               messages: [], created: Date.now(), updated: Date.now() };
    }

    async function save(conversation) {
      conversation.updated = Date.now();
      if (!conversations.includes(conversation)) { conversations.unshift(conversation); }
      conversations.sort((a, b) => b.updated - a.updated);
      try { await db.put(conversation); } catch (e) { setStatus("Couldn't save this chat: " + e.message, true); }
      renderList();
    }

    function titleFrom(text) {
      const line = text.replace(/\s+/g, " ").trim();
      return line.length > 60 ? line.slice(0, 57) + "…" : line || "New chat";
    }

    // MARK: the chat list

    function when(time) {
      const date = new Date(time);
      const today = new Date();
      return date.toDateString() === today.toDateString()
        ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
        : date.toLocaleDateString();
    }

    function renderList() {
      const query = els.search.value.trim().toLowerCase();
      const shown = conversations.filter((c) => c.messages.length || c === current).filter((c) => !query
        || c.title.toLowerCase().includes(query)
        || c.messages.some((m) => (m.content || "").toLowerCase().includes(query)));
      els.conversations.replaceChildren();
      for (const conversation of shown) {
        const row = make("div", "conv" + (conversation === current ? " current" : ""));
        const open = make("button", "open");
        open.type = "button";
        open.append(make("span", "title", conversation.title), make("span", "when", when(conversation.updated)));
        open.addEventListener("click", () => select(conversation));
        const tools = make("div", "tools");
        tools.append(
          button("Rename", "Rename this chat", () => rename(conversation, row)),
          button("Delete", "Delete this chat", (event) => confirmDelete(conversation, event.currentTarget)),
        );
        row.append(open, tools);
        els.conversations.append(row);
      }
      if (!shown.length && query) { els.conversations.append(make("p", "empty", "No chats match.")); }
    }

    function rename(conversation, row) {
      const input = make("input");
      input.value = conversation.title;
      input.setAttribute("aria-label", "Chat name");
      row.classList.add("editing");
      row.replaceChildren(input);
      input.focus();
      input.select();
      let done = false;
      const finish = async (keep) => {
        if (done) { return; }
        done = true;
        if (keep && input.value.trim()) { conversation.title = input.value.trim(); await save(conversation); }
        else { renderList(); }
      };
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); finish(true); }
        if (event.key === "Escape") { event.preventDefault(); finish(false); }
      });
      input.addEventListener("blur", () => finish(true));
    }

    async function confirmDelete(conversation, from) {
      if (from.dataset.confirm !== "yes") {
        from.dataset.confirm = "yes";
        from.textContent = "Sure?";
        setTimeout(() => { if (from.isConnected) { from.dataset.confirm = ""; from.textContent = "Delete"; } }, 3000);
        return;
      }
      conversations = conversations.filter((c) => c !== conversation);
      try { await db.remove(conversation.id); } catch (e) { /* already gone */ }
      if (conversation === current) { startNew(); } else { renderList(); }
    }

    function select(conversation) {
      if (controller) { controller.abort(); }
      current = conversation;
      store.set("quail.current", conversation.id);
      els.system.value = conversation.system || "";
      markSystemButton();
      if (!userPicked) { chooseModel(); }
      updateModelControls();
      updateSettingsAvailability();
      renderConversation();
      renderList();
      if (window.matchMedia("(max-width: 760px)").matches) { document.body.classList.add("side-closed"); }
    }

    function startNew() {
      if (current && !current.messages.length) { select(current); els.input.focus(); return; }
      select(blankConversation());
      els.input.focus();
    }

    // MARK: messages

    function renderConversation() {
      els.log.replaceChildren();
      els.timings.textContent = "";
      if (!current || !current.messages.length) {
        const empty = make("div", "empty");
        const model = els.model.value;
        empty.append(make("strong", "", model ? "Chat with " + model : "Start a chat"),
          make("span", "", models.length ? "Your chats are kept in this browser." : "Add a model in Quail to start."));
        els.log.append(empty);
        return;
      }
      current.messages.forEach((message, index) => els.log.append(messageView(message, index)));
      els.log.scrollTop = els.log.scrollHeight;
    }

    function timingsText(t) {
      if (!t) { return ""; }
      const speed = t.predicted_per_second ? t.predicted_per_second.toFixed(1) + " tok/s · " : "";
      return speed + (t.predicted_n || 0) + " tokens";
    }

    function messageView(message, index) {
      const root = make("div", "msg " + message.role + (message.error ? " error" : ""));
      const ui = { root, message };
      if (message.role === "assistant") {
        ui.thinking = make("details", "thinking");
        ui.thinking.append(make("summary", "", "Thinking"));
        ui.thinkingText = make("pre", "", message.reasoning || "");
        ui.thinking.append(ui.thinkingText);
        ui.thinking.hidden = !message.reasoning;
        ui.body = make("div", "md");
        MD.render(message.content || "", ui.body, copyText);
        root.append(ui.thinking, ui.body);
        for (const call of message.calls || []) { root.append(make("pre", "call", call)); }
      } else {
        if ((message.images || []).length) {
          const images = make("div", "images");
          for (const url of message.images) { const img = make("img"); img.src = url; img.alt = "Attached image"; images.append(img); }
          root.append(images);
        }
        if ((message.files || []).length) {
          const files = make("div", "files");
          for (const file of message.files) { files.append(make("span", "chip", file.name + " · " + sizeText(file.text.length))); }
          root.append(files);
        }
        ui.body = make("pre", "plain", message.content || "");
        root.append(ui.body);
      }
      if (message.error) { root.append(make("p", "", message.error)); }
      const meta = make("div", "meta");
      ui.meta = make("span", "", timingsText(message.timings));
      const actions = make("div", "msg-actions");
      actions.append(button("Copy", "Copy this message", (event) => copyText(message.content || "", event.currentTarget)));
      if (message.role === "user") {
        actions.append(button("Edit", "Change this message and ask again", () => edit(index, ui)));
      } else {
        actions.append(button("Regenerate", "Ask for this reply again", () => regenerate(index)));
      }
      actions.append(button("Delete", "Remove this message", () => removeMessage(index)));
      meta.append(ui.meta, actions);
      root.append(meta);
      ui.actions = actions;
      return root;
    }

    function edit(index, ui) {
      if (controller) { return; }
      const area = make("textarea", "edit");
      area.value = current.messages[index].content;
      const row = make("div", "actions");
      row.append(
        button("Save and send", "Replace this message and everything after it", async () => {
          const text = area.value.trim();
          const was = current.messages[index];
          if (!text && !(was.images || []).length && !(was.files || []).length) { return; }
          const old = current.messages[index];
          current.messages = current.messages.slice(0, index);
          current.messages.push(Object.assign({}, old, { content: text }));
          if (index === 0) { current.title = titleFrom(text); }
          await save(current);
          renderConversation();
          generate();
        }),
        button("Cancel", "", () => renderConversation()),
      );
      ui.root.replaceChildren(area, row);
      area.focus();
    }

    async function regenerate(index) {
      if (controller) { return; }
      current.messages = current.messages.slice(0, index);
      await save(current);
      renderConversation();
      generate();
    }

    async function removeMessage(index) {
      if (controller) { return; }
      current.messages.splice(index, 1);
      await save(current);
      renderConversation();
    }

    // MARK: models

    function formatOf(model) {
      return model && model.format ? model.format : "";
    }

    const statusOf = (model) => (model && model.status && (model.status.failed ? "failed" : model.status.value)) || "";
    // Set once someone picks a model in this page; until then the picker follows what the server has loaded.
    let userPicked = false;

    // The model the picker should show: the one you picked, else this chat's model if it's loaded, else the
    // loaded model, else this chat's or the last one used.
    function chooseModel() {
      const known = (id) => id && models.some((m) => m.id === id);
      const loaded = models.filter((m) => statusOf(m) === "loaded" || statusOf(m) === "loading");
      const chatModel = current && current.model;
      let id = "";
      if (userPicked && known(els.model.value)) { id = els.model.value; }
      else if (chatModel && loaded.some((m) => m.id === chatModel)) { id = chatModel; }
      else if (loaded.length) { id = loaded[0].id; }
      else if (known(chatModel)) { id = chatModel; }
      else if (known(store.get("quail.model"))) { id = store.get("quail.model"); }
      else if (models.length) { id = models[0].id; }
      if (id) { els.model.value = id; }
    }

    const hasVision = (model) => Boolean(model && model.architecture && (model.architecture.input_modalities || []).includes("image"));
    function formatBytes(bytes) {
      if (!bytes) { return ""; }
      const units = ["B", "KB", "MB", "GB", "TB"];
      let value = bytes;
      let unit = 0;
      while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit++; }
      return (value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)) + " " + units[unit];
    }
    // An MLX folder is named owner--repo; the repo is the name, the owner goes in the details.
    const displayName = (id) => (id.includes("--") ? id.slice(id.indexOf("--") + 2) : id);
    const ownerOf = (id) => (id.includes("--") ? id.slice(0, id.indexOf("--")) : "");
    // "5.0 GB · 32K context · vision · loads at start" — what the picker says under each name, after the
    // format badge.
    function describeModel(model) {
      const parts = [ownerOf(model.id)];
      if (model.size_bytes) { parts.push(formatBytes(model.size_bytes)); }
      if (model.context_size) { parts.push(Math.round(model.context_size / 1024) + "K context"); }
      if (hasVision(model)) { parts.push("vision"); }
      if (model.load_on_startup) { parts.push("loads at start"); }
      return parts.filter(Boolean).join(" · ");
    }
    const formatBadge = (model) => make("span", "badge " + formatOf(model), formatOf(model).toUpperCase());
    const stateLabel = (status) => ({ loaded: "loaded", loading: "loading…", failed: "failed" })[status] || "";

    // The picker: a button showing the chosen model, over a list with each model's details. The hidden
    // <select> stays the source of truth, so everything that reads els.model.value is unchanged.
    let activeIndex = -1;
    function renderPicker() {
      const model = models.find((m) => m.id === els.model.value);
      els["model-name"].textContent = model ? displayName(model.id) : (models.length ? "Choose a model" : "No models");
      els["model-meta"].replaceChildren(...(model ? [formatBadge(model), document.createTextNode(describeModel(model))] : []));
      els["model-button"].title = model ? model.id : "Choose a model";
      const list = els["model-list"];
      list.replaceChildren();
      models.forEach((m, index) => {
        const status = statusOf(m);
        const row = make("li", "option" + (index === activeIndex ? " active" : ""));
        row.id = "model-option-" + index;
        row.setAttribute("role", "option");
        row.setAttribute("aria-selected", String(m.id === els.model.value));
        row.title = m.id;
        const text = make("span", "option-text");
        const meta = make("span", "option-meta");
        meta.append(formatBadge(m), document.createTextNode(describeModel(m)));
        text.append(make("span", "option-name", displayName(m.id)), meta);
        row.append(make("span", "dot " + status), text, make("span", "option-state " + status, stateLabel(status)));
        row.addEventListener("mousedown", (event) => event.preventDefault()); // keep focus on the list
        row.addEventListener("click", () => pickModel(index));
        row.addEventListener("mousemove", () => { if (activeIndex !== index) { activeIndex = index; highlight(); } });
        list.append(row);
      });
    }
    function highlight() {
      [...els["model-list"].children].forEach((row, index) => row.classList.toggle("active", index === activeIndex));
      const row = els["model-list"].children[activeIndex];
      if (row) {
        els["model-list"].setAttribute("aria-activedescendant", row.id);
        row.scrollIntoView({ block: "nearest" });
      }
    }
    function openPicker() {
      if (els["model-button"].disabled || !models.length) { return; }
      activeIndex = Math.max(0, models.findIndex((m) => m.id === els.model.value));
      renderPicker();
      els["model-list"].hidden = false;
      els["model-button"].setAttribute("aria-expanded", "true");
      els["model-list"].focus();
      highlight();
    }
    function closePicker(refocus) {
      if (els["model-list"].hidden) { return; }
      els["model-list"].hidden = true;
      els["model-button"].setAttribute("aria-expanded", "false");
      if (refocus) { els["model-button"].focus(); }
    }
    function pickModel(index) {
      const model = models[index];
      closePicker(true);
      if (!model || model.id === els.model.value) { return; }
      els.model.value = model.id;
      els.model.dispatchEvent(new Event("change"));
    }

    function updateModelControls() {
      const model = models.find((m) => m.id === els.model.value);
      const status = statusOf(model);
      els["model-dot"].className = "dot " + status;
      els["model-dot"].title = status ? "Model " + status : "";
      renderPicker();
      const action = els["model-action"];
      action.disabled = !model || status === "loading" || Boolean(controller);
      action.textContent = status === "loaded" ? "Unload" : status === "loading" ? "Loading…" : "Load";
      action.title = status === "loaded" ? "Free this model's memory" : "Load this model now (a message loads it too)";
      action.dataset.action = status === "loaded" ? "unload" : "load";
    }

    async function refreshModels() {
      try {
        const res = await api("/v1/models");
        models = (await res.json()).data || [];
        const previous = els.model.value;
        els.model.replaceChildren();
        for (const model of models) {
          const option = make("option");
          option.value = model.id;
          option.textContent = model.id;
          els.model.append(option);
        }
        if (previous) { els.model.value = previous; }
        chooseModel();
        if (!models.length) { setStatus("No models yet. Add one in Quail.", false); }
        else if (els.status.className !== "error") { setStatus("", false); }
        updateModelControls();
        updateSettingsAvailability();
        if (current && !current.messages.length) { renderConversation(); }
        return models;
      } catch (error) {
        fail(error);
        return [];
      }
    }

    async function showBuild() {
      try {
        const res = await api("/props");
        els.build.textContent = (await res.json()).build_info || "";
      } catch (error) { els.build.textContent = ""; }
    }

    async function manage(action) {
      const model = els.model.value;
      if (!model) { return; }
      els["model-action"].disabled = true;
      els["model-action"].textContent = action === "load" ? "Loading…" : "Unloading…";
      try {
        await api("/models/" + action, { method: "POST", body: JSON.stringify({ model }) });
        for (let tries = 0; tries < 600; tries++) {
          const list = await refreshModels();
          const entry = list.find((m) => m.id === model);
          if (!entry || statusOf(entry) !== "loading") {
            if (entry && statusOf(entry) === "failed") { setStatus(model + " failed to load. Quail's Logs window says why.", true); }
            break;
          }
          await sleep(1000);
        }
      } catch (error) { fail(error); }
      updateModelControls();
    }

    // The two panels under the top bar (API key, system prompt): one open at a time.
    function showPanel(name, open) {
      for (const which of ["key", "system"]) {
        const show = which === name ? (open === undefined ? els[which + "-panel"].hidden : open) : false;
        els[which + "-panel"].hidden = !show;
        els[which + "-toggle"].setAttribute("aria-expanded", String(show));
      }
      if (!els[name + "-panel"].hidden) { els[name].focus(); }
    }

    function markSystemButton() {
      els["system-toggle"].textContent = els.system.value.trim() ? "System prompt ✓" : "System prompt";
    }

    function updateKeyButton() {
      const has = Boolean(els.key.value.trim());
      els["key-toggle"].textContent = has ? "Key ✓" : "Key";
      els["key-toggle"].title = has ? "The API key is set for this browser" : "Paste the server's API key";
    }

    // MARK: settings

    // `only`: which model formats the server honours it for; others ignore it (samplers) or refuse it (JSON mode).
    // `info`: what the setting does, and a good and a bad value, shown under the ⓘ button.
    const settingGroups = [
      { title: "Basics", keys: ["temperature", "max_tokens", "thinking", "seed", "json"] },
      { title: "Which words can be picked", keys: ["top_k", "top_p", "min_p", "typical_p", "top_n_sigma"] },
      { title: "Repetition", keys: ["repeat_penalty", "presence_penalty", "frequency_penalty", "dry_multiplier"] },
      { title: "Advanced", keys: ["xtc_probability", "xtc_threshold", "mirostat", "stop"] },
    ];
    const settingSpec = [
      { key: "temperature", label: "Temperature", kind: "number", step: "0.05", min: "0", placeholder: "0.8",
        info: ["How random each next word is. 0 always takes the likeliest word, so the same question gets the same answer.",
               "0.1–0.3 for code, maths or pulling facts out of text; 0.7–0.9 for conversation and writing.",
               "Above about 1.3 the text drifts into nonsense; 0 can get stuck repeating itself."] },
      { key: "max_tokens", label: "Max tokens", kind: "number", step: "1", min: "1", placeholder: "no limit",
        info: ["The longest a reply may be, in tokens (a token is about three quarters of a word). Blank lets the model stop by itself.",
               "512 for short answers; blank for long ones.",
               "16 cuts replies off mid-sentence; a thinking model needs room to think before it answers."] },
      { key: "thinking", label: "Thinking", kind: "select", options: [["", "Model's default"], ["on", "On"], ["off", "Off"]],
        info: ["Whether a reasoning model (Qwen3, DeepSeek R1 and similar) thinks before it answers. Others ignore it.",
               "On for maths, code and questions with several steps; off for quick chat.",
               "On for a simple question wastes time and tokens; off makes hard questions go wrong more often."] },
      { key: "seed", label: "Seed", kind: "number", step: "1", placeholder: "random",
        info: ["The starting point for the random choices. The same seed, settings and prompt give the same reply again.",
               "Any number (42) when you want to repeat a result or compare settings fairly.",
               "A fixed seed in normal chat makes Regenerate give the same answer."] },
      { key: "json", label: "Reply format", kind: "select", options: [["", "Text"], ["json", "JSON object"]], only: "gguf",
        info: ["JSON object makes the reply valid JSON, for a program to read.",
               "Pulling data out of text: \"List the people in this email as JSON\".",
               "Ordinary chat: the model is forced into braces and quotes."] },
      { key: "top_k", label: "Top-k", kind: "number", step: "1", min: "0", placeholder: "40",
        info: ["Only the k likeliest next words are considered.",
               "20–60; 40 is the usual default.",
               "1 always takes the top word (like temperature 0); 0 turns the limit off."] },
      { key: "top_p", label: "Top-p", kind: "number", step: "0.01", min: "0", placeholder: "0.95",
        info: ["Keeps the smallest set of likely words whose chances add up to p, and picks among those.",
               "0.9–0.95.",
               "0.1 is very repetitive; 1 turns it off."] },
      { key: "min_p", label: "Min-p", kind: "number", step: "0.01", min: "0", placeholder: "0.05",
        info: ["Drops words less than p times as likely as the best one. It keeps higher temperatures sensible.",
               "0.05–0.1, especially with a temperature of 1 or more.",
               "0.5 leaves few choices, so the text gets bland and repetitive."] },
      { key: "typical_p", label: "Typical-p", kind: "number", step: "0.01", placeholder: "1 (off)", only: "gguf",
        info: ["Prefers words about as surprising as the text usually is, which can read more naturally.",
               "0.9–0.95 for prose.",
               "0.2 makes odd choices; 1 turns it off."] },
      { key: "top_n_sigma", label: "Top-n-sigma", kind: "number", step: "0.1", placeholder: "-1 (off)", only: "gguf",
        info: ["Keeps only words scored within n standard deviations of the best, so it stays coherent even at high temperature.",
               "1–2 with a high temperature for varied but sensible text.",
               "0.1 is almost always the top word; -1 turns it off."] },
      { key: "repeat_penalty", label: "Repeat penalty", kind: "number", step: "0.01", placeholder: "1.0",
        info: ["Makes words used in the last 64 tokens less likely.",
               "1.0 (off) to 1.1 when replies repeat themselves.",
               "1.5 avoids words it needs (\"the\", variable names), which breaks code and grammar."] },
      { key: "presence_penalty", label: "Presence penalty", kind: "number", step: "0.01", placeholder: "0",
        info: ["Penalises any word already used, once, which nudges the model towards new topics.",
               "0–0.5.",
               "2 makes it ramble away from the question."] },
      { key: "frequency_penalty", label: "Frequency penalty", kind: "number", step: "0.01", placeholder: "0",
        info: ["Penalises words by how often they have appeared so far.",
               "0–0.5 to cut down repeated phrases.",
               "2 leads to strange word choices."] },
      { key: "dry_multiplier", label: "DRY multiplier", kind: "number", step: "0.05", min: "0", placeholder: "0 (off)", only: "gguf",
        info: ["DRY (\"don't repeat yourself\") stops the model repeating long runs of text it has already written.",
               "0.8 for stories or chats that start looping.",
               "Any value for code or data, which repeat on purpose; 0 turns it off."] },
      { key: "xtc_probability", label: "XTC probability", kind: "number", step: "0.05", min: "0", placeholder: "0 (off)", only: "gguf",
        info: ["XTC (\"exclude top choices\") sometimes removes the likeliest words, for less predictable writing.",
               "0.5 with threshold 0.1 for creative writing.",
               "Any value for code, facts or maths; 0 turns it off."] },
      { key: "xtc_threshold", label: "XTC threshold", kind: "number", step: "0.01", placeholder: "0.1", only: "gguf",
        info: ["Words more likely than this count as \"top choices\" that XTC may remove.",
               "0.1.",
               "0.5 or more makes XTC do nothing."] },
      { key: "mirostat", label: "Mirostat", kind: "select", options: [["", "Off"], ["1", "Mirostat 1"], ["2", "Mirostat 2"]], only: "gguf",
        info: ["Adjusts the choice as it goes to keep the text equally surprising throughout, instead of fixed top-k and top-p.",
               "Mirostat 2 for long creative writing.",
               "On for code or short answers, where it gains nothing."] },
      { key: "stop", label: "Stop strings (one per line)", kind: "textarea", wide: true,
        info: ["The reply ends as soon as one of these appears.",
               "A blank line (type Enter twice) for one paragraph; \"User:\" for script-style prompts.",
               "A common word, which ends replies early."] },
    ];
    let settings = {};
    try { settings = JSON.parse(store.get("quail.settings") || "{}") || {}; } catch (e) { settings = {}; }
    const inputs = {};

    function settingField(spec) {
      const field = make("div", "field" + (spec.wide ? " wide" : ""));
      const id = "setting-" + spec.key;
      const head = make("div", "field-head");
      const label = make("label", "", spec.label);
      label.htmlFor = id;
      head.append(label);
      const infoButton = make("button", "info-button", "i");
      infoButton.type = "button";
      infoButton.title = "What " + spec.label + " does";
      infoButton.setAttribute("aria-label", "About " + spec.label);
      infoButton.setAttribute("aria-expanded", "false");
      head.append(infoButton);
      if (spec.only) { head.append(make("span", "tag", "GGUF only")); }
      field.append(head);
      let input;
      if (spec.kind === "select") {
        input = make("select");
        for (const [value, text] of spec.options) { const o = make("option", "", text); o.value = value; input.append(o); }
      } else if (spec.kind === "textarea") {
        input = make("textarea");
        input.rows = 2;
      } else {
        input = make("input");
        input.type = "number";
        input.step = spec.step;
        if (spec.min !== undefined) { input.min = spec.min; }
        input.placeholder = spec.placeholder || "";
      }
      input.id = id;
      input.value = settings[spec.key] === undefined ? "" : settings[spec.key];
      input.addEventListener("change", () => {
        if (input.value === "") { delete settings[spec.key]; } else { settings[spec.key] = input.value; }
        store.set("quail.settings", JSON.stringify(settings));
      });
      const info = make("div", "info");
      info.hidden = true;
      info.id = id + "-info";
      infoButton.setAttribute("aria-controls", info.id);
      const [what, good, bad] = spec.info || ["", "", ""];
      info.append(make("p", "", what));
      const goodLine = make("p");
      goodLine.append(make("span", "good", "Good: "), document.createTextNode(good));
      const badLine = make("p");
      badLine.append(make("span", "bad", "Bad: "), document.createTextNode(bad));
      info.append(goodLine, badLine);
      if (spec.only) { info.append(make("p", "", "Only GGUF models use this; an MLX model ignores it.")); }
      infoButton.addEventListener("click", () => {
        info.hidden = !info.hidden;
        infoButton.setAttribute("aria-expanded", String(!info.hidden));
      });
      field.append(input, info);
      inputs[spec.key] = { input, field, spec };
      return field;
    }

    function buildSettings() {
      els["settings-fields"].replaceChildren();
      const byKey = Object.fromEntries(settingSpec.map((s) => [s.key, s]));
      for (const group of settingGroups) {
        const set = make("fieldset", "group");
        set.append(make("legend", "", group.title));
        for (const key of group.keys) { set.append(settingField(byKey[key])); }
        els["settings-fields"].append(set);
      }
      updateSettingsAvailability();
    }

    function currentFormat() {
      return formatOf(models.find((m) => m.id === els.model.value));
    }

    function updateSettingsAvailability() {
      const format = currentFormat();
      for (const { field, spec } of Object.values(inputs)) {
        field.classList.toggle("unavailable", Boolean(spec.only && format && spec.only !== format));
      }
    }

    function applySettings(body, format) {
      for (const spec of settingSpec) {
        const value = settings[spec.key];
        if (value === undefined || value === "") { continue; }
        if (spec.only && format && spec.only !== format) { continue; }
        if (spec.key === "thinking") { body.chat_template_kwargs = { enable_thinking: value === "on" }; }
        else if (spec.key === "json") { body.response_format = { type: "json_object" }; }
        else if (spec.key === "stop") {
          const stops = value.split("\n").filter((s) => s.length);
          if (stops.length) { body.stop = stops; }
        } else {
          const number = Number(value);
          if (!Number.isNaN(number)) { body[spec.key] = number; }
        }
      }
      return body;
    }

    // MARK: sending

    function setBusy(busy) {
      els.send.hidden = busy;
      els.stop.hidden = !busy;
      els.model.disabled = busy;
      els["model-button"].disabled = busy;
      if (busy) { closePicker(false); }
      els["model-action"].disabled = busy;
    }

    function handleChunk(data, reply, ui) {
      if (data === "[DONE]") { return; }
      const chunk = JSON.parse(data);
      if (chunk.error) { throw new Error(chunk.error.message || "the server reported an error"); }
      if (chunk.timings) { reply.timings = chunk.timings; }
      const delta = chunk.choices && chunk.choices[0] && chunk.choices[0].delta;
      if (!delta) { return; }
      if (delta.reasoning_content) {
        reply.reasoning = (reply.reasoning || "") + delta.reasoning_content;
        ui.thinking.hidden = false;
        ui.thinkingText.textContent = reply.reasoning;
      }
      if (delta.content) {
        reply.content += delta.content;
        scheduleRender(reply, ui);
      }
      for (const call of delta.tool_calls || []) {
        const text = JSON.stringify(call.function);
        (reply.calls = reply.calls || []).push(text);
        ui.root.insertBefore(make("pre", "call", text), ui.root.lastChild);
      }
    }

    // Markdown is re-rendered at most once a frame while a reply streams in.
    function scheduleRender(reply, ui) {
      if (ui.pending) { return; }
      ui.pending = true;
      requestAnimationFrame(() => {
        ui.pending = false;
        const atBottom = els.log.scrollHeight - els.log.scrollTop - els.log.clientHeight < 40;
        MD.render(reply.content, ui.body, copyText);
        if (atBottom) { els.log.scrollTop = els.log.scrollHeight; }
      });
    }

    async function readStream(res, reply, ui) {
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) { break; }
        buffer += decoder.decode(value, { stream: true });
        let end;
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          for (const line of frame.split("\n")) {
            if (line.startsWith("data: ")) { handleChunk(line.slice(6), reply, ui); }
          }
        }
      }
    }

    async function send() {
      const text = els.input.value.trim();
      if ((!text && !pending.length) || controller) { return; }
      if (!els.model.value) { setStatus("Choose a model first.", true); return; }
      const images = pending.filter((a) => a.kind === "image").map((a) => a.url);
      if (images.length && !modelReadsImages()) {
        setStatus("This model can't read images (it has no vision projector). Choose a vision model, or remove the images.", true);
        return;
      }
      if (!current) { current = blankConversation(); }
      const files = pending.filter((a) => a.kind === "text").map((a) => ({ name: a.name, text: a.text }));
      els.input.value = "";
      els.input.style.height = "auto";
      pending = [];
      renderPending();
      if (!current.messages.length) { current.title = titleFrom(text || (files[0] && files[0].name) || "Image"); }
      const message = { role: "user", content: text };
      if (images.length) { message.images = images; }
      if (files.length) { message.files = files; }
      current.messages.push(message);
      await save(current);
      renderConversation();
      generate();
    }

    async function generate() {
      const conversation = current;
      const model = els.model.value;
      if (!model) { setStatus("Choose a model first.", true); return; }
      conversation.model = model;
      store.set("quail.model", model);
      setStatus("", false);
      els.timings.textContent = "";
      const messages = [];
      const system = (conversation.system || "").trim();
      if (system) { messages.push({ role: "system", content: system }); }
      for (const m of conversation.messages) {
        if (!m.error) { messages.push({ role: m.role, content: apiContent(m) }); }
      }
      const reply = { role: "assistant", content: "", reasoning: "", timings: null };
      conversation.messages.push(reply);
      if (els.log.querySelector(".empty")) { els.log.replaceChildren(); }
      const view = messageView(reply, conversation.messages.length - 1);
      const ui = { root: view, body: view.querySelector(".md"), thinking: view.querySelector("details"),
                   thinkingText: view.querySelector("details pre") };
      els.log.append(view);
      els.log.scrollTop = els.log.scrollHeight;
      const body = applySettings({ model, messages, stream: true }, currentFormat());
      controller = new AbortController();
      setBusy(true);
      try {
        const res = await api("/v1/chat/completions", { method: "POST", signal: controller.signal, body: JSON.stringify(body) });
        await readStream(res, reply, ui);
      } catch (error) {
        if (error.name !== "AbortError") {
          fail(error);
          if (!reply.content) { reply.error = error.message; }
        }
      } finally {
        controller = null;
        setBusy(false);
        if (!reply.content && !reply.reasoning && !reply.calls) {
          conversation.messages.pop();
        }
        await save(conversation);
        if (conversation === current) { renderConversation(); }
        refreshModels();
      }
    }

    // MARK: attachments

    // Files waiting to go with the next message: images as data URLs, text files as their text.
    let pending = [];
    const maxImage = 20 * 1024 * 1024;
    const maxText = 256 * 1024;
    const textTypes = /^(text\/|application\/(json|xml|x-yaml|yaml|javascript|x-sh))/;
    const textNames = /\.(txt|md|markdown|json|csv|tsv|xml|ya?ml|toml|ini|log|py|js|ts|swift|c|h|cpp|rs|go|java|kt|rb|sh|sql|html|css)$/i;

    function sizeText(bytes) {
      return bytes < 1024 ? bytes + " B" : bytes < 1048576 ? (bytes / 1024).toFixed(0) + " KB" : (bytes / 1048576).toFixed(1) + " MB";
    }

    function modelReadsImages() {
      const model = models.find((m) => m.id === els.model.value);
      return Boolean(model && model.architecture && (model.architecture.input_modalities || []).includes("image"));
    }

    const readAs = (file, how) => new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      if (how === "url") { reader.readAsDataURL(file); } else { reader.readAsText(file); }
    });

    async function addFiles(fileList) {
      for (const file of fileList) {
        try {
          if (file.type.startsWith("image/")) {
            if (file.size > maxImage) { setStatus(file.name + " is larger than 20 MB.", true); continue; }
            pending.push({ kind: "image", name: file.name || "image", url: await readAs(file, "url") });
          } else if (textTypes.test(file.type) || textNames.test(file.name)) {
            if (file.size > maxText) { setStatus(file.name + " is larger than 256 KB; paste the part you need.", true); continue; }
            pending.push({ kind: "text", name: file.name, text: await readAs(file, "text") });
          } else {
            setStatus(file.name + " isn't an image or a text file.", true);
          }
        } catch (error) {
          setStatus("Couldn't read " + file.name + ".", true);
        }
      }
      renderPending();
      if (pending.some((a) => a.kind === "image") && !modelReadsImages()) {
        setStatus("The chosen model can't read images; choose a vision model before sending.", false);
      }
    }

    function renderPending() {
      els.attachments.replaceChildren();
      els.attachments.hidden = !pending.length;
      pending.forEach((item, index) => {
        const chip = make("span", "chip");
        if (item.kind === "image") { const img = make("img"); img.src = item.url; img.alt = item.name; chip.append(img); }
        chip.append(make("span", "name", item.kind === "image" ? item.name : item.name + " · " + sizeText(item.text.length)));
        chip.append(button("×", "Remove", () => { pending.splice(index, 1); renderPending(); }));
        els.attachments.append(chip);
      });
    }

    // What the API gets for a message: its text with any text files after it, and images as parts.
    function apiContent(message) {
      let text = message.content || "";
      for (const file of message.files || []) {
        text += (text ? "\n\n" : "") + "File: " + file.name + "\n```\n" + file.text.replace(/\n$/, "") + "\n```";
      }
      if (!(message.images || []).length) { return text; }
      const parts = message.images.map((url) => ({ type: "image_url", image_url: { url } }));
      if (text) { parts.push({ type: "text", text }); }
      return parts;
    }

    // MARK: export and import

    function exportAll() {
      const data = JSON.stringify({ format: "quail-chats", version: 1, exported: new Date().toISOString(),
                                    conversations: conversations.filter((c) => c.messages.length) }, null, 2);
      const link = make("a");
      link.href = URL.createObjectURL(new Blob([data], { type: "application/json" }));
      link.download = "quail-chats-" + new Date().toISOString().slice(0, 10) + ".json";
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(link.href), 10000);
    }

    // Ours, or anything shaped like a list of chats with `messages` of {role, content} (llama.cpp's export has
    // that shape, as far as we know; only the text is kept).
    function importedChats(data) {
      const list = Array.isArray(data) ? data : (data.conversations || (data.messages ? [data] : []));
      const out = [];
      for (const item of list) {
        const source = item.conv ? Object.assign({}, item.conv, { messages: item.messages }) : item;
        const messages = (source.messages || [])
          .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
          .map((m) => ({ role: m.role, content: m.content, reasoning: typeof m.reasoning === "string" ? m.reasoning : "" }));
        if (!messages.length) { continue; }
        out.push({ id: newID(), title: String(source.title || source.name || titleFrom(messages[0].content)).slice(0, 120),
                   model: typeof source.model === "string" ? source.model : "", system: typeof source.system === "string" ? source.system : "",
                   messages, created: Number(source.created) || Date.now(), updated: Number(source.updated || source.lastModified) || Date.now() });
      }
      return out;
    }

    async function importFile(file) {
      try {
        const chats = importedChats(JSON.parse(await file.text()));
        if (!chats.length) { setStatus("That file has no chats Quail can read.", true); return; }
        for (const chat of chats) { conversations.push(chat); await db.put(chat); }
        conversations.sort((a, b) => b.updated - a.updated);
        renderList();
        setStatus("Imported " + chats.length + (chats.length === 1 ? " chat." : " chats."), false);
      } catch (error) {
        setStatus("Couldn't read that file: " + error.message, true);
      }
    }

    // MARK: wiring

    els.form.addEventListener("submit", (event) => { event.preventDefault(); send(); });
    els.input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); send(); }
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && controller && !els.settings.open) { controller.abort(); }
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") { event.preventDefault(); startNew(); }
    });
    els.stop.addEventListener("click", () => { if (controller) { controller.abort(); } });
    els.attach.addEventListener("click", () => els["attach-file"].click());
    els["attach-file"].addEventListener("change", () => { addFiles([...els["attach-file"].files]); els["attach-file"].value = ""; });
    els.input.addEventListener("paste", (event) => {
      const files = [...(event.clipboardData ? event.clipboardData.files : [])];
      if (files.length) { event.preventDefault(); addFiles(files); }
    });
    els.form.addEventListener("dragover", (event) => { event.preventDefault(); els.form.classList.add("dropping"); });
    els.form.addEventListener("dragleave", () => els.form.classList.remove("dropping"));
    els.form.addEventListener("drop", (event) => {
      event.preventDefault();
      els.form.classList.remove("dropping");
      addFiles([...event.dataTransfer.files]);
    });
    els["new-chat"].addEventListener("click", startNew);
    els.search.addEventListener("input", renderList);
    els["toggle-sidebar"].addEventListener("click", () => document.body.classList.toggle("side-closed"));
    els.export.addEventListener("click", exportAll);
    els.import.addEventListener("click", () => els["import-file"].click());
    els["import-file"].addEventListener("change", () => {
      const file = els["import-file"].files[0];
      if (file) { importFile(file); }
      els["import-file"].value = "";
    });
    els.system.addEventListener("change", () => {
      if (!current) { current = blankConversation(); }
      current.system = els.system.value;
      markSystemButton();
      if (current.messages.length) { save(current); }
    });
    els["model-action"].addEventListener("click", () => manage(els["model-action"].dataset.action || "load"));
    els["key-toggle"].addEventListener("click", () => showPanel("key"));
    els["system-toggle"].addEventListener("click", () => showPanel("system"));
    els["settings-x"].addEventListener("click", () => els.settings.close());
    // The message box grows with what's typed, up to its maximum height.
    const fitInput = () => {
      els.input.style.height = "auto";
      els.input.style.height = Math.min(els.input.scrollHeight, 224) + "px";
    };
    els.input.addEventListener("input", fitInput);
    els.refresh.addEventListener("click", () => { refreshModels(); showBuild(); });
    els["model-button"].addEventListener("click", () => {
      if (els["model-list"].hidden) { openPicker(); } else { closePicker(true); }
    });
    // Pressing the button while the list is open must close it, not blur-close then reopen.
    els["model-button"].addEventListener("mousedown", (event) => {
      if (!els["model-list"].hidden) { event.preventDefault(); }
    });
    els["model-button"].addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); openPicker(); }
    });
    els["model-list"].addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") { activeIndex = Math.min(models.length - 1, activeIndex + 1); highlight(); }
      else if (event.key === "ArrowUp") { activeIndex = Math.max(0, activeIndex - 1); highlight(); }
      else if (event.key === "Home") { activeIndex = 0; highlight(); }
      else if (event.key === "End") { activeIndex = models.length - 1; highlight(); }
      else if (event.key === "Enter" || event.key === " ") { pickModel(activeIndex); }
      else if (event.key === "Escape") { closePicker(true); }
      else if (event.key === "Tab") { closePicker(false); return; }
      else { return; }
      event.preventDefault();
    });
    els["model-list"].addEventListener("blur", () => closePicker(false));
    document.addEventListener("mousedown", (event) => {
      if (!event.target.closest(".model-picker")) { closePicker(false); }
    });
    els.model.addEventListener("change", () => {
      userPicked = true;
      store.set("quail.model", els.model.value);
      updateModelControls();
      updateSettingsAvailability();
      if (current && !current.messages.length) { renderConversation(); }
    });
    els.key.addEventListener("change", () => {
      store.set("quail.key", els.key.value.trim());
      updateKeyButton();
      refreshModels();
      showBuild();
    });
    els["open-settings"].addEventListener("click", () => els.settings.showModal());
    els["settings-close"].addEventListener("click", () => els.settings.close());
    els["settings-reset"].addEventListener("click", () => {
      settings = {};
      store.set("quail.settings", "{}");
      buildSettings();
    });

    // Opened from the Quail app: `#ticket=…` is a one-time pass for the API key. The fragment is removed from
    // the address first, so it lands in no history entry, then traded for the key once.
    async function signIn() {
      const match = /^#ticket=([A-Za-z0-9_-]{16,128})$/.exec(window.location.hash);
      if (!match) { return; }
      window.history.replaceState(null, "", window.location.pathname + window.location.search);
      try {
        const res = await api("/auth/exchange", { method: "POST", body: JSON.stringify({ ticket: match[1] }) });
        const body = await res.json();
        if (typeof body.key === "string" && body.key) {
          els.key.value = body.key;
          store.set("quail.key", body.key);
          updateKeyButton();
        }
      } catch (error) {
        setStatus("The link from Quail has expired or was used. Open the chat from Quail's menu again, or paste the key.", true);
      }
    }

    // A service worker another page left on this origin (llama.cpp's, when the app ran llama-server here)
    // would keep serving its own cached page; this page has none, so any registration goes.
    async function retireServiceWorkers() {
      try {
        if (!navigator.serviceWorker) { return; }
        for (const registration of await navigator.serviceWorker.getRegistrations()) { await registration.unregister(); }
        // Its cached copies too: this page keeps nothing in Cache Storage.
        if (window.caches) { for (const name of await caches.keys()) { await caches.delete(name); } }
      } catch (e) { /* not allowed here: nothing to do */ }
    }

    async function start() {
      retireServiceWorkers();
      // On a narrow window the chat list is an overlay, closed until asked for.
      const narrow = window.matchMedia("(max-width: 760px)");
      document.body.classList.toggle("side-closed", narrow.matches);
      narrow.addEventListener("change", () => document.body.classList.toggle("side-closed", narrow.matches));
      els.key.value = store.get("quail.key");
      updateKeyButton();
      buildSettings();
      try { conversations = (await db.all()) || []; } catch (e) { conversations = []; }
      conversations.sort((a, b) => b.updated - a.updated);
      await signIn();
      await refreshModels();
      showBuild();
      const last = conversations.find((c) => c.id === store.get("quail.current"));
      select(last || blankConversation());
    }
    start();

    """#
}
