{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils = {
      url = "github:numtide/flake-utils";
    };
  };

  outputs = {
    self,
    nixpkgs,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          permittedInsecurePackages = [
            "olm-3.2.16"
          ];
        };
      };
      inherit (nixpkgs) lib;

      # Use Python 3.12 from nixpkgs
      python = pkgs.python312;

      workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};

      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        # Sdists are less likely to "just work" because of the metadata missing from uv.lock.
        # Binary wheels are more likely to, but may still require overrides for library dependencies.
        sourcePreference = "wheel";
      };

      pyprojectOverrides = import ./overrides.nix;

      # Construct package set
      pythonSet =
        # Use base package set from pyproject.nix builders
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        })
        .overrideScope
        (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            pyprojectOverrides
          ]
        );

      # Add metadata attributes to the virtual environment.
      addMeta = drv:
        drv.overrideAttrs (old: {
          # Pass through tests from our package into the virtualenv so they can be discovered externally.
          passthru = lib.recursiveUpdate (old.passthru or {}) {
            inherit (pythonSet.testing.passthru) tests;
          };

          # Set meta.mainProgram for commands like `nix run`.
          # https://nixos.org/manual/nixpkgs/stable/#var-meta-mainProgram
          meta =
            (old.meta or {})
            // {
              mainProgram = "bitchbot";
              description = "fuck you";
              homepage = "https://github.com/CPlusPatch/jesses-vengeance";
              license = lib.licenses.agpl3Only;
            };

          nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.python312Packages.python-olm];
        });
    in {
      packages = rec {
        bitchbot = addMeta (pythonSet.mkVirtualEnv "bitchbot-env" workspace.deps.default);
        default = bitchbot;
      };

      apps = rec {
        bitchbot = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/bitchbot";
          meta = self.packages.${system}.default.meta;
        };
        default = bitchbot;
      };

      nixosModules = {
        bitchbot = {
          config,
          lib,
          pkgs,
          ...
        }: let
          cfg = config.services.bitchbot;
          configFile = configFormat.generate "config.json" cfg.config;
          configFormat = pkgs.formats.json {};

          inherit (lib.options) mkOption;
          inherit (lib.modules) mkIf;
        in {
          options.services.bitchbot = {
            enable = mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable the bitchbot service";
            };

            dataDir = mkOption {
              type = lib.types.str;
              default = "/var/lib/bitchbot";
              description = "Path to the data directory for the bot";
            };

            config = mkOption {
              type = with lib.types;
                submodule {
                  freeformType = configFormat.type;
                  options = {
                    # This is a reduced set of popular options and defaults
                    # Do not add every available option here, they can be specified
                    # by the user at their own discretion. This is a freeform type!

                    homeserver_url = mkOption {
                      type = types.str;
                      description = "The homeserver URL";
                      default = "https://cpluspatch.dev";
                    };

                    user_id = mkOption {
                      type = types.str;
                      description = "The user ID that the bot will use to login to matrix";
                      default = "@bitchbot:cpluspatch.dev";
                    };

                    store_path = mkOption {
                      type = types.str;
                      description = "Path to the store for the bot";
                      default = "./store";
                    };

                    wife_id = mkOption {
                      type = types.str;
                      description = "The user ID of the wife";
                      default = "@nex:nexy7574.co.uk";
                    };
                  };
                };
              description = "Contents of the config file for the bitchbot service";
              default = {};
            };
          };

          config = mkIf cfg.enable {
            systemd.services.bitchbot = {
              after = ["network-online.target"];
              wantedBy = ["multi-user.target"];
              requires = ["network-online.target"];

              description = "Bitchbot service";

              serviceConfig = {
                ExecStart = "${self.packages.${system}.default}/bin/bitchbot";
                Type = "simple";
                Restart = "always";
                RestartSec = "5s";

                User = "bitchbot";
                Group = "bitchbot";

                StateDirectory = "bitchbot";
                StateDirectoryMode = "0700";
                RuntimeDirectory = "bitchbot";
                RuntimeDirectoryMode = "0700";

                # Set the working directory to the data directory
                WorkingDirectory = cfg.dataDir;

                StandardOutput = "journal";
                StandardError = "journal";
                SyslogIdentifier = "bitchbot";

                Environment = "CONFIG_FILE=${configFile}";
              };
            };

            users.users.bitchbot = {
              name = "bitchbot";
              group = "bitchbot";
              home = cfg.dataDir;
              isSystemUser = true;
              packages = [
                self.packages.${system}.default
              ];
            };

            users.groups.bitchbot = {};
          };
        };
      };

      devShells = {
        # From https://pyproject-nix.github.io/uv2nix/usage/hello-world.html
        uv2nix = let
          # Create an overlay enabling editable mode for all local dependencies.
          editableOverlay = workspace.mkEditablePyprojectOverlay {
            # Use environment variable
            root = "$REPO_ROOT";
          };

          # Override previous set with our overrideable overlay.
          editablePythonSet = pythonSet.overrideScope (
            lib.composeManyExtensions [
              editableOverlay

              # Apply fixups for building an editable package of your workspace packages
              (final: prev: {
                bitchbot = prev.bitchbot.overrideAttrs (old: {
                  # It's a good idea to filter the sources going into an editable build
                  # so the editable package doesn't have to be rebuilt on every change.
                  src = lib.fileset.toSource {
                    root = old.src;
                    fileset = lib.fileset.unions [
                      (old.src + "/pyproject.toml")
                      (old.src + "/README.md")
                    ];
                  };

                  # Hatchling (our build system) has a dependency on the `editables` package when building editables.
                  #
                  # In normal Python flows this dependency is dynamically handled, and doesn't need to be explicitly declared.
                  # This behaviour is documented in PEP-660.
                  #
                  # With Nix the dependency needs to be explicitly declared.
                  nativeBuildInputs =
                    old.nativeBuildInputs
                    ++ final.resolveBuildSystem {
                      editables = [];
                    };
                });
              })
            ]
          );

          # Build virtual environment, with local packages being editable.
          #
          # Enable all optional dependencies for development.
          virtualenv = editablePythonSet.mkVirtualEnv "bitchbot-dev-env" workspace.deps.all;
        in
          pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];

            env = {
              # Don't create venv using uv
              UV_NO_SYNC = "1";

              # Force uv to use Python interpreter from venv
              UV_PYTHON = "${virtualenv}/bin/python";

              # Prevent uv from downloading managed Python's
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              # Undo dependency propagation by nixpkgs.
              unset PYTHONPATH

              # Get repository root using git. This is expanded at runtime by the editable `.pth` machinery.
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
      };
    });
}
