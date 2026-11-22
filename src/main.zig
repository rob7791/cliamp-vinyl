//! vinyl — a 60+ FPS terminal "picture disc" front-end for cliamp.
const std = @import("std");
const term = @import("term.zig");
const Screen = @import("screen.zig").Screen;
const Cava = @import("cava.zig").Cava;
const cliamp = @import("cliamp.zig");
const art = @import("art.zig");
const render = @import("render.zig");
const kitty = @import("kitty.zig");

const usage =
    \\vinyl — picture-disc player front-end for cliamp
    \\
    \\Uso: vinyl [opzioni] [argomenti cliamp...]
    \\
    \\Senza argomenti cliamp, vinyl si collega al socket IPC di un'istanza `cliamp`
    \\già in esecuzione (o resta in attesa finché non avvii `cliamp`), evitando di
    \\occupare il socket con un demone vuoto.
    \\Se passi argomenti per cliamp (es. `vinyl --playlist Lofi --auto-play`,
    \\`vinyl ~/Music/album --auto-play`) oppure `--daemon`, e cliamp non è già attivo,
    \\vinyl avvia `cliamp --daemon` e lo ferma all'uscita.
    \\
    \\Opzioni:
    \\  --fps N             frame al secondo (default: auto da monitor o 60, max 240)
    \\  --rpm F             velocità manuale disco in RPM (default: auto da BPM o 5)
    \\  --bars N            barre per canale (default 48)
    \\  --aspect F          rapporto altezza/larghezza cella (default: auto, o 2.1)
    \\  --source NAME       sorgente PulseAudio/PipeWire per cava (default auto)
    \\  --kitty-mode MODE   trasporto Kitty: file (default, alta ris.) o direct (SSH)
    \\  --force-kitty       forza il protocollo Kitty anche se non rilevato
    \\  --no-kitty          disattiva il disco Kitty (solo visualizer Braille)
    \\  --bass-top          bassi in alto invece che in basso
    \\  --no-sheen          disattiva i riflessi del vinile
    \\  --keep-daemon       non fermare il demone lanciato da vinyl all'uscita
    \\  --daemon            avvia `cliamp --daemon` anche senza argomenti cliamp
    \\  --no-daemon         non lanciare mai cliamp, attendi solo il socket
    \\  --install-plugin    installa e approva il plugin Lua bridge per cliamp
    \\  -h, --help          questo aiuto
    \\
;

const bridge_lua = @embedFile("vinyl-art-bridge.lua");

