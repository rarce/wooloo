/* App-owned static notebook renderer. Notebook strings are data, never scripts. */
(() => {
    "use strict";
    const post = (body) => window.webkit.messageHandlers.notebook.postMessage(body);
    const root = document.getElementById("notebook");
    const md = window.markdownit({html: true, linkify: true, breaks: false});
    // Preserve TeX before Markdown's escape and emphasis rules consume its characters.
    md.inline.ruler.before("escape", "notebook_math", (state, silent) => {
        const start = state.pos;
        const pair = [["$$", "$$"], ["\\[", "\\]"], ["\\(", "\\)"], ["$", "$"]]
            .find(([left]) => state.src.startsWith(left, start));
        if (!pair) return false;
        const [left, right] = pair;
        let end = state.src.indexOf(right, start + left.length);
        while (end >= 0 && state.src[end - 1] === "\\") end = state.src.indexOf(right, end + right.length);
        if (end < 0 || end >= state.posMax || end === start + left.length) return false;
        if (!silent) state.push("text", "", 0).content = state.src.slice(start, end + right.length);
        state.pos = end + right.length;
        return true;
    });
    const priority = ["text/html", "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml", "text/markdown", "text/latex", "application/json", "text/plain"];
    let revision = "", pendingSource = null, imagePrefix = "", imageCounter = 0, svgCounter = 0, groups = [], pendingImages = new Map(), editable = false, rendering = false, last = null;
    // Every cell's section, in order, whether or not it is in the document; see `mount`.
    let sections = [], observer = null, mounted = new Set(), lastFind = null, activeFind = [], finding = false;
    // Above this many cells only the cells near the viewport stay in the document: the rest wait,
    // fully built, in slots of their measured or estimated height. With 4,096 cells, WebKit's
    // style, layout and painting of every cell took several seconds, and resizing a quarter second.
    const virtualizeAbove = 200, nearViewport = 1500;
    // A cell's place on the page: its slot when the page has slots, which holds it once mounted.
    const cellBox = section => section.cellSlot ?? section;
    // The cell at the top of the viewport and how far its top is from the viewport's, by a binary
    // search over the cells in order.
    const topCell = () => {
        let low = 0, high = sections.length;
        while (low < high) {
            const middle = (low + high) >>> 1;
            if (cellBox(sections[middle]).getBoundingClientRect().bottom > 0) high = middle;else low = middle + 1;
        }
        if (low >= sections.length) return null;
        return {section:sections[low], offset:cellBox(sections[low]).getBoundingClientRect().top};
    };
    const cellTop = section => cellBox(section).isConnected ? cellBox(section).getBoundingClientRect().top : null;
    // A cell scrolled back to by `render` stays at its offset while images and outputs above it
    // load and grow. Any scroll that moves it, by wheel, scroll bar, keys or find, lets it go;
    // content growing does not scroll the page, and keeping the cell in place does not move it.
    let pinned = null;
    const holdPinned = () => {
        if (!pinned) return;
        const top = cellTop(pinned.section);
        if (top === null) pinned = null;
        else if (Math.abs(top - pinned.offset) >= 1) window.scrollBy(0, top - pinned.offset);
    };
    new ResizeObserver(holdPinned).observe(root);
    for (const name of ["mousedown", "keydown"]) window.addEventListener(name, () => {pinned = null;}, {passive:true, capture:true});
    const node = (tag, text, className) => {
        const element = document.createElement(tag);
        if (text !== undefined) element.textContent = text;
        if (className) element.className = className;
        return element;
    };
    const searchable = (element) => { element.dataset.searchable = "true"; return element; };
    const textOutput = (text) => searchable(node("pre", text));
    const sanitized = (html, svg = false) => {
        const container = node("div", undefined, svg ? "svg-output" : "rich-output");
        container.innerHTML = DOMPurify.sanitize(html, {
            USE_PROFILES: svg ? {svg: true, svgFilters: false} : {html: true},
            FORBID_TAGS: ["style", "script", "iframe", "object", "embed", "form", "input", "button", "select", "textarea", "foreignObject", "animate", "animateMotion", "animateTransform", "set", "audio", "video", "link", "meta", "base"],
            FORBID_ATTR: ["srcset", "formaction", "action", "autofocus", "contenteditable"],
            ALLOW_DATA_ATTR: false,
            ADD_URI_SAFE_ATTR: ["src"]
        });
        // Matplotlib stores essential fill/stroke values in inline styles. Preserve only
        // SVG presentation values as attributes; author CSS never reaches the document.
        const presentation = new Set(["fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "color", "stop-color", "stop-opacity", "font-size", "font-family", "font-weight", "font-style", "text-anchor", "dominant-baseline", "vector-effect"]);
        const safeValue = /^(?:[a-z0-9#.,%+\-\s"']+|(?:rgb|rgba|hsl|hsla)\([0-9.,%+\-\s]+\)|url\(\s*["']?#[\w:.-]+["']?\s*\))$/i;
        container.querySelectorAll("[style]").forEach(element => {
            if (element.namespaceURI === "http://www.w3.org/2000/svg") {
                for (const property of element.style) {
                    const value = element.style.getPropertyValue(property).trim();
                    if (presentation.has(property) && safeValue.test(value)) element.setAttribute(property, value);
                }
            }
            element.removeAttribute("style");
        });
        // Definitions must remain local when two cells contain SVGs with the same IDs.
        container.querySelectorAll("svg").forEach(svg => {
            const prefix = "notebook-svg-" + (++svgCounter) + "-", ids = new Map();
            svg.querySelectorAll("[id]").forEach(element => {
                ids.set(element.id, prefix + element.id);element.id = prefix + element.id;
            });
            svg.querySelectorAll("*").forEach(element => {
                for (const attribute of Array.from(element.attributes)) {
                    if (["href", "xlink:href"].includes(attribute.name) && attribute.value.startsWith("#")) {
                        const id = ids.get(attribute.value.slice(1));
                        if (id) element.setAttribute(attribute.name, "#" + id);else element.removeAttribute(attribute.name);
                    } else if (attribute.value.includes("url(")) {
                        const value = attribute.value.replace(/url\(\s*["']?#([\w:.-]+)["']?\s*\)/g, (_, id) => ids.has(id) ? "url(#" + ids.get(id) + ")" : "none");
                        if (value.includes("url(") && !/^url\(#[\w:.-]+\)$/.test(value)) element.removeAttribute(attribute.name);
                        else element.setAttribute(attribute.name, value);
                    }
                }
            });
        });
        // No SVG reference can load another resource or document.
        container.querySelectorAll("svg [href],svg [xlink\\:href],svg image").forEach(element => {
            if (element.tagName.toLowerCase() === "image") { element.remove(); return; }
            for (const attribute of ["href", "xlink:href"]) {
                const value = element.getAttribute(attribute);
                if (value && !value.startsWith("#")) element.removeAttribute(attribute);
            }
        });
        return searchable(container);
    };
    const math = (element) => {
        renderMathInElement(element, {
            delimiters: [{left:"$$",right:"$$",display:true},{left:"\\[",right:"\\]",display:true},{left:"$",right:"$",display:false},{left:"\\(",right:"\\)",display:false}],
            trust: false, throwOnError: false, maxExpand: 500, maxSize: 20,
            ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code", "option"]
        });
    };
    const highlight = (element, language) => {
        if (language && hljs.getLanguage(language)) {
            element.innerHTML = hljs.highlight(element.textContent, {language, ignoreIllegals:true}).value;
        }
    };
    const failImage = (element, label) => {
        element.replaceWith(node("span", label || "Image unavailable in offline preview", "image-failure"));
    };
    const requestImage = (element, target) => {
        const id = String(++imageCounter);
        pendingImages.set(id, element);
        element.removeAttribute("src");
        post({kind:"image", revision, id, target});
    };
    const images = (element, cell) => {
        element.querySelectorAll("img").forEach(image => {
            const target = image.getAttribute("src") || "";
            image.removeAttribute("src");
            image.loading = "lazy";
            image.addEventListener("error", () => failImage(image));
            if (target.startsWith("attachment:")) {
                let name;
                try { name = decodeURIComponent(target.slice(11)); } catch { name = target.slice(11); }
                const bundle = Object.hasOwn(cell.attachments, name) && Array.isArray(cell.attachments[name])
                    ? cell.attachments[name] : [];
                const representation = bundle.find(item => item.imageID) || bundle.find(item => item.mime === "image/svg+xml");
                if (representation?.imageID) image.src = imagePrefix + representation.imageID;
                else if (representation?.mime === "image/svg+xml") image.replaceWith(sanitized(representation.text, true));
                else failImage(image, "Attachment unavailable: " + name);
            } else if (target) requestImage(image, target);
            else failImage(image);
        });
    };
    const markdown = (text, cell) => {
        const element = sanitized(md.render(text));
        element.classList.add("markdown");
        images(element, cell);
        element.querySelectorAll("pre code").forEach(code => highlight(code, (code.className.match(/language-([\w+-]+)/) || [])[1]));
        math(element);
        return element;
    };
    const ansi = (text) => {
        const element = textOutput("");
        let color = null, bold = false, last = 0;
        // Recognize SGR only. Strip other terminal control strings, never interpret them as HTML.
        text = text.replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "").replace(/\x1b\[(?![0-9;]*m)[0-?]*[ -/]*[@-~]/g, "");
        const expression = /\x1b\[([0-9;]*)m/g;
        const append = (value) => {
            const span = node("span", value.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, ""));
            if (color) span.style.color = color;
            if (bold) span.style.fontWeight = "bold";
            element.append(span);
        };
        for (const match of text.matchAll(expression)) {
            append(text.slice(last, match.index));
            for (const code of (match[1] || "0").split(";").map(Number)) {
                if (code === 0) { color = null; bold = false; }
                else if (code === 1) bold = true;
                else if (code === 22) bold = false;
                else if (code === 39) color = null;
                else if (code >= 30 && code <= 37) color = `var(--ansi-${code - 30})`;
                else if (code >= 90 && code <= 97) color = `var(--ansi-${code - 90 + 8})`;
            }
            last = match.index + match[0].length;
        }
        append(text.slice(last));
        return element;
    };
    const inspectUnsupported = (items) => {
        const element = node("div", undefined, "unsupported");
        element.append(node("p", "No supported static representation: " + (items.map(item => item.mime).join(", ") || "empty output")));
        const details = node("details");details.append(node("summary", "Inspect saved output"));
        details.append(textOutput(items.map(item => item.mime + "\n" + item.text).join("\n\n")));
        element.append(details);return element;
    };
    const rich = (output, cell) => {
        const container = node("div");
        const all = output.representations;
        const choices = priority.flatMap(mime => all.filter(item => item.mime === mime && (item.imageID || item.text.trim())));
        if (!choices.length) return inspectUnsupported(all);
        const area = node("div", undefined, "rich-output");
        let picker;
        const display = (index) => {
            area.replaceChildren();
            if (index >= choices.length) { area.append(inspectUnsupported(all)); collectSearch(); return; }
            const item = choices[index];
            if (picker) picker.value = String(index);
            let content;
            try {
                if (item.imageID) {
                    content = node("img", undefined, "output-image");content.alt = "Saved notebook output";content.loading = "lazy";
                    content.addEventListener("error", () => display(index + 1), {once:true});
                    content.src = imagePrefix + item.imageID;
                } else if (item.mime.startsWith("image/")) {
                    if (item.mime !== "image/svg+xml") { display(index + 1); return; }
                    content = sanitized(item.text, true);
                    if (!content.querySelector("svg")) { display(index + 1); return; }
                } else if (item.mime === "text/html") {
                    content = sanitized(item.text);images(content, cell);
                    if (!content.textContent.trim() && !content.querySelector("img,svg,table")) { display(index + 1); return; }
                } else if (item.mime === "text/markdown") content = markdown(item.text, cell);
                else if (item.mime === "text/latex") {
                    content = searchable(node("div"));
                    const value = item.text.replace(/^\s*(\$\$|\$|\\\[|\\\()/, "").replace(/(\$\$|\$|\\\]|\\\))\s*$/, "");
                    katex.render(value, content, {displayMode:true, trust:false, throwOnError:false, maxExpand:500, maxSize:20});
                } else content = ansi(item.text);
                area.append(content);
            } catch { display(index + 1); return; }
            if (sections.some(section => section.contains(container))) collectSearch();
        };
        if (choices.length > 1) {
            const label = node("label", "Display as ", "mime-picker");picker = node("select");picker.setAttribute("aria-label", "Output representation");
            choices.forEach((item, index) => { const option = node("option", item.mime);option.value = String(index);picker.append(option); });
            picker.addEventListener("change", () => display(Number(picker.value)));label.append(picker);container.append(label);
        }
        container.append(area);display(0);return container;
    };
    const leaves = (element) => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, {acceptNode: text =>
            text.parentElement.closest(".katex-mathml") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT});
        const result = [];while (walker.nextNode()) result.push(walker.currentNode);return result;
    };
    const collectSearch = () => {
        // From every cell, also those waiting outside the document.
        groups = sections.flatMap(section => Array.from(section.querySelectorAll("[data-searchable]")))
            .filter(element => !element.parentElement.closest("[data-searchable]"));
        const text = groups.map(element => leaves(element).map(leaf => leaf.textContent).join(""));
        post({kind:"search", revision, text});
    };
    const rangeFor = (element, lower, upper, cache) => {
        let index = cache.get(element);
        if (!index) {
            let position = 0;
            index = leaves(element).map(node => {
                const start = position;position += node.length;
                return {node, start, end: position};
            });
            cache.set(element, index);
        }
        // DOM ranges and native Find both use UTF-16 offsets. At a node boundary,
        // start in the next nonempty leaf, but end in the preceding leaf.
        const locate = (offset, isEnd) => {
            let low = 0, high = index.length;
            while (low < high) {
                const mid = (low + high) >>> 1;
                if (index[mid].end < offset || (!isEnd && index[mid].end === offset)) low = mid + 1;
                else high = mid;
            }
            return index[low];
        };
        const first = locate(lower, false), last = locate(upper, true);
        if (!first || !last || lower < 0 || upper <= lower) return null;
        const range = document.createRange();
        range.setStart(first.node, lower - first.start);range.setEnd(last.node, upper - last.start);
        return range;
    };
    const setFind = (next, selected, reveal) => {
        finding = true;
        try { findRanges(next, selected, reveal); } finally { finding = false; }
    };
    const findRanges = (next, selected, reveal) => {
        CSS.highlights?.delete("notebook-find");CSS.highlights?.delete("notebook-current");
        activeFind.forEach(element => element.classList.remove("find-active"));activeFind = [];
        lastFind = next.length ? {next, selected} : null;
        // Index each matched group once per call, rather than walking a large output
        // for every match. Keeping the cache local also handles replaced MIME nodes.
        const ranges = [], active = [], cache = new Map();
        for (const match of next) {
            const element = groups[match.block];if (!element) continue;
            const range = rangeFor(element, match.lower, match.upper, cache);if (!range) continue;
            ranges.push(range);
            if (match.index === selected) {
                active.push(range);element.classList.add("find-active");activeFind.push(element);
                if (reveal) {for (let parent = element.parentElement; parent; parent = parent.parentElement) {if (parent.tagName === "DETAILS") parent.open = true;}show(element);element.scrollIntoView({block:"center"});}
            }
        }
        if (CSS.highlights && window.Highlight) {
            CSS.highlights.set("notebook-find", new Highlight(...ranges));CSS.highlights.set("notebook-current", new Highlight(...active));
        }
    };
    // A rough height for a cell never shown yet, so the scroll bar is about right before it is.
    const estimate = (cell) => {
        const lines = (text) => text.split("\n").reduce((sum, line) => sum + 1 + Math.floor(line.length / 100), 0);
        let height = 22 + lines(cell.source) * (cell.kind === "markdown" ? 26 : 20) + (cell.kind === "markdown" ? 0 : 50);
        for (const output of cell.outputs || []) {
            const image = (output.representations || []).some(item => item.imageID);
            height += 40 + (image ? 300 : output.text.length > 10000 ? 360 : lines(output.text) * 18);
        }
        return height;
    };
    // Puts waiting cells in the document and takes others out, keeping what is on screen in place:
    // a cell already shown and on screen is the anchor, and the page scrolls by however far the
    // changes above it moved it. Every height is read before the document changes, so many cells
    // coming and going at once cost two layouts rather than one per cell. Removing a cell
    // collapses the find ranges inside it, so they are made again for cells that come back.
    const update = (coming, leaving) => {
        coming = coming.filter(slot => !mounted.has(slot));
        // A cell with focus or an open editor stays.
        leaving = leaving.filter(slot => mounted.has(slot) && !slot.cellSection.contains(document.activeElement)
            && !slot.cellSection.querySelector("textarea.cell-editor"));
        if (!coming.length && !leaving.length) return;
        const anchor = Array.from(mounted).filter(slot => !leaving.includes(slot))
            .map(slot => ({slot, top: slot.getBoundingClientRect().top}))
            .filter(item => item.top + item.slot.offsetHeight > 0 && item.top < innerHeight)
            .sort((left, right) => left.top - right.top)[0];
        const heights = leaving.map(slot => slot.offsetHeight);
        const before = anchor ? [] : coming.map(slot => ({height: slot.offsetHeight, above: slot.getBoundingClientRect().bottom <= 0}));
        leaving.forEach((slot, index) => {slot.style.height = heights[index] + "px";slot.cellSection.remove();mounted.delete(slot);});
        coming.forEach(slot => {slot.style.height = "";slot.append(slot.cellSection);mounted.add(slot);});
        const shift = anchor ? anchor.slot.getBoundingClientRect().top - anchor.top
            : coming.reduce((sum, slot, index) => sum + (before[index].above ? slot.offsetHeight - before[index].height : 0), 0);
        if (shift) window.scrollBy(0, shift);
        // Not while revealing a match: that call makes the ranges itself.
        if (coming.length && lastFind && !finding) setFind(lastFind.next, lastFind.selected, false);
    };
    // Makes sure the cell holding `element` is in the document, as before scrolling to it.
    const show = (element) => {
        const slot = element.closest(".cell")?.cellSlot;
        if (slot) update([slot], []);
    };
    // Only an entry's latest state counts: a slot can cross out and back within one batch.
    const observe = (entries) => {
        const latest = new Map(entries.map(entry => [entry.target, entry.isIntersecting]));
        const targets = Array.from(latest.keys());
        update(targets.filter(slot => latest.get(slot)), targets.filter(slot => !latest.get(slot)));
    };
    // Structured edits go to the app, which rewrites only the changed part of the JSON and
    // renders the notebook again; nothing here changes the document on its own.
    const edit = (body) => post(Object.assign({kind:"edit", revision}, body));
    const beginEdit = (section, cell, cellIndex) => {
        if (!editable || section.querySelector("textarea.cell-editor")) return;
        // The preview truncated this source: the app sends all of it, and the editor opens then.
        if (!cell.editable && !cell.whole) {pendingSource = {section, cell, cellIndex};post({kind:"fullSource", revision, cell:cellIndex, id:cell.id});return;}
        const editor = node("textarea", undefined, "cell-editor");
        editor.value = cell.source;editor.spellcheck = false;editor.setAttribute("aria-label", `Source of cell ${cellIndex+1}`);
        const hint = node("div", "⌘↩ or click outside to apply · Esc to cancel", "cell-editor-hint");
        const hidden = Array.from(section.children).filter(child => !child.classList.contains("cell-tools") && !child.classList.contains("cell-label"));
        // A source too long for the preview keeps a fixed height: measuring megabytes per key would stall typing.
        const fit = cell.whole ? () => {editor.style.height = "70vh";} : () => {editor.style.height = "auto";editor.style.height = (editor.scrollHeight + 2) + "px";};
        // A textarea turns "\r\n" and "\r" into "\n": compare without them, and write a changed
        // source back with the line breaks it had.
        const breaks = cell.source.includes("\r\n") ? "\r\n" : "\n", original = cell.source.replace(/\r\n?/g, "\n");
        let done = false;
        const finish = (save) => {
            if (done) return;done = true;
            // Removing an editor while the page renders again blurs it; the cell it edited is gone.
            if (save && !rendering && editor.value !== original) {
                // Kept on screen until the new render replaces the cell, or a refused edit restores it.
                editor.readOnly = true;hint.textContent = "Applying…";
                edit({op:"source", cell:cellIndex, id:cell.id, whole:Boolean(cell.whole), text:breaks === "\n" ? editor.value : editor.value.replace(/\n/g, breaks)});
            } else {
                editor.remove();hint.remove();hidden.forEach(child => child.hidden = false);
            }
        };
        editor.addEventListener("keydown", event => {
            if (event.key === "Escape") {event.preventDefault();event.stopPropagation();finish(false);section.focus();}
            else if (event.key === "Enter" && event.metaKey) {event.preventDefault();event.stopPropagation();finish(true);section.focus();}
        });
        editor.addEventListener("blur", () => finish(true));
        editor.addEventListener("input", fit);
        hidden.forEach(child => child.hidden = true);
        section.append(editor, hint);fit();editor.focus();
    };
    const tools = (section, cell, cellIndex, count) => {
        const bar = node("div", undefined, "cell-tools");
        bar.setAttribute("role", "toolbar");bar.setAttribute("aria-label", `Cell ${cellIndex+1} actions`);
        const button = (label, title, action, disabled) => {
            const element = node("button", label);element.type = "button";element.title = title;element.setAttribute("aria-label", title);
            element.disabled = Boolean(disabled);element.addEventListener("click", event => {event.stopPropagation();action();});
            bar.append(element);
        };
        button("Edit", cell.editable ? "Edit the cell's source" : "Edit the cell's whole source, which the preview truncates",
               () => beginEdit(section, cell, cellIndex));
        const kind = node("select");kind.title = "Cell type";kind.setAttribute("aria-label", "Cell type");
        for (const value of ["code", "markdown", "raw"]) {
            const option = node("option", value === "markdown" ? "Markdown" : value[0].toUpperCase() + value.slice(1));option.value = value;kind.append(option);
        }
        if (!["code", "markdown", "raw"].includes(cell.kind)) {const option = node("option", cell.kind);option.value = cell.kind;option.disabled = true;kind.append(option);}
        kind.value = cell.kind;
        kind.addEventListener("change", () => edit({op:"kind", cell:cellIndex, id:cell.id, value:kind.value}));
        bar.append(kind);
        button("↑", "Move the cell up", () => edit({op:"move", cell:cellIndex, id:cell.id, offset:-1}), cellIndex === 0);
        button("↓", "Move the cell down", () => edit({op:"move", cell:cellIndex, id:cell.id, offset:1}), cellIndex === count - 1);
        button("+ Code", "Insert a code cell below", () => edit({op:"insert", cell:cellIndex, id:cell.id, value:"code"}));
        button("+ Markdown", "Insert a Markdown cell below", () => edit({op:"insert", cell:cellIndex, id:cell.id, value:"markdown"}));
        button("Delete", "Delete the cell", () => edit({op:"delete", cell:cellIndex, id:cell.id}));
        return bar;
    };
    window.notebook = {
        // `start` is where the document's preview was left, for a page that shows no cells yet.
        render(data, token, palette, canEdit, start) {
            editable = Boolean(canEdit);last = {data, palette, canEdit};
            const anchor = topCell();
            const anchorID = anchor ? anchor.section.id : start?.cell, offset = anchor ? anchor.offset : start?.offset;
            const collapsed = new Set(sections.flatMap(section => Array.from(section.querySelectorAll("details[data-output]")))
                .filter(item => !item.open).map(item => item.dataset.output));
            observer?.disconnect();observer = null;sections = [];mounted = new Set();lastFind = null;activeFind = [];
            revision = token;imagePrefix = `wooloo-notebook://${token}/image/`;pendingImages.clear();
            for (const [key,value] of Object.entries(palette)) document.documentElement.style.setProperty(key,value);
            rendering = true;
            try {root.replaceChildren();} finally {rendering = false;}
            root.dataset.cells = String(data.cells.length);
            const virtual = data.cells.length > virtualizeAbove;
            // `update` keeps what is on screen in place itself; WebKit doing the same would double it.
            document.documentElement.style.overflowAnchor = virtual ? "none" : "";
            const header = node("header");header.append(node("h1", "Notebook"));
            header.append(node("p", `${data.cells.length} cells · ${data.language}${data.kernel ? " · " + data.kernel : ""} · Saved output`));root.append(header);
            data.warnings.forEach(warning => root.append(node("div", warning, "notice")));
            if (!data.cells.length) {
                root.append(node("p", "This notebook has no cells.", "unsupported"));
                if (editable) {
                    const add = node("div", undefined, "cell-tools empty");
                    for (const [label, value] of [["Add code cell", "code"], ["Add Markdown cell", "markdown"]]) {
                        const button = node("button", label);button.type = "button";
                        button.addEventListener("click", () => edit({op:"insert", cell:-1, value}));add.append(button);
                    }
                    root.append(add);
                }
            }
            data.cells.forEach((cell, cellIndex) => {
                const section = node("section", undefined, "cell");section.id = "cell-" + cell.id;section.tabIndex = 0;
                section.setAttribute("aria-label", `${cell.kind} cell ${cellIndex+1}`);
                if (editable) {
                    section.append(tools(section, cell, cellIndex, data.cells.length));
                    section.addEventListener("dblclick", event => {
                        if (event.target.closest(".source, .markdown") && !event.target.closest("a")) beginEdit(section, cell, cellIndex);
                    });
                    section.addEventListener("keydown", event => {
                        if (event.key === "Enter" && event.target === section) {event.preventDefault();beginEdit(section, cell, cellIndex);}
                    });
                }
                if (cell.kind === "markdown") section.append(markdown(cell.source, cell));
                else {
                    const label = node("div", undefined, "cell-label");
                    label.append(node("span", cell.kind === "code" ? `In [${cell.executionCount ?? " "}]:` : cell.kind, "count"));
                    label.append(node("span", cell.kind === "code" ? data.language : "Source"));
                    const copy = node("button", "Copy code");copy.type = "button";
                    copy.addEventListener("click", () => post({kind:"copy", revision, text:cell.source}));label.append(copy);section.append(label);
                    const pre = searchable(node("pre", undefined, "source")), code = node("code", cell.source);
                    if (cell.kind === "code") highlight(code, data.language);pre.append(code);section.append(pre);
                    cell.outputs.forEach((output, index) => {
                        const details = node("details", undefined, "output " + output.kind);details.dataset.output = `${cell.id}-${index}`;
                        details.open = !collapsed.has(details.dataset.output);
                        const summary = output.kind === "execute_result" ? `Out [${output.executionCount ?? " "}]` : output.kind;
                        details.append(node("summary", summary));
                        const content = ["display_data", "execute_result"].includes(output.kind) ? rich(output, cell) : ansi(output.text);
                        if (output.text.length > 10000) content.classList.add("long-output");details.append(content);section.append(details);
                    });
                }
                sections.push(section);
                if (!virtual) { root.append(section);return; }
                const slot = node("div", undefined, "cell-slot");slot.cellSection = section;section.cellSlot = slot;
                slot.style.height = estimate(cell) + "px";root.append(slot);
            });
            const anchorSection = anchorID && sections.find(section => section.id === anchorID);
            if (virtual) {
                // Fill the screen now, from the cell that was at the top, rather than after a
                // blank frame; the observer then keeps the cells near the viewport in the document.
                if (anchorSection) window.scrollBy(0, anchorSection.cellSlot.getBoundingClientRect().top - offset);
                // The first slot on screen, wherever the page is scrolled: the slots have their
                // heights, so this is one layout and `topCell`'s binary search.
                const first = topCell();
                const low = first ? sections.indexOf(first.section) : sections.length - 1;
                for (let index = Math.max(low, 0); index < sections.length; index++) {
                    if (sections[index].cellSlot.getBoundingClientRect().top > innerHeight + nearViewport) break;
                    update([sections[index].cellSlot], []);
                }
                observer = new IntersectionObserver(observe, {rootMargin: `${nearViewport}px 0px`});
                sections.forEach(section => observer.observe(section.cellSlot));
            } else if (anchorSection) window.scrollBy(0, anchorSection.getBoundingClientRect().top - offset);
            pinned = anchorSection ? {section:anchorSection, offset} : null;
            collectSearch();setFind([],null,false);
        },
        // The whole source of a truncated cell, asked for by `beginEdit`, for the cell still shown.
        // A null `text` means the app could not read it.
        fullSource(token, cellIndex, id, text) {
            const pending = pendingSource;
            if (token !== revision || !pending || pending.cellIndex !== cellIndex || pending.cell.id !== id) return;
            pendingSource = null;
            if (!sections.includes(pending.section)) return;
            if (text === null) {
                pending.section.querySelector(".cell-editor-hint")?.remove();
                pending.section.append(node("div", "The whole source could not be read; edit it in Source view", "cell-editor-hint"));
                return;
            }
            beginEdit(pending.section, Object.assign({}, pending.cell, {source:text, whole:true}), cellIndex);
        },
        // Shows the notebook as it was rendered again, after an edit the app did not make.
        restore(token) {
            if (token === revision && last) this.render(last.data, token, last.palette, last.canEdit);
        },
        image(id,url,token) {
            if (token !== revision) return;
            const element = pendingImages.get(id);pendingImages.delete(id);
            // Also for a cell waiting outside the document; not for an output replaced since.
            if (!element || !sections.some(section => section.contains(element))) return;
            if (url) element.src = url;else failImage(element);
        },
        find:setFind
    };
    // Tells the app which cell is at the top every frame or so while the page scrolls, so a preview
    // made again for the document starts there.
    let scrollReport = null;
    window.addEventListener("scroll", () => {
        if (pinned) {
            const top = cellTop(pinned.section);
            if (top === null || Math.abs(top - pinned.offset) >= 1) pinned = null;
        }
        if (scrollReport !== null) return;
        // A timer, not an animation frame, which a page not on screen never gets.
        scrollReport = setTimeout(() => {
            scrollReport = null;
            const top = topCell();
            if (top) post({kind:"scroll", revision, cell:top.section.id, offset:top.offset});
        }, 16);
    }, {passive:true});
    root.addEventListener("click", event => {
        const link = event.target.closest("a");if (!link) return;
        event.preventDefault();const target = link.getAttribute("href") || "";
        if (target.startsWith("#")) {
            const id = target.slice(1);
            let element = document.getElementById(id);
            for (const section of sections) {
                if (element) break;
                element = section.id === id ? section : section.querySelector(`[id="${CSS.escape(id)}"]`);
            }
            if (element) {show(element);element.scrollIntoView();}
            return;
        }
        post({kind:"link", revision, target});
    });
    root.addEventListener("keydown", event => {
        if (event.key === "Escape") {post({kind:"escape", revision});return;}
        // Undo and redo the app's cell edits, except while a text field keeps its own.
        if (editable && event.metaKey && event.key.toLowerCase() === "z" && !event.target.closest("textarea, input, select")) {
            event.preventDefault();post({kind:"findCommand", revision, key:"z", shift:event.shiftKey, option:false});return;
        }
        if (event.metaKey && ["f","g"].includes(event.key.toLowerCase())) {
            event.preventDefault();post({kind:"findCommand", revision, key:event.key.toLowerCase(), shift:event.shiftKey, option:event.altKey});
        }
    });
})();
