extension WebUI {
    /// The page's own code: conversations in IndexedDB, settings in localStorage, the model picker, the
    /// chat stream, and the sign-in ticket from the Quail app (ADR D-042). Every request goes through `api`,
    /// to a path on this server.
    static let app = #"""

    const $ = (id) => document.getElementById(id);
    const els = {};
    for (const id of ["sidebar", "new-chat", "search", "conversations", "export", "import", "import-file",
                      "toggle-sidebar", "build", "key", "model", "load", "unload", "refresh", "open-settings",
                      "system", "log", "status", "form", "input", "send", "stop", "timings",
                      "attachments", "attach", "attach-file",
                      "settings", "settings-fields", "settings-reset", "settings-close"]) {
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
        setStatus("This server needs an API key. Paste it above (Quail: Settings, Endpoint, Copy).", true);
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
      if (conversation.model && models.some((m) => m.id === conversation.model)) { els.model.value = conversation.model; }
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
        els.log.append(make("p", "empty", "Ask something to start. Chats are kept in this browser."));
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

    async function refreshModels() {
      try {
        const res = await api("/v1/models");
        models = (await res.json()).data || [];
        const wanted = els.model.value || (current && current.model) || store.get("quail.model");
        els.model.replaceChildren();
        for (const model of models) {
          const option = make("option");
          option.value = model.id;
          const parts = [formatOf(model).toUpperCase(), model.status && model.status.value].filter(Boolean);
          const vision = (model.architecture && (model.architecture.input_modalities || []).includes("image")) ? ", vision" : "";
          option.textContent = model.id + " (" + parts.join(", ") + vision + ")";
          els.model.append(option);
        }
        if (models.some((model) => model.id === wanted)) { els.model.value = wanted; }
        if (!models.length) { setStatus("No models yet. Add one in Quail.", false); }
        else if (els.status.className !== "error") { setStatus("", false); }
        updateSettingsAvailability();
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
      setStatus((action === "load" ? "Loading " : "Unloading ") + model + "…", false);
      try {
        await api("/models/" + action, { method: "POST", body: JSON.stringify({ model }) });
        for (let tries = 0; tries < 600; tries++) {
          const list = await refreshModels();
          const entry = list.find((m) => m.id === model);
          if (!entry || !entry.status || entry.status.value !== "loading") { break; }
          await sleep(1000);
        }
        setStatus("", false);
      } catch (error) { fail(error); }
    }

    // MARK: settings

    // `only`: which model formats the server honours it for; others ignore it (samplers) or refuse it (JSON mode).
    const settingSpec = [
      { key: "temperature", label: "Temperature", kind: "number", step: "0.05", min: "0", placeholder: "0.8" },
      { key: "max_tokens", label: "Max tokens", kind: "number", step: "1", min: "1", placeholder: "no limit" },
      { key: "top_k", label: "Top-k", kind: "number", step: "1", min: "0", placeholder: "40" },
      { key: "top_p", label: "Top-p", kind: "number", step: "0.01", min: "0", placeholder: "0.95" },
      { key: "min_p", label: "Min-p", kind: "number", step: "0.01", min: "0", placeholder: "0.05" },
      { key: "seed", label: "Seed", kind: "number", step: "1", placeholder: "random" },
      { key: "repeat_penalty", label: "Repeat penalty", kind: "number", step: "0.01", placeholder: "1.0" },
      { key: "presence_penalty", label: "Presence penalty", kind: "number", step: "0.01", placeholder: "0" },
      { key: "frequency_penalty", label: "Frequency penalty", kind: "number", step: "0.01", placeholder: "0" },
      { key: "dry_multiplier", label: "DRY multiplier", kind: "number", step: "0.05", min: "0", placeholder: "0 (off)", only: "gguf" },
      { key: "xtc_probability", label: "XTC probability", kind: "number", step: "0.05", min: "0", placeholder: "0 (off)", only: "gguf" },
      { key: "xtc_threshold", label: "XTC threshold", kind: "number", step: "0.01", placeholder: "0.1", only: "gguf" },
      { key: "typical_p", label: "Typical-p", kind: "number", step: "0.01", placeholder: "1 (off)", only: "gguf" },
      { key: "top_n_sigma", label: "Top-n-sigma", kind: "number", step: "0.1", placeholder: "-1 (off)", only: "gguf" },
      { key: "mirostat", label: "Mirostat", kind: "select", options: [["", "Off"], ["1", "Mirostat 1"], ["2", "Mirostat 2"]], only: "gguf" },
      { key: "thinking", label: "Thinking", kind: "select", options: [["", "Model's default"], ["on", "On"], ["off", "Off"]] },
      { key: "json", label: "Reply format", kind: "select", options: [["", "Text"], ["json", "JSON object"]], only: "gguf" },
      { key: "stop", label: "Stop strings (one per line)", kind: "textarea", wide: true },
    ];
    let settings = {};
    try { settings = JSON.parse(store.get("quail.settings") || "{}") || {}; } catch (e) { settings = {}; }
    const inputs = {};

    function buildSettings() {
      els["settings-fields"].replaceChildren();
      for (const spec of settingSpec) {
        const field = make("label", "field" + (spec.wide ? " wide" : ""));
        field.append(make("span", "", spec.label));
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
        input.value = settings[spec.key] === undefined ? "" : settings[spec.key];
        input.addEventListener("change", () => {
          if (input.value === "") { delete settings[spec.key]; } else { settings[spec.key] = input.value; }
          store.set("quail.settings", JSON.stringify(settings));
        });
        field.append(input);
        if (spec.only) { const note = make("span", "note", "GGUF models only"); field.append(note); field.dataset.only = spec.only; }
        inputs[spec.key] = { input, field, spec };
        els["settings-fields"].append(field);
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
      if (current.messages.length) { save(current); }
    });
    els.load.addEventListener("click", () => manage("load"));
    els.unload.addEventListener("click", () => manage("unload"));
    els.refresh.addEventListener("click", () => { refreshModels(); showBuild(); });
    els.model.addEventListener("change", () => { store.set("quail.model", els.model.value); updateSettingsAvailability(); });
    els.key.addEventListener("change", () => { store.set("quail.key", els.key.value.trim()); refreshModels(); showBuild(); });
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
        }
      } catch (error) {
        setStatus("The link from Quail has expired or was used. Open the chat from Quail's menu again, or paste the key.", true);
      }
    }

    async function start() {
      // On a narrow window the chat list is an overlay, closed until asked for.
      const narrow = window.matchMedia("(max-width: 760px)");
      document.body.classList.toggle("side-closed", narrow.matches);
      narrow.addEventListener("change", () => document.body.classList.toggle("side-closed", narrow.matches));
      els.key.value = store.get("quail.key");
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
