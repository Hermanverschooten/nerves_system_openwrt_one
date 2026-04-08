defmodule NervesSystemOpenwrtOne.UBootEnvKVBackend do
  @moduledoc """
  A `Nerves.Runtime.KVBackend` for the OpenWRT One Nerves system.

  The U-Boot environment lives in two redundant `ubootenv` UBI volumes
  on SPI NAND. Reads use the Erlang `UBootEnv` library directly (just
  opens the device, reads, decodes -- works fine on UBI character
  devices via `pread()`). Writes shell out to the C `fw_setenv` tool,
  because writing to a `/dev/ubi*` character device requires the
  `UBI_IOCVOLUP` ioctl to enter atomic-update mode -- plain `pwrite()`
  returns `EPERM`. The C tool issues that ioctl transparently for
  `/dev/ubi*` paths; the Erlang library doesn't.

  ## Usage

  In your project's `config/target.exs`, configure `:nerves_runtime`
  to use this backend instead of the default:

      config :nerves_runtime,
        kv_backend: {NervesSystemOpenwrtOne.UBootEnvKVBackend, []}

  Without this, `Nerves.Runtime.KV.put/1` (and anything that uses it,
  notably `Nerves.Runtime.validate_firmware/0` and
  `Nerves.Runtime.StartupGuard`) returns `{:error, :eperm}` and the
  startup-time validation chain falls over.
  """

  @behaviour Nerves.Runtime.KVBackend

  @fw_setenv "/usr/sbin/fw_setenv"

  @impl Nerves.Runtime.KVBackend
  def load(_options) do
    UBootEnv.read()
  end

  @impl Nerves.Runtime.KVBackend
  def save(%{} = kv, _options) do
    # Build a fw_setenv -s script: one `key value` line per pair, with
    # `=` between key and value replaced by the first space (fw_setenv -s
    # uses space as the separator and treats the rest of the line as the
    # value, so values containing spaces work fine).
    script =
      kv
      |> Enum.map_join("\n", fn {k, v} -> "#{k} #{v}" end)
      |> Kernel.<>("\n")

    path = Path.join(System.tmp_dir!(), "nerves_kv_#{System.unique_integer([:positive])}.env")

    try do
      File.write!(path, script)

      case System.cmd(@fw_setenv, ["-s", path], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> {:error, "fw_setenv -s exited #{code}: #{String.trim(out)}"}
      end
    after
      _ = File.rm(path)
    end
  end
end
