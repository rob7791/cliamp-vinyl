local BRIDGE_PATH = "/tmp/cliamp-vinyl-art.txt"

local p = plugin.register({
    name = "vinyl-art-bridge",
    version = "0.1.0",
    description = "Publish track path and album_art_url for vinyl player",
    type = "hook",
})

local last_payload = nil

local function publish(ev)
    local path = (ev and ev.path) or ""
    if path == "" and cliamp and cliamp.track and cliamp.track.path then
        path = cliamp.track.path() or ""
    end
    if path == "" then
        return
    end

    local art = (ev and ev.album_art_url) or ""
    if art == "" and cliamp and cliamp.track and cliamp.track.album_art_url then
        art = cliamp.track.album_art_url() or ""
    end

    local payload = path .. "\n" .. art .. "\n"
    if payload ~= last_payload then
        last_payload = payload
        pcall(cliamp.fs.write, BRIDGE_PATH, payload)
    end
end

local function clear()
    last_payload = nil
    pcall(cliamp.fs.remove, BRIDGE_PATH)
end

p:on("app.start", publish)
p:on("track.change", publish)
p:on("playback.state", publish)
p:on("playback.stop", clear)
p:on("app.quit", clear)
