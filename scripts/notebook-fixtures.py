#!/usr/bin/env python3
"""Generate saved-output fixtures and validate them with Jupyter's reference schema."""
import argparse
import base64
import io
import json
import os
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", str(Path("build/notebook-matplotlib-cache").resolve()))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nbformat as nbf
import pandas as pd
from nbconvert import HTMLExporter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/notebook-fixtures"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.plot([0, 1, 2, 3], [0, 1, 4, 9], marker="o")
    ax.set(title="Saved quadratic plot", xlabel="x", ylabel="x²")
    fig.tight_layout()
    png = io.BytesIO();fig.savefig(png, format="png", dpi=120)
    svg = io.StringIO();fig.savefig(svg, format="svg")
    plt.close(fig)
    encoded = base64.b64encode(png.getvalue()).decode()
    frame = pd.DataFrame({"Space": ["Research", "Analysis"], "Agents": [3, 2]})
    notebook = nbf.v4.new_notebook(metadata={
        "kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"},
        "language_info": {"name": "python"}, "wooloo_fixture": {"preserve": [1, True, None]},
    })
    notebook.cells = [
        nbf.v4.new_markdown_cell("# Notebook preview\n\nSaved results; **no kernel needed**.\n\nInline math $E=mc^2$.\n\n$$\\int_0^1 x^2\\,dx=\\frac13$$\n\n| Item | Value |\n| --- | --- |\n| Format | ipynb |\n\n[Local source](sample.py) · [Jupyter](https://jupyter.org)\n\n![Attached plot](attachment:plot.png)", attachments={"plot.png": {"image/png": encoded}}),
        nbf.v4.new_code_cell("import pandas as pd\nframe", execution_count=7, outputs=[nbf.v4.new_output("execute_result", execution_count=7, data={"text/html": frame.to_html(), "text/plain": frame.to_string()})]),
        nbf.v4.new_code_cell("plt.plot(x, x ** 2)", execution_count=3, outputs=[nbf.v4.new_output("display_data", data={"image/png": encoded, "image/svg+xml": svg.getvalue(), "text/plain": "<Figure: saved quadratic plot>"})]),
        nbf.v4.new_code_cell("print('hello')", outputs=[nbf.v4.new_output("stream", name="stdout", text="hello\n\x1b[32mGreen saved output\x1b[0m\n"), nbf.v4.new_output("stream", name="stderr", text="Example warning\n")]),
        nbf.v4.new_code_cell("raise ValueError('fixture')", execution_count=8, outputs=[nbf.v4.new_output("error", ename="ValueError", evalue="fixture", traceback=["\x1b[31mValueError\x1b[0m: fixture"])]),
        nbf.v4.new_code_cell("display(JSON({'ok': True}))", outputs=[nbf.v4.new_output("display_data", data={"application/json": {"ok": True, "count": 4}, "text/plain": "{'ok': True, 'count': 4}"})]),
        nbf.v4.new_raw_cell("Raw exporter content <script>must remain text</script>"),
        nbf.v4.new_code_cell("widget", outputs=[nbf.v4.new_output("display_data", data={"application/vnd.jupyter.widget-view+json": {"version_major": 2, "version_minor": 0, "model_id": "missing-model"}, "text/plain": "Widget (saved text fallback)"})]),
        nbf.v4.new_code_cell("unsupported", outputs=[nbf.v4.new_output("display_data", data={"application/vnd.wooloo.unsupported+json": {"inspect": "Saved data"}})]),
        nbf.v4.new_markdown_cell("## Cell-local attachment\n\n![Different plot](attachment:plot.png)", attachments={"plot.png": {"image/svg+xml": '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><rect width="120" height="40" fill="teal"/></svg>'}}),
    ]
    nbf.validate(notebook)
    nbf.write(notebook, args.output / "preview.ipynb")
    html, _ = HTMLExporter(sanitize_html=True).from_notebook_node(notebook)
    (args.output / "reference.html").write_text(html)
    (args.output / "sample.py").write_text("# Link target from the notebook\nprint('hello')\n")
    malicious = nbf.v4.new_notebook(cells=[nbf.v4.new_markdown_cell('<script>window.notebookInjected=true</script><img src="https://example.invalid/tracker" onerror="window.notebookInjected=true"><iframe src="https://example.invalid"></iframe>\n\nSafe narrative'), nbf.v4.new_code_cell("unsafe output", outputs=[nbf.v4.new_output("display_data", data={"text/html": '<script>window.notebookInjected=true</script><div onclick="window.notebookInjected=true" style="position:fixed">Safe table <table><tr><td>42</td></tr></table></div>', "text/plain": "Safe fallback"}), nbf.v4.new_output("display_data", data={"application/javascript": "window.notebookInjected=true", "text/plain": "JavaScript skipped"}), nbf.v4.new_output("display_data", data={"image/svg+xml": '<svg xmlns="http://www.w3.org/2000/svg" onload="window.notebookInjected=true"><script>window.notebookInjected=true</script><foreignObject><iframe src="https://example.invalid"/></foreignObject><rect width="40" height="40" fill="red"/></svg>'})])])
    nbf.validate(malicious);nbf.write(malicious, args.output / "untrusted.ipynb")
    legacy = json.loads(nbf.writes(notebook));legacy["nbformat_minor"] = 4
    for cell in legacy["cells"]:cell.pop("id", None)
    nbf.validate(legacy);(args.output / "legacy.ipynb").write_text(json.dumps(legacy, indent=2))
    large = nbf.v4.new_notebook(cells=[nbf.v4.new_code_cell("# Large saved output", outputs=[nbf.v4.new_output("stream", name="stdout", text="saved line\n" * 130_000)])])
    nbf.validate(large);nbf.write(large, args.output / "large.ipynb")
    (args.output / "invalid.ipynb").write_text('{"nbformat":4,"cells":[')
    print(f"Generated and schema-validated 4 notebooks, an invalid-JSON fixture, and a reference HTML export in {args.output}")


if __name__ == "__main__":
    main()
