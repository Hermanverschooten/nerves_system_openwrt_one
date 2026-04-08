defmodule NervesSystemOpenwrtOne.MixProject do
  use Mix.Project

  @github_organization "hverschooten"
  @app :nerves_system_openwrt_one
  @source_url "https://github.com/#{@github_organization}/#{@app}"
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: description(),
      package: package(),
      deps: deps(),
      aliases: [loadconfig: [&bootstrap/1]],
      docs: docs(),
      preferred_cli_env: %{
        docs: :docs,
        "hex.build": :docs,
        "hex.publish": :docs
      }
    ]
  end

  def application do
    # We don't start any OTP processes -- the system is a build-time
    # artifact -- but we DO ship a tiny piece of runtime Elixir
    # (`NervesSystemOpenwrtOne.UBootEnvKVBackend`) that user apps need
    # access to. Returning an empty keyword list (instead of nothing)
    # tells `mix release` to include this dep's BEAM files even though
    # the user app declares it with `runtime: false`.
    [extra_applications: []]
  end

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, "#{@github_organization}/#{@app}"}
      ],
      build_runner_opts: build_runner_opts(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      # The :env key is an experimental Nerves feature for adding environment
      # variables to the cross-compile environment, mainly for llvm-based
      # tooling that needs precise processor information.
      env: [
        {"TARGET_ARCH", "aarch64"},
        {"TARGET_CPU", "cortex_a53"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnu"},
        {"TARGET_GCC_FLAGS",
         "-mabi=lp64 -Wl,-z,max-page-size=4096 -Wl,-z,common-page-size=4096 -fstack-protector-strong -mcpu=cortex-a53 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: package_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.11", runtime: false},
      {:nerves_system_br, "1.33.4", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 13.2.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp description do
    "Nerves System - OpenWRT One (MediaTek MT7981B / Filogic 820)"
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp package_files do
    [
      "dts",
      "fwup_include",
      "lib",
      "patches",
      "prebuilt",
      "rootfs_overlay",
      "scripts",
      "CHANGELOG.md",
      "Config.in",
      "fwup-ops.conf",
      "fwup.conf",
      "LICENSE",
      "linux-6.18.defconfig",
      "mix.exs",
      "nerves_defconfig",
      "openwrt-one.its",
      "post-build.sh",
      "post-createfs.sh",
      "ubinize-fit.cfg",
      "README.md",
      "VERSION"
    ]
  end

  defp build_runner_opts() do
    # Download source files first to get download errors right away.
    [make_args: primary_site() ++ ["source", "all", "legal-info"]]
  end

  defp primary_site() do
    case System.get_env("BR2_PRIMARY_SITE") do
      nil -> []
      primary_site -> ["BR2_PRIMARY_SITE=#{primary_site}"]
    end
  end

  defp set_target() do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end
