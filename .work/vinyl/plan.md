# Plan — Vinyl CLI Player (60+ FPS Picture Disc)

## Strategy

Costruire `vinyl`, un frontend CLI in Zig (60+ FPS) per `cliamp` che visualizza la cover art del brano corrente come un disco vinile "picture disc" rotante (33⅓ giri, con inerzia in pausa/ripartenza e buco centrale) renderizzato ad alta risoluzione tramite **Kitty graphics protocol**, circondato da un margine e da un **visualizer audio stereo circolare** (onda/spettro continuo L/R) in **testo/Braille** alimentato da `cava`.

Si parte dal prototipo funzionante già presente in `src/` (che implementa IPC v2 verso `cliamp`, pipe `cava` raw stereo 16-bit, caricamento cover art asincrono con `ffmpeg`/`curl`, e loop di rendering 60+ FPS con diff-buffer e synchronized update `?2026h`/`?2026l`), sostituendo il rendering half-block del disco con il rendering pixel-perfect via Kitty graphics protocol e completando il bridge Lua per le cover art dei provider remoti.

## Goals

- **Framerate 60+ FPS** (configurabile con `--fps`, limitato solo da ciò che l'emulatore terminale supporta) con frame pacing preciso e synchronized output (`\x1b[?2026h` / `\x1b[?2026l`).
- **Disco vinile picture-disc ad alta risoluzione**: cover art ritagliata a cerchio con buco centrale, rotazione continua a 33⅓ RPM con inerzia su play/pausa, anti-aliasing, riflessi statici opzionali e crossfade tra cover, trasmessa via **Kitty graphics protocol**.
- **Visualizer stereo circolare in testo/Braille**: onda/spettro continuo dei 2 canali (L metà sinistra, R metà destra) attorno al disco con un margine netto di separazione, alimentato da `cava` in modalità `raw` stereo 16-bit.
- **Integrazione `cliamp` headless**: se `cliamp` non è attivo sul socket, `vinyl` lancia `cliamp --daemon` passando gli argomenti extra e lo chiude pulitamente (`SIGTERM`) all'uscita salvo `--keep-daemon`; se è già attivo, vi si collega.
- **Controlli playback essenziali e metadati**: titolo, artista, album, progress bar, volume, shuffle/repeat, scorciatoie da tastiera (spazio, `n`/`p`, frecce seek/volume, `s`/`r`, toggle visivi, `q`).
- **Cover art da tutte le sorgenti di `cliamp`**: file locali (tag embedded, file cover/folder nella cartella), MPRIS fallback e provider remoti (Navidrome, Spotify, YouTube Music) tramite un piccolo plugin Lua bridge per `cliamp` con comando/script di installazione.
- **Installazione locale**: binario compilabile con `zig build` e opzione di installazione in `~/.local/bin/vinyl`.

## Constraints

- **Linguaggio e toolchain**: Zig 0.15.1 (`build.zig`, `build.zig.zon`), zero dipendenze esterne Zig; strumenti di sistema già presenti: `cliamp` (v2.3.0), `cava` (0.10.2), `ffmpeg`, `curl`, `gdbus`.
- **Base di partenza**: raffinare/completare il prototipo già scritto in `build.zig` e `src/{main,term,screen,cava,cliamp,art,render}.zig`.
- **Rendering ibrido vincolato**: il disco deve usare **solo** Kitty graphics protocol (niente fallback half-block per il disco); il visualizer circolare attorno al disco deve essere in **testo/Braille** truecolor.
- **Ambiente target**: terminali con Kitty graphics protocol (Ghostty, eventualmente dentro multiplexer `herdr`).
- **Scope UI**: controlli playback essenziali + metadati (non un browser di playlist/libreria completo).

## Assumptions

- `cliamp` ascolta su `~/.config/cliamp/cliamp.sock` (o `$CLIAMP_CONFIG_DIR/cliamp.sock`) con protocollo IPC v2 NDJSON; `state.get` non include sempre `album_art_url`, quindi il plugin Lua bridge (che usa `track.change` / `playback.state` e `cliamp.track.album_art_url()`) è il canale affidabile per i provider remoti (Navidrome, Spotify, YT Music).
- `cava` gira su PipeWire/PulseAudio (`method = pulse`, `source = auto`) con output `raw`, `channels = stereo`, `data_format = binary`, `bit_format = 16bit`; il layout dei bar stereo è `[L high..low][R low..high]`.
- `TIOCGWINSZ` restituisce sia `(cols, rows)` sia `(xpixel, ypixel)` su Ghostty (da verificare anche sotto `herdr`) per dimensionare il framebuffer RGBA del disco in pixel esatti e allinearlo alla griglia delle celle Braille.

## Existing Prototype

File già presenti nel repository al momento del brief:
- `build.zig`, `build.zig.zon`: build Zig 0.15.1 con `ReleaseFast` di default, output `zig-out/bin/vinyl`.
- `src/main.zig`: CLI parsing, gestione lifecycle `cliamp --daemon`, loop 60+ FPS, input tastiera, inerzia giradischi.
- `src/term.zig`: raw mode, alt screen, `TIOCGWINSZ`, gestione segnali.
- `src/screen.zig`: cell buffer truecolor con diff-based ANSI emitter e synchronized updates (`?2026h`/`?2026l`).
- `src/cava.zig`: spawn `cava` in modalità binary stereo 16-bit non-blocking e decodifica ultimo frame.
- `src/cliamp.zig`: client Unix socket IPC v2 (polling `state.get` e invio `operation.submit` su thread dedicato).
- `src/art.zig`: worker thread per caricamento/decodifica cover 512x512 via `ffmpeg`/`curl`, lettura bridge `/tmp/cliamp-vinyl-art.txt`, estrazione palette colori, vinile placeholder.
- `src/render.zig`: attualmente renderizza il disco con half-block (`▀`) — da sostituire con Kitty graphics protocol — e il visualizer circolare stereo con Braille (`0x2800..0x28FF`) + barra metadati/progress.
