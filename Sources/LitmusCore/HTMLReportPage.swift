/// The fixed markup, style and script of `HTMLReport`; the run's data arrives as one JSON element the script reads, and
/// the script writes it into the page with `textContent` only.
enum HTMLReportPage {
    static func document(title: String, data: String) -> String {
        let escapedTitle = GitHubSummaryReport.html(title)
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escapedTitle)</title>
            <style>\(style)</style>
            </head>
            <body>
            <header><h1>\(escapedTitle)</h1><div id="scores"></div></header>
            <main><nav id="tree"></nav><section id="source"><p class="hint">Choose a file.</p></section></main>
            <aside id="drawer" hidden></aside>
            <script type="application/json" id="litmus-data">\(data)</script>
            <script>\(script)</script>
            </body>
            </html>

            """
    }

    static let style = """
        :root { color-scheme: light dark; --killed: #2e9e5b; --survived: #d9822b; --nocoverage: #8a8f98;
          --accepted: #3b7dd8; --other: #b05fc4; font: 13px/1.45 -apple-system, system-ui, sans-serif; }
        body { margin: 0; } header { padding: 8px 16px; border-bottom: 1px solid #8884; display: flex; gap: 16px;
          align-items: baseline; } h1 { font-size: 16px; margin: 0; }
        main { display: grid; grid-template-columns: minmax(220px, 28%) 1fr; height: calc(100vh - 44px); }
        nav { overflow: auto; border-right: 1px solid #8884; padding: 8px; } nav details { margin-left: 8px; }
        nav .file { cursor: pointer; padding: 1px 4px; border-radius: 4px; display: flex; justify-content: space-between; }
        nav .file:hover, nav .file.open { background: #8882; } .badge { font-variant-numeric: tabular-nums; opacity: .8; }
        #source { overflow: auto; font: 12px/1.5 ui-monospace, Menlo, monospace; }
        table { border-collapse: collapse; width: 100%; } td.n { color: #888; text-align: right; padding: 0 8px;
          user-select: none; width: 1%; } td.c { white-space: pre; padding-right: 16px; }
        tr.m { cursor: pointer; } tr.m td.n { border-left: 4px solid; } tr.killed td.n { border-color: var(--killed); }
        tr.survived { background: color-mix(in srgb, var(--survived) 18%, transparent); }
        tr.survived td.n { border-color: var(--survived); } tr.noCoverage td.n { border-color: var(--nocoverage); }
        tr.noCoverage { background: color-mix(in srgb, var(--nocoverage) 14%, transparent); }
        tr.accepted td.n { border-color: var(--accepted); } tr.other td.n { border-color: var(--other); }
        aside { position: fixed; right: 0; top: 44px; bottom: 0; width: min(560px, 90vw); overflow: auto;
          background: Canvas; border-left: 1px solid #8886; padding: 12px 16px; box-shadow: -4px 0 16px #0003; }
        .mutant { border: 1px solid #8884; border-radius: 6px; padding: 8px; margin: 8px 0; }
        .verdict { font-weight: 600; } pre { margin: 6px 0; padding: 6px; background: #8881; overflow: auto; }
        .del { color: #c0392b; } .add { color: #2e9e5b; } button { margin: 4px 4px 0 0; } .hint { padding: 16px; color: #888; }
        """

    static let script = """
        "use strict";
        const data = JSON.parse(document.getElementById("litmus-data").textContent);
        const detected = new Set(["killed", "crashed", "timeout"]);
        const undetected = new Set(["survived", "noCoverage"]);
        const el = (tag, text, cls) => { const e = document.createElement(tag); if (text != null) e.textContent = text;
          if (cls) e.className = cls; return e; };
        function score(mutants, domain) {
          const own = mutants.filter(m => !domain || m.domain === domain);
          const d = own.filter(m => detected.has(m.verdict)).length, u = own.filter(m => undetected.has(m.verdict)).length;
          return d + u === 0 ? null : Math.round(1000 * d / (d + u)) / 10;
        }
        function badge(mutants) {
          const parts = [["L", score(mutants, "logic")], ["UI", score(mutants, "ui")]].filter(p => p[1] !== null);
          return parts.map(p => p[0] + " " + p[1] + "%").join(" · ");
        }
        const scores = document.getElementById("scores");
        scores.append(el("span", "Score " + data.score));
        if (data.logic && data.ui) scores.append(el("span", " — Logic " + data.logic + " · UI " + data.ui));
        function classOf(mutants) {
          if (mutants.some(m => m.verdict === "survived" && !m.accepted)) return "survived";
          if (mutants.some(m => m.verdict === "noCoverage" && !m.accepted)) return "noCoverage";
          if (mutants.some(m => m.accepted)) return "accepted";
          if (mutants.every(m => detected.has(m.verdict))) return "killed";
          return "other";
        }
        const tree = {};
        for (const file of data.files) {
          let node = tree;
          const parts = file.path.split("/");
          for (const dir of parts.slice(0, -1)) node = node[dir] = node[dir] || {};
          (node["\\u0000files"] = node["\\u0000files"] || []).push(file);
        }
        const all = node => Object.entries(node).flatMap(([k, v]) => k === "\\u0000files" ? v.flatMap(f => f.mutants) : all(v));
        function renderTree(node, parent) {
          for (const [name, child] of Object.entries(node).filter(([k]) => k !== "\\u0000files").sort()) {
            const box = el("details"); box.open = true;
            const summary = el("summary", name + "/ "); summary.append(el("span", badge(all(child)), "badge"));
            box.append(summary); renderTree(child, box); parent.append(box);
          }
          for (const file of (node["\\u0000files"] || []).sort((a, b) => a.path.localeCompare(b.path))) {
            const row = el("div", null, "file");
            row.append(el("span", file.path.split("/").pop()), el("span", badge(file.mutants), "badge"));
            row.addEventListener("click", () => { document.querySelectorAll(".file.open").forEach(e => e.classList.remove("open"));
              row.classList.add("open"); showFile(file); });
            parent.append(row);
          }
        }
        renderTree(tree, document.getElementById("tree"));
        function showFile(file) {
          const section = document.getElementById("source");
          section.replaceChildren();
          const lines = file.source != null ? file.source.split("\\n") : [];
          const byLine = new Map();
          for (const m of file.mutants) for (let l = m.line; l <= m.endLine; l++) (byLine.get(l) || byLine.set(l, []).get(l)).push(m);
          const table = el("table");
          const count = Math.max(lines.length, ...file.mutants.map(m => m.endLine));
          for (let n = 1; n <= count; n++) {
            const row = el("tr"); const here = byLine.get(n);
            row.append(el("td", String(n), "n"), el("td", lines[n - 1] ?? "", "c"));
            if (here) { row.classList.add("m", classOf(here)); row.addEventListener("click", () => showLine(file, n, here)); }
            table.append(row);
          }
          section.append(table);
        }
        function copyButton(label, text) {
          const button = el("button", label);
          button.addEventListener("click", () => navigator.clipboard ? navigator.clipboard.writeText(text) : prompt("Copy:", text));
          return button;
        }
        function showLine(file, line, mutants) {
          const drawer = document.getElementById("drawer");
          drawer.replaceChildren(); drawer.hidden = false;
          const close = el("button", "Close"); close.addEventListener("click", () => { drawer.hidden = true; });
          drawer.append(close, el("h2", file.path + ":" + line));
          for (const m of mutants) {
            const box = el("div", null, "mutant");
            box.append(el("div", m.verdict + (m.accepted ? " (accepted)" : "") + " · " + m.operatorID + " · " + m.domain
              + " · " + m.milliseconds + " ms", "verdict"));
            const diff = el("pre");
            for (const l of m.original.split("\\n")) diff.append(el("div", "- " + l, "del"));
            for (const l of m.replacement.split("\\n")) diff.append(el("div", "+ " + l, "add"));
            box.append(diff, el("div", m.reason));
            if (m.accepted) box.append(el("div", "Accepted: " + m.accepted));
            if (m.reach.length) box.append(el("div", "Reached by: " + m.reach.join(", ")));
            box.append(copyButton("Copy rerun", "litmus run . --only-id " + m.id),
              copyButton("Copy accept", "litmus accept " + m.id + " --from '" + data.run + "' --reason '…'"));
            drawer.append(box);
          }
        }
        if (data.files.length) { document.querySelector(".file").classList.add("open"); showFile(data.files[0]); }
        """
}
