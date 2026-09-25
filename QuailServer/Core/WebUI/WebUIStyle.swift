extension WebUI {
    static let style = """

    :root { color-scheme: light dark; --bg: #fbfaf7; --fg: #1d1c1a; --muted: #6d6a63; --line: #dcd8ce; --panel: #f1eee6; --side: #f4f1ea; --user: #e4ecf7; --accent: #2f6f4f; --error: #b3261e; --code: #ece8de; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #171614; --fg: #ebe8e1; --muted: #9b978d; --line: #35322d; --panel: #211f1c; --side: #1c1b18; --user: #22303f; --accent: #6cc39a; --error: #f2857d; --code: #2a2824; }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { height: 100%; }
    body { margin: 0; display: flex; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, -apple-system, sans-serif; }
    input, select, textarea, button { font: inherit; color: inherit; background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 0.35rem 0.6rem; }
    button { cursor: pointer; }
    button:hover:not(:disabled) { border-color: var(--accent); }
    button:disabled { opacity: 0.5; cursor: default; }
    button[type=submit] { background: var(--accent); border-color: var(--accent); color: var(--bg); font-weight: 600; }
    label { color: var(--muted); font-size: 0.85rem; }
    ::placeholder { color: var(--muted); opacity: 0.7; font-style: italic; }

    #sidebar { width: 16rem; flex: none; display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem; background: var(--side); border-right: 1px solid var(--line); }
    body.side-closed #sidebar { display: none; }
    .side-top { display: flex; flex-direction: column; gap: 0.4rem; }
    #conversations { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
    .conv { display: flex; align-items: center; gap: 0.25rem; border-radius: 6px; }
    .conv.current { background: var(--panel); }
    .conv > button.open { flex: 1; min-width: 0; text-align: left; background: none; border-color: transparent; }
    .conv .title { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .conv .when { display: block; color: var(--muted); font-size: 0.75rem; }
    .conv .tools { display: none; gap: 0.2rem; }
    .conv:hover .tools, .conv.current .tools, .conv.editing .tools { display: flex; }
    .conv .tools button, .msg-actions button, .code-copy { font-size: 0.75rem; padding: 0.1rem 0.4rem; }
    .conv input { flex: 1; min-width: 0; }
    .side-bottom { display: flex; gap: 0.4rem; }
    .side-bottom button { flex: 1; }

    main { flex: 1; min-width: 0; height: 100vh; height: 100dvh; margin: 0 auto; max-width: 56rem; padding: 0.75rem 1rem; display: flex; flex-direction: column; gap: 0.6rem; }
    header { display: flex; align-items: baseline; gap: 0.75rem; flex-wrap: wrap; }
    #toggle-sidebar { padding: 0.15rem 0.5rem; font-size: 0.85rem; }
    h1 { margin: 0; font-size: 1.2rem; }
    #build { color: var(--muted); font-size: 0.85rem; flex: 1; }
    .bar { display: flex; gap: 0.4rem; flex-wrap: wrap; }
    .bar select { flex: 1; min-width: 12rem; }
    .system textarea { width: 100%; margin-top: 0.4rem; }
    summary { color: var(--muted); cursor: pointer; font-size: 0.85rem; }

    #log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 0.75rem; padding: 0.25rem 0; }
    .empty { color: var(--muted); margin: auto; text-align: center; }
    .msg { border: 1px solid var(--line); border-radius: 8px; padding: 0.5rem 0.75rem; max-width: 92%; }
    .msg.user { align-self: flex-end; background: var(--user); }
    .msg.assistant { align-self: flex-start; background: var(--panel); width: 92%; }
    .msg.error { border-color: var(--error); }
    .msg pre.plain { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; }
    .msg details.thinking { margin-bottom: 0.4rem; }
    .msg details.thinking pre { margin: 0.3rem 0 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; color: var(--muted); font-size: 0.9rem; }
    .msg .call { font: 0.85rem ui-monospace, Menlo, monospace; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; margin: 0.3rem 0 0; }
    .msg.user .meta { margin-top: 0.15rem; }
    .msg .meta:empty { display: none; }
    .msg .meta { display: flex; align-items: center; gap: 0.5rem; margin-top: 0.35rem; color: var(--muted); font-size: 0.8rem; flex-wrap: wrap; }
    .msg-actions { display: flex; gap: 0.25rem; opacity: 0; }
    .msg:hover .msg-actions, .msg:focus-within .msg-actions { opacity: 1; }
    .msg textarea.edit { width: 100%; min-height: 5rem; }

    .md { overflow-wrap: anywhere; }
    .md > :first-child { margin-top: 0; }
    .md > :last-child { margin-bottom: 0; }
    .md p, .md ul, .md ol, .md blockquote, .md table, .md .codeblock { margin: 0.5rem 0; }
    .md h1, .md h2, .md h3, .md h4, .md h5, .md h6 { margin: 0.8rem 0 0.4rem; line-height: 1.3; }
    .md h1 { font-size: 1.3rem; } .md h2 { font-size: 1.18rem; } .md h3 { font-size: 1.06rem; } .md h4, .md h5, .md h6 { font-size: 1rem; }
    .md ul, .md ol { padding-left: 1.5rem; }
    .md li > p { margin: 0.15rem 0; }
    .md blockquote { border-left: 3px solid var(--line); padding-left: 0.75rem; color: var(--muted); }
    .md code { font: 0.9em ui-monospace, Menlo, monospace; background: var(--code); border-radius: 4px; padding: 0.05rem 0.3rem; }
    .md .codeblock { position: relative; }
    .md .codeblock pre { margin: 0; padding: 0.6rem 0.75rem; background: var(--code); border-radius: 6px; overflow-x: auto; }
    .md .codeblock pre code { background: none; padding: 0; white-space: pre; }
    .md .codeblock .lang { position: absolute; top: 0.25rem; left: 0.6rem; color: var(--muted); font-size: 0.7rem; }
    .md .codeblock .lang + pre { padding-top: 1.3rem; }
    .code-copy { position: absolute; top: 0.25rem; right: 0.35rem; }
    .md code.math { font-style: italic; }
    .md hr { border: none; border-top: 1px solid var(--line); margin: 0.8rem 0; }
    .md table { border-collapse: collapse; display: block; overflow-x: auto; }
    .md th, .md td { border: 1px solid var(--line); padding: 0.25rem 0.5rem; }
    .md .align-center { text-align: center; } .md .align-right { text-align: right; }
    .md a { color: var(--accent); }

    #status { margin: 0; min-height: 1.4em; color: var(--muted); font-size: 0.9rem; }
    #status.error { color: var(--error); }
    #form textarea { width: 100%; resize: vertical; }
    .actions { display: flex; gap: 0.4rem; align-items: center; margin-top: 0.4rem; }
    #timings { color: var(--muted); font-size: 0.85rem; margin-left: auto; }

    dialog { max-width: 36rem; width: calc(100% - 2rem); border: 1px solid var(--line); border-radius: 10px; background: var(--bg); color: var(--fg); padding: 1rem 1.25rem; }
    dialog::backdrop { background: rgba(0, 0, 0, 0.35); }
    dialog h2 { margin: 0 0 0.25rem; font-size: 1.1rem; }
    .hint { color: var(--muted); font-size: 0.85rem; margin: 0 0 0.75rem; }
    #settings-fields { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem 1rem; max-height: 60vh; overflow-y: auto; }
    .field { display: flex; flex-direction: column; gap: 0.15rem; }
    .field.wide { grid-column: 1 / -1; }
    .field .note { color: var(--muted); font-size: 0.75rem; }
    .field.unavailable { opacity: 0.55; }
    dialog .actions { justify-content: flex-end; margin-top: 1rem; }

    @media (max-width: 760px) {
      #sidebar { position: fixed; z-index: 2; inset: 0 auto 0 0; box-shadow: 0 0 1rem rgba(0, 0, 0, 0.25); }
      #settings-fields { grid-template-columns: 1fr; }
      .msg, .msg.assistant { max-width: 100%; width: auto; }
    }

    """
}
