local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local opt = require 'mp.options'
local utils = require 'mp.utils'

-- Determine platform --
ON_WINDOWS = (package.config:sub(1,1) ~= '/')

-- Some helper functions needed to parse the options --
function isempty(v) return (v == false) or (v == nil) or (v == "") or (v == 0) or (type(v) == "table" and next(v) == nil) end

function divmod (a, b)
  return math.floor(a / b), a % b
end

-- Better modulo
function bmod( i, N )
  return (i % N + N) % N
end

function join_paths(...)
  local sep = ON_WINDOWS and "\\" or "/"
  local result = "";
  for i, p in pairs({...}) do
    if p ~= "" then
      if is_absolute_path(p) then
        result = p
      else
        result = (result ~= "") and (result:gsub("[\\"..sep.."]*$", "") .. sep .. p) or p
      end
    end
  end
  return result:gsub("[\\"..sep.."]*$", "")
end

-- /some/path/file.ext -> /some/path, file.ext
function split_path( path )
  local sep = ON_WINDOWS and "\\" or "/"
  local first_index, last_index = path:find('^.*' .. sep)

  if last_index == nil then
    return "", path
  else
    local dir = path:sub(0, last_index-1)
    local file = path:sub(last_index+1, -1)

    return dir, file
  end
end

function is_absolute_path( path )
  local tmp, is_win  = path:gsub("^[A-Z]:\\", "")
  local tmp, is_unix = path:gsub("^/", "")
  return (is_win > 0) or (is_unix > 0)
end

function Set(source)
  local set = {}
  for _, l in ipairs(source) do set[l] = true end
  return set
end

---------------------------
-- More helper functions --
---------------------------

-- Removes all keys from a table, without destroying the reference to it
function clear_table(target)
  for key, value in pairs(target) do
    target[key] = nil
  end
end
function shallow_copy(target)
  local copy = {}
  for k, v in pairs(target) do
    copy[k] = v
  end
  return copy
end

