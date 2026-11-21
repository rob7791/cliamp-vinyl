# Step 001 — Verifica ambiente e protocollo Kitty

**Plan phase:** to be defined
**Status:** not started

## Goal

Verificare il supporto al Kitty graphics protocol in Ghostty e dentro herdr, le metriche pixel del terminale (TIOCGWINSZ) e il metodo di trasmissione più veloce a 60+ FPS (SHM/file temporaneo vs base64 inline, image IDs e z-index).

## Checklist

- [ ] s1-probe | Verificare supporto Kitty graphics protocol in Ghostty e herdr (probe, TIOCGWINSZ pixel, z-index)
  - tags: research, kitty
- [ ] s1-fallback-dec | Definire comportamento se il terminale/multiplexer non supporta Kitty graphics protocol
  - tags: decision, kitty
  - hold: Se il terminale o il multiplexer (es. herdr) non supporta il Kitty graphics protocol o TIOCGWINSZ non riporta le dimensioni in pixel, come deve comportarsi vinyl?
  - hold_options: Esci subito con messaggio di errore chiaro indicando i terminali supportati | Mostra avviso e continua con solo visualizer Braille + metadati (senza disco)
  - hold_default: Esci subito con messaggio di errore chiaro indicando i terminali supportati
- [ ] s1-transport | Validare trasporto Kitty a 60+ FPS (SHM/file/inline, q=2, riuso image ID, pulizia)
  - tags: research, kitty, perf
  - deps: s1-probe

## Completion criteria

Supporto Kitty graphics protocol verificato sull'ambiente reale, strategia di trasmissione a 60+ FPS decisa e documentata nei risultati dello step.

## Results and decisions

## Handoff

- **Next action:** to be defined.
