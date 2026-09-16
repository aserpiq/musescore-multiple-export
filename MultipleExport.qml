import QtQuick 2.15
import QtQuick.Window 2.15
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    id: plugin

    title: "Multiple export"
    description: "Export the current score to multiple formats with optional per-format overrides."
    version: "1.0.0"
    requiresScore: true
    pluginType: "command"

    property color accentColor: palette.highlight
    property string statusMessage: ""

    property var exportOptions: ({})
    property string optionFormat: ""
    property string optionLabel: ""

    property bool mp3OverrideBitrate: false
    property int mp3Bitrate: 320

    property bool pngOverrideDpi: false
    property string pngDpi: "300"
    property bool pngTrim: false
    property string pngTrimMargin: "0"

    property bool svgTrim: false
    property string svgTrimMargin: "0"

    property var exportQueue: []
    property int exportQueueIndex: 0
    property int exportCompletedCount: 0
    property int exportTotalCount: 0

    property string exportBasePath: ""
    property string sourceScorePath: ""
    property string currentExportExt: ""
    property string currentExportTarget: ""

    property bool exportHadError: false
    property bool exportRunFinished: false
    property string exportErrorMessage: ""

    property string progressHeading: "Preparing export..."
    property string progressDetail: ""

    SystemPalette {
        id: palette
        colorGroup: SystemPalette.Active
    }

    QProcess { id: converterProcess }
    QProcess { id: pathResolverProcess }
    FileIO { id: outputCheck }

    ListModel {
        id: formatsModel

        ListElement { label: "PDF";      ext: "pdf";      isSelected: true }
        ListElement { label: "PNG";      ext: "png";      isSelected: false }
        ListElement { label: "SVG";      ext: "svg";      isSelected: false }

        ListElement { label: "MP3";      ext: "mp3";      isSelected: true }
        ListElement { label: "WAV";      ext: "wav";      isSelected: false }
        ListElement { label: "FLAC";     ext: "flac";     isSelected: false }
        ListElement { label: "OGG";      ext: "ogg";      isSelected: false }

        ListElement { label: "MIDI";     ext: "mid";      isSelected: true }
        ListElement { label: "MusicXML"; ext: "musicxml"; isSelected: true }
        ListElement { label: "MXL";      ext: "mxl";      isSelected: false }
        ListElement { label: "MEI";      ext: "mei";      isSelected: false }
        ListElement { label: "Braille";  ext: "brf";      isSelected: false }
    }

    function log(message) {
        console.log("[Multiple export] " + message);
    }

    function trim(value) {
        return String(value || "").replace(/^\s+|\s+$/g, "");
    }

    function normalizeDirectory(path) {
        var value = trim(path);

        if (value.length > 1) {
            var quoted =
                    (value.charAt(0) === '"' && value.charAt(value.length - 1) === '"') ||
                    (value.charAt(0) === "'" && value.charAt(value.length - 1) === "'");

            if (quoted)
                value = value.substring(1, value.length - 1);
        }

        value = value.replace(/\\/g, "/");
        value = value.replace(/^file:\/\/\//i, "");
        value = value.replace(/\/+$/g, "");

        return value;
    }

    function cleanFileName(name) {
        var value = trim(name);
        value = value.replace(/[\\\/:\*\?"<>|]/g, "_");
        value = value.replace(/[\. ]+$/g, "");
        return value || "score";
    }

    function contrastTextColor(colorValue) {
        var luma =
                0.299 * colorValue.r +
                0.587 * colorValue.g +
                0.114 * colorValue.b;

        return luma > 0.65 ? "#151515" : "#ffffff";
    }

    function formatLabelForExt(ext) {
        for (var i = 0; i < formatsModel.count; ++i) {
            if (formatsModel.get(i).ext === ext)
                return formatsModel.get(i).label;
        }

        return ext.toUpperCase();
    }

    function splitFormats(value) {
        var out = [];
        var bits = trim(value).split(",");

        for (var i = 0; i < bits.length; ++i) {
            var ext = trim(bits[i]).toLowerCase();
            if (ext)
                out.push(ext);
        }

        return out;
    }

    function loadFormats(saved) {
        var selected = splitFormats(saved);
        var defaults = ["pdf", "mp3", "mid", "musicxml"];

        for (var i = 0; i < formatsModel.count; ++i) {
            var ext = formatsModel.get(i).ext;
            var checked = selected.length
                    ? selected.indexOf(ext) !== -1
                    : defaults.indexOf(ext) !== -1;

            formatsModel.setProperty(i, "isSelected", checked);
        }
    }

    function selectedFormatsString() {
        var selected = [];

        for (var i = 0; i < formatsModel.count; ++i) {
            var item = formatsModel.get(i);
            if (item.isSelected)
                selected.push(item.ext);
        }

        return selected.join(",");
    }

    function setAllFormats(value) {
        for (var i = 0; i < formatsModel.count; ++i)
            formatsModel.setProperty(i, "isSelected", value);

        statusMessage = "";
    }

    function loadExportOptions(raw) {
        raw = trim(raw);

        if (!raw) {
            exportOptions = {};
            return;
        }

        try {
            exportOptions = JSON.parse(raw);
        } catch (e) {
            log("Could not read exportOptions metadata: " + e);
            exportOptions = {};
        }
    }

    function exportOptionsString() {
        try {
            return JSON.stringify(exportOptions || {});
        } catch (e) {
            log("Could not serialize export options: " + e);
            return "{}";
        }
    }

    function formatOptions(ext) {
        return exportOptions && exportOptions[ext] ? exportOptions[ext] : null;
    }

    function hasCustomOptions(ext) {
        var options = formatOptions(ext);

        if (!options)
            return false;

        for (var key in options)
            return true;

        return false;
    }

    function supportsExportOptions(ext) {
        return ext === "mp3" || ext === "png" || ext === "svg";
    }

    function setFormatOptions(ext, options) {
        var next = JSON.parse(JSON.stringify(exportOptions || {}));
        var hasValues = false;

        if (options) {
            for (var key in options) {
                hasValues = true;
                break;
            }
        }

        if (hasValues)
            next[ext] = options;
        else
            delete next[ext];

        // Assign a fresh object so the QML bindings notice the change.
        exportOptions = next;
    }

    function saveSettings(path, formats) {
        var oldPath = normalizeDirectory(curScore.metaTag("exportPath"));
        var oldFormats = trim(curScore.metaTag("exportFormats"));
        var oldOptions = trim(curScore.metaTag("exportOptions")) || "{}";
        var newOptions = exportOptionsString();

        if (oldPath === path &&
            oldFormats === formats &&
            oldOptions === newOptions) {
            return;
        }

        curScore.startCmd();
        curScore.setMetaTag("exportPath", path);
        curScore.setMetaTag("exportFormats", formats);
        curScore.setMetaTag("exportOptions", newOptions);
        curScore.endCmd();

        cmd("file-save");
    }

    function museScoreExecutable() {
        try {
            if (Qt.application &&
                Qt.application.arguments &&
                Qt.application.arguments.length > 0) {
                var exe = trim(Qt.application.arguments[0]);
                if (exe)
                    return exe;
            }
        } catch (e) {
            log("Could not read MuseScore executable path: " + e);
        }

        return "C:/Program Files/MuseScore 4/bin/MuseScore4.exe";
    }

    function resolveCurrentScorePath() {
        cmd("file-save");

        // MuseScore 4 does not expose Score.path to legacy plugins.
        // The save log is the only reliable path we have on Windows.
        var ps =
                "$ErrorActionPreference='Stop'; " +
                "$dir=Join-Path $env:LOCALAPPDATA 'MuseScore\\MuseScore4\\logs'; " +
                "$log=Get-ChildItem -LiteralPath $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1; " +
                "if(-not $log){exit 2}; " +
                "$m=Get-Content -LiteralPath $log.FullName -Tail 500 | " +
                "Select-String 'NotationProject::doSave \\| success save file: \"([^\"]+)\"' | Select-Object -Last 1; " +
                "if(-not $m){exit 3}; " +
                "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
                "Write-Output $m.Matches[0].Groups[1].Value;";

        try {
            pathResolverProcess.startWithArgs(
                "powershell.exe",
                [
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy", "Bypass",
                    "-Command", ps
                ]
            );
        } catch (e) {
            log("Could not start path resolver: " + e);
            return "";
        }

        if (!pathResolverProcess.waitForFinished(15000)) {
            log("Path resolver timed out.");
            return "";
        }

        var output = "";

        try {
            output = trim(String(pathResolverProcess.readAllStandardOutput()));
        } catch (e) {
            log("Could not read path resolver output: " + e);
            return "";
        }

        output = output.replace(/[\r\n]+/g, "");

        if (!output) {
            log("Could not resolve current score path.");
            return "";
        }

        return normalizeDirectory(output);
    }

    function outputExists(target, ext) {
        outputCheck.source = target;

        if (outputCheck.exists())
            return true;

        if (ext !== "png" && ext !== "svg")
            return false;

        var dot = target.lastIndexOf(".");
        var firstPage = dot >= 0
                ? target.substring(0, dot) + "-1" + target.substring(dot)
                : target + "-1";

        outputCheck.source = firstPage;
        return outputCheck.exists();
    }

    function converterArgs(target, ext, options, scorePath) {
        var args = [];

        if (ext === "mp3" && options && options.bitrate !== undefined) {
            args.push("-b");
            args.push(String(options.bitrate));
        }

        if (ext === "png" && options && options.dpi !== undefined) {
            args.push("-r");
            args.push(String(options.dpi));
        }

        if ((ext === "png" || ext === "svg") &&
            options &&
            options.trim === true) {
            var margin = parseInt(options.trimMargin || 0);

            if (isNaN(margin) || margin < 0)
                margin = 0;

            args.push("-T");
            args.push(String(margin));
        }

        args.push("-o");
        args.push(target);
        args.push(scorePath);

        return args;
    }

    function exportWithConverter(scorePath, target, ext) {
        var args = converterArgs(target, ext, formatOptions(ext), scorePath);

        log("Converter: " + JSON.stringify(args));

        try {
            converterProcess.startWithArgs(museScoreExecutable(), args);
        } catch (e) {
            log("Could not start MuseScore converter: " + e);
            return false;
        }

        if (!converterProcess.waitForFinished(600000)) {
            log("Converter timed out.");
            return false;
        }

        return outputExists(target, ext);
    }

    function needsConverter(ext) {
        return supportsExportOptions(ext) && hasCustomOptions(ext);
    }

    function prepareExportRun(path, formats) {
        exportQueue = splitFormats(formats);
        exportQueueIndex = 0;
        exportCompletedCount = 0;
        exportTotalCount = exportQueue.length;

        exportBasePath = path + "/" + cleanFileName(curScore.scoreName);
        sourceScorePath = "";

        exportHadError = false;
        exportRunFinished = false;
        exportErrorMessage = "";

        progressHeading = "Preparing export...";
        progressDetail =
                exportTotalCount +
                (exportTotalCount === 1 ? " format selected" : " formats selected");

        progressWindow.show();
        progressWindow.raise();
        progressWindow.requestActivate();

        prepareExportTimer.restart();
    }

    function prepareExportAfterPopup() {
        for (var i = 0; i < exportQueue.length; ++i) {
            if (!needsConverter(exportQueue[i]))
                continue;

            progressHeading = "Preparing custom export...";
            progressDetail = "Resolving the current score file";
            sourceScorePath = resolveCurrentScorePath();

            if (!sourceScorePath) {
                finishExportRun(
                    false,
                    "Could not resolve the current .mscz path for custom export options."
                );
                return;
            }

            break;
        }

        nextExportTimer.restart();
    }

    function beginCurrentExport() {
        if (exportQueueIndex >= exportQueue.length) {
            finishExportRun(!exportHadError, exportErrorMessage);
            return;
        }

        currentExportExt = exportQueue[exportQueueIndex];
        currentExportTarget = exportBasePath + "." + currentExportExt;

        var label = formatLabelForExt(currentExportExt);
        progressHeading = "Exporting " + label + "...";
        progressDetail =
                (exportQueueIndex + 1) +
                " of " + exportTotalCount +
                "  •  " + label;

        currentExportStartTimer.restart();
    }

    function performCurrentExport() {
        var ext = currentExportExt;
        var label = formatLabelForExt(ext);
        var ok;

        if (needsConverter(ext)) {
            progressDetail =
                    (exportQueueIndex + 1) +
                    " of " + exportTotalCount +
                    "  •  " + label +
                    "  •  Rendering audio/image";

            ok = exportWithConverter(
                sourceScorePath,
                currentExportTarget,
                ext
            );
        } else {
            ok = writeScore(curScore, currentExportTarget, ext);
        }

        completeCurrentExport(
            ok,
            ok ? "" : "Failed to export " + label + "."
        );
    }

    function completeCurrentExport(ok, message) {
        if (!ok) {
            exportHadError = true;

            if (!exportErrorMessage)
                exportErrorMessage = message;
        }

        exportCompletedCount++;
        exportQueueIndex++;

        if (exportQueueIndex >= exportQueue.length) {
            finishExportRun(!exportHadError, exportErrorMessage);
        } else {
            nextExportTimer.restart();
        }
    }

    function finishExportRun(ok, message) {
        exportRunFinished = true;

        if (ok) {
            progressHeading = "Export complete";
            progressDetail =
                    exportCompletedCount +
                    " of " + exportTotalCount +
                    " formats exported successfully.";

            finishCloseTimer.restart();
            return;
        }

        progressHeading = "Export finished with errors";
        progressDetail = message || "One or more formats could not be exported.";
    }

    function closeProgressAndQuit() {
        progressWindow.visible = false;
        plugin.quit();
    }

    function saveAndExport() {
        var path = normalizeDirectory(pathInput.text);
        var formats = selectedFormatsString();

        if (!path) {
            statusMessage = "Enter an export folder before continuing.";
            pathInput.forceActiveFocus();
            return;
        }

        if (!formats) {
            statusMessage = "Select at least one export format.";
            return;
        }

        saveSettings(path, formats);

        setupWindow.visible = false;
        prepareExportRun(path, formats);
    }

    function openFormatOptions(ext, label) {
        if (!supportsExportOptions(ext))
            return;

        optionFormat = ext;
        optionLabel = label;

        mp3OverrideBitrate = false;
        mp3Bitrate = 320;

        pngOverrideDpi = false;
        pngDpi = "300";
        pngTrim = false;
        pngTrimMargin = "0";

        svgTrim = false;
        svgTrimMargin = "0";

        optionsStatus.text = "";

        var options = formatOptions(ext);

        if (options) {
            if (ext === "mp3" && options.bitrate !== undefined) {
                mp3OverrideBitrate = true;
                mp3Bitrate = parseInt(options.bitrate);
            } else if (ext === "png") {
                if (options.dpi !== undefined) {
                    pngOverrideDpi = true;
                    pngDpi = String(options.dpi);
                }

                if (options.trim === true) {
                    pngTrim = true;
                    pngTrimMargin = String(options.trimMargin || 0);
                }
            } else if (ext === "svg" && options.trim === true) {
                svgTrim = true;
                svgTrimMargin = String(options.trimMargin || 0);
            }
        }

        optionsWindow.show();
        optionsWindow.raise();
        optionsWindow.requestActivate();
    }

    function applyFormatOptions() {
        var options = {};
        optionsStatus.text = "";

        if (optionFormat === "mp3") {
            if (mp3OverrideBitrate) {
                var validRates = [
                    32, 40, 48, 56, 64, 80, 96,
                    112, 128, 160, 192, 224, 256, 320
                ];

                var bitrate = parseInt(mp3Bitrate);

                if (validRates.indexOf(bitrate) === -1) {
                    optionsStatus.text = "Choose a valid MP3 bitrate.";
                    return;
                }

                options.bitrate = bitrate;
            }
        } else if (optionFormat === "png") {
            if (pngOverrideDpi) {
                var dpi = parseFloat(pngDpi);

                if (isNaN(dpi) || dpi <= 0 || dpi > 2400) {
                    optionsStatus.text = "PNG resolution must be between 1 and 2400 DPI.";
                    return;
                }

                options.dpi = dpi;
            }

            if (pngTrim) {
                var pngMargin = parseInt(pngTrimMargin);

                if (isNaN(pngMargin) || pngMargin < 0) {
                    optionsStatus.text = "Trim margin must be zero or greater.";
                    return;
                }

                options.trim = true;
                options.trimMargin = pngMargin;
            }
        } else if (optionFormat === "svg" && svgTrim) {
            var svgMargin = parseInt(svgTrimMargin);

            if (isNaN(svgMargin) || svgMargin < 0) {
                optionsStatus.text = "Trim margin must be zero or greater.";
                return;
            }

            options.trim = true;
            options.trimMargin = svgMargin;
        }

        setFormatOptions(optionFormat, options);
        optionsWindow.visible = false;
    }

    function useDefaultsForCurrentFormat() {
        setFormatOptions(optionFormat, null);
        optionsStatus.text = "";
        optionsWindow.visible = false;
    }

    function chooseMp3Bitrate(value) {
        mp3OverrideBitrate = true;
        mp3Bitrate = value;
        optionsStatus.text = "";
    }

    Timer {
        id: prepareExportTimer
        interval: 80
        repeat: false
        onTriggered: plugin.prepareExportAfterPopup()
    }

    Timer {
        id: nextExportTimer
        interval: 70
        repeat: false
        onTriggered: plugin.beginCurrentExport()
    }

    Timer {
        id: currentExportStartTimer
        interval: 70
        repeat: false
        onTriggered: plugin.performCurrentExport()
    }

    Timer {
        id: finishCloseTimer
        interval: 900
        repeat: false
        onTriggered: plugin.closeProgressAndQuit()
    }

    onRun: {
        if (!curScore) {
            log("No score is currently open.");
            quit();
            return;
        }

        var path = normalizeDirectory(curScore.metaTag("exportPath"));
        var formats = trim(curScore.metaTag("exportFormats"));
        var options = trim(curScore.metaTag("exportOptions"));

        pathInput.text = path;
        loadFormats(formats);
        loadExportOptions(options);

        statusMessage = "";

        setupWindow.show();
        setupWindow.raise();
        setupWindow.requestActivate();

        if (!pathInput.text)
            pathInput.forceActiveFocus();
    }

    Window {
        id: setupWindow

        width: 760
        height: 650
        minimumWidth: 760
        maximumWidth: 760
        minimumHeight: 650
        maximumHeight: 650

        visible: false
        title: "Multiple export"
        modality: Qt.ApplicationModal
        color: "#252525"

        onClosing: function(close) {
            close.accepted = true;
            setupWindow.visible = false;
            plugin.quit();
        }

        Rectangle {
            anchors.fill: parent
            color: "#252525"

            Text {
                x: 26
                y: 22
                text: "Multiple export"
                color: "white"
                font.pixelSize: 22
                font.bold: true
            }

            Text {
                x: 26
                y: 58
                width: parent.width - 52
                text: "Choose the destination folder, formats and optional per-format settings."
                color: "#cfcfcf"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            Text {
                x: 26
                y: 100
                text: "Export folder"
                color: "white"
                font.pixelSize: 14
                font.bold: true
            }

            Rectangle {
                id: inputBox
                x: 26
                y: 125
                width: parent.width - 52
                height: 40
                radius: 5
                color: "#ffffff"
                border.width: pathInput.activeFocus ? 2 : 1
                border.color: pathInput.activeFocus ? plugin.accentColor : "#888888"

                TextInput {
                    id: pathInput
                    anchors.fill: parent
                    anchors.leftMargin: 11
                    anchors.rightMargin: 11
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#111111"
                    font.pixelSize: 14
                    selectByMouse: true
                    clip: true
                }

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 11
                    verticalAlignment: Text.AlignVCenter
                    text: "Example: D:\\Music\\Project\\Exports"
                    color: "#888888"
                    font.pixelSize: 14
                    visible: pathInput.text.length === 0 && !pathInput.activeFocus
                }
            }

            Text {
                x: 26
                y: 190
                text: "Formats"
                color: "white"
                font.pixelSize: 14
                font.bold: true
            }

            Row {
                x: 26
                y: 220
                spacing: 28

                Column {
                    width: 340
                    spacing: 10

                    Text {
                        text: "Score and image"
                        color: "#b7b7b7"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Repeater {
                        model: 3
                        delegate: FormatCheck { modelIndex: index }
                    }

                    Item { width: 1; height: 8 }

                    Text {
                        text: "Audio"
                        color: "#b7b7b7"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Repeater {
                        model: 4
                        delegate: FormatCheck { modelIndex: index + 3 }
                    }
                }

                Column {
                    width: 340
                    spacing: 10

                    Text {
                        text: "Exchange and notation"
                        color: "#b7b7b7"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Repeater {
                        model: 5
                        delegate: FormatCheck { modelIndex: index + 7 }
                    }

                    Item { width: 1; height: 18 }

                    Row {
                        spacing: 10

                        Rectangle {
                            width: 112
                            height: 30
                            radius: 4
                            color: allMouse.pressed ? "#464646" : "#343434"
                            border.width: 1
                            border.color: "#606060"

                            Text {
                                anchors.centerIn: parent
                                text: "Select all"
                                color: "white"
                                font.pixelSize: 12
                            }

                            MouseArea {
                                id: allMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: plugin.setAllFormats(true)
                            }
                        }

                        Rectangle {
                            width: 112
                            height: 30
                            radius: 4
                            color: noneMouse.pressed ? "#464646" : "#343434"
                            border.width: 1
                            border.color: "#606060"

                            Text {
                                anchors.centerIn: parent
                                text: "Clear all"
                                color: "white"
                                font.pixelSize: 12
                            }

                            MouseArea {
                                id: noneMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: plugin.setAllFormats(false)
                            }
                        }
                    }
                }
            }

            Text {
                x: 26
                y: 545
                width: parent.width - 52
                height: 24
                text: plugin.statusMessage
                color: "#ffb0b0"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Rectangle {
                id: exportButton
                width: 160
                height: 38
                anchors.right: parent.right
                anchors.rightMargin: 26
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                radius: 5
                color: exportMouse.pressed
                       ? Qt.darker(plugin.accentColor, 1.18)
                       : plugin.accentColor

                Text {
                    anchors.centerIn: parent
                    text: "Export"
                    color: plugin.contrastTextColor(plugin.accentColor)
                    font.pixelSize: 13
                    font.bold: true
                }

                MouseArea {
                    id: exportMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: plugin.saveAndExport()
                }
            }

            Rectangle {
                id: cancelButton
                width: 96
                height: 38
                anchors.right: exportButton.left
                anchors.rightMargin: 12
                anchors.verticalCenter: exportButton.verticalCenter
                radius: 5
                color: cancelMouse.pressed ? "#454545" : "#393939"
                border.width: 1
                border.color: "#666666"

                Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: "white"
                    font.pixelSize: 13
                }

                MouseArea {
                    id: cancelMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        setupWindow.visible = false;
                        plugin.quit();
                    }
                }
            }
        }
    }

    Window {
        id: progressWindow

        width: 520
        height: 250
        minimumWidth: 520
        maximumWidth: 520
        minimumHeight: 250
        maximumHeight: 250

        visible: false
        title: "Multiple export"
        modality: Qt.ApplicationModal
        color: "#252525"

        onClosing: function(close) {
            // Synchronous writeScore() cannot be safely cancelled halfway.
            // Keep this window open while an export is active.
            if (!plugin.exportRunFinished) {
                close.accepted = false;
            } else {
                close.accepted = true;
                plugin.closeProgressAndQuit();
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#252525"

            Text {
                x: 28
                y: 28
                width: parent.width - 56
                text: plugin.progressHeading
                color: "white"
                font.pixelSize: 21
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                x: 28
                y: 68
                width: parent.width - 56
                text: plugin.progressDetail
                color: "#bdbdbd"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            Rectangle {
                id: progressTrack
                x: 28
                y: 120
                width: parent.width - 56
                height: 12
                radius: 6
                color: "#3a3a3a"

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: plugin.exportTotalCount > 0
                           ? parent.width * (plugin.exportCompletedCount / plugin.exportTotalCount)
                           : 0
                    color: plugin.accentColor

                    Behavior on width {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }

            Text {
                x: 28
                y: 148
                width: parent.width - 56
                text: plugin.exportTotalCount > 0
                      ? (plugin.exportCompletedCount + " / " + plugin.exportTotalCount)
                      : ""
                color: "#8f8f8f"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignRight
            }

            Rectangle {
                id: progressCloseButton
                width: 100
                height: 36
                anchors.right: parent.right
                anchors.rightMargin: 28
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 22
                radius: 5
                visible: plugin.exportRunFinished && plugin.exportHadError
                color: progressCloseMouse.pressed ? "#454545" : "#393939"
                border.width: 1
                border.color: "#666666"

                Text {
                    anchors.centerIn: parent
                    text: "Close"
                    color: "white"
                    font.pixelSize: 13
                }

                MouseArea {
                    id: progressCloseMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: plugin.closeProgressAndQuit()
                }
            }

            Text {
                x: 28
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 30
                width: parent.width - 170
                visible: !plugin.exportRunFinished
                text: "Please wait while MuseScore exports the selected formats."
                color: "#8f8f8f"
                font.pixelSize: 11
            }
        }
    }

    Window {
        id: optionsWindow

        width: 500
        height: 430
        minimumWidth: 500
        maximumWidth: 500
        minimumHeight: 430
        maximumHeight: 430

        visible: false
        title: optionLabel + " options"
        modality: Qt.ApplicationModal
        color: "#252525"

        onVisibleChanged: {
            if (visible)
                optionsStatus.text = "";
        }

        Rectangle {
            anchors.fill: parent
            color: "#252525"

            Text {
                x: 26
                y: 24
                text: optionLabel + " options"
                color: "white"
                font.pixelSize: 21
                font.bold: true
            }

            Text {
                x: 26
                y: 60
                width: parent.width - 52
                text: hasCustomOptions(optionFormat)
                      ? "Custom options are applied to this format."
                      : "No custom options are applied. MuseScore defaults will be used."
                color: "#bfbfbf"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            // ---------- MP3 ----------
            Item {
                x: 26
                y: 105
                width: parent.width - 52
                height: 220
                visible: optionFormat === "mp3"

                Text {
                    text: "Bitrate"
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }

                ToggleRow {
                    id: mp3OverrideToggle
                    y: 32
                    label: "Override MP3 bitrate"
                    checked: plugin.mp3OverrideBitrate
                    onToggled: function(checked) {
                        plugin.mp3OverrideBitrate = checked;
                        optionsStatus.text = "";
                    }
                }

                Text {
                    y: 76
                    text: "Quality (kbps)"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.mp3OverrideBitrate
                }

                Flow {
                    y: 100
                    width: parent.width
                    spacing: 7
                    visible: plugin.mp3OverrideBitrate

                    Repeater {
                        model: [96, 128, 160, 192, 224, 256, 320]

                        delegate: ChoiceButton {
                            label: String(modelData)
                            selected: plugin.mp3Bitrate === modelData
                            buttonWidth: 56
                            onChosen: plugin.chooseMp3Bitrate(modelData)
                        }
                    }
                }

                Text {
                    y: 152
                    width: parent.width
                    text: plugin.mp3OverrideBitrate
                          ? "Higher bitrates preserve more audio detail but create larger files."
                          : "The MP3 bitrate configured in MuseScore will be used."
                    color: "#a8a8a8"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }
            }

            // ---------- PNG ----------
            Item {
                x: 26
                y: 105
                width: parent.width - 52
                height: 245
                visible: optionFormat === "png"

                Text {
                    text: "Image settings"
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }

                ToggleRow {
                    id: pngDpiToggle
                    y: 32
                    label: "Override resolution"
                    checked: plugin.pngOverrideDpi
                    onToggled: function(checked) {
                        plugin.pngOverrideDpi = checked;
                        optionsStatus.text = "";
                    }
                }

                Text {
                    x: 240
                    y: 35
                    text: "DPI"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.pngOverrideDpi
                }

                Rectangle {
                    x: 275
                    y: 27
                    width: 90
                    height: 32
                    radius: 4
                    color: "white"
                    visible: plugin.pngOverrideDpi

                    TextInput {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        text: plugin.pngDpi
                        color: "#111111"
                        font.pixelSize: 13
                        selectByMouse: true
                        inputMethodHints: Qt.ImhFormattedNumbersOnly
                        onTextChanged: plugin.pngDpi = text
                    }
                }

                ToggleRow {
                    id: pngTrimToggle
                    y: 82
                    label: "Trim surrounding whitespace"
                    checked: plugin.pngTrim
                    onToggled: function(checked) {
                        plugin.pngTrim = checked;
                        optionsStatus.text = "";
                    }
                }

                Text {
                    x: 240
                    y: 85
                    text: "Margin"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.pngTrim
                }

                Rectangle {
                    x: 295
                    y: 77
                    width: 70
                    height: 32
                    radius: 4
                    color: "white"
                    visible: plugin.pngTrim

                    TextInput {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        text: plugin.pngTrimMargin
                        color: "#111111"
                        font.pixelSize: 13
                        selectByMouse: true
                        inputMethodHints: Qt.ImhDigitsOnly
                        onTextChanged: plugin.pngTrimMargin = text
                    }
                }

                Text {
                    x: 372
                    y: 85
                    text: "px"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.pngTrim
                }

                Text {
                    y: 135
                    width: parent.width
                    text: (!plugin.pngOverrideDpi && !plugin.pngTrim)
                          ? "MuseScore defaults will be used."
                          : "These overrides are applied only to this PNG export profile."
                    color: "#a8a8a8"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }
            }

            // ---------- SVG ----------
            Item {
                x: 26
                y: 105
                width: parent.width - 52
                height: 220
                visible: optionFormat === "svg"

                Text {
                    text: "SVG settings"
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }

                ToggleRow {
                    id: svgTrimToggle
                    y: 32
                    label: "Trim surrounding whitespace"
                    checked: plugin.svgTrim
                    onToggled: function(checked) {
                        plugin.svgTrim = checked;
                        optionsStatus.text = "";
                    }
                }

                Text {
                    x: 240
                    y: 35
                    text: "Margin"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.svgTrim
                }

                Rectangle {
                    x: 295
                    y: 27
                    width: 70
                    height: 32
                    radius: 4
                    color: "white"
                    visible: plugin.svgTrim

                    TextInput {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        text: plugin.svgTrimMargin
                        color: "#111111"
                        font.pixelSize: 13
                        selectByMouse: true
                        inputMethodHints: Qt.ImhDigitsOnly
                        onTextChanged: plugin.svgTrimMargin = text
                    }
                }

                Text {
                    x: 372
                    y: 35
                    text: "px"
                    color: "#b7b7b7"
                    font.pixelSize: 12
                    visible: plugin.svgTrim
                }

                Text {
                    y: 88
                    width: parent.width
                    text: plugin.svgTrim
                          ? "Trim is applied by MuseScore's converter."
                          : "MuseScore defaults will be used."
                    color: "#a8a8a8"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }
            }

            Text {
                id: optionsStatus
                x: 26
                y: 330
                width: parent.width - 52
                text: ""
                color: "#ffb0b0"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Rectangle {
                id: applyOptionsButton
                width: 112
                height: 36
                anchors.right: parent.right
                anchors.rightMargin: 26
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 22
                radius: 5
                color: applyOptionsMouse.pressed
                       ? Qt.darker(plugin.accentColor, 1.18)
                       : plugin.accentColor

                Text {
                    anchors.centerIn: parent
                    text: "Apply"
                    color: plugin.contrastTextColor(plugin.accentColor)
                    font.pixelSize: 13
                    font.bold: true
                }

                MouseArea {
                    id: applyOptionsMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: plugin.applyFormatOptions()
                }
            }

            Rectangle {
                id: defaultsButton
                width: 122
                height: 36
                anchors.right: applyOptionsButton.left
                anchors.rightMargin: 12
                anchors.verticalCenter: applyOptionsButton.verticalCenter
                radius: 5
                color: defaultsMouse.pressed ? "#454545" : "#393939"
                border.width: 1
                border.color: "#666666"

                Text {
                    anchors.centerIn: parent
                    text: "Use defaults"
                    color: "white"
                    font.pixelSize: 13
                }

                MouseArea {
                    id: defaultsMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: plugin.useDefaultsForCurrentFormat()
                }
            }

            Rectangle {
                width: 90
                height: 36
                anchors.right: defaultsButton.left
                anchors.rightMargin: 12
                anchors.verticalCenter: applyOptionsButton.verticalCenter
                radius: 5
                color: closeOptionsMouse.pressed ? "#454545" : "#393939"
                border.width: 1
                border.color: "#666666"

                Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: "white"
                    font.pixelSize: 13
                }

                MouseArea {
                    id: closeOptionsMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: optionsWindow.visible = false
                }
            }
        }
    }

    component FormatCheck: Item {
        id: formatRow

        property int modelIndex: 0
        property bool selected: formatsModel.get(modelIndex).isSelected
        property string formatExt: formatsModel.get(modelIndex).ext
        property string formatLabel: formatsModel.get(modelIndex).label
        property bool supportsOptions: plugin.supportsExportOptions(formatExt)

        width: 340
        height: 28

        Rectangle {
            id: box
            width: 18
            height: 18
            radius: 3
            x: 0
            anchors.verticalCenter: parent.verticalCenter

            color: formatRow.selected
                   ? plugin.accentColor
                   : "#2d2d2d"

            border.width: 1
            border.color: formatRow.selected
                          ? Qt.lighter(plugin.accentColor, 1.15)
                          : "#777777"

            Text {
                anchors.centerIn: parent
                text: "✓"
                visible: formatRow.selected
                color: plugin.contrastTextColor(plugin.accentColor)
                font.pixelSize: 14
                font.bold: true
            }
        }

        Text {
            x: 29
            width: 112
            anchors.verticalCenter: parent.verticalCenter
            text: formatRow.formatLabel
            color: "white"
            font.pixelSize: 13
            elide: Text.ElideRight
        }

        Rectangle {
            id: optionsButton
            x: 154
            width: 96
            height: 26
            anchors.verticalCenter: parent.verticalCenter
            radius: 4

            // Only MP3, PNG and SVG expose real per-export options.
            // The button is shown only while that format is selected.
            visible: formatRow.selected && formatRow.supportsOptions

            color: optionMouse.pressed
                   ? "#4a4a4a"
                   : (plugin.hasCustomOptions(formatRow.formatExt)
                      ? Qt.darker(plugin.accentColor, 1.25)
                      : "#353535")

            border.width: 1
            border.color: plugin.hasCustomOptions(formatRow.formatExt)
                          ? plugin.accentColor
                          : "#606060"

            Text {
                anchors.centerIn: parent
                text: "Options..."
                color: "white"
                font.pixelSize: 12
            }

            MouseArea {
                id: optionMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor

                onClicked: {
                    plugin.openFormatOptions(
                        formatRow.formatExt,
                        formatRow.formatLabel
                    );
                }
            }
        }

        Rectangle {
            width: 6
            height: 6
            radius: 3
            x: 258
            anchors.verticalCenter: parent.verticalCenter

            visible: formatRow.selected &&
                     formatRow.supportsOptions &&
                     plugin.hasCustomOptions(formatRow.formatExt)

            color: plugin.accentColor
        }

        MouseArea {
            x: 0
            y: 0
            width: 140
            height: parent.height
            cursorShape: Qt.PointingHandCursor

            onClicked: {
                formatsModel.setProperty(
                    formatRow.modelIndex,
                    "isSelected",
                    !formatRow.selected
                );

                plugin.statusMessage = "";
            }
        }
    }

    component ToggleRow: Item {
        property string label: ""
        property bool checked: false
        signal toggled(bool checked)

        width: 220
        height: 28

        Rectangle {
            id: toggleBox
            width: 18
            height: 18
            radius: 3
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            color: parent.checked ? plugin.accentColor : "#2d2d2d"
            border.width: 1
            border.color: parent.checked
                          ? Qt.lighter(plugin.accentColor, 1.15)
                          : "#777777"

            Text {
                anchors.centerIn: parent
                text: "✓"
                visible: toggleBox.parent.checked
                color: plugin.contrastTextColor(plugin.accentColor)
                font.pixelSize: 14
                font.bold: true
            }
        }

        Text {
            anchors.left: toggleBox.right
            anchors.leftMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            text: parent.label
            color: "white"
            font.pixelSize: 13
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.toggled(!parent.checked)
        }
    }

    component ChoiceButton: Rectangle {
        property string label: ""
        property bool selected: false
        property int buttonWidth: 60
        signal chosen()

        width: buttonWidth
        height: 30
        radius: 4

        color: selected
               ? plugin.accentColor
               : (choiceMouse.pressed ? "#484848" : "#343434")

        border.width: 1
        border.color: selected
                      ? Qt.lighter(plugin.accentColor, 1.15)
                      : "#606060"

        Text {
            anchors.centerIn: parent
            text: parent.label
            color: parent.selected
                   ? plugin.contrastTextColor(plugin.accentColor)
                   : "white"
            font.pixelSize: 12
            font.bold: parent.selected
        }

        MouseArea {
            id: choiceMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.chosen()
        }
    }
}
