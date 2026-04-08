# apply-ota.exs -- runs on the OpenWRT One after upload-ota.sh has SFTP'd
# /tmp/openwrt_one_ota.itb and /tmp/openwrt_one_ota.env into place.
#
# Looks at the current `nerves_fw_active` U-Boot variable, picks the
# *other* slot (a -> b, b -> a, or a if unset), writes the new FIT to
# the inactive slot's UBI volume via ubiupdatevol, then patches the
# inactive slot's <slot>.nerves_fw_* metadata via fw_setenv and flips
# `nerves_fw_active` to point at the new slot. Finally reboots.
#
# Volume IDs come from ubinize-fit.cfg in nerves_system_openwrt_one:
#   slot a = vol_id 3 -> /dev/ubi0_3
#   slot b = vol_id 4 -> /dev/ubi0_4

defmodule ApplyOTA do
  @itb_path "/tmp/openwrt_one_ota.itb"
  @env_path "/tmp/openwrt_one_ota.env"
  @fwenv_path "/tmp/openwrt_one_ota.fwenv"

  @slot_devices %{"a" => "/dev/ubi0_3", "b" => "/dev/ubi0_4"}

  def run do
    current = current_active_slot()
    target = flip(current)
    target_dev = Map.fetch!(@slot_devices, target)

    IO.puts("==> active slot is #{current}, writing to #{target} (#{target_dev})")

    write_itb(target_dev)
    write_env(target)

    cleanup()

    IO.puts("==> rebooting")
    Nerves.Runtime.reboot()
  end

  defp current_active_slot do
    case System.cmd("/usr/sbin/fw_printenv", ["-n", "nerves_fw_active"], stderr_to_stdout: true) do
      {value, 0} ->
        case String.trim(value) do
          "a" -> "a"
          "b" -> "b"
          _ -> "a"
        end

      _ ->
        "a"
    end
  end

  defp flip("a"), do: "b"
  defp flip("b"), do: "a"

  defp write_itb(target_dev) do
    {out, code} =
      System.cmd("/usr/sbin/ubiupdatevol", [target_dev, @itb_path], stderr_to_stdout: true)

    if code != 0 do
      IO.puts(out)
      raise "ubiupdatevol #{target_dev} failed (#{code})"
    end
  end

  defp write_env(target) do
    # Read the slot-agnostic env file the host uploaded, prefix each
    # `key=value` with `<target>.`, and append:
    #   - nerves_fw_active=<target>     -- the slot flip
    #   - upgrade_available=1           -- mark this boot as a trial
    #   - bootcount=0                   -- reset attempt counter
    # The U-Boot side bumps bootcount on every boot while
    # upgrade_available=1; once it exceeds bootlimit (3), it swaps
    # slots automatically. Nerves.Runtime.StartupGuard, once the app
    # has come up healthy, calls validate_firmware/0 which clears
    # upgrade_available + bootcount, locking in the new slot.
    # Then convert `=` to ` ` so fw_setenv -s can parse it.
    prefixed =
      @env_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> "#{target}.#{line}" end)
      |> Kernel.++([
        "nerves_fw_active=#{target}",
        "upgrade_available=1",
        "bootcount=0"
      ])
      |> Enum.map(fn line -> String.replace(line, "=", " ", global: false) end)
      |> Enum.join("\n")

    File.write!(@fwenv_path, prefixed <> "\n")

    {out, code} =
      System.cmd("/usr/sbin/fw_setenv", ["-s", @fwenv_path], stderr_to_stdout: true)

    if code != 0 do
      IO.puts(out)
      raise "fw_setenv -s failed (#{code})"
    end

    IO.puts("==> env patched (#{target}.nerves_fw_* + nerves_fw_active=#{target} + upgrade_available=1)")
  end

  defp cleanup do
    Enum.each([@itb_path, @env_path, @fwenv_path], &File.rm/1)
  end
end

ApplyOTA.run()
