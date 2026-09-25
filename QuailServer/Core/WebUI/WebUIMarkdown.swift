extension WebUI {
    /// A small Markdown reader for model replies: headings, paragraphs with line breaks, emphasis, strong,
    /// strikethrough, inline code, links, fenced code, block quotes, nested lists, tables, rules, and maths
    /// shown as code. It never produces HTML: `MD.parse` builds a plain tree (checked by `WebUITests` in
    /// JavaScriptCore) and `MD.render` turns that tree into DOM nodes with `textContent`. HTML in the input
    /// stays text, and only http(s) and mailto links become links.
    static let markdown = #"""

    "use strict";
    const MD = (() => {
      const fenceOpen = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)/;
      const isBlank = (line) => /^\s*$/.test(line);
      const indentOf = (line) => line.length - line.replace(/^ +/, "").length;
      const listMarker = (line) => /^( *)([-*+]|\d{1,9}[.)])( +|$)/.exec(line);
      const isRule = (line) => /^ {0,3}([-*_])( *\1){2,} *$/.test(line);
      const isHeading = (line) => /^ {0,3}#{1,6}(\s|$)/.test(line);
      const isQuote = (line) => /^ {0,3}>/.test(line);
      const isMathFence = (line) => /^ {0,3}\$\$/.test(line);
      const isTableRule = (line) => line.includes("-") && /^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$/.test(line);
      const startsBlock = (line) => fenceOpen.test(line) || isHeading(line) || isRule(line) || isQuote(line)
        || isMathFence(line) || listMarker(line) !== null;

      function cells(line) {
        let text = line.trim();
        if (text.startsWith("|")) { text = text.slice(1); }
        if (text.endsWith("|") && !text.endsWith("\\|")) { text = text.slice(0, -1); }
        const out = [];
        let cell = "";
        for (let i = 0; i < text.length; i++) {
          if (text[i] === "\\" && text[i + 1] === "|") { cell += "|"; i++; continue; }
          if (text[i] === "|") { out.push(cell.trim()); cell = ""; continue; }
          cell += text[i];
        }
        out.push(cell.trim());
        return out;
      }

      function blocks(lines) {
        const out = [];
        let i = 0;
        while (i < lines.length) {
          const line = lines[i];
          if (isBlank(line)) { i++; continue; }
          let m = fenceOpen.exec(line);
          if (m) {
            const marker = m[1];
            const close = new RegExp("^ {0,3}" + (marker[0] === "`" ? "`" : "~") + "{" + marker.length + ",}\\s*$");
            const body = [];
            i++;
            while (i < lines.length && !close.test(lines[i])) { body.push(lines[i]); i++; }
            i++;
            out.push({ t: "code", lang: m[2] || "", text: body.join("\n") });
            continue;
          }
          if (isMathFence(line)) {
            const first = line.replace(/^ {0,3}\$\$/, "");
            const body = [];
            if (/\$\$\s*$/.test(first) && first.trim() !== "") {
              body.push(first.replace(/\$\$\s*$/, ""));
              i++;
            } else {
              if (first.trim() !== "") { body.push(first); }
              i++;
              while (i < lines.length && !/\$\$\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
              if (i < lines.length) { const last = lines[i].replace(/\$\$\s*$/, ""); if (last.trim()) { body.push(last); } i++; }
            }
            out.push({ t: "math", text: body.join("\n").trim() });
            continue;
          }
          m = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*$/.exec(line);
          if (m) {
            out.push({ t: "h", level: m[1].length, inline: inline((m[2] || "").replace(/\s+#+$/, "")) });
            i++;
            continue;
          }
          if (isRule(line)) { out.push({ t: "hr" }); i++; continue; }
          if (isQuote(line)) {
            const body = [];
            while (i < lines.length && !isBlank(lines[i])) {
              if (isQuote(lines[i])) { body.push(lines[i].replace(/^ {0,3}> ?/, "")); }
              else if (body.length && !startsBlock(lines[i])) { body.push(lines[i]); }
              else { break; }
              i++;
            }
            out.push({ t: "quote", blocks: blocks(body) });
            continue;
          }
          if (line.includes("|") && i + 1 < lines.length && isTableRule(lines[i + 1])) {
            const head = cells(line);
            const align = cells(lines[i + 1]).map((c) =>
              c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : "");
            const rows = [];
            i += 2;
            while (i < lines.length && !isBlank(lines[i]) && lines[i].includes("|")) { rows.push(cells(lines[i])); i++; }
            out.push({ t: "table", align, head: head.map(inline), rows: rows.map((row) => head.map((_, c) => inline(row[c] || ""))) });
            continue;
          }
          m = listMarker(line);
          if (m) {
            const ordered = /\d/.test(m[2]);
            const indent = m[1].length;
            const items = [];
            while (i < lines.length) {
              const item = listMarker(lines[i]);
              if (!item || item[1].length !== indent || /\d/.test(item[2]) !== ordered) { break; }
              const width = item[0].length > item[1].length + item[2].length + 4 ? item[1].length + item[2].length + 1 : item[0].length;
              const body = [lines[i].slice(width)];
              i++;
              while (i < lines.length) {
                const next = lines[i];
                if (isBlank(next)) {
                  let j = i + 1;
                  while (j < lines.length && isBlank(lines[j])) { j++; }
                  if (j < lines.length && indentOf(lines[j]) >= width) { body.push(""); i++; continue; }
                  break;
                }
                if (indentOf(next) >= width) { body.push(next.slice(width)); i++; continue; }
                if (startsBlock(next)) { break; }
                body.push(next.trim());
                i++;
              }
              items.push(blocks(body));
            }
            out.push({ t: "list", ordered, start: ordered ? parseInt(m[2], 10) : 1, items });
            continue;
          }
          const para = [];
          while (i < lines.length && !isBlank(lines[i]) && (para.length === 0 || !startsBlock(lines[i]))) {
            para.push(lines[i].trim());
            i++;
          }
          out.push({ t: "p", inline: inline(para.join("\n")) });
        }
        return out;
      }

      // The end of a run of exactly `marker` that can close emphasis (not after a space), or -1.
      function findClose(text, from, marker) {
        let j = from;
        while (j < text.length) {
          j = text.indexOf(marker[0], j);
          if (j < 0) { return -1; }
          let run = 1;
          while (text[j + run] === marker[0]) { run++; }
          if (run === marker.length && !/\s/.test(text[j - 1] || " ")) { return j; }
          j += run;
        }
        return -1;
      }

      function closingBracket(text, open) {
        let depth = 0;
        for (let i = open; i < text.length; i++) {
          if (text[i] === "\\") { i++; continue; }
          if (text[i] === "[") { depth++; }
          if (text[i] === "]") { depth--; if (depth === 0) { return i; } }
        }
        return -1;
      }

      function inline(text) {
        const out = [];
        let buffer = "";
        const flush = () => { if (buffer) { out.push({ t: "text", text: buffer }); buffer = ""; } };
        let i = 0;
        while (i < text.length) {
          const c = text[i];
          if (c === "\\" && i + 1 < text.length && /[\\`*_{}[\]()#+\-.!|~$<>]/.test(text[i + 1])) {
            buffer += text[i + 1];
            i += 2;
            continue;
          }
          if (c === "\n") { flush(); out.push({ t: "br" }); i++; continue; }
          if (c === "`") {
            let n = 1;
            while (text[i + n] === "`") { n++; }
            const ticks = "`".repeat(n);
            const end = text.indexOf(ticks, i + n);
            if (end > 0) {
              flush();
              const code = text.slice(i + n, end);
              out.push({ t: "code", text: /^ .* $/.test(code) ? code.slice(1, -1) : code });
              i = end + n;
              continue;
            }
            buffer += ticks;
            i += n;
            continue;
          }
          if (c === "$" && text[i + 1] && text[i + 1] !== " " && text[i + 1] !== "$") {
            const end = text.indexOf("$", i + 1);
            if (end > i + 1 && text[end - 1] !== " " && !/\d/.test(text[end + 1] || "")) {
              flush();
              out.push({ t: "math", text: text.slice(i + 1, end) });
              i = end + 1;
              continue;
            }
          }
          if (c === "[") {
            const close = closingBracket(text, i);
            if (close > 0 && text[close + 1] === "(") {
              const end = text.indexOf(")", close + 2);
              if (end > 0) {
                flush();
                const target = text.slice(close + 2, end).trim().split(/\s+/)[0].replace(/^<|>$/g, "");
                out.push({ t: "link", href: target, children: inline(text.slice(i + 1, close)) });
                i = end + 1;
                continue;
              }
            }
          }
          if (c === "*" || c === "_" || c === "~") {
            let n = 1;
            while (text[i + n] === c) { n++; }
            const intraword = c === "_" && /[A-Za-z0-9]/.test(text[i - 1] || "");
            const size = c === "~" ? 2 : Math.min(n, 3);
            if (!intraword && (c !== "~" || n === 2) && n === size) {
              const start = i + size;
              if (text[start] && !/\s/.test(text[start])) {
                const end = findClose(text, start, c.repeat(size));
                if (end > start) {
                  flush();
                  const kind = c === "~" ? "del" : size === 1 ? "em" : size === 2 ? "strong" : "strongem";
                  out.push({ t: kind, children: inline(text.slice(start, end)) });
                  i = end + size;
                  continue;
                }
              }
            }
            buffer += c.repeat(n);
            i += n;
            continue;
          }
          buffer += c;
          i++;
        }
        flush();
        return out;
      }

      function parse(source) {
        return blocks(String(source).replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n"));
      }

      function safeHref(href) {
        return /^(https?:\/\/[^\s]+|mailto:[^\s]+)$/i.test(href) ? href : null;
      }

      function make(tag, className, text) {
        const element = document.createElement(tag);
        if (className) { element.className = className; }
        if (text !== undefined) { element.textContent = text; }
        return element;
      }

      function renderInline(nodes, parent) {
        for (const node of nodes) {
          switch (node.t) {
            case "text": parent.append(document.createTextNode(node.text)); break;
            case "br": parent.append(make("br")); break;
            case "code": parent.append(make("code", "", node.text)); break;
            case "math": parent.append(make("code", "math", node.text)); break;
            case "em": case "strong": case "del": {
              const element = make(node.t);
              renderInline(node.children, element);
              parent.append(element);
              break;
            }
            case "strongem": {
              const strong = make("strong");
              const em = make("em");
              renderInline(node.children, em);
              strong.append(em);
              parent.append(strong);
              break;
            }
            case "link": {
              const href = safeHref(node.href);
              if (!href) { renderInline(node.children, parent); break; }
              const link = make("a");
              link.href = href;
              link.rel = "noopener noreferrer";
              link.target = "_blank";
              renderInline(node.children, link);
              parent.append(link);
              break;
            }
          }
        }
      }

      function renderBlocks(list, parent, copy) {
        for (const block of list) {
          switch (block.t) {
            case "p": { const p = make("p"); renderInline(block.inline, p); parent.append(p); break; }
            case "h": { const h = make("h" + block.level); renderInline(block.inline, h); parent.append(h); break; }
            case "hr": parent.append(make("hr")); break;
            case "code": case "math": {
              const wrap = make("div", "codeblock");
              if (block.t === "code" && block.lang) { wrap.append(make("span", "lang", block.lang)); }
              const pre = make("pre");
              pre.append(make("code", block.t === "math" ? "math" : "", block.text));
              wrap.append(pre);
              if (copy) {
                const button = make("button", "code-copy", "Copy");
                button.type = "button";
                button.addEventListener("click", () => copy(block.text, button));
                wrap.append(button);
              }
              parent.append(wrap);
              break;
            }
            case "quote": { const q = make("blockquote"); renderBlocks(block.blocks, q, copy); parent.append(q); break; }
            case "list": {
              const list = make(block.ordered ? "ol" : "ul");
              if (block.ordered && block.start !== 1) { list.start = block.start; }
              for (const item of block.items) { const li = make("li"); renderBlocks(item, li, copy); list.append(li); }
              parent.append(list);
              break;
            }
            case "table": {
              const table = make("table");
              const thead = make("thead");
              const headRow = make("tr");
              block.head.forEach((cell, c) => {
                const th = make("th", block.align[c] ? "align-" + block.align[c] : "");
                renderInline(cell, th);
                headRow.append(th);
              });
              thead.append(headRow);
              const tbody = make("tbody");
              for (const row of block.rows) {
                const tr = make("tr");
                row.forEach((cell, c) => {
                  const td = make("td", block.align[c] ? "align-" + block.align[c] : "");
                  renderInline(cell, td);
                  tr.append(td);
                });
                tbody.append(tr);
              }
              table.append(thead, tbody);
              parent.append(table);
              break;
            }
          }
        }
      }

      function render(source, parent, copy) {
        parent.replaceChildren();
        renderBlocks(parse(source), parent, copy);
      }

      return { parse, render, safeHref };
    })();

    """#
}
