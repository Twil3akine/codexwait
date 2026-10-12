{ lib, writeShellApplication, coreutils, findutils, gnugrep, jq }:

writeShellApplication {
  name = "codexwait";

  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    jq
  ];

  text = builtins.readFile ./src/codexwait.sh;

  meta = {
    description = "Resume Codex CLI work automatically when usage limits recover";
    homepage = "https://github.com/OWNER/codexwait";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "codexwait";
  };
}
