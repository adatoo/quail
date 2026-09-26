extension WebUI {
    static let style = """

    :root { color-scheme: light dark; --bg: #fbfaf7; --fg: #1d1c1a; --muted: #6d6a63; --line: #e2ded4; --panel: #f3f0e9; --field: #ffffff; --side: #f4f1ea; --user: #e6edf7; --accent: #2f6f4f; --accent-fg: #ffffff; --error: #b3261e; --code: #eeeae1; --ring: rgba(47, 111, 79, 0.45); --shadow: 0 1px 2px rgba(0, 0, 0, 0.06), 0 4px 16px rgba(0, 0, 0, 0.06); }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #171614; --fg: #ebe8e1; --muted: #9b978d; --line: #34312c; --panel: #211f1c; --field: #1c1b18; --side: #1b1a17; --user: #23303e; --accent: #6cc39a; --accent-fg: #10231a; --error: #f2857d; --code: #2a2824; --ring: rgba(108, 195, 154, 0.5); --shadow: 0 1px 2px rgba(0, 0, 0, 0.3), 0 4px 16px rgba(0, 0, 0, 0.3); }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { height: 100%; }
    body { margin: 0; display: flex; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, -apple-system, sans-serif; }
    input, select, textarea, button { font: inherit; color: inherit; }
    input, select, textarea { background: var(--field); border: 1px solid var(--line); border-radius: 8px; padding: 0.4rem 0.6rem; }
    button { cursor: pointer; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 0.35rem 0.75rem; }
    button:hover:not(:disabled) { border-color: var(--muted); }
    button:disabled { opacity: 0.5; cursor: default; }
    :focus-visible { outline: 2px solid var(--ring); outline-offset: 2px; }
    input:focus-visible, select:focus-visible, textarea:focus-visible { outline-offset: 0; border-color: var(--accent); }
    button.primary, button.send { background: var(--accent); border-color: var(--accent); color: var(--accent-fg); font-weight: 600; }
    button.ghost { background: transparent; border-color: transparent; color: var(--muted); }
    button.ghost:hover:not(:disabled), button.ghost[aria-expanded=true] { background: var(--panel); border-color: var(--line); color: var(--fg); }
    button.link { background: none; border: none; padding: 0.2rem 0.3rem; color: var(--muted); font-size: 0.85rem; }
    button.link:hover { color: var(--fg); text-decoration: underline; }
    button.icon { display: inline-grid; place-items: center; width: 2rem; height: 2rem; padding: 0; background: transparent; border-color: transparent; color: var(--muted); }
    button.icon:hover:not(:disabled) { background: var(--panel); border-color: var(--line); color: var(--fg); }
    button.icon svg { width: 1.15rem; height: 1.15rem; }
    button.small { padding: 0.25rem 0.65rem; font-size: 0.85rem; }
    label { color: var(--muted); font-size: 0.85rem; }
    ::placeholder { color: var(--muted); opacity: 0.75; }
    .hint { color: var(--muted); font-size: 0.8rem; margin: 0; }

    #sidebar { width: 16rem; flex: none; display: flex; flex-direction: column; gap: 0.6rem; padding: 0.75rem; background: var(--side); border-right: 1px solid var(--line); }
    body.side-closed #sidebar { display: none; }
    .side-top { display: flex; flex-direction: column; gap: 0.5rem; }
    #conversations { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; padding: 2px; margin: -2px; }
    .conv { display: flex; align-items: center; gap: 0.25rem; border-radius: 8px; }
    .conv:hover { background: var(--panel); }
    .conv.current { background: var(--panel); box-shadow: inset 3px 0 0 var(--accent); }
    .conv > button.open { flex: 1; min-width: 0; text-align: left; background: none; border-color: transparent; padding: 0.35rem 0.55rem; }
    .conv .title { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .conv .when { display: block; color: var(--muted); font-size: 0.75rem; }
    .conv .tools { display: none; gap: 0.15rem; padding-right: 0.25rem; }
    .conv:hover .tools, .conv.current .tools, .conv.editing .tools { display: flex; }
    .conv .tools button, .msg-actions button, .code-copy { font-size: 0.72rem; padding: 0.1rem 0.4rem; background: transparent; }
    .conv input { flex: 1; min-width: 0; margin: 0.15rem; }
    .side-bottom { display: flex; flex-direction: column; gap: 0.25rem; border-top: 1px solid var(--line); padding-top: 0.5rem; }
    .side-links { display: flex; gap: 0.5rem; }
    #build { color: var(--muted); font-size: 0.75rem; padding: 0 0.3rem; }

    main { flex: 1; min-width: 0; height: 100vh; height: 100dvh; margin: 0 auto; max-width: 52rem; padding: 0.6rem 1rem 0.9rem; display: flex; flex-direction: column; gap: 0.6rem; }
    .topbar { display: flex; align-items: center; gap: 0.4rem; flex-wrap: wrap; }
    .spacer { flex: 1; }
    .model-picker { position: relative; display: flex; align-items: center; min-width: 12rem; flex: 0 1 26rem; }
    .picker { display: flex; align-items: center; gap: 0.5rem; width: 100%; min-width: 0; text-align: left; padding: 0.3rem 0.5rem 0.3rem 0.65rem; }
    .picker-text { display: flex; flex-direction: column; min-width: 0; flex: 1; line-height: 1.2; }
    .picker-name, .option-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .picker-meta, .option-meta { color: var(--muted); font-size: 0.72rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .badge { display: inline-block; font-size: 0.62rem; font-weight: 600; letter-spacing: 0.02em; padding: 0 0.3rem; margin-right: 0.35rem; border-radius: 4px; vertical-align: 1px; }
    .badge.gguf { color: #2f6fd6; background: rgba(47, 111, 214, 0.13); }
    .badge.mlx { color: #9a3fc4; background: rgba(154, 63, 196, 0.13); }
    .caret { width: 1rem; height: 1rem; flex: none; color: var(--muted); }
    .picker-list { position: absolute; top: calc(100% + 4px); left: 0; z-index: 20; width: max(100%, 22rem); max-height: 60vh; overflow-y: auto; margin: 0; padding: 0.3rem; list-style: none; background: var(--bg); border: 1px solid var(--line); border-radius: 10px; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16); }
    .picker-list[hidden] { display: none; }
    .option { display: flex; align-items: center; gap: 0.55rem; padding: 0.45rem 0.55rem; border-radius: 7px; cursor: pointer; }
    .option.active { background: var(--panel); }
    .option[aria-selected="true"] .option-name { font-weight: 600; }
    .option-text { display: flex; flex-direction: column; min-width: 0; flex: 1; }
    .option-state { font-size: 0.7rem; color: var(--muted); flex: none; }
    .option-state.loaded { color: #2e9d63; }
    .option-state.failed { color: var(--error); }
    .dot { flex: none; width: 0.5rem; height: 0.5rem; border-radius: 50%; background: var(--line); }
    .dot.loaded { background: #2e9d63; }
    .dot.loading { background: #d99b2b; }
    .dot.failed { background: var(--error); }
    .panel { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.75rem; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; }
    .panel textarea, .panel input { width: 100%; }

    #log { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 1rem; padding: 0.5rem 2px; }
    .empty { color: var(--muted); margin: auto; text-align: center; max-width: 26rem; }
    .empty strong { display: block; color: var(--fg); font-size: 1.15rem; margin-bottom: 0.3rem; }
    .msg { max-width: 88%; }
    .msg.user { align-self: flex-end; background: var(--user); border-radius: 14px 14px 4px 14px; padding: 0.55rem 0.85rem; }
    .msg.assistant { align-self: flex-start; width: 100%; max-width: 100%; padding: 0 0.15rem; }
    .msg.error .md, .msg.error > p { color: var(--error); }
    .msg pre.plain { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; }
    .msg details.thinking { margin-bottom: 0.4rem; border-left: 2px solid var(--line); padding-left: 0.6rem; }
    .msg details.thinking summary { color: var(--muted); cursor: pointer; font-size: 0.85rem; }
    .msg details.thinking pre { margin: 0.3rem 0 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit; color: var(--muted); font-size: 0.9rem; }
    .msg .call { font: 0.85rem ui-monospace, Menlo, monospace; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; margin: 0.3rem 0 0; }
    .msg .meta { display: flex; align-items: center; gap: 0.5rem; margin-top: 0.3rem; color: var(--muted); font-size: 0.78rem; flex-wrap: wrap; min-height: 1.5rem; }
    .msg.user .meta { min-height: 0; margin-top: 0.15rem; }
    .msg-actions { display: flex; gap: 0.15rem; opacity: 0; transition: opacity 0.1s; }
    .msg:hover .msg-actions, .msg:focus-within .msg-actions { opacity: 1; }
    .msg textarea.edit { width: 100%; min-height: 5rem; }

    .md { overflow-wrap: anywhere; }
    .md > :first-child { margin-top: 0; }
    .md > :last-child { margin-bottom: 0; }
    .md p, .md ul, .md ol, .md blockquote, .md table, .md .codeblock { margin: 0.55rem 0; }
    .md h1, .md h2, .md h3, .md h4, .md h5, .md h6 { margin: 0.9rem 0 0.4rem; line-height: 1.3; }
    .md h1 { font-size: 1.3rem; } .md h2 { font-size: 1.18rem; } .md h3 { font-size: 1.06rem; } .md h4, .md h5, .md h6 { font-size: 1rem; }
    .md ul, .md ol { padding-left: 1.5rem; }
    .md li > p { margin: 0.15rem 0; }
    .md blockquote { border-left: 3px solid var(--line); padding-left: 0.75rem; color: var(--muted); }
    .md code { font: 0.9em ui-monospace, Menlo, monospace; background: var(--code); border-radius: 4px; padding: 0.05rem 0.3rem; }
    .md .codeblock { position: relative; }
    .md .codeblock pre { margin: 0; padding: 0.7rem 0.8rem; background: var(--code); border-radius: 8px; overflow-x: auto; }
    .md .codeblock pre code { background: none; padding: 0; white-space: pre; }
    .md .codeblock .lang { position: absolute; top: 0.3rem; left: 0.7rem; color: var(--muted); font-size: 0.7rem; }
    .md .codeblock .lang + pre { padding-top: 1.4rem; }
    .code-copy { position: absolute; top: 0.3rem; right: 0.4rem; }
    .md code.math { font-style: italic; }
    .md hr { border: none; border-top: 1px solid var(--line); margin: 0.9rem 0; }
    .md table { border-collapse: collapse; display: block; overflow-x: auto; }
    .md th, .md td { border: 1px solid var(--line); padding: 0.3rem 0.55rem; }
    .md .align-center { text-align: center; } .md .align-right { text-align: right; }
    .md a { color: var(--accent); }

    #status { margin: 0; min-height: 1.2em; color: var(--muted); font-size: 0.85rem; }
    #status:empty { display: none; }
    #status.error { color: var(--error); }
    .composer { background: var(--field); border: 1px solid var(--line); border-radius: 14px; padding: 0.55rem 0.6rem 0.45rem; box-shadow: var(--shadow); }
    .composer:focus-within { border-color: var(--accent); }
    .composer.dropping { border-style: dashed; border-color: var(--accent); }
    .composer textarea { width: 100%; border: none; background: transparent; resize: none; padding: 0.2rem 0.3rem; max-height: 14rem; min-height: 1.6rem; }
    .composer textarea:focus-visible { outline: none; }
    .composer-bar { display: flex; align-items: center; gap: 0.5rem; margin-top: 0.25rem; }
    .composer-bar .hint { flex: 1; }
    #timings { color: var(--muted); font-size: 0.78rem; }
    button.stop { border-color: var(--error); color: var(--error); background: transparent; }
    #attachments { display: flex; gap: 0.4rem; flex-wrap: wrap; margin-bottom: 0.4rem; }
    .chip { display: flex; align-items: center; gap: 0.35rem; border: 1px solid var(--line); border-radius: 8px; padding: 0.2rem 0.35rem; background: var(--panel); font-size: 0.8rem; max-width: 16rem; }
    .chip img, .msg .images img { display: block; max-height: 3.5rem; max-width: 6rem; border-radius: 6px; object-fit: cover; }
    .chip .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .chip button { font-size: 0.75rem; padding: 0 0.35rem; }
    .msg .images { display: flex; gap: 0.35rem; flex-wrap: wrap; margin-bottom: 0.35rem; }
    .msg .images img { max-height: 10rem; max-width: 14rem; }
    .msg .files { display: flex; gap: 0.35rem; flex-wrap: wrap; margin-bottom: 0.35rem; }

    dialog { max-width: 40rem; width: calc(100% - 2rem); max-height: calc(100vh - 3rem); border: 1px solid var(--line); border-radius: 14px; background: var(--bg); color: var(--fg); padding: 1rem 1.25rem; box-shadow: var(--shadow); }
    dialog[open] { display: flex; flex-direction: column; }
    dialog::backdrop { background: rgba(0, 0, 0, 0.35); }
    .dialog-head { display: flex; align-items: center; justify-content: space-between; }
    dialog h2 { margin: 0; font-size: 1.1rem; }
    dialog > .hint { margin: 0.2rem 0 0.6rem; }
    /* Room inside the scrolling area, so a focused field's ring isn't cut off at the edges. */
    #settings-fields { overflow-y: auto; padding: 4px 6px 6px; margin: 0 -6px; flex: 1; min-height: 0; }
    .group { border: none; margin: 0 0 0.9rem; padding: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem 1rem; }
    .group legend { grid-column: 1 / -1; padding: 0; margin-bottom: 0.1rem; font-weight: 600; font-size: 0.9rem; }
    .field { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
    .field.wide { grid-column: 1 / -1; }
    .field-head { display: flex; align-items: center; gap: 0.3rem; }
    .field-head label { color: var(--fg); font-size: 0.85rem; }
    .info-button { width: 1.25rem; height: 1.25rem; padding: 0; border-radius: 50%; font-size: 0.75rem; line-height: 1; color: var(--muted); background: transparent; border-color: var(--line); }
    .info-button[aria-expanded=true] { background: var(--accent); border-color: var(--accent); color: var(--accent-fg); }
    .field .tag { margin-left: auto; font-size: 0.7rem; color: var(--muted); border: 1px solid var(--line); border-radius: 999px; padding: 0 0.4rem; }
    .field .info { font-size: 0.8rem; color: var(--muted); background: var(--panel); border-radius: 8px; padding: 0.5rem 0.6rem; margin: 0.1rem 0 0.2rem; }
    .field .info p { margin: 0 0 0.3rem; }
    .field .info p:last-child { margin-bottom: 0; }
    .field .info .good { color: #2e9d63; }
    .field .info .bad { color: var(--error); }
    .field.unavailable input, .field.unavailable select, .field.unavailable label { opacity: 0.55; }
    dialog .actions { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 0.75rem; }

    @media (max-width: 760px) {
      #sidebar { position: fixed; z-index: 2; inset: 0 auto 0 0; box-shadow: 0 0 1rem rgba(0, 0, 0, 0.25); }
      .group { grid-template-columns: 1fr; }
      .composer-bar .hint { display: none; }
      .msg { max-width: 100%; }
      #system-toggle, #key-toggle { font-size: 0.8rem; }
    }

    """
}
