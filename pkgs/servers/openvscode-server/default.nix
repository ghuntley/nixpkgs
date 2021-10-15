{ lib, stdenv, fetchFromGitHub, buildGoModule, makeWrapper, runCommand
, cacert, moreutils, jq, git, zip, rsync, pkg-config, yarn, python3
, nodejs-14_x, libsecret, xorg, esbuild, ripgrep
, AppKit, Cocoa, Security, cctools }:

let
  system = stdenv.hostPlatform.system;

  nodejs = nodejs-14_x;
  python = python3;
  yarn' = yarn.override { inherit nodejs; };
  defaultYarnOpts = [ "frozen-lockfile" "non-interactive" "no-progress"];

in stdenv.mkDerivation rec {
  pname = "openvscode-server";
  commit = "212e0f7df75d4fc52067667f43c8cc23bf39db04";
  version = "${commit}";

  src = fetchFromGitHub {
    owner = "ghuntley";
    repo = "openvscode-server";
    # https://github.com/gitpod-io/vscode/tree/web-server
    rev = "${commit}";
    sha256 = "0ng6zq2grfhmklsbaa983cqa3jargxknsxjbgzfbvxasnnilvhj6";
  };

  yarnCache = stdenv.mkDerivation {
    name = "${pname}-${version}-${system}-yarn-cache";
    inherit src;
    nativeBuildInputs = [ cacert yarn git ];
    buildPhase = ''
      export HOME=$PWD
 
      yarn config set yarn-offline-mirror $out
      find "$PWD" -name "yarn.lock" -printf "%h\n" | \
        xargs -I {} yarn --cwd {} \
          --frozen-lockfile --ignore-scripts --ignore-platform \
          --ignore-engines --no-progress --non-interactive
    '';

    installPhase = ''
      echo yarnCache
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";

    # to get hash values use nix-build -A vscode-webserver.prefetchYarnCache
    outputHash = {
      x86_64-linux = "10h89anyhg1j2c0h7vsr4ddww18xibczd92m0rqw4707ib6rvqnd";
      aarch64-linux = "10h89anyhg1j2c0h7vsr4ddww18xibczd92m0rqw4707ib6rvqnd";
      x86_64-darwin = "10h89anyhg1j2c0h7vsr4ddww18xibczd92m0rqw4707ib6rvqnd";
    }.${system} or (throw "Unsupported system ${system}");
  };

  # Extract the Node.js source code which is used to compile packages with
  # native bindings
  nodeSources = runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';

  nativeBuildInputs = [
    nodejs yarn' python pkg-config zip makeWrapper git rsync jq moreutils esbuild
  ];
  buildInputs = lib.optionals (!stdenv.isDarwin) [ libsecret ]
    ++ (with xorg; [ libX11 libxkbfile ])
    ++ lib.optionals stdenv.isDarwin [
      AppKit Cocoa Security cctools
    ];

  patches = [
  
  ];

  postPatch = ''
    export HOME=$PWD

    patchShebangs .

    # use offline cache when installing packages
    substituteInPlace build/npm/postinstall.js \
      --replace 'yarn' 'yarn --ignore-scripts'

  '';

  configurePhase = ''
    # run yarn offline by default
    echo '--install.offline true' >> .yarnrc

    # set default yarn opts
    ${lib.concatMapStrings (option: ''
      yarn --offline config set ${option}
    '') defaultYarnOpts}

    # set offline mirror to yarn cache we created in previous steps
    yarn --offline config set yarn-offline-mirror "${yarnCache}"

    # skip unnecessary electron download
    export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  '' + lib.optionalString stdenv.isLinux ''
    # set nodedir, so we can build binaries later
    npm config set nodedir "${nodeSources}"
  '';

  buildPhase = ''
    # install vscode-webserver dependencies
    yarn --offline --ignore-scripts

    # put ripgrep binary into bin, so postinstall does not try to download it
    find -name vscode-ripgrep -type d \
      -execdir mkdir -p {}/bin \; \
      -execdir ln -s ${ripgrep}/bin/rg {}/bin/rg \;

    find -name esbuild -type d \
      -execdir mkdir -p {}/bin \; \
      -execdir ln -s ${esbuild}/bin/esbuild {}/bin/esbuild \;

    # patch shebangs of everything, also cached files, as otherwise postinstall
    # will not be able to find /usr/bin/env, as it does not exist in sandbox
    patchShebangs .

    # Playwright is only needed for tests, we can disable it for builds.
    # There's an environment variable to disable downloads, but the package makes a breaking call to
    # sw_vers before that variable is checked.
    patch -p1 -i ${./playwright.patch}

    # rebuild binaries, we use npm here, as yarn does not provide an alternative
    # that would not attempt to try to reinstall everything and break our
    # patching attempts
    npm rebuild --update-binary

    # run postinstall scripts, which eventually do yarn install on all
    # additional requirements
    yarn postinstall --frozen-lockfile --offline
    
    # build vscode-webserver
    yarn gulp server-min
  '';

  installPhase = ''
     echo installPhase
  '';

  passthru = {
    prefetchYarnCache = lib.overrideDerivation yarnCache (d: {
      outputHash = lib.fakeSha256;
    });
  };

  meta = with lib; {
    description = "Run VS Code on a remote server";
    longDescription = ''
      vscode-webserver is VS Code running on a remote server, accessible through the
      browser.
    '';
    homepage = "https://github.com/gitpod-io/openvscode-server";
    license = licenses.mit;
    maintainers = with maintainers; [ offline ghuntley ];
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" ];
  };
}
