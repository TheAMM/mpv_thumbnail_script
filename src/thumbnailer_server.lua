function skip_nil(tbl)
    local n = {}
    for k, v in pairs(tbl) do
        table.insert(n, v)
    end
    return n
end

function create_thumbnail_mpv(file_path, timestamp, size, output_path, options)
    options = options or {}

    local ytdl_disabled = not options.enable_ytdl and (mp.get_property_native("ytdl") == false
                                                       or thumbnailer_options.remote_direct_stream)

    local header_fields_arg = nil
    local header_fields = mp.get_property_native("http-header-fields", {})
    if #header_fields > 0 then
        -- We can't escape the headers, mpv won't parse "--http-header-fields='Name: value'" properly
        header_fields_arg = "--http-header-fields=" .. table.concat(header_fields, ",")
    end

    local profile_arg = nil
    if thumbnailer_options.mpv_profile ~= "" then
        profile_arg = "--profile=" .. thumbnailer_options.mpv_profile
    end

    local log_arg = "--log-file=" .. output_path .. ".log"

    local mpv_command = skip_nil({
        "mpv",
        -- Hide console output
        "--msg-level=all=no",

        -- Disable ytdl
        (ytdl_disabled and "--no-ytdl" or nil),
        -- Pass HTTP headers from current instance
        header_fields_arg,
        -- Pass User-Agent and Referer - should do no harm even with ytdl active
        "--user-agent=" .. mp.get_property_native("user-agent", ""),
        "--referrer=" .. mp.get_property_native("referrer", ""),
        -- Disable hardware decoding
        "--hwdec=no",

        -- Insert --no-config, --profile=... and --log-file if enabled
        (thumbnailer_options.mpv_no_config and "--no-config" or nil),
        profile_arg,
        (thumbnailer_options.mpv_logs and log_arg or nil),

        file_path,

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
        "--o=" .. output_path
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


function check_output(ret, output_path, is_mpv)
    local log_path = output_path .. ".log"
    local success = true

    if ret.killed_by_us then
        return nil
    else
        if ret.error or ret.status ~= 0 then
            msg.error("Thumbnailing command failed!")
            msg.error("mpv process error:", ret.error)
            msg.error("Process stdout:", ret.stdout)
            if is_mpv then
                msg.error("Debug log:", log_path)
            end

            success = false
        end

        if not file_exists(output_path) then
            msg.error("Output file missing!", output_path)
            success = false
        end
    end

    if is_mpv and not thumbnailer_options.mpv_keep_logs then
        -- Remove successful debug logs
        if success and file_exists(log_path) then
            os.remove(log_path)
        end
    end

    return success
end


function do_worker_job(state_json_string, frames_json_string)
    msg.debug("Handling given job")
    local thumb_state, err = utils.parse_json(state_json_string)
    if err then
        msg.error("Failed to parse state JSON")
        return
    end
    local state_id = thumb_state.id

    local thumbnail_indexes, err = utils.parse_json(frames_json_string)
    if err then
        msg.error("Failed to parse thumbnail frame indexes")
        return
    end

    local thumbnail_func = create_thumbnail_mpv
    if not thumbnailer_options.prefer_mpv then
        if ExecutableFinder:get_executable_path("ffmpeg") then
            thumbnail_func = create_thumbnail_ffmpeg
        else
            msg.warn("Could not find ffmpeg in PATH! Falling back on mpv.")
        end
    end

    local file_duration = mp.get_property_native("duration")
    -- Bail if we get a nil duration
    if not file_duration then
      return
    end

    local file_path = thumb_state.worker_input_path

    if thumb_state.is_remote then
        if (thumbnail_func == create_thumbnail_ffmpeg) then
            msg.warn("Thumbnailing remote path, falling back on mpv.")
        end
        thumbnail_func = create_thumbnail_mpv
    end

    local generate_thumbnail_for_index = function(thumbnail_index)
        -- Given a 1-based thumbnail index, generate a thumbnail for it based on the thumbnailer state
        local thumb_idx = thumbnail_index - 1
        msg.debug("Starting work on thumbnail", thumb_idx)

        local thumbnail_path = thumb_state.thumbnail_template:format(thumb_idx)
        -- Grab the "middle" of the thumbnail duration instead of the very start, and leave some margin in the end
        local timestamp = math.min(file_duration - 0.25, (thumb_idx + 0.5) * thumb_state.thumbnail_delta)

        mp.commandv("script-message", "mpv_thumbnail_script-progress", tostring(state_id), tostring(thumbnail_index))

        -- The expected size (raw BGRA image)
        local thumbnail_raw_size = (thumb_state.thumbnail_size.w * thumb_state.thumbnail_size.h * 4)

        local need_thumbnail_generation = false

        -- Check if the thumbnail already exists and is the correct size
        local thumbnail_file = io.open(thumbnail_path, "rb")
        if thumbnail_file == nil then
            need_thumbnail_generation = true
        else
            local existing_thumbnail_filesize = thumbnail_file:seek("end")
            if existing_thumbnail_filesize ~= thumbnail_raw_size then
                -- Size doesn't match, so (re)generate
                msg.warn("Thumbnail", thumb_idx, "did not match expected size, regenerating")
                need_thumbnail_generation = true
            end
            thumbnail_file:close()
        end

        if need_thumbnail_generation then
            local ret = thumbnail_func(file_path, timestamp, thumb_state.thumbnail_size, thumbnail_path, thumb_state.worker_extra)
            local success = check_output(ret, thumbnail_path, thumbnail_func == create_thumbnail_mpv)

            if success == nil then
                -- Killed by us, changing files, ignore
                msg.debug("Changing files, subprocess killed")
                return true
            elseif not success then
                -- Real failure
                mp.osd_message("Thumbnailing failed, check console for details", 3.5)
                return true
            end
        else
            msg.debug("Thumbnail", thumb_idx, "already done!")
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

        msg.debug("Finished work on thumbnail", thumb_idx)
        mp.commandv("script-message", "mpv_thumbnail_script-ready", tostring(state_id), tostring(thumbnail_index), thumbnail_path)
    end

    msg.debug(("Generating %d thumbnails @ %dx%d for %q"):format(
        #thumbnail_indexes,
        thumb_state.thumbnail_size.w,
        thumb_state.thumbnail_size.h,
        file_path))

    for i, thumbnail_index in ipairs(thumbnail_indexes) do
        local bail = generate_thumbnail_for_index(thumbnail_index)
        if bail then return end
    end

end

-- Set up listeners and keybinds

-- Job listener
mp.register_script_message("mpv_thumbnail_script-job", do_worker_job)


-- Register this worker with the master script
local register_timer = nil
local register_timeout = mp.get_time() + 1.5

local register_function = function()
    if mp.get_time() > register_timeout and register_timer then
        msg.error("Thumbnail worker registering timed out")
        register_timer:stop()
    else
        msg.debug("Announcing self to master...")
        mp.commandv("script-message", "mpv_thumbnail_script-worker", mp.get_script_name())
    end
end

register_timer = mp.add_periodic_timer(0.1, register_function)

mp.register_script_message("mpv_thumbnail_script-slaved", function()
    msg.debug("Successfully registered with master")
    register_timer:stop()
end)
