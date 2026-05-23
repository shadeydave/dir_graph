defmodule DirGraph.CLI do
  @moduledoc "Command-line interface for DirGraph."

  alias DirGraph.{Indexer, Analyzer}

  def main(args) do
    args |> parse_args() |> process()
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          file: :string,
          search: :string,
          depth: :integer,
          index_dir: :string,
          export: :string,
          db: :string,
          summary: :boolean,
          help: :boolean
        ],
        aliases: [f: :file, s: :search, d: :depth, i: :index_dir, e: :export, h: :help]
      )

    opts
  end

  def process(help: true), do: print_help()

  def process(opts) do
    file = Keyword.get(opts, :file)
    search = Keyword.get(opts, :search)
    depth = Keyword.get(opts, :depth, 2)
    index_dir = Keyword.get(opts, :index_dir)
    export = Keyword.get(opts, :export)
    db = Keyword.get(opts, :db)
    summary = Keyword.get(opts, :summary, false)

    # --- Path A: Build and export a full-directory graph ---
    if index_dir && export do
      unless File.dir?(index_dir) do
        error("Directory '#{index_dir}' not found.")
        System.halt(1)
      end

      IO.puts("Indexing #{index_dir} ...")
      graph = Indexer.index_directory(index_dir)
      Indexer.save_graph(graph, export)
      n = graph |> Graph.vertices() |> length()
      e = graph |> Graph.edges() |> length()
      ok("Indexed #{n} nodes, #{e} edges → saved to #{export}")
      System.halt(0)
    end

    # --- Path B: Query ---
    unless search do
      error("--search is required for querying.")
      print_help()
      System.halt(1)
    end

    graph =
      cond do
        db ->
          unless File.exists?(db) do
            error("DB file '#{db}' not found.")
            System.halt(1)
          end

          {graph, _manifest} = Indexer.load_graph(db)
          graph

        file ->
          unless File.exists?(file) do
            error("File '#{file}' not found.")
            System.halt(1)
          end

          {g, refs} = Indexer.index_file(file)
          Indexer.resolve_cross_file_refs(g, refs)

        true ->
          error("Provide --file or --db to query.")
          print_help()
          System.halt(1)
      end

    case Analyzer.find_node(graph, search) do
      nil ->
        IO.puts(IO.ANSI.yellow() <> "Node '#{search}' not found." <> IO.ANSI.reset())
        System.halt(2)

      vertex_id ->
        subgraph = Analyzer.extract_slice(graph, vertex_id, depth)
        payload = Analyzer.format_for_llm(subgraph)

        if summary do
          Analyzer.print_slice_summary(payload)
        else
          # Annotate with fuzzy-match info if the match wasn't exact
          matched_name =
            case Graph.vertex_labels(graph, vertex_id) do
              [%{name: n} | _] -> n
              _ -> vertex_id
            end

          payload =
            if String.downcase(matched_name) != String.downcase(search) do
              Map.put(payload, :_fuzzy_match, %{
                requested: search,
                matched_id: vertex_id,
                matched_name: matched_name
              })
            else
              payload
            end

          IO.puts(Jason.encode!(payload, pretty: true))
        end
    end
  end

  defp error(msg),
    do: IO.puts(IO.ANSI.red() <> "Error: #{msg}" <> IO.ANSI.reset())

  defp ok(msg),
    do: IO.puts(IO.ANSI.green() <> msg <> IO.ANSI.reset())

  defp print_help do
    IO.puts("""

    DirGraph — Semantic Code Slicer

    USAGE
      dir_graph [options]

    OPTIONS
      -f, --file       <path>   Index a single file (JIT)
      -s, --search     <term>   Concept / node name to search for (required for queries)
      -d, --depth      <int>    BFS depth from matched node (default: 2)
      -i, --index-dir  <path>   Recursively index a full directory
      -e, --export     <path>   Save index to a binary file
          --db         <path>   Load a pre-compiled graph binary
          --summary             Print a human-readable summary instead of JSON
      -h, --help                Show this help

    EXAMPLES
      # Index a directory and save to disk:
      ./dir_graph --index-dir . --export project.bin

      # Fast query against pre-compiled index:
      ./dir_graph --db project.bin --search verify_token

      # Human-readable summary:
      ./dir_graph --db project.bin --search verify_token --summary

      # Single-file JIT slice:
      ./dir_graph --file lib/auth.ex --search login --depth 3
    """)
  end
end
