--[[--
Audiobook Library Bridge for KOReader

Routes audio files selected in KOReader's file browser to the Audiobook
Read-Along plugin and exposes optional sidecar cover art to library UIs that
use KOReader's BookInfoManager.

This plugin does not play audio itself.
--]]

local FileChooser = require("ui/widget/filechooser")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

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

local function unsupportedFilesVisible()
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

    local ok_render, RenderImage = pcall(require, "ui/renderimage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_util, util = pcall(require, "util")
    if not (ok_render and ok_lfs and ok_util) then
        logger.warn("audiobooklibrarybridge: cover dependencies unavailable")
        return false
    end

    local orig_getBookInfo = BookInfoManager.getBookInfo

    function BookInfoManager:getBookInfo(filepath, ...)
        -- Start from KOReader/SimpleUI's normal result so new fields added by
        -- future versions are preserved instead of being reimplemented here.
        local bookinfo = orig_getBookInfo(self, filepath, ...)
        local get_cover = select(1, ...)

        if not (get_cover and isAudioFile(filepath)) then
            return bookinfo
        end

        local cover_path = sidecarCoverPath(filepath)
        if not cover_path
                or lfs.attributes(cover_path, "mode") ~= "file"
        then
            return bookinfo
        end

        -- Return a fresh buffer for every BookInfoManager request.
        -- Stock CoverBrowser may explicitly free the returned cover_bb, while
        -- SimpleUI may retain it. Sharing one decoded buffer across callers
        -- would therefore risk handing a later screen an already-freed buffer.
        local cover_bb = RenderImage:renderImageFile(
            cover_path,
            false
        )

        if not cover_bb then
            return bookinfo
        end

        local directory, filename =
            util.splitFilePathName(filepath)

        bookinfo = bookinfo or {}
        bookinfo.directory = bookinfo.directory or directory
        bookinfo.filename = bookinfo.filename or filename
        bookinfo.in_progress = bookinfo.in_progress or 0
        bookinfo.cover_fetched = "Y"
        bookinfo.has_cover = true
        bookinfo.ignore_cover = nil
        bookinfo.cover_w = cover_bb:getWidth()
        bookinfo.cover_h = cover_bb:getHeight()
        bookinfo.cover_bb = cover_bb
        bookinfo.cover_sizetag =
            bookinfo.cover_w .. "x" .. bookinfo.cover_h
        bookinfo._is_directory = false
        bookinfo._no_provider = true

        -- Audio is intentionally not registered with DocumentRegistry as a
        -- document type, so leave text-metadata extraction disabled.
        bookinfo.has_meta = bookinfo.has_meta or nil
        bookinfo.ignore_meta = "Y"

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

    local ok_reader, ReaderUI =
        pcall(require, "apps/reader/readerui")
    if not ok_reader or not ReaderUI then
        logger.warn("audiobooklibrarybridge: ReaderUI not available")
        return
    end

    -- FileManager and ReaderUI recreate plugin instances. Patch the ReaderUI
    -- class only once per KOReader process.
    if ReaderUI._audiobook_bridge_patched then return end
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

function Bridge:setUnsupportedFilesVisible(enabled)
    enabled = enabled and true or false

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
            },
        },
    }
end

return Bridge
