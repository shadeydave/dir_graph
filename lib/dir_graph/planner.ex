defmodule DirGraph.Planner do
  @moduledoc """
  Responsible for Intent Capture. Generates a 'Scaffold' or 
  'Target Graph' from a JSON checklist or LLM Plan.
  This target graph can later be diffed against the actual indexer
  output to ensure the generated code matches the intended architecture.
  """

  alias DirGraph.Graph, as: CG

  @doc """
  Generates a graph from a simplified JSON plan structure.
  
  Expected plan structure:
  ```json
  {
    "nodes": [
      {"id": "File:lib/new_module.ex", "type": "File", "name": "new_module.ex"},
      {"id": "Function:new_module:init", "type": "Function", "name": "init"}
    ],
    "edges": [
      {"source": "File:lib/new_module.ex", "target": "Function:new_module:init", "rel": "CONTAINS"}
    ]
  }
  ```
  """
  def generate_scaffold(plan_json_str) do
    plan = Jason.decode!(plan_json_str)
    
    graph = CG.new()
    
    # Add Planned Nodes
    graph = 
      Enum.reduce(plan["nodes"] || [], graph, fn node, acc_graph ->
        # We inject `is_planned: true` to distinguish from actual indexed code
        attrs = %{is_planned: true}
        CG.add_node(acc_graph, node["id"], node["type"], node["name"], attrs)
      end)
      
    # Add Planned Edges
    graph =
      Enum.reduce(plan["edges"] || [], graph, fn edge, acc_graph ->
        CG.add_edge(acc_graph, edge["source"], edge["target"], edge["rel"])
      end)
      
    graph
  end
end
