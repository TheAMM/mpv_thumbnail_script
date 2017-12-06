function skip_nil(tbl)
    local n = {}
    for k, v in pairs(tbl) do
        table.insert(n, v)
    end
    return n
end

function create_thumbnail_mpv(file_path, timestamp, size, output_path)
    local ytdl_disabled = mp.get_property_native("ytdl") == false or thumbnailer_options.remote_direct_stream

    local mpv_command = skip_nil({
        "mpv",
        file_path,

        -- Disable ytdl
        (ytdl_disabled and "--no-ytdl" or nil),
        -- Disable hardware decoding
        "--hwdec=no",

        "--start=" .. tostring(timestamp),
        "--frames=1",
        "--hr-seek=yes",
        "--no-audio",
        -- Optionally disable subtitles
        (thumbnailer_options.mpv_no_sub and "--no-sub" or nil),

        ("--vf=scale=%d:%d"):format(size.w, size.h),
        "--vf-add=format=bgra",
        "--of=rawvideo",
        "--ovc=rawvideo",
        "--o", output_path
    })
    return utils.subprocess({args=mpv_command})
end


function create_thumbnail_ffmpeg(file_path, timestamp, size, output_path)
    local ffmpeg_command = {
        "ffmpeg",
        "-loglevel", "quiet",
        "-noaccurate_seek",
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
    return utils.subprocess({args=ffmpeg_command})
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


function generate_thumbnails(from_keypress)
    msg.debug("Thumbnailer state:")
    msg.debug(utils.to_string(Thumbnailer.state))

    if not Thumbnailer.state.available then
        if from_keypress then
            mp.osd_message("Nothing to thumbnail", 2)
        end
        if Thumbnailer.state.is_remote then
            msg.warn("Not thumbnailing remote file")
        end
        return
    end

    local thumbnail_count = Thumbnailer.state.thumbnail_count
    local thumbnail_delta = Thumbnailer.state.thumbnail_delta
    local thumbnail_size = Thumbnailer.state.thumbnail_size
    local file_template = Thumbnailer.state.thumbnail_template
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

    if Thumbnailer.state.is_remote then
        thumbnail_func = create_thumbnail_mpv
        if thumbnailer_options.remote_direct_stream then
            -- Use the direct stream (possibly) provided by ytdl
            -- This skips ytdl on the sub-calls, making the thumbnailing faster
            -- Works well on YouTube, rest not really tested
            file_path = mp.get_property_native("stream-path")
        end
    end

    mp.commandv("script-message", "mpv_thumbnail_script-enabled")

    local generate_thumbnail_for_index = function(thumbnail_index)
        local thumbnail_path = file_template:format(thumbnail_index)
        local timestamp = math.min(file_duration, thumbnail_index * thumbnail_delta)

        -- The expected size (raw BGRA image)
        local thumbnail_raw_size = (thumbnail_size.w * thumbnail_size.h * 4)

        local need_thumbnail_generation = false

        -- Check if the thumbnail already exists and is the correct size
        local thumbnail_file = io.open(thumbnail_path, "rb")
        if thumbnail_file == nil then
            need_thumbnail_generation = true
        else
            local existing_thumbnail_filesize = thumbnail_file:seek("end")
            if existing_thumbnail_filesize ~= thumbnail_raw_size then
                -- Size doesn't match, so (re)generate
                msg.warn("Thumbnail", thumbnail_index, "did not match expected size, regenerating")
                need_thumbnail_generation = true
            end
            thumbnail_file:close()
        end

        if need_thumbnail_generation then
            local ret = thumbnail_func(file_path, timestamp, thumbnail_size, thumbnail_path)
            local success = check_output(ret, thumbnail_path)

            if success == nil then
                -- Killed by us, changing files, ignore
                return true
            elseif not success then
                -- Failure
                mp.osd_message("Thumbnailing failed, check console for details", 3.5)
                return true
            end
        end

        -- Verify thumbnail size
        -- Sometimes ffmpeg will output an empty file when seeking to a "bad" section (usually the end)
        thumbnail_file = io.open(thumbnail_path, "rb")

        -- Bail if we can't read the file (it should really exist by now, we checked this in check_output!)
        if thumbnail_file == nil then
            msg.error("Thumbnail suddenly disappeared!")
            return true
        end

        -- Check the size of the generated file
        local thumbnail_file_size = thumbnail_file:seek("end")
        thumbnail_file:close()

        -- Check if the file is big enough
        local missing_bytes = math.max(0, thumbnail_raw_size - thumbnail_file_size)
        if missing_bytes > 0 then
            msg.warn(("Thumbnail missing %d bytes (expected %d, had %d), padding %s"):format(
              missing_bytes, thumbnail_raw_size, thumbnail_file_size, thumbnail_path
            ))
            -- Pad the file if it's missing content (eg. ffmpeg seek to file end)
            thumbnail_file = io.open(thumbnail_path, "ab")
            thumbnail_file:write(string.rep(string.char(0), missing_bytes))
            thumbnail_file:close()
        end

        mp.commandv("script-message", "mpv_thumbnail_script-ready", tostring(thumbnail_index), thumbnail_path)
    end

    -- Keep track of which thumbnails we've checked during the passes (instead of proper math for no-overlap)
    local generated_thumbnails = {}

    -- Do several passes over the thumbnails with increasing frequency
    for res = 6, 0, -1 do
        local nth = (2^res)

        for thumbnail_index = 0, thumbnail_count-1, nth do
            if not generated_thumbnails[thumbnail_index] then
                local bail = generate_thumbnail_for_index(thumbnail_index)
                if bail then return end
                generated_thumbnails[thumbnail_index] = true
            end
        end
    end
end


function on_script_keypress()
    mp.osd_message("Starting thumbnail generation", 2)
    generate_thumbnails(true)
    mp.osd_message("All thumbnails generated", 2)
end

-- Set up listeners and keybinds

mp.register_script_message("mpv_thumbnail_script-generate", generate_thumbnails)

local thumb_script_key = not thumbnailer_options.disable_keybinds and "T" or nil
mp.add_key_binding(thumb_script_key, "generate-thumbnails", on_script_keypress)
