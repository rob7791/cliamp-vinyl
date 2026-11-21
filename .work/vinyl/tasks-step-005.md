# Step 005 — Packaging, test end-to-end e documentazione

**Plan phase:** Phase 5: Packaging & Verification
**Status:** in progress
**Prerequisites:** Step 003 e Step 004 completati

## Goal

Aggiungere installazione in ~/.local/bin/vinyl, eseguire test end-to-end (60+ FPS, resize, pausa/ripresa, cambio traccia, lifecycle daemon) e scrivere il README.md.

## Checklist

- [x] s5-install | Aggiungere installazione del binario in ~/.local/bin/vinyl
  - tags: packaging
  - deps: s3-vis-polish, s3-ui-controls, s4-art-verify
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: Aggiunto step zig build install-local in build.zig; installato e verificato ~/.local/bin/vinyl --help
- [x] s5-e2e | Eseguire test end-to-end a 60+ FPS (daemon auto-start/attach, pausa/inerzia, cambio brano, resize, cleanup)
  - tags: verify, perf
  - deps: s5-install
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: E2E PTY+Kitty+Braille verificato: 55.7-60.0 fps direct (30.6 MB/s) e 60.0 fps file (0.13 MB/s), resize SIGWINCH 160x50->140x44, pausa space, auto-start/stop cliamp --daemon, cleanup Kitty a=d,d=A e /tmp/vinyl-kitty-*; ispezionate screenshot PNG composite
- [ ] s5-readme | Scrivere README.md con installazione, setup plugin cliamp, opzioni CLI e scorciatoie
  - tags: docs
  - deps: s5-e2e
  - mode: isolated
  - mode_reason: Scrive solo README.md a fine implementazione
  - claimed_by: sub-docs

## Completion criteria

Binario installabile in ~/.local/bin/vinyl, test end-to-end superati senza errori/leak e README.md completo.

## Results and decisions

## Handoff

- **Next action:** to be defined.
