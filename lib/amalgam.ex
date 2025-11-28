defmodule Amalgam do
  @moduledoc """
  Semantic merge driver for Elixir that treats functions as atomic units.
  """

  def main([base_path, local_path, remote_path, _merged_path]) do
    base = File.read!(base_path)
    local = File.read!(local_path)
    remote = File.read!(remote_path)

    case merge(base, local, remote) do
      {:ok, merged} ->
        File.write!(local_path, merged)
        System.halt(0)

      {:conflict, merged_with_markers} ->
        File.write!(local_path, merged_with_markers)
        System.halt(1)
    end
  end

  def merge(base, local, remote) do
    base_chunks = extract_chunks(base)
    local_chunks = extract_chunks(local)
    remote_chunks = extract_chunks(remote)

    get_inner = fn chunks ->
      case Enum.find(chunks, fn c -> elem(c, 0) == :module_body end) do
        {:module_body, _, inner} -> Enum.map(inner, &chunk_key/1)
        _ -> :no_body
      end
    end

    debug = """
    BASE INNER: #{inspect(get_inner.(base_chunks), limit: :infinity)}
    LOCAL INNER: #{inspect(get_inner.(local_chunks), limit: :infinity)}
    REMOTE INNER: #{inspect(get_inner.(remote_chunks), limit: :infinity)}
    """

    File.write!("/tmp/amalgam_debug.log", debug)
    {merged, has_conflicts} = merge_chunks(base_chunks, local_chunks, remote_chunks)

    File.write!("/tmp/amalgam_merged_chunks.log", inspect(merged, pretty: true, limit: 500))
    rendered = render_chunks(merged)

    if has_conflicts do
      {:conflict, rendered}
    else
      {:ok, rendered}
    end
  end

  # Parse source and extract chunks, handling defmodule wrapper
  defp extract_chunks(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        File.write!("/tmp/amalgam_ast.log", inspect(ast, pretty: true, limit: :infinity))

        parse_ast(ast, source)

      {:error, error} ->
        File.write!("/tmp/amalgam_parse_error.log", """
        Parse error: #{inspect(error)}
        First 500 chars of source:
        #{String.slice(source, 0, 500)}
        """)

        [{:raw, source}]
    end
  end

  defp parse_ast({:defmodule, _meta, [module_alias, opts]} = ast, source) when is_list(opts) do
    # Find the do block body regardless of how it's structured
    body =
      case Keyword.get(opts, :do) do
        nil ->
          # Sourceror style: [{{:__block__, _, [:do]}, body}]
          case opts do
            [{{:__block__, _, [:do]}, b}] -> b
            [{:do, b}] -> b
            _ -> nil
          end

        b ->
          b
      end

    if body do
      body_forms =
        case body do
          {:__block__, _, forms} -> forms
          single -> [single]
        end

      module_range = Sourceror.get_range(ast)
      first_form = List.first(body_forms)
      first_form_range = first_form && Sourceror.get_range(first_form)

      # DEBUG
      File.write!("/tmp/amalgam_header.log", """
      Module range: #{inspect(module_range)}
      First form: #{inspect(first_form |> elem(0))}
      First form range: #{inspect(first_form_range)}
      """)

      header_end_line =
        case first_form_range do
          %{start: start_pos} -> start_pos[:line] - 1
          _ -> module_range.start[:line]
        end

      lines = String.split(source, "\n")
      header = lines |> Enum.take(header_end_line) |> Enum.join("\n")
      module_name = extract_module_name(module_alias)
      inner_chunks = group_into_chunks(body_forms, source)

      [
        {:module_header, module_name, header},
        {:module_body, module_name, inner_chunks},
        {:module_footer, module_name, "end"}
      ]
    else
      [{:other, source}]
    end
  end

  defp parse_ast({:__block__, _meta, forms}, source) do
    group_into_chunks(forms, source)
  end

  # Handle single top-level form that's not a defmodule
  defp parse_ast(ast, source) do
    group_into_chunks([ast], source)
  end

  defp extract_module_name({:__aliases__, _, parts}) do
    parts |> Enum.map(&to_string/1) |> Enum.join(".")
  end

  defp extract_module_name(other), do: inspect(other)

  # Group forms into chunks, treating functions by {name, arity}
  defp group_into_chunks(forms, source) do
    forms
    |> Enum.reduce({[], nil, []}, fn form, {chunks, current_fn, pending_attrs} ->
      case classify_form(form) do
        {:function, name, arity, _form} = fn_info ->
          key = {name, arity}

          case current_fn do
            {^key, clauses, attrs} ->
              # Same function, accumulate clause (keep existing attrs)
              {chunks, {key, clauses ++ [fn_info], attrs}, []}

            nil ->
              # Start new function, attach pending attrs
              {chunks, {key, [fn_info], pending_attrs}, []}

            {other_key, clauses, attrs} ->
              # Different function, flush previous
              chunk = make_function_chunk(other_key, clauses, attrs, source)
              {chunks ++ [chunk], {key, [fn_info], pending_attrs}, []}
          end

        {:spec, attr_source} ->
          # Hold onto spec for next function
          case current_fn do
            nil ->
              {chunks, nil, pending_attrs ++ [attr_source]}

            {key, clauses, attrs} ->
              # Flush current function, hold new spec
              chunk = make_function_chunk(key, clauses, attrs, source)
              {chunks ++ [chunk], nil, [attr_source]}
          end

        :impl_attribute ->
          # Same as spec - attach to next function
          impl_source = "@impl true"

          case current_fn do
            nil ->
              {chunks, nil, pending_attrs ++ [impl_source]}

            {key, clauses, attrs} ->
              # Flush current function, hold impl
              chunk = make_function_chunk(key, clauses, attrs, source)
              {chunks ++ [chunk], nil, [impl_source]}
          end

        {:other, form_source} ->
          chunk = {:other, resolve_source(form_source)}

          case current_fn do
            nil ->
              # If we had pending attrs with no function, emit them as other
              attr_chunks = Enum.map(pending_attrs, &{:other, &1})
              {chunks ++ attr_chunks ++ [chunk], nil, []}

            {key, clauses, attrs} ->
              fn_chunk = make_function_chunk(key, clauses, attrs, source)
              {chunks ++ [fn_chunk, chunk], nil, []}
          end
      end
    end)
    |> then(fn {chunks, current_fn, pending_attrs} ->
      # Flush final function if any
      chunks =
        case current_fn do
          nil -> chunks
          {key, clauses, attrs} -> chunks ++ [make_function_chunk(key, clauses, attrs, source)]
        end

      # Emit any trailing attrs as other
      if pending_attrs != [] do
        chunks ++ Enum.map(pending_attrs, &{:other, &1})
      else
        chunks
      end
    end)
  end

  defp make_function_chunk(key, clauses, attrs, source) do
    source_slice = get_function_source(clauses, source)
    attr_prefix = if attrs != [], do: Enum.join(attrs, "\n") <> "\n", else: ""
    {:function, key, attr_prefix <> source_slice}
  end

  defp classify_form({:@, _meta, [{:impl, _, _} | _]}) do
    # We'll handle this specially
    :impl_attribute
  end

  # Classify a form as either a function (with name/arity) or other
  defp classify_form({:@, _meta, [{:spec, _, _} | _]} = form) do
    source = form_to_source(form)
    {:spec, resolve_source(source)}
  end

  defp classify_form({def_type, _meta, [{:when, _, [{name, _, args} | _]} | _]} = form)
       when def_type in [:def, :defp, :defmacro, :defmacrop] do
    arity = if is_list(args), do: length(args), else: 0
    # Store full form, not just meta
    {:function, name, arity, form}
  end

  defp classify_form({def_type, _meta, [{name, _, args} | _]} = form)
       when def_type in [:def, :defp, :defmacro, :defmacrop] do
    arity = if is_list(args), do: length(args), else: 0
    # Store full form, not just meta
    {:function, name, arity, form}
  end

  defp classify_form(form) do
    {:other, form_to_source(form)}
  end

  defp resolve_source({:needs_extraction, _range, form}), do: Macro.to_string(form)
  defp resolve_source(source) when is_binary(source), do: source

  defp form_to_source(form) do
    case Sourceror.get_range(form) do
      nil ->
        Macro.to_string(form)

      range ->
        # We'll extract this later when we have source context
        {:needs_extraction, range, form}
    end
  end

  # Get source for a function (all clauses)
  defp get_function_source(clauses, source) do
    ranges =
      clauses
      |> Enum.map(fn {:function, _, _, form} ->
        Sourceror.get_range(form)
      end)
      |> Enum.reject(&is_nil/1)

    case ranges do
      [] ->
        "# could not extract source"

      ranges ->
        start_pos = ranges |> Enum.map(& &1.start) |> Enum.min_by(&{&1[:line], &1[:column]})
        end_pos = ranges |> Enum.map(& &1.end) |> Enum.max_by(&{&1[:line], &1[:column]})

        result = extract_range(source, start_pos, end_pos)

        # Debug: log function extractions
        File.write!(
          "/tmp/amalgam_extract.log",
          """
          --- FUNCTION ---
          Start: #{inspect(start_pos)}
          End: #{inspect(end_pos)}
          Source:
          #{result}
          --- END ---

          """,
          [:append]
        )

        result
    end
  end

  defp extract_range(source, start_pos, end_pos) do
    lines = String.split(source, "\n")

    lines
    |> Enum.slice((start_pos[:line] - 1)..(end_pos[:line] - 1)//1)
    |> Enum.join("\n")
  end

  # Three-way merge at chunk level
  defp merge_chunks(base, local, remote) do
    # Handle module structure
    File.write!("/tmp/amalgam_merge_chunks.log", """
    BASE first: #{inspect(List.first(base))}
    LOCAL first: #{inspect(List.first(local))}
    REMOTE first: #{inspect(List.first(remote))}
    """)

    case {local, remote} do
      {[{:module_header, _, _} | _], [{:module_header, _, _} | _]} ->
        merge_module_chunks(base, local, remote)

      _ ->
        merge_flat_chunks(base, local, remote)
    end
  end

  defp merge_module_chunks(base, local, remote) do
    # Extract parts
    base_header = find_chunk(base, :module_header)
    local_header = find_chunk(local, :module_header)
    remote_header = find_chunk(remote, :module_header)

    base_body = find_chunk(base, :module_body)
    local_body = find_chunk(local, :module_body)
    remote_body = find_chunk(remote, :module_body)

    base_footer = find_chunk(base, :module_footer)
    local_footer = find_chunk(local, :module_footer)
    remote_footer = find_chunk(remote, :module_footer)

    # Merge header (imports, aliases, module attributes, etc.)
    {merged_header, header_conflict} =
      merge_single_chunk(base_header, local_header, remote_header)

    # Merge body (the functions)
    base_inner = if base_body, do: elem(base_body, 2), else: []
    local_inner = if local_body, do: elem(local_body, 2), else: []
    remote_inner = if remote_body, do: elem(remote_body, 2), else: []

    {merged_inner, body_conflict} = merge_flat_chunks(base_inner, local_inner, remote_inner)

    # Use local footer (should always be "end")
    merged_footer = local_footer || remote_footer || base_footer

    module_name =
      cond do
        local_header -> elem(local_header, 1)
        remote_header -> elem(remote_header, 1)
        base_header -> elem(base_header, 1)
        true -> "Unknown"
      end

    merged = [
      merged_header,
      {:module_body, module_name, merged_inner},
      merged_footer
    ]

    {merged, header_conflict or body_conflict}
  end

  defp find_chunk(chunks, type) do
    Enum.find(chunks, fn
      {^type, _, _} -> true
      _ -> false
    end)
  end

  defp merge_single_chunk(base, local, remote) do
    base_src = chunk_source(base)
    local_src = chunk_source(local)
    remote_src = chunk_source(remote)

    cond do
      local_src == remote_src ->
        {local, false}

      base_src == remote_src ->
        {local, false}

      base_src == local_src ->
        {remote, false}

      true ->
        # Conflict in header
        conflict_text = """
        <<<<<<< LOCAL
        #{local_src}
        =======
        #{remote_src}
        >>>>>>> REMOTE
        """

        {{:conflict, conflict_text}, true}
    end
  end

  defp merge_flat_chunks(base, local, remote) do
    base_map = chunks_to_map(base)
    local_map = chunks_to_map(local)
    remote_map = chunks_to_map(remote)

    # Preserve order from local, then add new items from remote
    local_order = Enum.map(local, &chunk_key/1)
    remote_keys = Enum.map(remote, &chunk_key/1)
    remote_only = Enum.reject(remote_keys, &(&1 in local_order))
    key_order = local_order ++ remote_only

    {merged_chunks, has_conflicts} =
      key_order
      |> Enum.uniq()
      |> Enum.reduce({[], false}, fn key, {chunks, conflicts} ->
        base_val = Map.get(base_map, key)
        local_val = Map.get(local_map, key)
        remote_val = Map.get(remote_map, key)

        case three_way_merge(base_val, local_val, remote_val) do
          {:ok, merged} ->
            {chunks ++ [merged], conflicts}

          {:conflict, conflict_chunk} ->
            {chunks ++ [conflict_chunk], true}

          :deleted ->
            {chunks, conflicts}
        end
      end)

    {merged_chunks, has_conflicts}
  end

  defp chunks_to_map(chunks) when is_list(chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} -> {chunk_key(chunk, idx), chunk} end)
    |> Map.new()
  end

  defp chunks_to_map(_), do: %{}

  defp chunk_key(chunk, idx \\ 0) do
    case chunk do
      {:function, key, _source} ->
        {:fn, key}

      {:other, source} when is_binary(source) ->
        {:other, :erlang.phash2(source)}

      {:other, {:needs_extraction, _range, form}} ->
        {:other, :erlang.phash2(Macro.to_string(form))}

      {:raw, _source} ->
        {:raw, idx}

      {:module_header, name, _} ->
        {:header, name}

      {:module_body, name, _} ->
        {:body, name}

      {:module_footer, name, _} ->
        {:footer, name}

      {:conflict, _} ->
        {:conflict, idx}

      nil ->
        {nil, idx}
    end
  end

  # Three-way merge logic
  defp three_way_merge(base, local, remote) do
    base_src = chunk_source(base)
    local_src = chunk_source(local)
    remote_src = chunk_source(remote)

    cond do
      # Both same as base, or all identical
      local_src == remote_src ->
        if local, do: {:ok, local}, else: :deleted

      # Only local changed
      base_src == remote_src ->
        if local, do: {:ok, local}, else: :deleted

      # Only remote changed
      base_src == local_src ->
        if remote, do: {:ok, remote}, else: :deleted

      # Both changed differently - conflict
      true ->
        {:conflict, make_conflict_chunk(local, remote)}
    end
  end

  defp make_conflict_chunk(local, remote) do
    local_source = chunk_source(local) || "# (deleted)"
    remote_source = chunk_source(remote) || "# (deleted)"

    conflict_text = """
    <<<<<<< LOCAL
    #{local_source}
    =======
    #{remote_source}
    >>>>>>> REMOTE
    """

    {:conflict, String.trim(conflict_text)}
  end

  defp chunk_source(nil), do: nil
  defp chunk_source({:function, _key, source}), do: source
  defp chunk_source({:other, source}) when is_binary(source), do: source
  defp chunk_source({:other, {:needs_extraction, _range, form}}), do: Macro.to_string(form)
  defp chunk_source({:conflict, text}), do: text
  defp chunk_source({:raw, source}), do: source
  defp chunk_source({:module_header, _, source}), do: source
  defp chunk_source({:module_body, _, _chunks}), do: nil
  defp chunk_source({:module_footer, _, source}), do: source

  # Render merged chunks back to source
  defp render_chunks(chunks) do
    chunks
    |> Enum.map(&render_chunk/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp render_chunk({:module_header, _, source}), do: source
  defp render_chunk({:module_footer, _, source}), do: source

  defp render_chunk({:module_body, _, inner_chunks}) do
    inner_chunks
    |> Enum.map(&render_chunk/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&indent/1)
    |> Enum.join("\n\n")
  end

  defp render_chunk({:function, _key, source}), do: source
  defp render_chunk({:other, source}) when is_binary(source), do: source
  defp render_chunk({:other, {:needs_extraction, _range, form}}), do: Macro.to_string(form)
  defp render_chunk({:conflict, text}), do: text
  defp render_chunk({:raw, source}), do: source
  defp render_chunk(nil), do: nil

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.trim(line) == "" do
        ""
      else
        "  " <> line
      end
    end)
    |> Enum.join("\n")
  end
end
