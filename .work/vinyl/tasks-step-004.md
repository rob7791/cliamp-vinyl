# Step 004 — Cover art completa e plugin Lua bridge per cliamp

**Plan phase:** Phase 4: Cover Art & Bridge
**Status:** not started
**Prerequisites:** Step 002 (caricamento texture sul disco Kitty)

## Goal

Implementare e integrare il plugin Lua bridge per cliamp per risolvere le cover art di tutti i provider remoti (Navidrome, Spotify, YT Music) oltre ai file locali e MPRIS, con comando o script di installazione/trust.

## Checklist

- [ ] s4-lua-plugin | Creare il plugin Lua bridge per cliamp che pubblica album_art_url su /tmp/cliamp-vinyl-art.txt
  - tags: cliamp, art, plugin
- [ ] s4-plugin-install | Aggiungere comando o script di installazione e trust del plugin Lua bridge per cliamp
  - tags: cliamp, plugin, ux
  - deps: s4-lua-plugin
- [ ] s4-art-verify | Verificare caricamento cover art per tutte le sorgenti (locale embedded/sidecar, bridge remoto, MPRIS, placeholder)
  - tags: art, verify
  - deps: s4-plugin-install, s2-frame-loop

## Completion criteria

Plugin Lua bridge installabile facilmente, cover art caricate correttamente per brani locali (embedded/sidecar) e remoti di cliamp.

## Results and decisions

## Handoff

- **Next action:** to be defined.
