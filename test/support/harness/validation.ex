defmodule Support.Harness.Validation do
  import ExUnit.Assertions

  alias Absinthe.{Blueprint, Schema, Phase, Pipeline, Language}

  @type error_checker_t :: ([{Blueprint.t, Blueprint.Error.t}] -> boolean)

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__)
      def bad_value(node_kind, message, line, check \\ []) do
        location = case List.wrap(line) do
          [single] ->
            "(from line ##{single})"
          multiple when is_list(multiple) ->
            numbers = multiple |> Enum.join(", #")
            "(from lines ##{numbers})"
          nil ->
            "(at any line number)"
        end
        expectation_banner = "\nExpected #{node_kind} node with error #{location}:\n---\n#{message}\n---"
        check_fun = node_check_function(check)
        fn
          pairs ->
            assert !Enum.empty?(pairs), "No errors were found.\n#{expectation_banner}"
            matched = Enum.any?(pairs, fn
              {%str{} = node, %Phase.Error{phase: @rule, message: ^message} = err} when str == node_kind ->
                if check_fun.(node) do
                  if !line do
                    true
                  else
                    List.wrap(line)
                    |> Enum.all?(fn
                      l ->
                        Enum.any?(err.locations, fn
                          %{line: ^l} ->
                            true
                          _ ->
                            false
                        end)
                    end)
                  end
                else
                  false
                end
              _ ->
                false
            end)
            formatted_errors = Enum.map(pairs, fn
              {_, error} ->
                error.message
            end)
            assert matched, "Could not find error.\n#{expectation_banner}\n\n  Did find these errors...\n  ---\n  " <> Enum.join(formatted_errors, "\n  ") <> "\n  ---"
        end
      end
      defp node_check_function(check) when is_list(check) do
        fn
          node ->
            Enum.all?(check, fn {key, value} -> Map.get(node, key) == value end)
        end
      end
      defp node_check_function(check) when is_function(check) do
        check
      end

    end
  end

  @spec assert_valid(Schema.t, [Phase.t], Language.Source.t, map) :: no_return
  def assert_valid(schema, rules, document, options) do
    result = case run(schema, rules, document, options) do
      {:ok, result} ->
        result
      # :jump, etc
      {_other, result, _config} ->
        result
    end
    formatted_errors = Enum.map(error_pairs(result), fn
      {_, error} ->
        error.message
    end)
    assert Enum.empty?(formatted_errors), "Expected no errors, found:\n  ---\n  " <> Enum.join(formatted_errors, "\n  ") <> "\n  ---"
  end

  @spec assert_invalid(Schema.t, [Phase.t], Language.Source.t, map, [error_checker_t] | error_checker_t) :: no_return
  def assert_invalid(schema, rules, document, options, error_checkers) do
    result = case run(schema, rules, document, options) do
      {:ok, result, _} ->
        result
      # :jump, etc
      {_other, result, _config} ->
        result
    end
    pairs = error_pairs(result)
    List.wrap(error_checkers)
    |> Enum.each(&(&1.(pairs)))
  end

  @spec assert_passes_rule(Phase.t, Language.Source.t, map) :: no_return
  def assert_passes_rule(rule, document, options) do
    assert_valid(Support.Harness.Validation.Schema, [rule], document, options)
  end

  @spec assert_fails_rule(Phase.t, Language.Source.t, map, [error_checker_t] | error_checker_t) :: no_return
  def assert_fails_rule(rule, document, options, error_checker) do
    assert_invalid(Support.Harness.Validation.Schema, [rule], document, options, error_checker)
  end

  @spec assert_passes_rule_with_schema(Schema.t, Phase.t, Language.Source.t, map) :: no_return
  def assert_passes_rule_with_schema(schema, rule, document, options) do
    assert_valid(schema, [rule], document, options)
  end

  @spec assert_fails_rule_with_schema(Schema.t, Phase.t, Language.Source.t, map, error_checker_t) :: no_return
  def assert_fails_rule_with_schema(schema, rule, document, options, error_checker) do
    assert_invalid(schema, [rule], document, options, error_checker)
  end

  defp run(schema, rules, document, options) do
    pipeline = pre_validation_pipeline(schema, options)
    Pipeline.run(document, pipeline ++ rules)
  end

  defp pre_validation_pipeline(schema, :schema) do
    Pipeline.for_schema(schema)
    |> Pipeline.upto(Phase.Schema)
  end
  defp pre_validation_pipeline(schema, options) do
    Pipeline.for_document(schema, options)
    |> Pipeline.upto(Phase.Document.Validation.Result)
    |> Pipeline.reject(~r/Validation/)
  end

  # Build a map of node => errors
  defp nodes_with_errors(input) do
    {_, errors} = Blueprint.prewalk(input, [], &do_nodes_with_errors/2)
    errors
  end

  defp error_pairs(input) do
    nodes_with_errors(input)
    |> Enum.flat_map(fn
      %{errors: errors} = node ->
        Enum.map(errors, &{node, &1})
    end)
  end

  defp do_nodes_with_errors(%{errors: []} = node, acc) do
    {node, acc}
  end
  defp do_nodes_with_errors(%{errors: _} = node, acc) do
    {node, [node | acc]}
  end
  defp do_nodes_with_errors(node, acc) do
    {node, acc}
  end

end
