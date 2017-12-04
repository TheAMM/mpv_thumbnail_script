local SCRIPT_NAME = "mpv_thumbnail_script"

local default_cache_base = ON_WINDOWS and os.getenv("TEMP") or "/tmp/"

local thumbnailer_options = {
    -- The thumbnail directory
    cache_directory = join_paths(default_cache_base, "mpv_thumbs_cache"),

    autogenerate = true,

    -- Use mpv to generate thumbnail even if ffmpeg is found in PATH
    prefer_mpv = false,

    -- Disable the built-in keybind ("T")
    disable_keybinds = false,

    -- The maximum dimensions of the thumbnails
    thumbnail_width = 200,
    thumbnail_height = 200,

    -- asd
    thumbnail_count = 150,
    min_delta = 5,
    max_delta = 120,
}

read_options(thumbnailer_options, SCRIPT_NAME)
