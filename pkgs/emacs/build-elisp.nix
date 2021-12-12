{ lib, stdenv, emacs, texinfo, gcc }:
{ ename
, src
, version
, files
, meta
, allowSkipCompiling ? false
, nativeCompileAhead
, elispInputs
, ...
}:
let
  inherit (builtins) concatStringsSep replaceStrings match elem;

  nativeComp = emacs.nativeComp or false;

  buildCmd = ''
    if ! emacs --batch -L . -f batch-byte-compile *.el
    then
      if [[ "${lib.boolToString allowSkipCompiling}" = true ]]
      then
        echo "warn: Byte-compile is skipped."
      else
        echo "To allow this error, set allowErrors.allowSkipCompiling to true."
        exit 1
      fi
    fi
    emacs --batch -l package --eval "(package-generate-autoloads '${ename} \".\")"

    if [[ ! -e "${ename}-pkg.el" ]]
    then
      cat > ${ename}-pkg.el <<PKG
      (define-package "${ename}" "${version}"
        "${meta.description or ""}"
        '(${
          # It may be necessary to include the version actually specified in the
          # header, but it won't matter anyway.
          lib.concatMapStrings (name: "(" + name + " \"0\")")
            (lib.catAttrs "ename" elispInputs)
        }))
      ;; Local Variables:
      ;; no-byte-compile: t
      ;; End:
    PKG
    fi
  '';

  hasInfoOutput =
    # (elem "info" (meta.outputsToInstall or []))
    # &&
    (lib.findFirst (f: match ".+\\.(info|texi(nfo)?)" f != null) null files
    != null);

  buildInfo = ''
    cwd="$PWD"
    cd $src
    for doc in $(find -name '*.texi' -o -name '*.texinfo')
    do
      local basename=$(basename $doc)
      cd $src/$(dirname $doc)
      makeinfo --no-split "$basename" -o $cwd/''${basename%%.*}.info
    done
    cd $cwd
  '';

  installInfo = ''
    mkdir -p $info/share
    install -d $info/share/info
    for i in *.info
    do
      install -t $info/share/info $i
    done
  '';
in
stdenv.mkDerivation rec {
  inherit src ename meta version;

  pname = concatStringsSep "-" [
    (replaceStrings [ "." ] [ "-" ] emacs.name)
    (lib.toPName ename)
  ];

  preferLocalBuild = true;
  allowSubstitutes = false;

  outputs = [ "out" ] ++ lib.optional hasInfoOutput "info";

  buildInputs = [ emacs texinfo ];
  # nativeBuildInputs = lib.optional nativeComp gcc;

  # TODO: Copy documents of ELPA packages specified in :doc and :readme.
  # TODO: Handle :rename of ELPA packages
  # See https://git.savannah.gnu.org/cgit/emacs/elpa.git/plain/README for details.
  unpackPhase = ''
    for file in ${lib.escapeShellArgs files}
    do
      cp -r $src/$file .
    done
  '';

  EMACSLOADPATH = lib.concatStrings
    (map (pkg: "${pkg.outPath}/share/emacs/site-lisp/elpa/${pkg.ename}-${pkg.version}:")
      elispInputs);

  buildPhase = ''
    export EMACSLOADPATH

    runHook preBuild

    ${buildCmd}

    ${lib.optionalString hasInfoOutput buildInfo}

    runHook postBuild
  '';

  EMACSNATIVELOADPATH = "${
    lib.makeSearchPath "share/emacs/native-lisp/" elispInputs
  }:";

  # Because eln depends on the file name hash of the source file, native
  # compilation must be done after the elisp files are installed. For details,
  # see the documentation of comp-el-to-eln-rel-filename.
  buildAndInstallNativeLisp = ''
    nativeLispDir=$out/share/emacs/native-lisp
    mkdir -p $nativeLispDir

    EMACSLOADPATH="$EMACSLOADPATH" EMACSNATIVELOADPATH="$EMACSNATIVELOADPATH" \
      emacs --batch -L $lispDir -l ${./comp-native.el} \
        --eval "(push \"$nativeLispDir/\" native-comp-eln-load-path)" \
        --eval "(setq native-compile-target-directory \"$nativeLispDir/\")" \
        -f run-native-compile-sync $lispDir
  '';

  installPhase = ''
    runHook preInstall

    lispDir=$out/share/emacs/site-lisp/elpa/$ename-$version
    install -d $lispDir
    tar cf - --exclude='*.info' --exclude='eln-cache' . \
      | (cd $lispDir && tar xf -)

    ${lib.optionalString (nativeComp && nativeCompileAhead) buildAndInstallNativeLisp}

    ${lib.optionalString hasInfoOutput installInfo}

    runHook postInstall
  '';
}
