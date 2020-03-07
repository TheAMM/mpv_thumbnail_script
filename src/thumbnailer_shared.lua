local Thumbnailer = {
    cache_directory = thumbnailer_options.cache_directory,

    state = {
        -- Used to make sure updates sent to us by workers correspond to the
        -- current state (the video hasn't changed)
        id = 0,
        ready = false,
        available = false,
        enabled = false,

        thumbnail_template = nil,

        thumbnail_delta = nil,
        thumbnail_count = 0,

        thumbnail_size = nil,

        finished_thumbnails = 0,

        -- List of thumbnail states (from 1 to thumbnail_count)
        -- ready: 1
        -- in progress: 0
        -- not ready: -1
        thumbnails = {},

        worker_input_path = nil,
        -- Extra options for the workers
        worker_extra = {},
    },
    -- Set in register_client
    worker_register_timeout = nil,
    -- A timer used to wait for more workers in case we have none
    worker_wait_timer = nil,
    workers = {}
}

function Thumbnailer:clear_state()
    local prev_state_id = self.state.id

    clear_table(self.state)
    self.state.id = prev_state_id + 1
    self.state.ready = false
    self.state.available = false
    self.state.finished_thumbnails = 0
    self.state.thumbnails = {}
    self.state.worker_extra = {}
end


function Thumbnailer:on_file_loaded()
    self:clear_state()
end

function Thumbnailer:on_thumb_ready(state_id, index)
    if self.state.id ~= state_id then
      return
    end

    self.state.thumbnails[index] = 1

    -- Full recount instead of a naive increment (let's be safe!)
    self.state.finished_thumbnails = 0
    for i, v in pairs(self.state.thumbnails) do
        if v > 0 then
            self.state.finished_thumbnails = self.state.finished_thumbnails + 1
        end
    end
end

function Thumbnailer:on_thumb_progress(state_id, index)
    if self.state.id ~= state_id then
      return
    end

    self.state.thumbnails[index] = math.max(self.state.thumbnails[index], 0)
end

function Thumbnailer:on_start_file()
    -- Clear state when a new file is being loaded
    self:clear_state()
end

function Thumbnailer:on_video_change(params)
    -- Gather a new state when we get proper video-dec-params and our state is empty
    if params ~= nil then
        if not self.state.ready then
            self:update_state()
        end
    end
end


function Thumbnailer:update_state()
    msg.debug("Gathering video/thumbnail state")

    self.state.thumbnail_delta = self:get_delta()
    self.state.thumbnail_count = self:get_thumbnail_count(self.state.thumbnail_delta)

    -- Prefill individual thumbnail states
    for i = 1, self.state.thumbnail_count do
        self.state.thumbnails[i] = -1
    end

    self.state.thumbnail_template, self.state.thumbnail_directory = self:get_thumbnail_template()
    self.state.thumbnail_size = self:get_thumbnail_size()

    self.state.ready = true

    local file_path = mp.get_property_native("path", "")
    self.state.is_remote = file_path:find("://") ~= nil

    self.state.available = false

    -- Make sure the file has video (and not just albumart)
    local track_list = mp.get_property_native("track-list", {})
    local has_video = false
    for i, track in pairs(track_list) do
        if track.type == "video" and not track.external and not track.albumart then
            has_video = true
            break
        end
    end

    if has_video and self.state.thumbnail_delta ~= nil and self.state.thumbnail_size ~= nil and self.state.thumbnail_count > 0 then
        self.state.available = true
    end

    msg.debug("Thumbnailer.state:", utils.to_string(self.state))

end


function Thumbnailer:get_thumbnail_template()
    local file_path = mp.get_property_native("path", "")
    local is_remote = file_path:find("://") ~= nil

    local filename = mp.get_property_native("filename/no-ext", "")
    local filesize = mp.get_property_native("file-size", 0)

    if is_remote then
        filesize = 0
    end

    filename = filename:gsub('[^a-zA-Z0-9_.%-\' ]', '')
    -- Hash overly long filenames (most likely URLs)
    if #filename > thumbnailer_options.hash_filename_length then
        filename = sha1.hex(filename)
    end

    local file_key = ("%s-%d"):format(filename, filesize)

    local thumbnail_directory = join_paths(self.cache_directory, file_key)
    local file_template = join_paths(thumbnail_directory, "%06d.bgra")
    return file_template, thumbnail_directory
end


function Thumbnailer:get_thumbnail_size()
    local video_dec_params = mp.get_property_native("video-dec-params", {})
    local video_width = video_dec_params.dw
    local video_height = video_dec_params.dh
    if not (video_width and video_height) then
        return nil
    end

    local w, h
    if video_width > video_height then
        w = thumbnailer_options.thumbnail_width
        h = math.floor(video_height * (w / video_width))
    else
        h = thumbnailer_options.thumbnail_height
        w = math.floor(video_width * (h / video_height))
    end
    return { w=w, h=h }
end


function Thumbnailer:get_delta()
    local file_path = mp.get_property_native("path", "")
    local file_duration = mp.get_property_native("duration")
    local is_seekable = mp.get_property_native("seekable")

    -- Naive url check
    local is_remote = file_path:find("://") ~= nil

    local remote_and_disallowed = is_remote
    if is_remote and thumbnailer_options.thumbnail_network then
        remote_and_disallowed = false
    end

    if remote_and_disallowed or not is_seekable or not file_duration then
        -- Not a local path (or remote thumbnails allowed), not seekable or lacks duration
        return nil
    end

    local thumbnail_count = thumbnailer_options.thumbnail_count
    local min_delta = thumbnailer_options.min_delta
    local max_delta = thumbnailer_options.max_delta

    if is_remote then
        thumbnail_count = thumbnailer_options.remote_thumbnail_count
        min_delta = thumbnailer_options.remote_min_delta
        max_delta = thumbnailer_options.remote_max_delta
    end

    local target_delta = (file_duration / thumbnail_count)
    local delta = math.max(min_delta, math.min(max_delta, target_delta))

    return delta
end


function Thumbnailer:get_thumbnail_count(delta)
    if delta == nil then
        return 0
    end

    local file_duration = mp.get_property_native("duration", 0)
    return math.ceil(file_duration / delta)
end

function Thumbnailer:get_closest(thumbnail_index)
    -- Given a 1-based index, find the closest available thumbnail and return it's 1-based index

    -- Check the direct thumbnail index first
    if self.state.thumbnails[thumbnail_index] > 0 then
        return thumbnail_index
    end

    local min_distance = self.state.thumbnail_count + 1
    local closest = nil

    -- Naive, inefficient, lazy. But functional.
    for index, value in pairs(self.state.thumbnails) do
        local distance = math.abs(index - thumbnail_index)
        if distance < min_distance and value > 0 then
            min_distance = distance
            closest = index
        end
    end
    return closest
end

function Thumbnailer:get_thumbnail_index(time_position)
    -- Returns a 1-based thumbnail index for the given timestamp (between 1 and thumbnail_count, inclusive)
    if self.state.thumbnail_delta and (self.state.thumbnail_count and self.state.thumbnail_count > 0) then
        return math.min(math.floor(time_position / self.state.thumbnail_delta) + 1, self.state.thumbnail_count)
    else
        return nil
    end
end

function Thumbnailer:get_thumbnail_path(time_position)
    -- Given a timestamp, return:
    --   the closest available thumbnail path (if any)
    --   the 1-based thumbnail index calculated from the timestamp
    --   the 1-based thumbnail index of the closest available (and used) thumbnail
    -- OR nil if thumbnails are not available.

    local thumbnail_index = self:get_thumbnail_index(time_position)
    if not thumbnail_index then return nil end

    local closest = self:get_closest(thumbnail_index)

    if closest ~= nil then
        return self.state.thumbnail_template:format(closest-1), thumbnail_index, closest
    else
        return nil, thumbnail_index, nil
    end
end

function Thumbnailer:register_client()
    self.worker_register_timeout = mp.get_time() + 2

    mp.register_script_message("mpv_thumbnail_script-ready", function(state_id, index, path)
        self:on_thumb_ready(tonumber(state_id), tonumber(index), path)
    end)
    mp.register_script_message("mpv_thumbnail_script-progress", function(state_id, index, path)
        self:on_thumb_progress(tonumber(state_id), tonumber(index), path)
    end)

    mp.register_script_message("mpv_thumbnail_script-worker", function(worker_name)
        if not self.workers[worker_name] then
            msg.debug("Registered worker", worker_name)
            self.workers[worker_name] = true
            mp.commandv("script-message-to", worker_name, "mpv_thumbnail_script-slaved")
        end
    end)

    -- Notify workers to generate thumbnails when video loads/changes
    -- This will be executed after the on_video_change (because it's registered after it)
    mp.observe_property("video-dec-params", "native", function()
        local duration = mp.get_property_native("duration")
        local max_duration = thumbnailer_options.autogenerate_max_duration

        if duration ~= nil and self.state.available and thumbnailer_options.autogenerate then
            -- Notify if autogenerate is on and video is not too long
            if duration < max_duration or max_duration == 0 then
                self:start_worker_jobs()
            end
        end
    end)

    local thumb_script_key = not thumbnailer_options.disable_keybinds and "T" or nil
    mp.add_key_binding(thumb_script_key, "generate-thumbnails", function()
        if self.state.available then
            mp.osd_message("Started thumbnailer jobs")
            self:start_worker_jobs()
        else
            mp.osd_message("Thumbnailing unavailabe")
        end
    end)
end

function Thumbnailer:_create_thumbnail_job_order()
    -- Returns a list of 1-based thumbnail indices in a job order
    local used_frames = {}
    local work_frames = {}

    -- Pick frames in increasing frequency.
    -- This way we can do a quick few passes over the video and then fill in the gaps.
    for x = 6, 0, -1 do
        local nth = (2^x)

        for thi = 1, self.state.thumbnail_count, nth do
            if not used_frames[thi] then
                table.insert(work_frames, thi)
                used_frames[thi] = true
            end
        end
    end
    return work_frames
end

function Thumbnailer:prepare_source_path()
    local file_path = mp.get_property_native("path", "")

    if self.state.is_remote and thumbnailer_options.remote_direct_stream then
        -- Use the direct stream (possibly) provided by ytdl
        -- This skips ytdl on the sub-calls, making the thumbnailing faster
        -- Works well on YouTube, rest not really tested
        file_path = mp.get_property_native("stream-path", "")

        -- edl:// urls can get LONG. In which case, save the path (URL)
        -- to a temporary file and use that instead.
        local playlist_filename = join_paths(self.state.thumbnail_directory, "playlist.txt")

        if #file_path > 8000 then
            -- Path is too long for a playlist - just pass the original URL to
            -- workers and allow ytdl
            self.state.worker_extra.enable_ytdl = true
            file_path = mp.get_property_native("path", "")
            msg.warn("Falling back to original URL and ytdl due to LONG source path. This will be slow.")

        elseif #file_path > 1024 then
            local playlist_file = io.open(playlist_filename, "wb")
            if not playlist_file then
                msg.error(("Tried to write a playlist to %s but couldn't!"):format(playlist_file))
                return false
            end

            playlist_file:write(file_path .. "\n")
            playlist_file:close()

            file_path = "--playlist=" .. playlist_filename
            msg.warn("Using playlist workaround due to long source path")
        end
    end

    self.state.worker_input_path = file_path
    return true
end

function Thumbnailer:start_worker_jobs()
    -- Create directory for the thumbnails, if needed
    local l, err = utils.readdir(self.state.thumbnail_directory)
    if err then
        msg.debug("Creating thumbnail directory", self.state.thumbnail_directory)
        create_directories(self.state.thumbnail_directory)
    end

    -- Try to prepare the source path for workers, and bail if unable to do so
    if not self:prepare_source_path() then
        return
    end

    local worker_list = { state_id = self.state.id }
    for worker_name in pairs(self.workers) do table.insert(worker_list, worker_name) end

    local worker_count = #worker_list

    -- In case we have a worker timer created already, clear it
    -- (For example, if the video-dec-params change in quick succession or the user pressed T, etc)
    if self.worker_wait_timer then
        self.worker_wait_timer:stop()
    end

    if worker_count == 0 then
        local now = mp.get_time()
        if mp.get_time() > self.worker_register_timeout then
            -- Workers have had their time to register but we have none!
            local err = "No thumbnail workers found. Make sure you are not missing a script!"
            msg.error(err)
            mp.osd_message(err, 3)

        else
            -- We may be too early. Delay the work start a bit to try again.
            msg.warn("No workers found. Waiting a bit more for them.")
            -- Wait at least half a second
            local wait_time = math.max(self.worker_register_timeout - now, 0.5)
            self.worker_wait_timer = mp.add_timeout(wait_time, function() self:start_worker_jobs() end)
        end

    else
        -- We have at least one worker. This may not be all of them, but they have had
        -- their time to register; we've done our best waiting for them.
        self.state.enabled = true

        msg.debug( ("Splitting %d thumbnails amongst %d worker(s)"):format(self.state.thumbnail_count, worker_count) )

        local frame_job_order = self:_create_thumbnail_job_order()
        local worker_jobs = {}
        for i = 1, worker_count do worker_jobs[worker_list[i]] = {} end

        -- Split frames amongst the workers
        for i, thumbnail_index in ipairs(frame_job_order) do
            local worker_id = worker_list[ ((i-1) % worker_count) + 1 ]
            table.insert(worker_jobs[worker_id], thumbnail_index)
        end

        local state_json_string = utils.format_json(self.state)
        msg.debug("Giving workers state:", state_json_string)

        for worker_name, worker_frames in pairs(worker_jobs) do
            if #worker_frames > 0 then
                local frames_json_string = utils.format_json(worker_frames)
                msg.debug("Assigning job to", worker_name, frames_json_string)
                mp.commandv("script-message-to", worker_name, "mpv_thumbnail_script-job", state_json_string, frames_json_string)
            end
        end
    end
end

mp.register_event("start-file", function() Thumbnailer:on_start_file() end)
mp.observe_property("video-dec-params", "native", function(name, params) Thumbnailer:on_video_change(params) end)
