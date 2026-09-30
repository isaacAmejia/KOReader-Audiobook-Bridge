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
    local ext = path:match("%.([^./]+)$")
    return ext and ext:lower() or nil
end

local function isAudioFile(path)
    local ext = getExtension(path)
    return ext and AUDIO_EXTS[ext] or false
end

local function unsupportedFilesVisible()
    return G_reader_settings
        and G_reader_settings:readSetting("show_unsupported") == true
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
    -- FileManager is normally active when a library item is tapped.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    local audiobook = fm and fm.audiobook

    -- Fall back to ReaderUI for workflows invoked while a book is open.
    if not audiobook and ReaderUI then
        local reader = ReaderUI.instance
        audiobook = reader and reader.audiobook
    end

    return audiobook
end

local function sidecarCoverPath(filepath)
    if not isAudioFile(filepath) then return nil end
    local stem = filepath:gsub("%.[^./]+$", "")
    return stem .. ".sdr/cover.jpg"
end

local function installSidecarCoverProvider()
    -- BookInfoManager is part of KOReader's library/cover stack. Playback
    -- routing remains functional if this optional integration is unavailable.
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.getBookInfo) ~= "function" then
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
    if not (ok_render and ok_lfs) then
        logger.warn("audiobooklibrarybridge: cover dependencies unavailable")
        return false
    end

    local orig_getBookInfo = BookInfoManager.getBookInfo

    function BookInfoManager:getBookInfo(filepath, ...)
        local get_cover = select(1, ...)

        if get_cover and isAudioFile(filepath) then
            local cover_path = sidecarCoverPath(filepath)

            if cover_path and lfs.attributes(cover_path, "mode") == "file" then
                local cover_bb = RenderImage:renderImageFile(cover_path)

                if cover_bb then
                    local directory, filename =
                        require("util").splitFilePathName(filepath)
                    local cover_w = cover_bb:getWidth()
                    local cover_h = cover_bb:getHeight()

                    return {
                        directory = directory,
                        filename = filename,
                        in_progress = 0,
                        cover_fetched = "Y",
                        has_meta = nil,
                        has_cover = true,
                        ignore_meta = "Y",
                        ignore_cover = nil,
                        cover_w = cover_w,
                        cover_h = cover_h,
                        cover_bb = cover_bb,
                        cover_sizetag = cover_w .. "x" .. cover_h,
                        _is_directory = false,
                        _no_provider = true,
                    }
                end
            end
        end

        return orig_getBookInfo(self, filepath, ...)
    end

    BookInfoManager._audiobook_bridge_cover_patched = true
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

    pcall(installSidecarCoverProvider)

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_reader or not ReaderUI then
        logger.warn("audiobooklibrarybridge: ReaderUI not available")
        return
    end

    -- FileManager and ReaderUI can recreate plugin instances. Patch the
    -- ReaderUI class only once per KOReader session.
    if ReaderUI._audiobook_bridge_patched then return end
    ReaderUI._audiobook_bridge_patched = true

    local orig_showReader = ReaderUI.showReader

    ReaderUI.showReader = function(cls, file, provider, seamless, ...)
        if isAudioFile(file) then
            local audiobook = findAudiobookPlugin(ReaderUI)

            if playerReady(audiobook) then
                -- Audiobook Read-Along owns the platform-specific audio
                -- readiness checks (Bluetooth/output setup, where needed).
                if type(audiobook._audioOutputReady) == "function" then
                    local ok_ready, ready = pcall(
                        audiobook._audioOutputReady,
                        audiobook
                    )
                    if ok_ready and not ready then
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

        return orig_showReader(cls, file, provider, seamless, ...)
    end
end

function Bridge:addToMainMenu(menu_items)
    menu_items.audiobooklibrarybridge = {
        text = _("Audiobook Library Bridge"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return unsupportedFilesVisible()
                        and _("Audio files in library: visible")
                        or _("Audio files in library: hidden")
                end,
                callback = function()
                    if unsupportedFilesVisible() then
                        showMessage(
                            _("Audio files are visible in KOReader's file browser."),
                            4
                        )
                    else
                        showMessage(_(
                            "Audio files are currently hidden.\n\n"
                            .. "Enable KOReader's 'Show unsupported files' setting, "
                            .. "then refresh the file browser."
                        ), 7)
                    end
                end,
            },
            {
                text = _("About / setup status"),
                callback = function()
                    local ok_reader, ReaderUI =
                        pcall(require, "apps/reader/readerui")
                    local audiobook =
                        ok_reader and findAudiobookPlugin(ReaderUI) or nil

                    local status = _("Audiobook Library Bridge") .. "\n\n"
                        .. _("Audiobook Read-Along: ")
                        .. (playerReady(audiobook) and _("ready") or _("not ready"))
                        .. "\n"
                        .. _("Audio files visible: ")
                        .. (unsupportedFilesVisible() and _("yes") or _("no"))
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
