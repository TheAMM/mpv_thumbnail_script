local Thumbnailer = {
    cache_directory = thumbnailer_options.cache_directory,

    state = {
        ready = false,
        available = false,
        enabled = false,

        thubmnail_template = nil,

        thumbnail_delta = nil,
        thumbnail_count = 0,

        thumbnail_size = nil,

        finished_thumbnails = 0
    }
}

function Thumbnailer:clear_state()
    clear_table(self.state)
    self.state.ready = false
    self.state.available = false
    self.state.finished_thumbnails = 0
end


function Thumbnailer:on_file_loaded()
    self:clear_state()
end

function Thumbnailer:on_thumb_ready(index)
    if index > self.state.finished_thumbnails then
        self.state.finished_thumbnails = index
    end
end

function Thumbnailer:on_video_change(params)
    self:clear_state()
    if params ~= nil then
        if not self.state.ready then
            self:update_state()
        end
    end
end


function Thumbnailer:update_state()
    self.state.thumbnail_delta = self:get_delta()
    self.state.thumbnail_count = self:get_thumbnail_count()

    self.state.thubmnail_template = self:get_thubmnail_template()
    self.state.thumbnail_size = self:get_thumbnail_size()

    self.state.ready = true

    self.state.available = false
    if self.state.thumbnail_delta ~= nil and self.state.thumbnail_size ~= nil and self.state.thumbnail_count > 0 then
        self.state.available = true
    end

end


function Thumbnailer:get_thubmnail_template()
    local file_key = ("%s-%d"):format(mp.get_property_native("filename/no-ext"), mp.get_property_native("file-size"))
    local file_template = join_paths(self.cache_directory, file_key, "%06d.bgra")
    return file_template
end


function Thumbnailer:get_thumbnail_size()
    local video_dec_params = mp.get_property_native("video-dec-params")
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
    local file_path = mp.get_property_native("path")
    local file_duration = mp.get_property_native("duration")
    local is_seekable = mp.get_property_native("seekable")

    if file_path:find("://") ~= nil or not is_seekable or not file_duration then
        -- Not a local path, not seekable or lacks duration
        return nil
    end

    local target_delta = (file_duration / thumbnailer_options.thumbnail_count)
    local delta = math.max(thumbnailer_options.min_delta, math.min(thumbnailer_options.max_delta, target_delta))
    -- print("DELTA:", target_delta, delta)

    return delta
end


function Thumbnailer:get_thumbnail_count()
    local delta = self:get_delta()
    if delta == nil then
        return 0
    end
    local file_duration = mp.get_property_native("duration")

    return math.floor(file_duration / delta) + 1
end


function Thumbnailer:get_thumbnail_path(time_position)
    local thumbnail_index = math.min(math.floor(time_position / self.state.thumbnail_delta), self.state.thumbnail_count-1)

    if thumbnail_index < self.state.finished_thumbnails then
        return self.state.thubmnail_template:format(thumbnail_index), thumbnail_index
    else
        return nil, thumbnail_index
    end
end

function Thumbnailer:register_client()
    mp.register_script_message("mpv_thumbnail_script-ready", function(index, path) self:on_thumb_ready(tonumber(index), path) end)
    -- For when autogenerate is off
    mp.register_script_message("mpv_thumbnail_script-enabled", function() self.state.enabled = true end)

    -- Notify server to generate thumbnails
    mp.observe_property("video-dec-params", "native", function()
        if thumbnailer_options.autogenerate then
            mp.commandv("script-message", "mpv_thumbnail_script-generate")
        end
    end)
end

-- mp.register_event("file-loaded", function() Thumbnailer:on_file_loaded() end)
mp.observe_property("video-dec-params", "native", function(name, params) Thumbnailer:on_video_change(params) end)

