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
    let revision = "", imagePrefix = "", imageCounter = 0, svgCounter = 0, groups = [], pendingImages = new Map();
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
            if (root.contains(container)) collectSearch();
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
        groups = Array.from(root.querySelectorAll("[data-searchable]")).filter(element => !element.parentElement.closest("[data-searchable]"));
        const text = groups.map(element => leaves(element).map(leaf => leaf.textContent).join(""));
        post({kind:"search", revision, text});
    };
    const rangeFor = (element, lower, upper) => {
        const range = document.createRange();let position = 0, started = false;
        for (const leaf of leaves(element)) {
            const end = position + leaf.length;
            if (!started && lower < end) {range.setStart(leaf, Math.max(0, lower - position));started = true;}
            if (started && upper <= end) {range.setEnd(leaf, Math.max(0, upper - position));return range;}
            position = end;
        }
        return null;
    };
    const setFind = (next, selected, reveal) => {
        CSS.highlights?.delete("notebook-find");CSS.highlights?.delete("notebook-current");
        root.querySelectorAll(".find-active").forEach(element => element.classList.remove("find-active"));
        const ranges = [], active = [];
        for (const match of next) {
            const element = groups[match.block];if (!element) continue;
            const range = rangeFor(element, match.lower, match.upper);if (!range) continue;
            ranges.push(range);
            if (match.index === selected) {
                active.push(range);element.classList.add("find-active");
                if (reveal) {for (let parent = element.parentElement; parent; parent = parent.parentElement) {if (parent.tagName === "DETAILS") parent.open = true;}element.scrollIntoView({block:"center"});}
            }
        }
        if (CSS.highlights && window.Highlight) {
            CSS.highlights.set("notebook-find", new Highlight(...ranges));CSS.highlights.set("notebook-current", new Highlight(...active));
        }
    };
    window.notebook = {
        render(data, token, palette) {
            const anchor = Array.from(root.querySelectorAll(".cell")).find(cell => cell.getBoundingClientRect().bottom > 0);
            const anchorID = anchor?.id, offset = anchor?.getBoundingClientRect().top;
            const collapsed = new Set(Array.from(root.querySelectorAll("details[data-output]")).filter(item => !item.open).map(item => item.dataset.output));
            revision = token;imagePrefix = `wooloo-notebook://${token}/image/`;pendingImages.clear();
            for (const [key,value] of Object.entries(palette)) document.documentElement.style.setProperty(key,value);
            root.replaceChildren();
            const header = node("header");header.append(node("h1", "Notebook"));
            header.append(node("p", `${data.cells.length} cells · ${data.language}${data.kernel ? " · " + data.kernel : ""} · Saved output`));root.append(header);
            data.warnings.forEach(warning => root.append(node("div", warning, "notice")));
            if (!data.cells.length) root.append(node("p", "This notebook has no cells.", "unsupported"));
            data.cells.forEach((cell, cellIndex) => {
                const section = node("section", undefined, "cell");section.id = "cell-" + cell.id;section.tabIndex = 0;
                section.setAttribute("aria-label", `${cell.kind} cell ${cellIndex+1}`);
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
                root.append(section);
            });
            if (anchorID) { const next = document.getElementById(anchorID);if (next) window.scrollBy(0,next.getBoundingClientRect().top-offset); }
            collectSearch();setFind([],null,false);
        },
        image(id,url,token) {
            if (token !== revision) return;
            const element = pendingImages.get(id);pendingImages.delete(id);if (!element?.isConnected) return;
            if (url) element.src = url;else failImage(element);
        },
        find:setFind
    };
    root.addEventListener("click", event => {
        const link = event.target.closest("a");if (!link) return;
        event.preventDefault();const target = link.getAttribute("href") || "";
        if (target.startsWith("#")) {document.getElementById(target.slice(1))?.scrollIntoView();return;}
        post({kind:"link", revision, target});
    });
    root.addEventListener("keydown", event => {
        if (event.key === "Escape") {post({kind:"escape", revision});return;}
        if (event.metaKey && ["f","g"].includes(event.key.toLowerCase())) {
            event.preventDefault();post({kind:"findCommand", revision, key:event.key.toLowerCase(), shift:event.shiftKey, option:event.altKey});
        }
    });
})();
