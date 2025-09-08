{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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
    
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
      systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      pyproject = pyproject-nix.lib.project.loadPyproject { projectRoot = ./.; };
      projectName = pyproject.pyproject.project.name;
      projectVersion = pyproject.pyproject.project.version;

      # Load Python dependencies from uv workspace into a package overlay.
      overlay = workspace.mkPyprojectOverlay {
        # By default, we set the preference to `wheel`, letting most packages "just work".
        # If you want to build everything from source, use `sdist`, but you will likely need
        # to implement dependency fixups below.
        sourcePreference = "wheel";
      };

      perSystem =
        system:
        let
          pkgs = nixpkgs.legacyPackages."${system}";

          # By default, we use the current "stable" version of Python selected by `nixpkgs`.
          python = pkgs.python3;

          # This contains any build fixups needed for Python packages.
          dependencyFixups = (
            _final: _prev: {
              # Implement project-specific build fixups for dependencies here.
              # See https://pyproject-nix.github.io/uv2nix/patterns/patching-deps.html for details.
              # Note that uv2nix is _not_ using Nixpkgs buildPythonPackage.
              # It's using https://pyproject-nix.github.io/pyproject.nix/build.html
              # If you need to build everything from sdists, you should consider reusing existing
              # build system fixups, like https://github.com/TyberiusPrime/uv2nix_hammer_overrides
              krb5 = _prev.krb5.overrideAttrs (old: {
                nativeBuildInputs = old.nativeBuildInputs ++  [ pkgs.krb5.dev ];
              });
              pykerberos = _prev.pykerberos.overrideAttrs (old: {
                buildInputs = (old.buildInputs or []) ++  [ pkgs.krb5.dev ];
              });
              pyaudio = _prev.pyaudio.overrideAttrs (old: {
                buildInputs = (old.buildInputs or []) ++  [ pkgs.portaudio ];
              });
              pygraphviz = _prev.pygraphviz.overrideAttrs (old: {
                buildInputs = (old.buildInputs or []) ++  [ pkgs.graphviz ];
              });
              python-libarchive = _prev.python-libarchive.overrideAttrs (old: {
                buildInputs = (old.buildInputs or []) ++  [ pkgs.libarchive.dev ];
              });
              asks = _prev.asks.overrideAttrs (old: {
                nativeBuildInputs = old.nativeBuildInputs ++ [ _final.h11 ];
              });
            }
          );

          buildSystemFixups = (
            _final: _prev:
            let
              buildSystemOverrides = {
                docopt.setuptools = [ ];
                packmodule.setuptools = [ ];
                atomicwrites.setuptools = [ ];
                fpdf.setuptools = [ ];
                llvmlite.setuptools = [ ];
                numba.setuptools = [ ];
                psycopg2.setuptools = [ ];
                peewee.setuptools = [ ];
                amazon-ion.setuptools = [ ];
                krb5 = { setuptools = [ ]; cython = [ ]; };
                varint.setuptools = [ ];
                webrtcvad.setuptools = [ ];
                sqlmap.setuptools = [ ];
                pygraphviz.setuptools = [ ];
                pyaudio.setuptools = [ ];
                pykerberos.setuptools = [ ];
                nuitka.setuptools = [ ];
                pycipher.setuptools = [ ];
                python-libarchive.setuptools = [ ];
                sseclient.setuptools = [ ];
                twofish.setuptools = [ ];
                clickhouse-driver.setuptools = [ ];
                sansio-multipart.setuptools = [ ];
                toutatis.setuptools = [ ];
                z3.setuptools = [ ];
              };
            in
            builtins.mapAttrs (
              name: spec:
              _prev.${name}.overrideAttrs (old: {
                nativeBuildInputs = old.nativeBuildInputs ++ _final.resolveBuildSystem spec;
              })
            ) buildSystemOverrides
          );

          # Constuct complete Python package set based on workspace and overrides.
          pythonSet =
            (pkgs.callPackage pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.default
                  overlay
                  dependencyFixups
                  buildSystemFixups
                ]
              );

          # Apply any fixups that apply at the virtualenv level, not to specific packages.
          applyVirtualenvFixups =
            env:
            lib.pipe env [
              # Ignore a configured list of colliding files (semi-common in namespace packages)
              (
                env:
                env.overrideAttrs (old: {
                  venvIgnoreCollisions = [ ];
                })
              )
              # Add a metadata element so that things like `nix run` point at the main script
              (env: lib.addMetaAttrs { mainProgram = projectName; } env)
              (env: env.overrideAttrs (old: {
                fixupPhase = ''
                  ${old.fixupPhase or ""}
                  rm $out/bin/activate
                '';
              }))
            ];

          # Build the "release" virtualenv, used for `nix run` or container builds.
          venvRelease = applyVirtualenvFixups (
            pythonSet.mkVirtualEnv "${projectName}-env" workspace.deps.default
          );
        in
        {
          packages.default = venvRelease;
        
          devShells.default = pkgs.mkShellNoCC {
            packages = [
              venvRelease
              pkgs.uv
            ];

            env = {
              # Don't create venv using uv
              UV_NO_SYNC = "1";

              # Force uv to use Python interpreter from venv
              UV_PYTHON = "${venvRelease}/bin/python";

              # Prevent uv from downloading managed Python
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              # Undo nixpkgs default dependency propagation
              unset PYTHONPATH
            '';
          };
        };

      eachSystem = lib.genAttrs (import systems);
      applySystemToAttrs =
        attrNames: lib.genAttrs attrNames (attrName: eachSystem (system: (perSystem system)."${attrName}"));
      flakeOutput = applySystemToAttrs [
        "devShells"
        "packages"
      ];
    in
    flakeOutput;
}
