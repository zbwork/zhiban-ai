---
name: chart-visualization
description: Render a real PNG chart from numeric data, picking from 26 chart types (bar / column / line / pie / scatter / radar / area / histogram / boxplot / heatmap / treemap / sankey / funnel / gauge / etc.). ALWAYS use this skill for "数据图表" / "柱状图" / "折线图" / "饼图" / "条形图" / "散点图" / "热力图" / "可视化" / "画个图表" / "chart" / "plot" / "graph" / "visualize" / "make a chart" / "draw a histogram". NEVER answer with a text table claiming to "be" the chart, NEVER write SVG/HTML by hand. NEVER say "this skill is not installed" — invoke it and let runtime fail explicitly. If the skill returns a remote CDN URL (e.g. mdn.alipayobjects.com), use it directly. If it writes a local PNG under `outbox/`, reply `![](<outbox/...>)` — note the `<...>` angle-bracket URL (handles any filename, even with spaces or parens). The runtime auto-publishes the local file to a public URL before delivery. No publish step is needed.
compatibility:
  nodejs: ">=18.0.0"
---

# Chart Visualization Skill

This skill provides a comprehensive workflow for transforming data into visual charts. It handles chart selection, parameter extraction, and image generation.

## Workflow

To visualize data, follow these steps:

### 1. Intelligent Chart Selection
Analyze the user's data features to determine the most appropriate chart type. Use the following guidelines (and consult `references/` for detailed specs):

- **Time Series**: Use `generate_line_chart` (trends) or `generate_area_chart` (accumulated trends). Use `generate_dual_axes_chart` for two different scales.
- **Comparisons**: Use `generate_bar_chart` (categorical) or `generate_column_chart`. Use `generate_histogram_chart` for frequency distributions.
- **Part-to-Whole**: Use `generate_pie_chart` or `generate_treemap_chart` (hierarchical).
- **Relationships & Flow**: Use `generate_scatter_chart` (correlation), `generate_sankey_chart` (flow), or `generate_venn_chart` (overlap).
- **Maps**: Use `generate_district_map` (regions), `generate_pin_map` (points), or `generate_path_map` (routes).
- **Hierarchies & Trees**: Use `generate_organization_chart` or `generate_mind_map`.
- **Specialized**:
    - `generate_radar_chart`: Multi-dimensional comparison.
    - `generate_funnel_chart`: Process stages.
    - `generate_liquid_chart`: Percentage/Progress.
    - `generate_word_cloud_chart`: Text frequency.
    - `generate_boxplot_chart` or `generate_violin_chart`: Statistical distribution.
    - `generate_network_graph`: Complex node-edge relationships.
    - `generate_fishbone_diagram`: Cause-effect analysis.
    - `generate_flow_diagram`: Process flow.
    - `generate_spreadsheet`: Tabular data or pivot tables for structured data display and cross-tabulation.

### 2. Parameter Extraction
Once a chart type is selected, read the corresponding file in the `references/` directory (e.g., `references/generate_line_chart.md`) to identify the required and optional fields.
Extract the data from the user's input and map it to the expected `args` format.

### 3. Chart Generation
Invoke the `scripts/generate.js` script with a JSON payload.

**Payload Format:**
```json
{
  "tool": "generate_chart_type_name",
  "args": {
    "data": [...],
    "title": "...",
    "theme": "...",
    "style": { ... }
  }
}
```

**Execution Command:**
```bash
node ./scripts/generate.js '<payload_json>'
```

### 4. Result Return
The script will output the URL of the generated chart image.
Return the following to the user:
- The image URL.
- The complete `args` (specification) used for generation.

## Reference Material
Detailed specifications for each chart type are located in the `references/` directory. Consult these files to ensure the `args` passed to the script match the expected schema.

## License

This `SKILL.md` is provided by [antvis/chart-visualization-skills](https://github.com/antvis/chart-visualization-skills).
Licensed under the [MIT License](https://github.com/antvis/chart-visualization-skills/blob/master/LICENSE).