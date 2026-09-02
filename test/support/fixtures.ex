defmodule Humanport.Fixtures do
  @moduledoc """
  Test fixtures for HumanPort domain resources.

  Every fixture in this module MUST be built on the resource's real Ash code
  interface (e.g. the eventual `HumanPort.Requests.HumanRequest.submit/1`),
  never on `Repo.insert` directly — a fixture that bypasses the action under
  test bypasses the behaviour the test exists to prove.

  Empty for now: the `HumanRequest` resource and its `:submit` action do not
  exist yet in this plan (01-01, scaffolding only). `request_fixture/1` lands
  in plan 01-02 when the action does, built against the sandboxed
  (`Humanport.DataCase`) and unsandboxed (`Humanport.UnsandboxedCase`) case
  templates that already exist in this directory.
  """
end
