# Step 003 — Allineamento visualizer Braille circolare e UI

**Plan phase:** Phase 3: Visualizer & UI
**Status:** not started
**Prerequisites:** Step 002 (disco Kitty funzionante)

## Goal

Allineare geometricamente il disco Kitty in pixel con il margine e il visualizer circolare stereo Braille (cava), rifinire resa estetica, latenza/banda e controlli/metadati UI.

## Checklist

- [ ] s3-align | Allineare geometria pixel del disco Kitty con margine e anello Braille stereo anche al resize
  - tags: render, visualizer
  - deps: s2-frame-loop
- [ ] s3-vis-polish | Rifinire resa estetica del visualizer circolare continuo L/R (smoothing, peak hold, palette, sfondo)
  - tags: render, visualizer
  - deps: s3-align
- [ ] s3-ui-controls | Verificare e rifinire barra metadati, progress bar, scorciatoie playback e overlay (? / f) sopra/attorno al layer Kitty
  - tags: ui, cliamp
  - deps: s3-align

## Completion criteria

Nessuna sovrapposizione tra immagine Kitty e anello Braille a diverse dimensioni terminale; controlli playback e barra metadati reattivi e puliti.

## Results and decisions

## Handoff

- **Next action:** to be defined.
