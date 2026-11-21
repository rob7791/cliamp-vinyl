# Step 001 — Verifica ambiente e protocollo Kitty

**Plan phase:** to be defined
**Status:** completed

## Goal

Verificare il supporto al Kitty graphics protocol in Ghostty e dentro herdr, le metriche pixel del terminale (TIOCGWINSZ) e il metodo di trasmissione più veloce a 60+ FPS (SHM/file temporaneo vs base64 inline, image IDs e z-index).

## Checklist

- [x] s1-probe | Verificare supporto Kitty graphics protocol in Ghostty e herdr (probe, TIOCGWINSZ pixel, z-index)
  - tags: research, kitty
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: Verificato Ghostty + herdr 0.9.5 (libghostty + kitty_graphics=true); TIOCGWINSZ dentro herdr ha xpixel=0/ypixel=0 quindi il placement userà c=<cols>,r=<rows> in celle
- [x] s1-fallback-dec | Definire comportamento se il terminale/multiplexer non supporta Kitty graphics protocol
  - tags: decision, kitty
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - asked: Se il terminale o il multiplexer (es. herdr) non supporta il Kitty graphics protocol o TIOCGWINSZ non riporta le dimensioni in pixel, come deve comportarsi vinyl?
  - answer: mostra avviso e ti farò proseguire da una istanza fuori da herdr
  - answered_at: 2026-11-21T14:49:06Z
  - result: Applicata risposta utente: se Kitty graphics non e supportato mostrare avviso in UI e continuare con visualizer Braille + metadati (supportati --force-kitty e --no-kitty); herdr 0.9.5 supporta Kitty via ghostty_vt
- [x] s1-transport | Validare trasporto Kitty a 60+ FPS (SHM/file/inline, q=2, riuso image ID, pulizia)
  - tags: research, kitty, perf
  - deps: s1-probe
  - mode: integrated
  - mode_reason: Condivide la codebase Zig in src/ o esegue verifica integrata
  - result: Definita strategia Kitty 60+ FPS: direct t=d chunk 4096B (default) + file t=f ring-buffer 4 slot, i=1 p=1 z=0 C=1 q=2 dentro ?2026h/?2026l, S=clamp(disc_cols*6,96,320), dirty-skip in pausa

## Completion criteria

Supporto Kitty graphics protocol verificato sull'ambiente reale, strategia di trasmissione a 60+ FPS decisa e documentata nei risultati dello step.

## Results and decisions

### s1-probe (Ambiente Ghostty + herdr + TIOCGWINSZ)
- **Terminale esterno**: Ghostty (`GHOSTTY_BIN_DIR=/usr/bin`, `GHOSTTY_RESOURCES_DIR=/usr/share/ghostty`, `COLORTERM=truecolor`), supporto completo al Kitty graphics protocol.
- **Multiplexer `herdr` (v0.9.5)**: integra `ghostty_vt` (`GhosttyKittyGraphics*`) con `kitty_graphics = true` di default (`src/kitty_graphics.rs`), gestisce i comandi APC Kitty dei pane e inoltra verso l'esterno usando `a=t`, `a=p` (`c=`, `r=`, `z=`, `C=1`, `q=2`) e `a=d` (`d=i`/`d=A`).
- **`TIOCGWINSZ`**: su Ghostty diretto può riportare `xpixel`/`ypixel`, mentre dentro `herdr` riporta `(rows, cols, xpixel=0, ypixel=0)`. Di conseguenza:
  - Il posizionamento dell'immagine Kitty deve basarsi esplicitamente sull'area in celle (`c=<disc_cols>,r=<disc_rows>`) anziché dipendere da `xpixel/ypixel > 0`.
  - L'aspect ratio delle celle usa `xpixel/ypixel` se disponibile, altrimenti fallback a `2.1` (o `--aspect F`).

### s1-fallback-dec (Fallback se Kitty graphics non supportato)
- In base alla decisione utente: se `!kitty.isSupported()` (e `--force-kitty` non è specificato), `vinyl` mostra un avviso chiaro nella UI e prosegue con il solo visualizer circolare Braille + metadati senza disco Kitty. Dentro `herdr`, Ghostty, Kitty e WezTerm il supporto è attivo di default.

### s1-transport (Strategia di trasmissione Kitty a 60+ FPS)
- **Doppia modalità**:
  - `direct` (`t=d`, default): chunk base64 da 4096 byte inline dentro il blocco sincronizzato `\x1b[?2026h ... \x1b[?2026l`, compatibilità universale (Ghostty, `herdr`, Kitty, WezTerm).
  - `file` (`t=f`, opzione `--kitty-mode=file`): ring buffer a 4 slot `/tmp/vinyl-kitty-<pid>-<0..3>.rgba` con path in base64 per banda PTY minima (~80 B/frame).
- **Parametri placement**: `a=T,f=32,s=<S>,v=<S>,c=<disc_cols>,r=<disc_rows>,i=1,p=1,z=0,C=1,q=2` con `C=1` (non sposta il cursore), `q=2` (sopprime risposte terminal ACK), `i=1,p=1` (riuso ID/placement).
- **Ottimizzazioni**: risoluzione dinamica `S = clamp(disc_cols * 6, 96, 320)` pari; dirty-skip dell'upload Kitty quando `spin == 0`, `fade == 1.0`, geometria/immagine/sheen invariati e `screen.force == false`; cleanup con `a=d,d=A,q=2` su resize cambio box e su uscita.

## Handoff

- **Next action:** to be defined.
