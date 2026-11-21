# Step 004 — Cover art completa e plugin Lua bridge per cliamp

**Plan phase:** Phase 4: Cover Art & Bridge
**Status:** completed
**Prerequisites:** Step 002 (caricamento texture sul disco Kitty)

## Goal

Implementare e integrare il plugin Lua bridge per cliamp per risolvere le cover art di tutti i provider remoti (Navidrome, Spotify, YT Music) oltre ai file locali e MPRIS, con comando o script di installazione/trust.

## Checklist

- [x] s4-lua-plugin | Creare il plugin Lua bridge per cliamp che pubblica album_art_url su /tmp/cliamp-vinyl-art.txt
  - tags: cliamp, art, plugin
  - mode: isolated
  - mode_reason: Crea solo plugins/vinyl-art-bridge.lua senza toccare src/*.zig
  - result: Creato plugins/vinyl-art-bridge.lua per esportare path e album_art_url su /tmp/cliamp-vinyl-art.txt
- [x] s4-plugin-install | Aggiungere comando o script di installazione e trust del plugin Lua bridge per cliamp
  - tags: cliamp, plugin, ux
  - deps: s4-lua-plugin
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: Aggiunto --install-plugin in src/main.zig (con @embedFile) e scripts/install-plugin.sh; verificato su /tmp/vcd/cfg con cliamp plugins list -> trusted
- [x] s4-art-verify | Verificare caricamento cover art per tutte le sorgenti (locale embedded/sidecar, bridge remoto, MPRIS, placeholder)
  - tags: art, verify
  - deps: s4-plugin-install, s2-frame-loop
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: Verificato caricamento cover art: zig test src/art.zig ok (embedded/sidecar/data:/file://, deriveRemoteArtUrl Navidrome/YT Music, placeholder), probe ffmpeg 786432B su /tmp/vcd/test.mp3, zig build ok

## Completion criteria

Plugin Lua bridge installabile facilmente, cover art caricate correttamente per brani locali (embedded/sidecar) e remoti di cliamp.

## Results and decisions

## Handoff

- **Next action:** to be defined.
