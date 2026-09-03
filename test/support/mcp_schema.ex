defmodule Humanport.McpSchema.DigestMismatchError do
  @moduledoc """
  Raised when the vendored `priv/mcp/schema-2026-07-28.json` file's SHA-256
  digest no longer matches the digest recorded in `priv/mcp/SHA256SUMS`. The
  oracle refuses to validate anything against a file that has silently
  drifted from its pin — a substituted or edited schema fails loudly here,
  never quietly.
  """

  defexception [:message]
end

defmodule Humanport.McpSchema.UnknownDefinitionError do
  @moduledoc """
  Raised when `assert_valid!/2` or `refute_valid!/2` is asked to validate
  against a definition name that is not a key of the vendored schema's
  `$defs`. Silently validating against nothing would make the helper worse
  than useless.
  """

  defexception [:message]
end

defmodule Humanport.McpSchema.ValidationError do
  @moduledoc """
  Raised by `assert_valid!/2` when a payload expected to be well-formed does
  not validate against the vendored schema. Carries the validator's own
  error list in the message.
  """

  defexception [:message]
end

defmodule Humanport.McpSchema.UnexpectedlyValidError do
  @moduledoc """
  Raised by `refute_valid!/2` when a payload expected to be malformed
  validates anyway. This is the failure mode the oracle exists to catch: a
  validator that accepts everything is indistinguishable from no validator
  at all.
  """

  defexception [:message]
end

defmodule Humanport.McpSchema do
  @moduledoc """
  D-08a (`02.1-CONTEXT.md`) — the oracle. HumanPort implements MCP by hand,
  so "follows the official spec" has to be a passing test, not a claim. This
  module validates payloads against the vendored, digest-pinned copy of the
  official MCP JSON Schema for revision `2026-07-28`
  (`priv/mcp/schema-2026-07-28.json`, see `priv/mcp/README.md`).

  ## The draft-07 substitution

  `ex_json_schema` (the dependency the owner approved on 2026-09-03,
  `02.1-01-PLAN.md` Task 1) supports JSON Schema draft 4, 6 and 7 only, and
  raises on any other `$schema` value. The vendored MCP schema declares
  `https://json-schema.org/draft/2020-12/schema`. This module builds its
  validator root from the decoded schema with `"$schema"` replaced by
  `"http://json-schema.org/draft-07/schema#"` — **in memory only**. The file
  on disk, and the digest pinned in `SHA256SUMS`, are never touched; that is
  what keeps the pin meaningful.

  This substitution is sound for the pinned `2026-07-28` revision
  specifically, not in general — see `priv/mcp/README.md` for the full
  keyword audit that justifies it and the re-audit obligation that comes
  with re-vendoring a newer schema. In short: every keyword the vendored
  file actually uses (`type`, `properties`, `required`, `enum`, `const`,
  `items`, `allOf`, `minimum`, `additionalProperties`, and `$ref` values that
  are plain JSON Pointers of the form `#/$defs/Name`) has identical
  semantics under draft 7 and draft 2020-12 — including `$ref` resolution:
  JSON Pointer traversal does not care whether the intermediate key is named
  `$defs` or `definitions`, so a `#/$defs/Name` pointer resolves the same
  way under either draft.

  ## Digest verification

  On first use in a test run, this module reads the vendored file, computes
  its SHA-256 digest, and compares it against the digest recorded in
  `SHA256SUMS`. A mismatch raises `Humanport.McpSchema.DigestMismatchError`
  naming both digests — never a silent pass. The verified, decoded schema is
  then cached (`:persistent_term`) for the rest of the run.
  """

  alias Humanport.McpSchema.{
    DigestMismatchError,
    UnknownDefinitionError,
    UnexpectedlyValidError,
    ValidationError
  }

  @draft07_schema_uri "http://json-schema.org/draft-07/schema#"
  @persistent_term_key {__MODULE__, :vendored_schema}

  @doc "Absolute path to the vendored schema file, resolved via the compiled OTP release layout."
  def vendored_path do
    Application.app_dir(:humanport, "priv/mcp/schema-2026-07-28.json")
  end

  @doc "Absolute path to the digest pin for the vendored schema file."
  def sha256sums_path do
    Application.app_dir(:humanport, "priv/mcp/SHA256SUMS")
  end

  @doc """
  Validates `payload` against the vendored schema's `definition_name`
  definition. Raises `Humanport.McpSchema.UnknownDefinitionError` if
  `definition_name` is not a known `$defs` key, and
  `Humanport.McpSchema.ValidationError` (carrying the validator's own error
  list) if `payload` does not validate.
  """
  def assert_valid!(payload, definition_name) do
    root = ref_root_for!(definition_name)

    case ExJsonSchema.Validator.validate(root, payload) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ValidationError,
          message: "payload did not validate against ##{definition_name}: #{inspect(errors)}"
    end
  end

  @doc """
  The mirror of `assert_valid!/2` — raises
  `Humanport.McpSchema.UnexpectedlyValidError` if `payload` unexpectedly
  validates against `definition_name`. This is the assertion that proves the
  oracle actually rejects malformed input rather than accepting everything.
  """
  def refute_valid!(payload, definition_name) do
    root = ref_root_for!(definition_name)

    case ExJsonSchema.Validator.validate(root, payload) do
      :ok ->
        raise UnexpectedlyValidError,
          message: "expected payload to be rejected against ##{definition_name}, but it validated"

      {:error, _errors} ->
        :ok
    end
  end

  defp ref_root_for!(definition_name) do
    decoded = verified_decoded_schema()
    defs = Map.get(decoded, "$defs", %{})

    unless Map.has_key?(defs, definition_name) do
      raise UnknownDefinitionError,
        message:
          "no such MCP schema definition: #{inspect(definition_name)} " <>
            "(priv/mcp/schema-2026-07-28.json has #{map_size(defs)} known definitions)"
    end

    decoded
    |> Map.put("$ref", "#/$defs/" <> definition_name)
    |> ExJsonSchema.Schema.resolve()
  end

  defp verified_decoded_schema do
    case :persistent_term.get(@persistent_term_key, :not_loaded) do
      :not_loaded ->
        decoded = load_and_verify!()
        :persistent_term.put(@persistent_term_key, decoded)
        decoded

      decoded ->
        decoded
    end
  end

  defp load_and_verify! do
    contents = File.read!(vendored_path())
    sha256sums_contents = File.read!(sha256sums_path())
    :ok = verify_digest!(contents, sha256sums_contents)

    contents
    |> Jason.decode!()
    |> Map.put("$schema", @draft07_schema_uri)
  end

  @doc false
  # Pure and independently testable — no persistent_term, no real filesystem
  # required — so the "digest mismatch raises loudly" behavior can be proven
  # without corrupting the actual vendored oracle file that every other test
  # in the run relies on.
  def verify_digest!(contents, sha256sums_contents) do
    actual_digest = contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    expected_digest = expected_digest!(sha256sums_contents)

    unless actual_digest == expected_digest do
      raise DigestMismatchError,
        message:
          "vendored MCP schema digest mismatch: SHA256SUMS pins #{expected_digest}, " <>
            "the file actually hashes to #{actual_digest} " <>
            "(see priv/mcp/README.md before trusting anything validated against it)"
    end

    :ok
  end

  defp expected_digest!(sha256sums_contents) do
    sha256sums_contents
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.find_value(fn line ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [digest, filename] ->
          if String.trim(filename) == "schema-2026-07-28.json", do: digest

        _ ->
          nil
      end
    end) ||
      raise DigestMismatchError,
        message: "priv/mcp/SHA256SUMS has no entry for schema-2026-07-28.json"
  end
end
