# vinyl

Frontend da terminale a **60+ FPS** in stile *picture disc* per [`cliamp`](https://github.com/bjarneo/cliamp).

`vinyl` mostra la copertina dell'album ritagliata a disco in vinile rotante (**33⅓ RPM** con inerzia su play/pausa, solchi, riflessi speculari e foro centrale) renderizzata ad alta risoluzione tramite il **protocollo grafico Kitty**, circondata da un margine e da un visualizer circolare stereo continuo (canale sinistro a sinistra, destro a destra) in caratteri Braille pilotato da `cava`.

## Funzionalità principali

- **Picture disc ad alta risoluzione**: rasterizzazione RGBA con anti-aliasing sui bordi, foro centrale trasparente, micro-solchi, riflessi dinamici e dissolvenza incrociata tra le copertine.
- **Rotazione realistica**: velocità a 33⅓ RPM con accelerazione e decelerazione progressiva al cambio di stato play/pausa.
- **Visualizer circolare stereo**: anello continuo in Unicode Braille (`U+2800`–`U+28FF`) con interpolazione Catmull-Rom, peak hold e palette cromatica estratta automaticamente dalla copertina.
- **Gestione automatica di `cliamp`**: si collega a un'istanza di `cliamp` già attiva (TUI o demone) oppure avvia `cliamp --daemon` passando eventuali argomenti extra, arrestandolo in modo pulito (`SIGTERM`) all'uscita.

## Requisiti

- **`zig`** `0.15.1` o superiore (per la compilazione)
- **`cliamp`** `v2.3.0` o superiore (con supporto `--daemon` headless o TUI attiva)
- **`cava`** (usato in modalità `raw` binaria stereo su sorgente PulseAudio/PipeWire)
- **`ffmpeg`** e **`curl`** (decodifica e download delle copertine)
- **Terminale compatibile con Kitty graphics protocol**: ad esempio **Ghostty**, **Kitty**, **WezTerm**, **Konsole** oppure all'interno di **`herdr`** `0.9.5+`.
  - Se il protocollo Kitty non viene rilevato, `vinyl` mostra un avviso in alto (`Kitty graphics non supportato: solo visualizer Braille (--force-kitty)`) ed esegue comunque il visualizer circolare Braille con i metadati e la barra di avanzamento. È possibile forzare o disattivare il rilevamento con `--force-kitty` o `--no-kitty`.

## Compilazione e installazione

```bash
# Compila il binario in modalità ReleaseFast (default) -> zig-out/bin/vinyl
zig build

# Oppure installa direttamente in ~/.local/bin/vinyl
zig build install-local
```

È anche possibile eseguire direttamente senza installare con:

```bash
zig build run -- [opzioni]
```

## Setup del plugin Lua bridge per `cliamp`

Per pubblicare l'URL della copertina e il percorso del brano anche quando `cliamp` viene usato in modalità TUI o con build recenti, è disponibile il plugin [`plugins/vinyl-art-bridge.lua`](plugins/vinyl-art-bridge.lua).

Puoi installarlo e approvarlo in uno dei due modi seguenti:

```bash
vinyl --install-plugin
```

oppure, dal repository:

```bash
./scripts/install-plugin.sh
```

Entrambi i metodi copiano `vinyl-art-bridge.lua` nella directory dei plugin di `cliamp` (`$CLIAMP_CONFIG_DIR/plugins`, `$XDG_CONFIG_HOME/cliamp/plugins` oppure `~/.config/cliamp/plugins`) ed eseguono:

```bash
cliamp plugins trust vinyl-art-bridge
```

### Come vengono risolte le copertine

`vinyl` cerca la copertina in ordine di priorità:

1. **IPC `album_art_url`** fornito direttamente da `cliamp` (es. stream Spotify).
2. **Plugin Lua bridge** tramite `/tmp/cliamp-vinyl-art.txt`.
3. **Derivazione automatica dell'URL** per sorgenti remote prive di `album_art_url`:
   - **Navidrome / Subsonic**: converte `/rest/stream` o `/rest/download` in `/rest/getCoverArt`.
   - **YouTube / YouTube Music**: ricava la miniatura `https://i.ytimg.com/vi/<id>/hqdefault.jpg` dagli URL `youtube.com/watch?v=...` o `youtu.be/...`.
   - **Spotify**: risolve la copertina (640×640) tramite l'endpoint pubblico `open.spotify.com/oembed` a partire da `spotify:track:<id>` o `open.spotify.com/track/<id>`.
4. **File locali**: copertina incorporata nei tag del file audio (decodificata via `ffmpeg`) oppure immagine sidecar nella stessa cartella (`cover.jpg`, `cover.png`, `Cover.jpg`, `Cover.png`, `folder.jpg`, `folder.png`, `Folder.jpg`, `front.jpg`, `front.png`, `Front.jpg`, `album.jpg`, `AlbumArt.jpg`, `cover.webp`, `folder.webp`).
5. **MPRIS `mpris:artUrl`** interrogando `org.mpris.MediaPlayer2.cliamp` via `gdbus`.
6. **Placeholder procedurale**: vinile nero con solchi ed etichetta colorata generata in base al brano.

## Esempi d'uso

```bash
# Avvia cliamp --daemon con una playlist specifica e riproduzione automatica
vinyl --playlist Lofi --auto-play

# Riproduce una cartella locale
vinyl ~/Music/album --auto-play

# Si collega a un cliamp già in esecuzione, altrimenti avvia il demone
# (e lo arresta all'uscita, a meno che non sia impostato --keep-daemon)
vinyl

# Riduce la banda verso il terminale usando 4 file temporanei RGBA in /tmp
vinyl --kitty-mode file
```

## Opzioni CLI

Tutti gli argomenti non riconosciuti da `vinyl` vengono inoltrati direttamente a `cliamp --daemon` (quando il demone viene avviato da `vinyl`).

| Opzione | Descrizione |
| --- | --- |
| `--fps N` | Frame al secondo (`5`–`240`; se omesso, rilevato automaticamente dal refresh rate del monitor con fallback a `60`) |
| `--rpm F` | Velocità manuale iniziale del disco in RPM (`0`–`200`; se omesso, `vinyl` adatta automaticamente gli RPM ai BPM della traccia con fallback a `28` RPM) |
| `--bars N` | Numero di barre per canale per `cava` (intervallo `8`–`128`, default `48`) |
| `--aspect F` | Rapporto altezza/larghezza delle celle (intervallo `1.0`–`4.0`; default rilevamento automatico o `2.1`) |
| `--source NAME` | Sorgente audio PulseAudio/PipeWire per `cava` (default `auto`) |
| `--kitty-mode MODE` | Trasporto fotogrammi Kitty: `file` (default, alta risoluzione fino a 768×768 su ring-buffer `/tmp/vinyl-kitty-<pid>-<slot>.rgba`) o `direct` (base64 su PTY, utile su SSH) |
| `--force-kitty` | Forza il rendering del disco Kitty anche se il terminale non viene rilevato |
| `--no-kitty` | Disattiva il disco Kitty (mostra solo il visualizer Braille e i metadati) |
| `--bass-top` | Posiziona le frequenze basse nella parte superiore dell'anello invece che in basso |
| `--no-sheen` | Disattiva i riflessi speculari sul vinile |
| `--keep-daemon` | Non arresta il demone `cliamp` avviato da `vinyl` all'uscita |
| `--daemon` | Avvia `cliamp --daemon` anche senza argomenti cliamp (di default senza argomenti `vinyl` attende `cliamp` senza occupare il socket) |
| `--no-daemon` | Non avvia mai `cliamp --daemon`, attende solo il socket IPC esistente |
| `--install-plugin` | Installa `vinyl-art-bridge.lua` nella cartella plugin di `cliamp` ed esegue `cliamp plugins trust vinyl-art-bridge` |
| `-h`, `--help` | Mostra il messaggio di aiuto ed esce |

## Scorciatoie da tastiera

| Tasto | Azione |
| --- | --- |
| `Spazio` | Play / Pausa |
| `n` / `p` | Traccia successiva / precedente |
| `←` / `→` | Seek indietro / avanti di 5 secondi |
| `↑` / `↓` oppure `+` (`=`) / `-` | Regola il volume di ±1 dB |
| `s` / `r` | Attiva/disattiva `shuffle` / cambia modalità `repeat` |
| `[` / `]` | Diminuisce / aumenta la velocità di rotazione del disco di ±5 RPM (`0`–`200`) |
| `{` / `}` | Regolazione fine della velocità di rotazione di ±1 RPM |
| `v` | Cicla i preset vinile (`28`, `33.3`, `45`, `78`, `0`, `16.7` RPM) in modalità manuale |
| `0` | Ripristina la modalità automatica legata ai BPM della traccia (o `28` RPM se i BPM non sono disponibili) |
| `w` | Cicla la modalità visualizer: `path (1:1)` *(default, solo riempimento picchi 1:1 sfumato `rebeccapurple`/`teal`/`yellow` senza bande base)*, `ellipsis` (soli bordi colorati delle 3 curve ellittiche/picchi 1:1 senza riempimento né bande) e `peak` (bande smorzate + trattini con decay) |
| `g` | Attiva/disattiva il bagliore sidechain sui colpi di cassa (100–300 Hz) attorno al disco |
| `a` | Attiva/disattiva l'aurora scura temporalesca ai lati dello schermo sui sub-bassi (20–80 Hz) |
| `c` | Alterna i colori di bagliore cassa e aurora tra quelli derivati dalla copertina/scurimento (`cover`) e quelli coerenti con la frequenza predominante (`rebeccapurple` per aurora, tra `rebeccapurple` e `teal` per cassa) |
| `d` | Cicla la risoluzione massima del disco Kitty: `512px` *(default)* → `768px` (ultra) → `384px` (veloce) |
| `x` | Attiva/disattiva l'antialiasing del disco (bordo circolare + filtro bilineare vs nearest-neighbor) |
| `m` | Cicla la barra info/seekbar: `auto` *(default: fadeout dopo 5s, fade-in/out lento solo 2 righe al cambio brano per 10s, barra completa immediata in pausa)* → `show` → `hide` |
| `l` | Attiva/disattiva i riflessi del vinile |
| `b` | Alterna lo sfondo tra tinta derivata dalla copertina e nero |
| `i` | Inverte l'orientamento delle frequenze (bassi in alto / in basso) |
| `f` | Mostra/nasconde il contatore FPS e RPM |
| `?` / `h` | Mostra/nasconde la legenda delle scorciatoie |
| `q` / `Q` / `Ctrl+C` | Esci da `vinyl` |
