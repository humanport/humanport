defmodule HumanportWeb.UnauthorizedError do
  @moduledoc """
  D-02 — raised by `HumanportWeb.Plugs.ResolveActor.on_mount/4` when the
  configured resolver returns `{:error, _}` for a LiveView socket.

  Deliberately NOT a redirect to `/`: `/` is served by the exact same
  `on_mount` hook (`live_session :requests, on_mount:
  [HumanportWeb.Plugs.ResolveActor]`), so redirecting there on a broken
  Access configuration would re-enter the same plug and loop rather than
  fail visibly — 02-CONTEXT.md D-02 requires locking the owner out
  "visibly and immediately," not routing him in a circle. Raising here
  terminates the LiveView mount outright; the client's own reconnect logic
  then falls back to a full page load, and that dead render meets
  `ResolveActor.call/2`'s 401 the same way any other unauthenticated
  request does.

  `plug_status: 401` lets Phoenix's own error-view machinery render a
  standard 401 if this ever surfaces through a plain Plug pipeline instead
  of a LiveView socket — it does not today (`call/2`'s own `case` handles
  the conn/HTTP path directly and never raises this), but the field costs
  nothing and keeps both paths honestly labeled the same status.
  """

  defexception message: "Identity could not be resolved.", plug_status: 401
end
