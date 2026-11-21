# Step 002 — Rendering del disco via Kitty graphics protocol

**Plan phase:** Phase 2: Disc Rendering
**Status:** not started
**Prerequisites:** Step 001 (verifica Kitty graphics protocol e metriche pixel)

## Goal

Sostituire il rendering half-block del disco in src/render.zig con un renderer RGBA ad alta risoluzione via Kitty graphics protocol (disco circolare con buco centrale, rotazione fluida a 33⅓ RPM con inerzia, anti-aliasing, riflessi statici opzionali, crossfade tra cover e gestione resize/pulizia).

## Checklist

- [ ] s2-kitty-mod | Implementare modulo src/kitty.zig per trasmissione RGBA Kitty e cleanup su resize/uscita
  - tags: kitty, impl
  - deps: s1-transport, s1-fallback-dec
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
- [ ] s2-disc-rgba | Sostituire il disco half-block con rasterizzazione RGBA circolare ad alta risoluzione (rotazione, buco, AA, riflessi, crossfade)
  - tags: kitty, render, impl
  - deps: s2-kitty-mod
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
- [ ] s2-frame-loop | Integrare trasmissione Kitty nel loop 60+ FPS in src/main.zig con synchronized updates senza flicker
  - tags: kitty, perf, impl
  - deps: s2-disc-rgba
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata

## Completion criteria

Il disco vinile con cover art ruota a 60+ FPS via Kitty graphics protocol con bordi puliti, buco centrale trasparente/sfondo, senza artefatti né flicker al cambio brano o resize.

## Results and decisions

## Handoff

- **Next action:** to be defined.
