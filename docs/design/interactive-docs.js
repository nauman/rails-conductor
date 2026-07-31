(function () {
  function parseJson(script) {
    try {
      return JSON.parse(script.textContent);
    } catch (error) {
      console.error("Invalid interactive-docs JSON", script, error);
      return null;
    }
  }

  function renderMermaid(mermaid) {
    if (!mermaid) return;
    mermaid.initialize({ startOnLoad: false, theme: "neutral" });
    mermaid.run({ querySelector: ".mermaid" });
  }

  function renderVegaLite() {
    if (!window.vegaEmbed) return;
    document.querySelectorAll("script[data-vega-lite]").forEach((script) => {
      const target = document.getElementById(script.dataset.vegaLite);
      const spec = parseJson(script);
      if (!target || !spec) return;
      window.vegaEmbed(target, spec, { actions: false });
    });
  }

  function renderCytoscape() {
    if (!window.cytoscape) return;
    const styles = getComputedStyle(document.documentElement);
    const cssVar = (name, fallback) => styles.getPropertyValue(name).trim() || fallback;
    const nodeColor = cssVar("--np-focus", "steelblue");
    const textColor = cssVar("--np-text", "black");
    const edgeColor = cssVar("--np-rule-runtime", "gray");

    document.querySelectorAll("script[data-cytoscape]").forEach((script) => {
      const target = document.getElementById(script.dataset.cytoscape);
      const graph = parseJson(script);
      if (!target || !graph) return;
      window.cytoscape({
        container: target,
        elements: graph.elements || [],
        layout: graph.layout || { name: "breadthfirst", directed: true },
        style: [
          {
            selector: "node",
            style: {
              "background-color": nodeColor,
              "color": textColor,
              "label": "data(label)",
              "text-valign": "center",
              "text-halign": "center",
              "font-size": 12,
              "width": 74,
              "height": 74
            }
          },
          {
            selector: "edge",
            style: {
              "curve-style": "bezier",
              "target-arrow-shape": "triangle",
              "line-color": edgeColor,
              "target-arrow-color": edgeColor,
              "label": "data(label)",
              "font-size": 10
            }
          }
        ]
      });
    });
  }

  window.renderInteractiveDocs = function (libraries) {
    renderMermaid(libraries && libraries.mermaid);
    renderVegaLite();
    renderCytoscape();
  };
})();