const Opts = struct {
    fps: ?u32 = null,
    rpm: ?f32 = null,
    bars: usize = 48,
    aspect: ?f32 = null,
    source: ?[]const u8 = null,
    kitty_mode: kitty.Mode = .file,
    force_kitty: bool = false,
    no_kitty: bool = false,
    bass_top: bool = false,
    sheen: bool = true,
    keep_daemon: bool = false,
    force_daemon: bool = false,
    no_daemon: bool = false,
    passthrough: std.ArrayList([]const u8) = .empty,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var opts = Opts{};
    defer opts.passthrough.deinit(gpa);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const eq = std.mem.eql;
        if (eq(u8, a, "-h") or eq(u8, a, "--help")) {
            std.fs.File.stdout().writeAll(usage) catch {};
            return;
        } else if (eq(u8, a, "--install-plugin")) {
            try installPlugin(gpa);
            return;
        } else if (eq(u8, a, "--fps") and i + 1 < argv.len) {
            i += 1;
            opts.fps = std.math.clamp(try std.fmt.parseInt(u32, argv[i], 10), 5, 240);
        } else if (eq(u8, a, "--rpm") and i + 1 < argv.len) {
            i += 1;
            opts.rpm = std.math.clamp(try std.fmt.parseFloat(f32, argv[i]), 0.0, 200.0);
        } else if (eq(u8, a, "--bars") and i + 1 < argv.len) {
            i += 1;
            opts.bars = std.math.clamp(try std.fmt.parseInt(usize, argv[i], 10), 8, 128);
        } else if (eq(u8, a, "--aspect") and i + 1 < argv.len) {
            i += 1;
            opts.aspect = std.math.clamp(try std.fmt.parseFloat(f32, argv[i]), 1.0, 4.0);
        } else if (eq(u8, a, "--source") and i + 1 < argv.len) {
            i += 1;
            opts.source = argv[i];
        } else if (eq(u8, a, "--kitty-mode") and i + 1 < argv.len) {
            i += 1;
            if (eq(u8, argv[i], "file")) {
                opts.kitty_mode = .file;
            } else if (eq(u8, argv[i], "direct")) {
                opts.kitty_mode = .direct;
            } else {
                std.debug.print("modalità Kitty non valida: {s} (usa direct o file)\n", .{argv[i]});
                return;
            }
        } else if (eq(u8, a, "--force-kitty")) {
            opts.force_kitty = true;
        } else if (eq(u8, a, "--no-kitty")) {
            opts.no_kitty = true;
        } else if (eq(u8, a, "--bass-top")) {
            opts.bass_top = true;
        } else if (eq(u8, a, "--no-sheen")) {
            opts.sheen = false;
        } else if (eq(u8, a, "--keep-daemon")) {
            opts.keep_daemon = true;
        } else if (eq(u8, a, "--daemon")) {
            opts.force_daemon = true;
        } else if (eq(u8, a, "--no-daemon")) {
            opts.no_daemon = true;
        } else {
            try opts.passthrough.append(gpa, a);
        }
    }

    // --- cliamp daemon -------------------------------------------------------
    // Only auto-spawn `cliamp --daemon` when passthrough args or `--daemon` were given;
    // otherwise wait for an existing/upcoming `cliamp` TUI without stealing cliamp.sock.
    var daemon: ?std.process.Child = null;
    const want_daemon = !opts.no_daemon and (opts.force_daemon or opts.passthrough.items.len > 0);
    if (want_daemon and !cliamp.isAlive()) {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "cliamp", "--daemon" });
        try args.appendSlice(gpa, opts.passthrough.items);
        var child = std.process.Child.init(args.items, gpa);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.pgid = 0; // own process group: terminal signals don't hit it directly
        child.spawn() catch |err| {
            std.debug.print("impossibile avviare cliamp: {s}\n", .{@errorName(err)});
            return;
        };
        daemon = child;
        var waited: usize = 0;
        while (!cliamp.isAlive() and waited < 50) : (waited += 1) std.Thread.sleep(100 * std.time.ns_per_ms);
    } else if (opts.passthrough.items.len > 0 and cliamp.isAlive()) {
        std.debug.print("cliamp è già in esecuzione: argomenti ignorati: ", .{});
        for (opts.passthrough.items) |a| std.debug.print("{s} ", .{a});
        std.debug.print("\n", .{});
        std.Thread.sleep(1200 * std.time.ns_per_ms);
    }
    defer if (daemon) |*d| {
        if (!opts.keep_daemon) {
            // SIGTERM lets cliamp save its resume position
            std.posix.kill(d.id, std.posix.SIG.TERM) catch {};
            _ = d.wait() catch {};
        }
    };

    // --- workers -------------------------------------------------------------
    var client = cliamp.Client{ .alloc = gpa };
    try client.start();
    defer client.stop();

    var loader = art.Loader{ .alloc = gpa, .client = &client };
    try loader.start();
    defer loader.stop();

    const target_fps: u32 = opts.fps orelse term.detectRefreshRate(gpa);

    var cava = Cava.start(gpa, opts.bars, target_fps, opts.source);
    defer cava.stop();

    var renderer = render.Renderer{ .alloc = gpa };
    defer renderer.deinit();
    renderer.setImage(try art.placeholder(gpa, 220));

    var screen = Screen.init(gpa);
    defer screen.deinit();

    const kitty_supported = kitty.isSupported();
    const use_kitty = !opts.no_kitty and (kitty_supported or opts.force_kitty);
    const kitty_warn = !opts.no_kitty and !kitty_supported and !opts.force_kitty;

    var kitty_enc = kitty.Encoder{ .alloc = gpa, .mode = opts.kitty_mode };
    defer kitty_enc.deinit();
    var kitty_out: std.ArrayList(u8) = .empty;
    defer kitty_out.deinit(gpa);

    try term.enter();
    defer term.leave();

    // --- main loop -----------------------------------------------------------
    const frame_ns: i128 = @divTrunc(std.time.ns_per_s, target_fps);
    var next_frame = std.time.nanoTimestamp();
    var last = next_frame;
    const default_rpm: f32 = 5.0;
    var angle: f32 = 0;
    var spin: f32 = 0; // rad/s
    var rpm_manual: bool = opts.rpm != null;
    var rpm: f32 = opts.rpm orelse default_rpm;
    var rpm_hud_timer: f32 = 0;
    var peak_mode: render.PeakMode = .path;
    var viz_motion: render.VizMotion = .raw;
    var viz_color: render.VizColor = .freq;
    var glow = true;
    var aurora = true;
    var star_level: u8 = 3;
    var wave_level: u8 = 4;
    var ring_mode: render.RingMode = .off;
    var glow_gain: f32 = 1.0;
    var aurora_gain: f32 = 1.0;
    var fx_color: render.FxColorMode = .cover;
    var disc_res: render.DiscRes = .high;
    var disc_style: render.DiscStyle = .cover;
    var aa = true;
    var info_mode: render.InfoMode = .auto;
    const AutoInfoPhase = enum { hidden, full_hold, full_fadeout, track_fadein, track_hold, track_fadeout };
    var info_phase: AutoInfoPhase = .full_hold;
    var info_timer: f32 = 0;
    var prev_play_state: cliamp.PlayState = .unknown;
    var last_track_key: u64 = 0;
    var hud_buf: [64]u8 = undefined;
    var hud_msg: []const u8 = "";
    var hud_timer: f32 = 0;
    const rpm_presets = [_]f32{ 5.0, 16.666, 28.0, 33.333, 45.0, 78.0, 0.0 };
    var sheen = opts.sheen;
    var bass_top = opts.bass_top;
    var show_fps = false;
    var show_help = false;
    var bg_mode: render.BgMode = .tint;
    var fps_acc: f32 = 0;
    var fps_frames: u32 = 0;
    var fps_val: f32 = 0;
    var left = [_]f32{0} ** 128;
    var right = [_]f32{0} ** 128;

    while (!term.quit_requested.load(.acquire)) {
        const now = std.time.nanoTimestamp();
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now - last)) / std.time.ns_per_s);
        last = now;

        // input
        var ibuf: [64]u8 = undefined;
        const n = term.readInput(&ibuf);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const ch = ibuf[k];
            if (ch == 0x1b and k + 2 < n and ibuf[k + 1] == '[') {
                switch (ibuf[k + 2]) {
                    'A' => client.op("volume.adjust", "{\"value\":1}"),
                    'B' => client.op("volume.adjust", "{\"value\":-1}"),
                    'C' => client.op("seek", "{\"value\":5}"),
                    'D' => client.op("seek", "{\"value\":-5}"),
                    else => {},
                }
                k += 2;
                continue;
            }
            switch (ch) {
                'q', 'Q', 3 => term.quit_requested.store(true, .release),
                ' ' => client.op("toggle", "{}"),
                'n' => client.op("next", "{}"),
                'p' => client.op("prev", "{}"),
                's' => client.op("shuffle", "{\"name\":\"toggle\"}"),
                'r' => client.op("repeat", "{\"name\":\"cycle\"}"),
                '+', '=' => client.op("volume.adjust", "{\"value\":1}"),
                '-' => client.op("volume.adjust", "{\"value\":-1}"),
                'l' => sheen = !sheen,
                'i' => bass_top = !bass_top,
                'f' => show_fps = !show_fps,
                'b' => bg_mode = if (bg_mode == .tint) .black else .tint,
                '[' => {
                    rpm_manual = true;
                    rpm = if (rpm <= 10.0) @max(0.0, rpm - 1.0) else @max(10.0, rpm - 5.0);
                    rpm_hud_timer = 2.0;
                },
                ']' => {
                    rpm_manual = true;
                    rpm = if (rpm < 10.0) @min(10.0, rpm + 1.0) else @min(200.0, rpm + 5.0);
                    rpm_hud_timer = 2.0;
                },
                '{' => {
                    rpm_manual = true;
                    rpm = @max(0.0, rpm - 1.0);
                    rpm_hud_timer = 2.0;
                },
                '}' => {
                    rpm_manual = true;
                    rpm = @min(200.0, rpm + 1.0);
                    rpm_hud_timer = 2.0;
                },
                'v' => {
                    rpm_manual = true;
                    var next_idx: usize = 0;
                    for (rpm_presets, 0..) |preset, idx| {
                        if (@abs(rpm - preset) < 0.5) {
                            next_idx = (idx + 1) % rpm_presets.len;
                            break;
                        }
                    }
                    rpm = rpm_presets[next_idx];
                    rpm_hud_timer = 2.0;
                },
                '0' => {
                    rpm_manual = false;
                    hud_msg = " rpm: auto (BPM) ";
                    hud_timer = 2.0;
                },
                'w' => {
                    peak_mode = switch (peak_mode) {
                        .path => .ellipsis,
                        .ellipsis => .ellipsis2,
                        .ellipsis2 => .peak,
                        .peak => .path,
                    };
                    hud_msg = switch (peak_mode) {
                        .path => " viz: path ",
                        .ellipsis => " viz: ellipsis ",
                        .ellipsis2 => " viz: ellipsis2 ",
                        .peak => " viz: peak ",
                    };
                    hud_timer = 2.0;
                },
                't' => {
                    viz_motion = if (viz_motion == .raw) .smooth else .raw;
                    hud_msg = if (viz_motion == .raw) " motion: 1:1 " else " motion: smooth ";
                    hud_timer = 2.0;
                },
                'k' => {
                    viz_color = if (viz_color == .freq) .cover else .freq;
                    hud_msg = if (viz_color == .freq) " viz col: freq " else " viz col: cover ";
                    hud_timer = 2.0;
                },
                'g' => {
                    glow = !glow;
                    hud_msg = if (glow) " glow on " else " glow off ";
                    hud_timer = 2.0;
                },
                'a' => {
                    aurora = !aurora;
                    hud_msg = if (aurora) " aurora on " else " aurora off ";
                    hud_timer = 2.0;
                },
                '5' => {
                    if (star_level > 0) star_level -= 1;
                    hud_msg = if (star_level == 0)
                        " stars: 0 (off) "
                    else
                        std.fmt.bufPrint(&hud_buf, " stars: {d} ", .{star_level}) catch " stars ";
                    hud_timer = 2.0;
                },
                '6' => {
                    if (star_level < 10) star_level += 1;
                    hud_msg = std.fmt.bufPrint(&hud_buf, " stars: {d} ", .{star_level}) catch " stars ";
                    hud_timer = 2.0;
                },
                '7' => {
                    if (wave_level > 0) wave_level -= 1;
                    hud_msg = if (wave_level == 0)
                        " waves: 0 (off) "
                    else
                        std.fmt.bufPrint(&hud_buf, " waves: {d} ", .{wave_level}) catch " waves ";
                    hud_timer = 2.0;
                },
                '8' => {
                    if (wave_level < 10) wave_level += 1;
                    hud_msg = std.fmt.bufPrint(&hud_buf, " waves: {d} ", .{wave_level}) catch " waves ";
                    hud_timer = 2.0;
                },
                '9' => {
                    ring_mode = switch (ring_mode) {
                        .off => .kick,
                        .kick => .mid,
                        .mid => .off,
                    };
                    hud_msg = switch (ring_mode) {
                        .off => " rings: off ",
                        .kick => " rings: kick ",
                        .mid => " rings: vocal ",
                    };
                    hud_timer = 2.0;
                },
                '1' => {
                    glow_gain = @max(0.2, glow_gain - 0.2);
                    hud_msg = std.fmt.bufPrint(&hud_buf, " glow: {d:.0}% ", .{glow_gain * 100.0}) catch " glow ";
                    hud_timer = 2.0;
                },
                '2' => {
                    glow_gain = @min(3.0, glow_gain + 0.2);
                    hud_msg = std.fmt.bufPrint(&hud_buf, " glow: {d:.0}% ", .{glow_gain * 100.0}) catch " glow ";
                    hud_timer = 2.0;
                },
                '3' => {
                    aurora_gain = @max(0.2, aurora_gain - 0.2);
                    hud_msg = std.fmt.bufPrint(&hud_buf, " aurora: {d:.0}% ", .{aurora_gain * 100.0}) catch " aurora ";
                    hud_timer = 2.0;
                },
                '4' => {
                    aurora_gain = @min(3.0, aurora_gain + 0.2);
                    hud_msg = std.fmt.bufPrint(&hud_buf, " aurora: {d:.0}% ", .{aurora_gain * 100.0}) catch " aurora ";
                    hud_timer = 2.0;
                },
                'c' => {
                    fx_color = if (fx_color == .cover) .spectrum else .cover;
                    hud_msg = if (fx_color == .spectrum) " fx: freq " else " fx: cover ";
                    hud_timer = 2.0;
                },
                'd' => {
                    disc_res = switch (disc_res) {
                        .high => .ultra,
                        .ultra => .med,
                        .med => .high,
                    };
                    hud_msg = disc_res.label();
                    hud_timer = 2.0;
                },
                'x' => {
                    aa = !aa;
                    hud_msg = if (aa) " AA on " else " AA off ";
                    hud_timer = 2.0;
                },
                'o' => {
                    disc_style = switch (disc_style) {
                        .cover => .vinyl,
                        .vinyl => .vinyl_art,
                        .vinyl_art => .cd,
                        .cd => .cover,
                    };
                    hud_msg = disc_style.label();
                    hud_timer = 2.0;
                },
                'm' => {
                    info_mode = switch (info_mode) {
                        .auto => .show,
                        .show => .hide,
                        .hide => .auto,
                    };
                    if (info_mode == .auto) {
                        info_phase = .full_hold;
                        info_timer = 0;
                    }
                    hud_msg = switch (info_mode) {
                        .auto => " info: auto ",
                        .show => " info: show ",
                        .hide => " info: hide ",
                    };
                    hud_timer = 2.0;
                },
                '?', 'h' => show_help = !show_help,
                else => {},
            }
        }

        // size
        const sz = term.getSize();
        try screen.resize(sz.cols, sz.rows);
        const cell_px_w: f32 = if (sz.xpix > 0 and sz.cols > 0)
            @as(f32, @floatFromInt(sz.xpix)) / @as(f32, @floatFromInt(sz.cols))
        else
            0;
        const aspect: f32 = opts.aspect orelse blk: {
            if (sz.xpix > 0 and sz.ypix > 0) {
                const cw = @as(f32, @floatFromInt(sz.xpix)) / @as(f32, @floatFromInt(sz.cols));
                const ch = @as(f32, @floatFromInt(sz.ypix)) / @as(f32, @floatFromInt(sz.rows));
                break :blk std.math.clamp(ch / cw, 1.2, 3.5);
            }
            break :blk 2.1;
        };

        // data
        if (loader.take()) |img| renderer.setImage(img);
        _ = cava.poll();
        const nb = cava.per_channel;
        for (0..nb) |b| {
            const tl = cava.left[b];
            const tr = cava.right[b];
            left[b] += (tl - left[b]) * (if (tl > left[b]) @min(1.0, dt * 20.0) else @min(1.0, dt * 7.5));
            right[b] += (tr - right[b]) * (if (tr > right[b]) @min(1.0, dt * 20.0) else @min(1.0, dt * 7.5));
        }
        const snap = client.get();
        var pos = snap.position;
        if (snap.state == .playing and snap.stamp_ns > 0)
            pos += @as(f64, @floatFromInt(now - snap.stamp_ns)) / std.time.ns_per_s;
        if (snap.duration > 0) pos = @min(pos, snap.duration);

        // turntable inertia (auto BPM -> RPM when not manually overridden, smooth transition on track change)
        if (rpm_hud_timer > 0) rpm_hud_timer = @max(0.0, rpm_hud_timer - dt);
        if (hud_timer > 0) hud_timer = @max(0.0, hud_timer - dt);
        const track_bpm = loader.getBpm();
        if (!rpm_manual) {
            rpm = if (track_bpm > 0) std.math.clamp(track_bpm * (default_rpm / 120.0), 1.5, 25.0) else default_rpm;
        }
        const rpm_speed: f32 = rpm / 60.0 * std.math.tau;
        const target: f32 = if (snap.state == .playing) rpm_speed else 0;
        spin += (target - spin) * @min(1.0, dt * 2.5);
        angle = @mod(angle + spin * dt, std.math.tau);

        // info bar visibility / fade state machine
        const cur_track_key: u64 = if (snap.connected and (snap.path.len > 0 or snap.title.len > 0)) blk: {
            var h = std.hash.Wyhash.init(0);
            h.update(snap.path.get());
            h.update("\x00");
            h.update(snap.title.get());
            break :blk h.final();
        } else 0;
        const track_changed = cur_track_key != 0 and last_track_key != 0 and cur_track_key != last_track_key;
        if (cur_track_key != 0) last_track_key = cur_track_key;

        var info_alpha: f32 = 1.0;
        var info_seekbar: bool = true;
        if (snap.state == .paused or !snap.connected) {
            // Pause always shows the full bar immediately with zero fade in every mode
            info_alpha = 1.0;
            info_seekbar = true;
        } else {
            if (prev_play_state == .paused and info_mode == .auto) {
                info_phase = .full_hold;
                info_timer = 0;
            }
            if (track_changed and info_mode == .auto) {
                info_phase = .track_fadein;
                info_timer = 0;
            }
            switch (info_mode) {
                .show => {
                    info_alpha = 1.0;
                    info_seekbar = true;
                },
                .hide => {
                    info_alpha = 0.0;
                    info_seekbar = false;
                },
                .auto => {
                    info_timer += dt;
                    switch (info_phase) {
                        .full_hold => {
                            info_alpha = 1.0;
                            info_seekbar = true;
                            if (info_timer >= 5.0) {
                                info_phase = .full_fadeout;
                                info_timer = 0;
                            }
                        },
                        .full_fadeout => {
                            const t = std.math.clamp(info_timer / 1.2, 0.0, 1.0);
                            info_alpha = 1.0 - t * t * (3.0 - 2.0 * t);
                            info_seekbar = true;
                            if (info_timer >= 1.2) {
                                info_phase = .hidden;
                                info_timer = 0;
                            }
                        },
                        .track_fadein => {
                            const t = std.math.clamp(info_timer / 2.4, 0.0, 1.0);
                            info_alpha = t * t * (3.0 - 2.0 * t);
                            info_seekbar = false;
                            if (info_timer >= 2.4) {
                                info_phase = .track_hold;
                                info_timer = 0;
                            }
                        },
                        .track_hold => {
                            info_alpha = 1.0;
                            info_seekbar = false;
                            if (info_timer >= 10.0) {
                                info_phase = .track_fadeout;
                                info_timer = 0;
                            }
                        },
                        .track_fadeout => {
                            const t = std.math.clamp(info_timer / 2.4, 0.0, 1.0);
                            info_alpha = 1.0 - t * t * (3.0 - 2.0 * t);
                            info_seekbar = false;
                            if (info_timer >= 2.4) {
                                info_phase = .hidden;
                                info_timer = 0;
                            }
                        },
                        .hidden => {
                            info_alpha = 0.0;
                            info_seekbar = false;
                        },
                    }
                },
            }
        }
        prev_play_state = snap.state;

        kitty_out.clearRetainingCapacity();
        const force_redraw = screen.force;
        renderer.render(&screen, .{
            .aspect = aspect,
            .angle = angle,
            .dt = dt,
            .left = left[0..nb],
            .right = right[0..nb],
            .raw_left = cava.left[0..nb],
            .raw_right = cava.right[0..nb],
            .snap = &snap,
            .position = pos,
            .sheen = sheen,
            .bass_top = bass_top,
            .show_fps = show_fps,
            .show_help = show_help,
            .fps = fps_val,
            .rpm = rpm,
            .bpm = track_bpm,
            .show_rpm = rpm_hud_timer > 0,
            .peak_mode = peak_mode,
            .viz_motion = viz_motion,
            .viz_color = viz_color,
            .glow = glow,
            .aurora = aurora,
            .star_level = star_level,
            .wave_level = wave_level,
            .ring_mode = ring_mode,
            .glow_gain = glow_gain,
            .aurora_gain = aurora_gain,
            .fx_color = fx_color,
            .hud_msg = if (hud_timer > 0) hud_msg else "",
            .bg_mode = bg_mode,
            .cava_ok = cava.ok,
            .kitty_enc = if (use_kitty) &kitty_enc else null,
            .kitty_out = &kitty_out,
            .kitty_warn = kitty_warn,
            .force_redraw = force_redraw,
            .cell_px_w = cell_px_w,
            .disc_res = disc_res,
            .disc_style = disc_style,
            .aa = aa,
            .info_alpha = info_alpha,
            .info_seekbar = info_seekbar,
        });
        term.writeAll(try screen.flush(kitty_out.items));

        // fps meter
        fps_acc += dt;
        fps_frames += 1;
        if (fps_acc >= 0.5) {
            fps_val = @as(f32, @floatFromInt(fps_frames)) / fps_acc;
            fps_acc = 0;
            fps_frames = 0;
        }

        // pacing
        next_frame += frame_ns;
        const after = std.time.nanoTimestamp();
        if (next_frame > after) {
            std.Thread.sleep(@intCast(next_frame - after));
        } else if (after - next_frame > frame_ns * 4) {
            next_frame = after; // fell behind: don't try to catch up
        }
    }
}

