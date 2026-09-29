defmodule Humanport.Requests.ContentHash do
  @moduledoc """
  SEC-08 / §54.8 — the fingerprint of exactly what a human is shown when
  asked to decide: the request's type, title, description, context, subject,
  options and their limits, stated risk and reversibility, and who is asking.

  The same function computes it from a create changeset (at submit, stored
  as `content_hash`) and from a loaded record (at decision time, and whenever
  `Humanport.Requests.verify_content/1` re-checks it), so the two can only
  agree when the content is byte-for-byte the content that was hashed.

  The encoding is canonical JSON: object keys sorted, map keys stringified,
  atoms as strings, embedded subject/options reduced to the fields the wire
  shape (`HumanportWeb.RequestJSON`) shows. The result is prefixed with
  `sha256:` so a later change of algorithm or encoding is visible in every
  stored value rather than silently incompatible.

  This is content binding. The typed approval token in the inbox is not —
  that remains mis-click prevention only (see `HumanPort.UI.ApprovalCard`).
  """

  alias Humanport.Requests.HumanRequest

  @fields [
    :type,
    :title,
    :description,
    :context,
    :subject,
    :options,
    :allow_free_text,
    :max_selections,
    :risk,
    :reversible,
    :requester_label,
    :requester_verified
  ]

  @doc "The fingerprint of a loaded request's current content."
  @spec compute(Ash.Resource.record()) :: String.t()
  def compute(%HumanRequest{} = request), do: request |> Map.take(@fields) |> digest()

  @doc "The fingerprint of the content a create changeset is about to store."
  @spec compute_changeset(Ash.Changeset.t()) :: String.t()
  def compute_changeset(%Ash.Changeset{} = changeset) do
    @fields
    |> Map.new(&{&1, Ash.Changeset.get_attribute(changeset, &1)})
    |> digest()
  end

  defp digest(fields) do
    fields
    |> Map.update!(:subject, &subject/1)
    |> Map.update!(:options, &options/1)
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp subject(nil), do: nil
  defp subject(subject), do: Map.new([:type, :id, :label], &{&1, field(subject, &1)})

  defp options(nil), do: nil

  defp options(options) when is_list(options) do
    Enum.map(options, fn option ->
      Map.new([:id, :label, :description, :recommended], &{&1, field(option, &1)})
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value) when is_boolean(value) or is_nil(value), do: value
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end
