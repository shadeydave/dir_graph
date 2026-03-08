defmodule DirGraph.LSP.ImportExtractor do
  @moduledoc """
  Extracts import/require paths from source files by language.

  `textDocument/documentSymbol` does not surface import relationships, so this
  module fills that gap. It is intentionally narrow — it only extracts the
  *path string* from import statements, not structure. Structure is LSP's job.

  ## Supported languages

  - **JS/TS** — `import ... from './path'`, `export ... from './path'`, `require('./path')`
  - **Python** — `from .relative import ...` (dotted module paths converted to file paths)
  - **Ruby** — `require_relative 'path'`

  Only relative paths (starting with `.`) are returned. External package imports
  cannot be resolved to project files and are silently skipped.

  ## Return format

  Each ref is a tagged tuple compatible with `DirGraph.Indexer.resolve_cross_file_refs/2`:

      {:js_import, "./relative/path", "/abs/from_file.ts", line_number}
      {:py_import, "./relative/module", "/abs/from_file.py", line_number}
  """

  # ----------------------------------------------------------------
  # JS / TS
  # ----------------------------------------------------------------
  # `from 'path'` — covers: standard imports, named imports, namespace
  # imports, re-exports, AND the last line of multi-line imports since
  # `from 'path'` always appears as its own token at the end.
  @js_from ~r/\bfrom\s+['"](\.[^'"]+)['"]/

  # `require('./path')` — CommonJS
  @js_require ~r/require\(\s*['"](\.[^'"]+)['"]\s*\)/

  # ----------------------------------------------------------------
  # Python
  # ----------------------------------------------------------------
  # `from .module import X` or `from ..module import X`
  # Leading dots encode directory depth. `from . import X` (bare dot) is
  # skipped — it refers to the package init, not a specific file.
  @py_relative ~r/^from\s+(\.+\S*)\s+import/

  # ----------------------------------------------------------------
  # Ruby
  # ----------------------------------------------------------------
  # `require_relative 'path'` — already a file-path-style string
  @ruby_relative ~r/require_relative\s+['"]([^'"]+)['"]/

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Extracts import refs from `file_path`. Returns a list of ref tuples,
  or `[]` if the language is unsupported or no relative imports exist.
  """
  @spec extract(String.t()) :: [tuple()]
  def extract(file_path) do
    ext = Path.extname(file_path)

    case File.read(file_path) do
      {:ok, source} -> do_extract(ext, source, file_path)
      _ -> []
    end
  end

  # ----------------------------------------------------------------
  # Per-language extraction
  # ----------------------------------------------------------------

  defp do_extract(ext, source, file_path) when ext in ~w(.js .jsx .ts .tsx) do
    source
    |> lines_with_numbers()
    |> Enum.flat_map(fn {line, n} ->
      cond do
        m = Regex.run(@js_from,    line) -> [{:js_import, Enum.at(m, 1), file_path, n}]
        m = Regex.run(@js_require, line) -> [{:js_import, Enum.at(m, 1), file_path, n}]
        true -> []
      end
    end)
  end

  defp do_extract(".py", source, file_path) do
    source
    |> lines_with_numbers()
    |> Enum.flat_map(fn {line, n} ->
      case Regex.run(@py_relative, String.trim_leading(line)) do
        [_, dotted] ->
          case py_dots_to_path(dotted) do
            nil  -> []
            path -> [{:py_import, path, file_path, n}]
          end

        nil -> []
      end
    end)
  end

  defp do_extract(".rb", source, file_path) do
    source
    |> lines_with_numbers()
    |> Enum.flat_map(fn {line, n} ->
      case Regex.run(@ruby_relative, line) do
        [_, path] -> [{:js_import, path, file_path, n}]
        nil -> []
      end
    end)
  end

  defp do_extract(_unsupported, _source, _file_path), do: []

  # ----------------------------------------------------------------
  # Python dotted-module → relative file path
  # ----------------------------------------------------------------
  # `.foo`      → 1 dot, same dir  → "./foo"
  # `..foo`     → 2 dots, up 1 dir → "../foo"
  # `..a.b`     → 2 dots           → "../a/b"
  # `.`         → bare dot (package init) → nil (skip)

  defp py_dots_to_path(dotted) do
    dots  = dotted |> String.graphemes() |> Enum.take_while(&(&1 == ".")) |> length()
    rest  = String.slice(dotted, dots, String.length(dotted))

    if rest == "" do
      nil
    else
      ups         = String.duplicate("../", dots - 1)
      module_path = String.replace(rest, ".", "/")
      "#{ups}#{module_path}"
    end
  end

  defp lines_with_numbers(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