fn installPlugin(alloc: std.mem.Allocator) !void {
    var dbuf: [480]u8 = undefined;
    const cfg_dir = try cliamp.configDir(&dbuf);

    var pdir_buf: [512]u8 = undefined;
    const plugins_dir = try std.fmt.bufPrint(&pdir_buf, "{s}/plugins", .{cfg_dir});
    try std.fs.cwd().makePath(plugins_dir);

    var dest_buf: [544]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}/vinyl-art-bridge.lua", .{plugins_dir});
    {
        const f = try std.fs.cwd().createFile(dest, .{ .truncate = true });
        defer f.close();
        try f.writeAll(bridge_lua);
    }

    var msg_buf: [640]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Plugin installato in: {s}\n", .{dest});
    std.fs.File.stdout().writeAll(msg) catch {};

    var child = std.process.Child.init(&.{ "cliamp", "plugins", "trust", "vinyl-art-bridge" }, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term_res = child.spawnAndWait() catch |err| {
        std.debug.print("Avvio di `cliamp plugins trust` fallito ({s}). Esegui manualmente:\n  cliamp plugins trust vinyl-art-bridge\n", .{@errorName(err)});
        return;
    };
    if (term_res != .Exited or term_res.Exited != 0) {
        std.debug.print("Approva manualmente il plugin con:\n  cliamp plugins trust vinyl-art-bridge\n", .{});
    }
}
