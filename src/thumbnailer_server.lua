
function create_thumbnail_mpv(file_path, timestamp, size, output_path)
    local mpv_command = {
        "mpv",
        file_path,
        "--start=" .. tostring(timestamp),
        "--frames=1",
        "--hr-seek=yes",
        "--no-audio",

        ("--vf=scale=%d:%d"):format(size.w, size.h),
        "--vf-add=format=bgra",
        "--of=rawvideo",
        "--ovc=rawvideo",
        "--o", output_path
    }
    return utils.subprocess({args=mpv_command})
end


function create_thumbnail_ffmpeg(file_path, timestamp, size, output_path)
    local ffmpeg_command = {
        "ffmpeg",
        "-loglevel", "quiet",
        "-ss", format_time(timestamp, ":"),
        "-i", file_path,

        "-frames:v", "1",
        "-an",

        "-vf", ("scale=%d:%d"):format(size.w, size.h),
        "-c:v", "rawvideo",
        "-pix_fmt", "bgra",
        "-f", "rawvideo",

        "-y", output_path
    }
    local ret = utils.subprocess({args=ffmpeg_command})
    return ret
end


function check_output(ret, output_path)
    if ret.killed_by_us then
        return nil
    end

    if ret.error or ret.status ~= 0 then
        msg.error("Thumbnailing command failed!")
        msg.error(ret.error or ret.stdout)

        return false
    end

    if not file_exists(output_path) then
        msg.error("Output file missing!")
        return false
    end

    return true
end


function generate_thumbnails()
    if not Thumbnailer.state.available then
        -- print("Thumbnailer state not ready")
        return
    end

    local thumbnail_count = Thumbnailer.state.thumbnail_count
    local thumbnail_delta = Thumbnailer.state.thumbnail_delta
    local thumbnail_size = Thumbnailer.state.thumbnail_size
    local file_template = Thumbnailer.state.thubmnail_template
    local file_duration = mp.get_property_native("duration")
    local file_path = mp.get_property_native("path")

    msg.info(("Generating %d thumbnails @ %dx%d"):format(thumbnail_count, thumbnail_size.w, thumbnail_size.h))

    -- Create directory for the thumbnails
    local thumbnail_directory = split_path(file_template)
    local l, err = utils.readdir(thumbnail_directory)
    if err then
        msg.info("Creating", thumbnail_directory)
        create_directories(thumbnail_directory)
    end

    local thumbnail_func = create_thumbnail_mpv
    if not thumbnailer_options.prefer_mpv then
        if ExecutableFinder:get_executable_path("ffmpeg") then
            thumbnail_func = create_thumbnail_ffmpeg
        else
            msg.warning("Could not find ffmpeg in PATH! Falling back on mpv.")
        end
    end

    mp.commandv("script-message", "mpv_thumbnail_script-enabled")

    for thumbnail_index = 0, thumbnail_count-1 do
        local thumbnail_path = file_template:format(thumbnail_index)
        local timestamp = math.min(file_duration, thumbnail_index * thumbnail_delta)

        if not path_exists(thumbnail_path) then

            local ret = thumbnail_func(file_path, timestamp, thumbnail_size, thumbnail_path)
            local success = check_output(ret, thumbnail_path)

            if success == nil then
                -- Killed by us, changing files, ignore
                return
            elseif not success then
                -- Failure
                mp.osd_message("Thumbnailing failed, check console for details", 3.5)
                return
            end

        end

        mp.commandv("script-message", "mpv_thumbnail_script-ready", tostring(thumbnail_index+1), thumbnail_path)
    end
end

-- function on_file_loaded()
--     if thumbnailer_options.autogenerate then
--         generate_thumbnails()
--     end
-- end
-- mp.observe_property("video-dec-params", "native", on_file_loaded)

function on_script_keypress()
    mp.osd_message("Starting thumbnail generation", 2)
    generate_thumbnails()
    mp.osd_message("All thumbnails generated", 2)
end

mp.register_script_message("mpv_thumbnail_script-generate", generate_thumbnails)

local thumb_script_key = not thumbnailer_options.disable_keybinds and "T" or nil
mp.add_key_binding(thumb_script_key, "generate-thumbnails", on_script_keypress)
