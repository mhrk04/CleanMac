# CleanMac Diagrams

All diagrams for CleanMac are authored as inline [Mermaid](https://mermaid.js.org/) code fences directly inside the main guide, so they render as graphics on GitHub and most Markdown viewers. This page is a pointer to where each one lives.

👉 **Main guide:** [`../CODEBASE_GUIDE.md`](../CODEBASE_GUIDE.md)
👉 **Formal architecture:** [`../ARCHITECTURE.md`](../ARCHITECTURE.md)

## Diagram index

| Diagram | Type | Section |
| --- | --- | --- |
| Layered architecture (UI → ViewModels → Core → FileSystem → disk) | `graph TD` | [1. Big Picture](../CODEBASE_GUIDE.md#1-big-picture--layered-architecture) |
| App startup / composition root | `sequenceDiagram` | [3. App Startup](../CODEBASE_GUIDE.md#3-app-startup--composition-root) |
| Rule loading (bundled + user overrides → effective rule set) | `graph LR` | [4. The Rule System](../CODEBASE_GUIDE.md#4-the-rule-system-how-junk-is-defined) |
| Scan decision funnel (rule → ScanItem) | `flowchart TD` | [5. Scan Pipeline](../CODEBASE_GUIDE.md#5-scan-pipeline-scannerengine) |
| Denylist `decide()` decision tree | `flowchart TD` | [6. Safety Denylist](../CODEBASE_GUIDE.md#6-the-safety-denylist-pathdenylist) |
| Clean / trash‑first pipeline | `sequenceDiagram` | [7. Clean Pipeline](../CODEBASE_GUIDE.md#7-clean--delete-pipeline-trash-first) |
| Restore / undo flow | `sequenceDiagram` | [8. Undo / History](../CODEBASE_GUIDE.md#8-undo--history-historystore--historyviewmodel) |

## Tips for viewing

- On **GitHub**, Mermaid fences render automatically — just open `CODEBASE_GUIDE.md`.
- In **VS Code**, install a Mermaid preview extension (or use the built‑in Markdown preview with Mermaid support).
- To export a diagram as an image, paste its fence into the [Mermaid Live Editor](https://mermaid.live).