-- Rounds to given decimals. eg. round_dec(3.145, 0) => 3
function round_dec(num, idp)
  local mult = 10^(idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

function file_exists(name)
  local f = io.open(name, "rb")
  if f ~= nil then
    local ok, err, code = f:read(1)
    io.close(f)
    return code == nil
  else
    return false
  end
end

function path_exists(name)
  local f = io.open(name, "rb")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

function create_directories(path)
  local cmd
  if ON_WINDOWS then
    cmd = { args = {"cmd", "/c", "mkdir", path} }
  else
    cmd = { args = {"mkdir", "-p", path} }
  end
  utils.subprocess(cmd)
end

-- Find an executable in PATH or CWD with the given name
function find_executable(name)
  local delim = ON_WINDOWS and ";" or ":"

  local pwd = os.getenv("PWD") or utils.getcwd()
  local path = os.getenv("PATH")

  local env_path = pwd .. delim .. path -- Check CWD first

  local result, filename
  for path_dir in env_path:gmatch("[^"..delim.."]+") do
    filename = join_paths(path_dir, name)
    if file_exists(filename) then
      result = filename
      break
    end
  end

  return result
end

local ExecutableFinder = { path_cache = {} }
-- Searches for an executable and caches the result if any
function ExecutableFinder:get_executable_path( name, raw_name )
  name = ON_WINDOWS and not raw_name and (name .. ".exe") or name

  if self.path_cache[name] == nil then
    self.path_cache[name] = find_executable(name) or false
  end
  return self.path_cache[name]
end

-- Format seconds to HH.MM.SS.sss
function format_time(seconds, sep, decimals)
  decimals = decimals == nil and 3 or decimals
  sep = sep and sep or "."
  local s = seconds
  local h, s = divmod(s, 60*60)
  local m, s = divmod(s, 60)

  local second_format = string.format("%%0%d.%df", 2+(decimals > 0 and decimals+1 or 0), decimals)

  return string.format("%02d"..sep.."%02d"..sep..second_format, h, m, s)
end

-- Format seconds to 1h 2m 3.4s
function format_time_hms(seconds, sep, decimals, force_full)
  decimals = decimals == nil and 1 or decimals
  sep = sep ~= nil and sep or " "

  local s = seconds
  local h, s = divmod(s, 60*60)
  local m, s = divmod(s, 60)

  if force_full or h > 0 then
    return string.format("%dh"..sep.."%dm"..sep.."%." .. tostring(decimals) .. "fs", h, m, s)
  elseif m > 0 then
    return string.format("%dm"..sep.."%." .. tostring(decimals) .. "fs", m, s)
  else
    return string.format("%." .. tostring(decimals) .. "fs", s)
  end
end

-- Writes text on OSD and console
function log_info(txt, timeout)
  timeout = timeout or 1.5
  msg.info(txt)
  mp.osd_message(txt, timeout)
end

-- Join table items, ala ({"a", "b", "c"}, "=", "-", ", ") => "=a-, =b-, =c-"
function join_table(source, before, after, sep)
  before = before or ""
  after = after or ""
  sep = sep or ", "
  local result = ""
  for i, v in pairs(source) do
    if not isempty(v) then
      local part = before .. v .. after
      if i == 1 then
        result = part
      else
        result = result .. sep .. part
      end
    end
  end
  return result
end

function wrap(s, char)
  char = char or "'"
  return char .. s .. char
end
-- Wraps given string into 'string' and escapes any 's in it
function escape_and_wrap(s, char, replacement)
  char = char or "'"
  replacement = replacement or "\\" .. char
  return wrap(string.gsub(s, char, replacement), char)
end
-- Escapes single quotes in a string and wraps the input in single quotes
function escape_single_bash(s)
  return escape_and_wrap(s, "'", "'\\''")
end

-- Returns (a .. b) if b is not empty or nil
function joined_or_nil(a, b)
  return not isempty(b) and (a .. b) or nil
end

-- Put items from one table into another
function extend_table(target, source)
  for i, v in pairs(source) do
    table.insert(target, v)
  end
end

-- Creates a handle and filename for a temporary random file (in current directory)
function create_temporary_file(base, mode, suffix)
  local handle, filename
  suffix = suffix or ""
  while true do
    filename = base .. tostring(math.random(1, 5000)) .. suffix
    handle = io.open(filename, "r")
    if not handle then
      handle = io.open(filename, mode)
      break
    end
    io.close(handle)
  end
  return handle, filename
end


function get_processor_count()
  local proc_count

  if ON_WINDOWS then
    proc_count = tonumber(os.getenv("NUMBER_OF_PROCESSORS"))
  else
    local cpuinfo_handle = io.open("/proc/cpuinfo")
    if cpuinfo_handle ~= nil then
      local cpuinfo_contents = cpuinfo_handle:read("*a")
      local _, replace_count = cpuinfo_contents:gsub('processor', '')
      proc_count = replace_count
    end
  end

  if proc_count and proc_count > 0 then
      return proc_count
  else
    return nil
  end
end

function substitute_values(string, values)
  local substitutor = function(match)
    if match == "%" then
       return "%"
    else
      -- nil is discarded by gsub
      return values[match]
    end
  end

  local substituted = string:gsub('%%(.)', substitutor)
  return substituted
end

-- ASS HELPERS --
function round_rect_top( ass, x0, y0, x1, y1, r )
  local c = 0.551915024494 * r -- circle approximation
  ass:move_to(x0 + r, y0)
  ass:line_to(x1 - r, y0) -- top line
  if r > 0 then
      ass:bezier_curve(x1 - r + c, y0, x1, y0 + r - c, x1, y0 + r) -- top right corner
  end
  ass:line_to(x1, y1) -- right line
  ass:line_to(x0, y1) -- bottom line
  ass:line_to(x0, y0 + r) -- left line
  if r > 0 then
      ass:bezier_curve(x0, y0 + r - c, x0 + r - c, y0, x0 + r, y0) -- top left corner
  end
end

function round_rect(ass, x0, y0, x1, y1, rtl, rtr, rbr, rbl)
    local c = 0.551915024494
    ass:move_to(x0 + rtl, y0)
    ass:line_to(x1 - rtr, y0) -- top line
    if rtr > 0 then
        ass:bezier_curve(x1 - rtr + rtr*c, y0, x1, y0 + rtr - rtr*c, x1, y0 + rtr) -- top right corner
    end
    ass:line_to(x1, y1 - rbr) -- right line
    if rbr > 0 then
        ass:bezier_curve(x1, y1 - rbr + rbr*c, x1 - rbr + rbr*c, y1, x1 - rbr, y1) -- bottom right corner
    end
    ass:line_to(x0 + rbl, y1) -- bottom line
    if rbl > 0 then
        ass:bezier_curve(x0 + rbl - rbl*c, y1, x0, y1 - rbl + rbl*c, x0, y1 - rbl) -- bottom left corner
    end
    ass:line_to(x0, y0 + rtl) -- left line
    if rtl > 0 then
        ass:bezier_curve(x0, y0 + rtl - rtl*c, x0 + rtl - rtl*c, y0, x0 + rtl, y0) -- top left corner
    end
end
