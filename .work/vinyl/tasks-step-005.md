# Step 005 — Packaging, test end-to-end e documentazione

**Plan phase:** Phase 5: Packaging & Verification
**Status:** not started
**Prerequisites:** Step 003 e Step 004 completati

## Goal

Aggiungere installazione in ~/.local/bin/vinyl, eseguire test end-to-end (60+ FPS, resize, pausa/ripresa, cambio traccia, lifecycle daemon) e scrivere il README.md.

## Checklist

- [ ] s5-install | Aggiungere installazione del binario in ~/.local/bin/vinyl
  - tags: packaging
  - deps: s3-vis-polish, s3-ui-controls, s4-art-verify
- [ ] s5-e2e | Eseguire test end-to-end a 60+ FPS (daemon auto-start/attach, pausa/inerzia, cambio brano, resize, cleanup)
  - tags: verify, perf
  - deps: s5-install
- [ ] s5-readme | Scrivere README.md con installazione, setup plugin cliamp, opzioni CLI e scorciatoie
  - tags: docs
  - deps: s5-e2e

## Completion criteria

Binario installabile in ~/.local/bin/vinyl, test end-to-end superati senza errori/leak e README.md completo.

## Results and decisions

## Handoff

- **Next action:** to be defined.
