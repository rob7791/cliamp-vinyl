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
    \\Se cliamp non è già in esecuzione, vinyl avvia `cliamp --daemon` passando
    \\gli argomenti non riconosciuti (es. `vinyl --playlist Lofi --auto-play`,
    \\`vinyl ~/Music/album --auto-play`) e lo ferma all'uscita.
    \\Se cliamp è già in esecuzione (TUI o demone) vinyl si collega a quello.
    \\
    \\Opzioni:
    \\  --fps N             frame al secondo (default 60, max 240)
    \\  --rpm F             velocità di rotazione disco in RPM (default 33.333, 0..200)
    \\  --bars N            barre per canale (default 48)
    \\  --aspect F          rapporto altezza/larghezza cella (default: auto, o 2.1)
    \\  --source NAME       sorgente PulseAudio/PipeWire per cava (default auto)
    \\  --kitty-mode MODE   trasporto Kitty: direct (default) o file
    \\  --force-kitty       forza il protocollo Kitty anche se non rilevato
    \\  --no-kitty          disattiva il disco Kitty (solo visualizer Braille)
    \\  --bass-top          bassi in alto invece che in basso
    \\  --no-sheen          disattiva i riflessi del vinile
    \\  --keep-daemon       non fermare il demone lanciato da vinyl all'uscita
    \\  --no-daemon         non lanciare mai cliamp, attendi solo il socket
    \\  --install-plugin    installa e approva il plugin Lua bridge per cliamp
    \\  -h, --help          questo aiuto
    \\
;

const bridge_lua = @embedFile("vinyl-art-bridge.lua");

const Opts = struct {
    fps: u32 = 60,
    rpm: f32 = 33.333,
    bars: usize = 48,
    aspect: ?f32 = null,
    source: ?[]const u8 = null,
    kitty_mode: kitty.Mode = .direct,
    force_kitty: bool = false,
    no_kitty: bool = false,
    bass_top: bool = false,
    sheen: bool = true,
    keep_daemon: bool = false,
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
        } else if (eq(u8, a, "--no-daemon")) {
            opts.no_daemon = true;
        } else {
            try opts.passthrough.append(gpa, a);
        }
    }

    // --- cliamp daemon -------------------------------------------------------
    var daemon: ?std.process.Child = null;
    if (!opts.no_daemon and !cliamp.isAlive()) {
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

    var cava = Cava.start(gpa, opts.bars, opts.fps, opts.source);
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
    const frame_ns: i128 = @divTrunc(std.time.ns_per_s, opts.fps);
    var next_frame = std.time.nanoTimestamp();
    var last = next_frame;
    var angle: f32 = 0;
    var spin: f32 = 0; // rad/s
    var rpm: f32 = opts.rpm;
    var rpm_hud_timer: f32 = 0;
    const rpm_presets = [_]f32{ 33.333, 45.0, 78.0, 0.0, 16.666 };
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
                    rpm = @max(0.0, rpm - 5.0);
                    rpm_hud_timer = 2.0;
                },
                ']' => {
                    rpm = @min(200.0, rpm + 5.0);
                    rpm_hud_timer = 2.0;
                },
                '{' => {
                    rpm = @max(0.0, rpm - 1.0);
                    rpm_hud_timer = 2.0;
                },
                '}' => {
                    rpm = @min(200.0, rpm + 1.0);
                    rpm_hud_timer = 2.0;
                },
                'v' => {
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
                    rpm = 33.333;
                    rpm_hud_timer = 2.0;
                },
                '?', 'h' => show_help = !show_help,
                else => {},
            }
        }

        // size
        const sz = term.getSize();
        try screen.resize(sz.cols, sz.rows);
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
            left[b] += (tl - left[b]) * (if (tl > left[b]) @min(1.0, dt * 32.0) else @min(1.0, dt * 11.0));
            right[b] += (tr - right[b]) * (if (tr > right[b]) @min(1.0, dt * 32.0) else @min(1.0, dt * 11.0));
        }
        const snap = client.get();
        var pos = snap.position;
        if (snap.state == .playing and snap.stamp_ns > 0)
            pos += @as(f64, @floatFromInt(now - snap.stamp_ns)) / std.time.ns_per_s;
        if (snap.duration > 0) pos = @min(pos, snap.duration);

        // turntable inertia
        if (rpm_hud_timer > 0) rpm_hud_timer = @max(0.0, rpm_hud_timer - dt);
        const rpm_speed: f32 = rpm / 60.0 * std.math.tau;
        const target: f32 = if (snap.state == .playing) rpm_speed else 0;
        spin += (target - spin) * @min(1.0, dt * 2.5);
        angle = @mod(angle + spin * dt, std.math.tau);

        kitty_out.clearRetainingCapacity();
        const force_redraw = screen.force;
        renderer.render(&screen, .{
            .aspect = aspect,
            .angle = angle,
            .dt = dt,
            .left = left[0..nb],
            .right = right[0..nb],
            .snap = &snap,
            .position = pos,
            .sheen = sheen,
            .bass_top = bass_top,
            .show_fps = show_fps,
            .show_help = show_help,
            .fps = fps_val,
            .rpm = rpm,
            .show_rpm = rpm_hud_timer > 0,
            .bg_mode = bg_mode,
            .cava_ok = cava.ok,
            .kitty_enc = if (use_kitty) &kitty_enc else null,
            .kitty_out = &kitty_out,
            .kitty_warn = kitty_warn,
            .force_redraw = force_redraw,
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
