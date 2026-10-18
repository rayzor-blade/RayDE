# Markdown Preview

A tab beside the editor that draws a Markdown file as you save it.

## What it draws

- Headings, paragraphs and **strong** or *emphasised* text
- `Code spans` and [links](https://example.com)
- Lists, quotes and fenced code

> The preview is written in RayScript, and runs in the extension host.

```
mount(() -> <Document source={source}/>, 'tab:Preview')
```

---

1. Right-click a Markdown file in the Explorer
2. Choose Preview
