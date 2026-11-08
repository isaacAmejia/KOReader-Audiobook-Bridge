--[[--
Audiobook Library Bridge for KOReader

Routes audio files selected in KOReader's file browser to the Audiobook
Read-Along plugin and exposes optional sidecar cover art to library UIs that
use KOReader's BookInfoManager.

This plugin does not play audio itself.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Load by path, not require("updater"): KOReader plugins share Lua's module
-- cache, so a generic module name could resolve to another plugin's copy.
local PLUGIN_DIR =
    (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"
local Updater = dofile(PLUGIN_DIR .. "updater.lua")

local Bridge = WidgetContainer:extend {
    name = "audiobooklibrarybridge",
    is_doc_only = false,
}

local AUDIO_EXTS = {
    mp3 = true,
    m4a = true,
    m4b = true,
    ogg = true,
    opus = true,
    flac = true,
    wav = true,
    aac = true,
    wma = true,
}

local function getExtension(path)
    if type(path) ~= "string" then return nil end
    local ext = path:match("%.([^./\\]+)$")
    return ext and ext:lower() or nil
end

local function isAudioFile(path)
    local ext = getExtension(path)
    return ext and AUDIO_EXTS[ext] or false
end

local function getFileChooser()
    return require("ui/widget/filechooser")
end

local function unsupportedFilesVisible()
    local FileChooser = getFileChooser()

    return FileChooser.show_unsupported == true
        or (
            G_reader_settings
            and G_reader_settings:isTrue("show_unsupported")
        )
end

local function showMessage(message, timeout)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not (ok_ui and ok_info) then
        logger.warn("audiobooklibrarybridge:", message)
        return
    end

    UIManager:show(InfoMessage:new {
        text = message,
        timeout = timeout,
    })
end

local function findAudiobookPlugin(ReaderUI)
    -- Prefer KOReader's plugin registry. This works even when a custom UI
    -- (such as SimpleUI) is sitting on top of FileManager.
    local ok_loader, PluginLoader =
        pcall(require, "pluginloader")

    if ok_loader
            and PluginLoader
            and type(PluginLoader.getPluginInstance) == "function"
    then
        local audiobook =
            PluginLoader:getPluginInstance("audiobook")

        if audiobook then
            return audiobook
        end
    end

    -- Fallback for older/unusual KOReader contexts.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    local audiobook = fm and fm.audiobook

    if not audiobook and ReaderUI then
        local reader = ReaderUI.instance
        audiobook = reader and reader.audiobook
    end

    return audiobook
end

local function sidecarCoverPath(filepath)
    if not isAudioFile(filepath) then return nil end
    local stem = filepath:gsub("%.[^./\\]+$", "")
    return stem .. ".sdr/cover.jpg"
end

local function installSidecarCoverProvider()
    -- BookInfoManager belongs to KOReader's CoverBrowser stack. Playback
    -- routing remains functional if this optional integration is unavailable.
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim
            or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.getBookInfo) ~= "function"
    then
        logger.info(
            "audiobooklibrarybridge: BookInfoManager unavailable; sidecar covers disabled"
        )
        return false
    end

    if BookInfoManager._audiobook_bridge_cover_patched then
        return true
    end

    -- Keep the provider hook cheap at startup. Image decoding, filesystem
    -- helpers, and utility code are loaded only if an audio cover is actually
    -- requested.
    local RenderImage
    local lfs
    local util

    local cover_cache = {}
    local cover_order = {}
    local COVER_CACHE_MAX = 2
    local COVER_MAX_W = 360
    local COVER_MAX_H = 540

    local function ensureCoverDependencies()
        if RenderImage and lfs and util then
            return true
        end

        local ok_render
        local ok_lfs
        local ok_util

        ok_render, RenderImage =
            pcall(require, "ui/renderimage")
        ok_lfs, lfs =
            pcall(require, "libs/libkoreader-lfs")
        ok_util, util =
            pcall(require, "util")

        return ok_render
            and ok_lfs
            and ok_util
    end

    local function removeFromCoverOrder(path)
        for i, cached_path in ipairs(cover_order) do
            if cached_path == path then
                table.remove(cover_order, i)
                return
            end
        end
    end

    local function getMasterCover(cover_path)
        local mtime =
            lfs.attributes(cover_path, "modification")
        local cached = cover_cache[cover_path]

        if cached
                and cached.mtime == mtime
                and cached.bb
        then
            removeFromCoverOrder(cover_path)
            cover_order[#cover_order + 1] =
                cover_path
            return cached.bb
        end

        if cached and cached.bb then
            pcall(cached.bb.free, cached.bb)
            cover_cache[cover_path] = nil
            removeFromCoverOrder(cover_path)
        end

        local bb = RenderImage:renderImageFile(
            cover_path,
            false
        )

        if not bb then
            return nil
        end

        local width = bb:getWidth()
        local height = bb:getHeight()

        if width > COVER_MAX_W
                or height > COVER_MAX_H
        then
            local scale = math.min(
                COVER_MAX_W / width,
                COVER_MAX_H / height
            )
            local target_w =
                math.max(1, math.floor(width * scale))
            local target_h =
                math.max(1, math.floor(height * scale))

            bb = RenderImage:scaleBlitBuffer(
                bb,
                target_w,
                target_h,
                true
            )
        end

        if not bb then
            return nil
        end

        cover_cache[cover_path] = {
            bb = bb,
            mtime = mtime,
        }
        cover_order[#cover_order + 1] =
            cover_path

        while #cover_order > COVER_CACHE_MAX do
            local oldest =
                table.remove(cover_order, 1)
            local entry = cover_cache[oldest]
            cover_cache[oldest] = nil

            if entry and entry.bb then
                pcall(entry.bb.free, entry.bb)
            end
        end

        return bb
    end

    local orig_getBookInfo = BookInfoManager.getBookInfo

    function BookInfoManager:getBookInfo(filepath, ...)
        local get_cover = select(1, ...)

        -- Normal documents stay on KOReader's native path with effectively
        -- just an extension check added by this bridge.
        if not (get_cover and isAudioFile(filepath)) then
            return orig_getBookInfo(self, filepath, ...)
        end

        if not ensureCoverDependencies() then
            return orig_getBookInfo(self, filepath, ...)
        end

        local cover_path = sidecarCoverPath(filepath)
        if not cover_path
                or lfs.attributes(cover_path, "mode") ~= "file"
        then
            return orig_getBookInfo(self, filepath, ...)
        end

        -- Audio is not a KOReader document, so when a sidecar exists there is
        -- no benefit in running the normal document metadata/provider lookup.
        -- This is a hot path in cover-heavy UIs such as SimpleUI.
        local master_cover =
            getMasterCover(cover_path)
        if not master_cover then
            return orig_getBookInfo(self, filepath, ...)
        end

        local ok_copy, cover_bb =
            pcall(master_cover.copy, master_cover)
        if not ok_copy or not cover_bb then
            return orig_getBookInfo(self, filepath, ...)
        end

        local directory, filename =
            util.splitFilePathName(filepath)

        local bookinfo = {
            directory = directory,
            filename = filename,
            in_progress = 0,
            cover_fetched = "Y",
            has_meta = nil,
            has_cover = true,
            ignore_meta = "Y",
            ignore_cover = nil,
            cover_w = cover_bb:getWidth(),
            cover_h = cover_bb:getHeight(),
            cover_bb = cover_bb,
            _is_directory = false,
            _no_provider = true,
        }

        bookinfo.cover_sizetag =
            bookinfo.cover_w .. "x" .. bookinfo.cover_h

        return bookinfo
    end

    BookInfoManager._audiobook_bridge_cover_patched = true
    logger.info(
        "audiobooklibrarybridge: sidecar cover provider installed"
    )
    return true
end

local function playerReady(audiobook)
    return audiobook
        and audiobook._init_ok
        and audiobook.media_sync
        and type(audiobook._playAudioFile) == "function"
end

function Bridge:init()
    self.updater = Updater:new {
        repo = "isaacAmejia/KOReader-Audiobook-Bridge",
        folder = "audiobooklibrarybridge.koplugin",
        title = _("Audiobook Library Bridge"),
    }

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    local ok_cover, cover_result =
        pcall(installSidecarCoverProvider)
    if not ok_cover then
        logger.warn(
            "audiobooklibrarybridge: sidecar provider installation failed:",
            tostring(cover_result)
        )
    end

    local function installReaderHook()
        local ok_reader, ReaderUI =
            pcall(require, "apps/reader/readerui")
        if not ok_reader or not ReaderUI then
            logger.warn("audiobooklibrarybridge: ReaderUI not available")
            return
        end

        -- FileManager and ReaderUI recreate plugin instances. Patch the
        -- ReaderUI class only once per KOReader process.
        if ReaderUI._audiobook_bridge_patched then
            return
        end
        ReaderUI._audiobook_bridge_patched = true

        local orig_showReader = ReaderUI.showReader

        ReaderUI.showReader =
            function(
            cls,
            file,
            provider,
            seamless,
            is_provider_forced,
            after_open_callback
        )
            if isAudioFile(file) then
                local audiobook = findAudiobookPlugin(ReaderUI)

                if playerReady(audiobook) then
                    -- Audiobook Read-Along owns platform-specific audio
                    -- readiness checks (Bluetooth/output setup, where needed).
                    if type(audiobook._audioOutputReady) == "function" then
                        local ok_ready, ready = pcall(
                            audiobook._audioOutputReady,
                            audiobook
                        )

                        if not ok_ready then
                            logger.warn(
                                "audiobooklibrarybridge: audio readiness check failed:",
                                tostring(ready)
                            )
                            showMessage(
                                _("Audiobook output could not be initialized. Check the KOReader log for details."),
                                7
                            )
                            return
                        end

                        if not ready then
                            return
                        end
                    end

                    logger.dbg(
                        "audiobooklibrarybridge: routing audio file to Audiobook Read-Along"
                    )

                    local ok_play, play_err = pcall(
                        audiobook._playAudioFile,
                        audiobook,
                        file
                    )

                    if not ok_play then
                        logger.warn(
                            "audiobooklibrarybridge: playback routing failed:",
                            tostring(play_err)
                        )
                        showMessage(
                            _("Audiobook playback could not be started. Check the KOReader log for details."),
                            7
                        )
                    end
                    return
                end

                showMessage(_(
                    "Audiobook Read-Along is required to play audio files from the library.\n\n"
                    .. "Install and enable Audiobook Read-Along, then restart KOReader."
                ), 7)
                return
            end

                return orig_showReader(
                    cls,
                    file,
                    provider,
                    seamless,
                    is_provider_forced,
                    after_open_callback
                )
            end
    end

    -- Loading ReaderUI is relatively expensive on low-end devices. Deferring
    -- it one event-loop turn lets the FileManager finish its first paint while
    -- still installing the hook long before a user can select an audiobook.
    local ok_manager, UIManager =
        pcall(require, "ui/uimanager")

    if ok_manager and UIManager then
        UIManager:nextTick(installReaderHook)
    else
        installReaderHook()
    end
end

function Bridge:setUnsupportedFilesVisible(enabled)
    enabled = enabled and true or false

    local FileChooser = getFileChooser()
    FileChooser.show_unsupported = enabled
    G_reader_settings:saveSetting(
        "show_unsupported",
        enabled
    )

    if G_reader_settings.flush then
        G_reader_settings:flush()
    end

    if self.ui
            and self.ui.file_chooser
            and type(self.ui.file_chooser.refreshPath) == "function"
    then
        self.ui.file_chooser:refreshPath()
    end
end

function Bridge:addToMainMenu(menu_items)
    menu_items.audiobooklibrarybridge = {
        text = _("Audiobook Library Bridge"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show unsupported files (required for audio)"),
                checked_func = function()
                    return unsupportedFilesVisible()
                end,
                callback = function()
                    self:setUnsupportedFilesVisible(
                        not unsupportedFilesVisible()
                    )
                end,
                keep_menu_open = true,
            },
            {
                text = _("About / setup status"),
                callback = function()
                    local ok_reader, ReaderUI =
                        pcall(require, "apps/reader/readerui")
                    local audiobook =
                        ok_reader
                        and findAudiobookPlugin(ReaderUI)
                        or nil

                    local status =
                        _("Audiobook Library Bridge")
                        .. "\n\n"
                        .. _("Audiobook Read-Along: ")
                        .. (
                            playerReady(audiobook)
                            and _("ready")
                            or _("not ready")
                        )
                        .. "\n"
                        .. _("Audio files visible: ")
                        .. (
                            unsupportedFilesVisible()
                            and _("yes")
                            or _("no")
                        )
                        .. "\n\n"
                        .. _(
                            "This bridge routes supported audio files to Audiobook "
                            .. "Read-Along and uses <book>.sdr/cover.jpg as optional "
                            .. "library artwork."
                        )

                    showMessage(status, 10)
                end,
                separator = true,
            },
            self.updater:getMenuItem(),
        },
    }
end

return Bridge
