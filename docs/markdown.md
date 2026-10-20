# Markdown preview

The built-in Markdown extension opens editor tabs. **Markdown: Open Preview** uses the active Markdown file; **Open Preview** in the Explorer and editor menus passes the selected file. The preview and its command use Remix's Markdown icon. The extension contributes no sidebar view.

The Explorer includes Markdown in the project root, documentation folders and source folders. `.md`, `.markdown`, `.mdown` and `.mkd` are recognized without case sensitivity and use the Markdown icon. Source folders start expanded; other folders load when opened.

![Markdown source opened from the project Explorer](images/markdown-explorer.png)

Edits update an open preview after the editor's change debounce, including unsaved buffers. Opening the same preview again focuses its existing tab. The source and refresh actions have icon tooltips. Inactive preview tabs release decoded images, generated SVGs, code viewers and diagram canvases; their document structure, scroll position and disclosure state remain available for reopening. Closing a preview, including through a bulk close action, releases its document model too.

## Rendering

The parser supports CommonMark with GFM tables, task lists, strikethrough, autolinks and footnotes. Nested emphasis, ordered and unordered lists, block quotes, fenced code and heading anchors are rendered with Ashui components. Local PNG, JPEG, WebP and SVG images resolve relative to the Markdown file. Relative document links open another preview; other file links open the editor. HTTP, HTTPS and mailto links open in the system handler after a click.

Task lists use read-only Ashui checkboxes. Checked and unchecked markers share the same 14 px square and spacing.

Inline math uses `$...$`. Display math uses `$$...$$` or a fenced `math`/`latex` block. LaTeX-Rust typesets fractions, roots, integrals, sums, Greek and mathematical symbols, accents and supported matrix/alignment environments into SVG paths using its embedded STIX Two Math font. This is mathematical LaTeX, rather than a LaTeX document compiler.

![Inline and display mathematics in the dark preview](images/markdown-preview-math.png)

````markdown
The identity $E = mc^2$ appears within a paragraph.

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
flowchart LR
  Source --> Parser --> Preview
```
````

Mermaid fences use the pinned native Mermaid renderer's diagram families, including flowcharts, sequence, class, state, ER, pie, mindmap, journey, timeline, Gantt, requirement, Git, C4, Sankey, quadrant, ZenUML, block, packet, Kanban, architecture, radar, treemap and XY charts. Drag to pan and use the wheel to zoom around the pointer. Zoom in, zoom out and fit controls have tooltips. The SVG follows the CanvasKit viewport and remains sharp when scaled; the canvas occupies the visible diagram area.

![Mermaid viewport with zoom and fit controls](images/markdown-preview-mermaid.png)

![Tables, equal-size task checkboxes and local images in the light preview](images/markdown-preview-tasks.png)

Malformed equations and diagrams show an error and their source within the document. Other blocks continue rendering. Remote images are not fetched automatically. Preview documents are limited to 2 MiB, local image files to 8 MiB, and Mermaid fences to 32 KiB/500 lines.

## HTML and images

Embedded HTML is parsed with Scraper/html5ever and rendered with Ashui. Supported document elements include paragraphs, headings, block containers, inline emphasis, underline, mark, small/superscript/subscript text, links, images, lists, tables, code/pre and native details/summary disclosures. HTML entities and omitted closing tags follow HTML5 parsing. `align` and `style="text-align: ..."` control alignment; image `width`/`height` accept pixel values, and width also accepts percentages. Images preserve their aspect ratio when only one dimension is supplied and fit the available document width. Scripts, event attributes, forms, embedded pages and external stylesheets are omitted; this is a native document renderer with a limited presentation style set.

```html
<p align="center"><img src="assets/logo.svg" alt="Logo" width="250"/></p>
<h2 align="center">Project title</h2>
<details><summary>More information</summary><p>Document content.</p></details>
```

Images remain file references in the cached document. The visible view reads them through the workspace's capability and path checks; image bytes are not embedded in the extension VM's document JSON. Raster buffers are reduced for the requested display size, allowing 2× backing resolution with a 2048 px longest-side cap. The scroll container opts into Ashui's `virtualizeImages`: offscreen images release decoded pixels, keep dimensions and compressed source, and reload on reentry. The renderer reclaims unused atlas entries and reduces texture capacity as the resident set changes. Hiding the tab releases its image sources too. Ashui packs displayed images into a shared RGBA atlas; GPU block compression is currently available for mesh textures rather than this 2D atlas.

![HTML alignment, sized images and inline formatting](images/markdown-html.png)

![The contextual Open Preview action](images/markdown-preview-menu.png)

## Shared syntax highlighting

Fenced code consumes [RayDE's syntax system](syntax.md). Language flags such as `rust`, `python`, `c++`, `bash` and `ts` resolve through the shared registry. Unknown flags remain readable plain text. Code blocks are read-only Ashui code viewers with selection, copying and scrolling.

The old `tests/fixtures/markdown` extension remains a small extension-authoring demonstration. The production implementation is `extensions/markdown`; `markdownpreview` snapshots install and exercise that implementation in an ordinary Haxe workspace.
