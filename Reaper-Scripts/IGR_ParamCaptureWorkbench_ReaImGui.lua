-- @description IGR Parameter Capture Workbench (ReaImGui)
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Combined launcher UI for capture + validation scripts.
--   Requires ReaImGui extension.

local function script_dir()
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  src = src:gsub("^@", "")
  return src:match("^(.*[\\/])") or ""
end

local BASE_DIR = script_dir()
local CAPTURE_PATH = BASE_DIR .. "CapturePluginParameterGrid.lua"
local VALIDATE_PATH = BASE_DIR .. "ValidateParamGridCapture.lua"
local INSTRUCTIONS_PATH = BASE_DIR .. "ParameterGridCapture_Instructions.txt"

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

if not reaper.ImGui_CreateContext then
  reaper.MB(
    "ReaImGui is not available.\n\nInstall ReaImGui from ReaPack, then run this script again.",
    "IGR Workbench",
    0
  )
  return
end

local ctx = reaper.ImGui_CreateContext("IGR Param Capture Workbench")
local visible = true
local status = "Ready"

local function run_script(path, friendly_name)
  if not file_exists(path) then
    status = friendly_name .. " not found: " .. path
    return
  end

  status = "Launching " .. friendly_name .. "..."
  local ok, err = pcall(dofile, path)
  if ok then
    status = friendly_name .. " finished"
  else
    status = friendly_name .. " error: " .. tostring(err)
  end
end

local function main_loop()
  if not visible then
    reaper.ImGui_DestroyContext(ctx)
    return
  end

  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
  visible, _ = reaper.ImGui_Begin(ctx, "IGR Param Capture Workbench", true, flags)

  if visible then
    reaper.ImGui_Text(ctx, "Analysis Phase Workbench")
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, "Use this panel to run capture and validation without switching scripts.")
    reaper.ImGui_Spacing(ctx)

    if reaper.ImGui_Button(ctx, "Run Parameter Grid Capture", 280, 28) then
      run_script(CAPTURE_PATH, "Capture script")
    end

    if reaper.ImGui_Button(ctx, "Run Dataset Validation", 280, 28) then
      run_script(VALIDATE_PATH, "Validation script")
    end

    if reaper.ImGui_Button(ctx, "Open Instructions (Notepad)", 280, 28) then
      if file_exists(INSTRUCTIONS_PATH) then
        if reaper.CF_ShellExecute then
          reaper.CF_ShellExecute(INSTRUCTIONS_PATH)
          status = "Opened instructions"
        else
          local cmd = string.format('start "" "%s"', INSTRUCTIONS_PATH)
          os.execute(cmd)
          status = "Opened instructions (shell fallback)"
        end
      else
        status = "Instructions file not found"
      end
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, "Status: " .. status)

    reaper.ImGui_End(ctx)
  end

  reaper.defer(main_loop)
end

main_loop()
