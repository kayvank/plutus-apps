{ system ? builtins.currentSystem
, enableHaskellProfiling ? false
, sourcesOverride ? { }
, sources ? import ./nix/sources.nix { inherit system; } // sourcesOverride
, packages ? import ./. { inherit system enableHaskellProfiling sources sourcesOverride; }
}:
let
  inherit (packages) pkgs plutus-apps docs;
  inherit (pkgs) stdenv lib utillinux python3 nixpkgs-fmt glibcLocales;
  inherit (plutus-apps) haskell stylish-haskell sphinxcontrib-haddock sphinx-markdown-tables sphinxemoji scriv nix-pre-commit-hooks cabal-fmt;

  # Feed cardano-wallet, cardano-cli & cardano-node to our shell. This is stable as it doesn't mix
  # dependencies with this code-base; the fetched binaries are the "standard" builds that people
  # test. This should be fast as it mostly fetches Hydra caches without building much.
  cardano-wallet = (import sources.flake-compat {
    inherit pkgs;
    src = builtins.fetchTree
      {
        type = "github";
        owner = "input-output-hk";
        repo = "cardano-wallet";
        rev = "18a931648550246695c790578d4a55ee2f10463e";
        narHash = "sha256-3Rnj/g3KLzOW5YSieqsUa9IF1Td22Eskk5KuVsOFgEQ=";
      };
  }).defaultNix;

  cardano-node = (import sources.flake-compat {
    inherit pkgs;
    src = builtins.fetchTree
      {
        type = "github";
        owner = "input-output-hk";
        repo = "cardano-node";
        rev = "ebc7be471b30e5931b35f9bbc236d21c375b91bb";
        narHash = "sha256-WRRzfpDc+YVmTNbN9LNYY4dS8o21p/6NoKxtcZmoAcg=";
      };
  }).defaultNix;

  # For Sphinx, scriv, and ad-hoc usage
  pythonTools = python3.withPackages (ps: [
    scriv
    sphinxcontrib-haddock.sphinxcontrib-domaintools
    sphinx-markdown-tables
    sphinxemoji
    ps.sphinxcontrib_plantuml
    ps.sphinxcontrib-bibtex
    ps.sphinx-autobuild
    ps.sphinx
    ps.sphinx_rtd_theme
    ps.recommonmark
  ]);

  # Configure project pre-commit hooks
  pre-commit-check = nix-pre-commit-hooks.run {
    src = (lib.cleanSource ./.);
    tools = {
      stylish-haskell = stylish-haskell;
      nixpkgs-fmt = nixpkgs-fmt;
      shellcheck = pkgs.shellcheck;
      cabal-fmt = cabal-fmt;
    };
    hooks = {
      stylish-haskell.enable = true;
      nixpkgs-fmt = {
        enable = true;
        # While nixpkgs-fmt does exclude patterns specified in `.ignore` this
        # does not appear to work inside the hook. For now we have to thus
        # maintain excludes here *and* in `./.ignore` and *keep them in sync*.
        excludes = [ ".*nix/pkgs/haskell/materialized.*/.*" ];
      };
      cabal-fmt.enable = true;
      shellcheck.enable = true;
      png-optimization = {
        enable = true;
        name = "png-optimization";
        description = "Ensure that PNG files are optimized";
        entry = "${pkgs.optipng}/bin/optipng";
        files = "\\.png$";
      };
    };
  };

  nixFlakesAlias = pkgs.runCommand "nix-flakes-alias" { } ''
    mkdir -p $out/bin
    ln -sv ${pkgs.nixFlakes}/bin/nix $out/bin/nix-flakes
  '';

  # build inputs from nixpkgs ( -> ./nix/default.nix )
  nixpkgsInputs = with pkgs; [
    awscli2
    bzip2
    cacert
    editorconfig-core-c
    dateutils
    ghcid
    jq
    nixFlakesAlias
    nixpkgs-fmt
    cabal-fmt
    nodejs
    plantuml
    # See https://github.com/cachix/pre-commit-hooks.nix/issues/148 for why we need this
    pre-commit
    shellcheck
    sqlite-interactive
    stack
    wget
    yq
    z3
    zlib
  ];

  # local build inputs ( -> ./nix/pkgs/default.nix )
  localInputs = (with plutus-apps; [
    cabal-install
    cardano-node.packages.${pkgs.system}.cardano-cli
    cardano-node.packages.${pkgs.system}.cardano-node
    cardano-wallet.packages.${pkgs.system}.cardano-wallet
    cardano-repo-tool
    docs.build-and-serve-docs
    fixPngOptimization
    fixCabalFmt
    fixStylishHaskell
    haskell-language-server
    haskell-language-server-wrapper
    hie-bios
    hlint
    stylish-haskell
  ]);

  deprecation-warning = ''
    echo -e "\033[0;33m*********************************************************************"
    echo -e "* nix-shell is deprecated and will be gone on March 13th 2023.      *"
    echo -e "* Please exit this shell and run 'nix develop' instead.             *"
    echo -e "* For any problem with the new shell please notify @zeme-iohk       *"
    echo -e "* and revert to using 'nix-shell' until fixed.                      *"
    echo -e "*********************************************************************\033[0m"
  '';

in
haskell.project.shellFor {
  nativeBuildInputs = nixpkgsInputs ++ localInputs ++ [ pythonTools ];
  # We don't currently use this, and it's a pain to materialize, and otherwise
  # costs a fair bit of eval time.
  withHoogle = false;

  shellHook = ''
    ${pre-commit-check.shellHook}
    ${deprecation-warning}
  ''
  # Work around https://github.com/NixOS/nix/issues/3345, which makes
  # tests etc. run single-threaded in a nix-shell.
  # Sets the affinity to cores 0-1000 for $$ (current PID in bash)
  # Only necessary for linux - darwin doesn't even expose thread
  # affinity APIs!
  + lib.optionalString stdenv.isLinux ''
    ${utillinux}/bin/taskset -pc 0-1000 $$
  ''
  + ''
    export GITHUB_SHA=$(git rev-parse HEAD)

    # This is probably set by haskell.nix's shellFor, but it interferes
    # with the pythonTools in nativeBuildInputs above.
    # This workaround will become obsolete soon once this respository
    # is migrated to Standard.
    export PYTHONPATH=
  '';

  # This is no longer set automatically as of more recent `haskell.nix` revisions,
  # but is useful for users with LANG settings.
  LOCALE_ARCHIVE = lib.optionalString
    (stdenv.hostPlatform.libc == "glibc")
    "${glibcLocales}/lib/locale/locale-archive";
}
