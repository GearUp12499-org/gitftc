# verify a compatible version of PowerShell is installed
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "This script requires PowerShell 5.0 or later."
}

function New-TemporaryDirectory {
    $parent=[System.IO.Path]::GetTempPath()
    [string]$name=[System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path $parent -Name $name -ErrorAction Stop
}

$VERSION=2

function Clear-Line {
    Write-Host -NoNewline -ForegroundColor DarkGray -BackgroundColor Black ("`r" + (" " * $host.UI.RawUI.BufferSize.Width) + "`r")
}

function wred($text) {
    Write-Host $text -ForegroundColor Red
}
function wblu($text) {
    Write-Host $text -ForegroundColor Blue
}
function wgrn($text) {
    Write-Host $text -ForegroundColor Green
}
function wylw($text) {
    Write-Host $text -ForegroundColor Yellow
}
function wgry($text) {
    Write-Host $text -ForegroundColor DarkGray
}
function working($text) {
    Write-Host -N $text -ForegroundColor DarkGray
}

function usage {
    wred "Usage: gitftc [command]"
    wred "command: one of"
    wred "  status (or no command) - display status of system"
    wred "  deploy, d - write current version to connected device"
    wred "  delete - delete version data for this repo on connected device"
    wred "  checkout, c - checkout connected device's version of the code"
}

function is_connected {
    adb get-state 2>&1>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    } else {
        return $true
    }
}

function require_connection {
    if (!(is_connected)) {
        wred "X No device connected (required)"
        wblu "> Ensure the device is connected and ADB sees it (adb connect ...?)"
        throw "No device connected"
    } else {
        wgrn "  Device connected"
    }
}

function require_libraries {
    $missing=$false
    if (-not(Get-Command adb -ErrorAction SilentlyContinue)) {
        wylw "! missing ADB"
        $missing=$true
    }
    if (-not(Get-Command git -ErrorAction SilentlyContinue)) {
        wylw "! missing git"
        $missing=$true
    }
    if ($missing) {
        wred "X Aborting due to missing libraries"
        throw "Missing libraries"
    }
}

try {
    require_libraries
} catch {
    exit 1
}

$TEMPF=New-TemporaryDirectory
wgry "Using $TEMPF for temporary files"
# at this point, we have a temporary directory to work in
try {
    if (-not(git rev-parse --is-inside-work-tree 2> $null)) {
        wred "X Not in a Git repository"
        wblu "> cd to a Git repository then try again"
        throw "Not in a git repository"
    }
    $REPONAME=(git rev-list --max-parents=0 HEAD)
    $REPOROOT=(git rev-parse --show-toplevel)
    $HEAD_AT=(git rev-parse HEAD)

    function pulldown {
        working "  downloading files, please wait"
        adb pull "/sdcard/gitftc" "$TEMPF" > $null
        New-Item -Type Directory -Path "$TEMPF\gitftc" -Force > $null
        Clear-Line
    }

    function pushup {
        working "  uploading files, please wait"
        New-Item -Type Directory -Path "$TEMPF\gitftc" -Force > $null
        New-Item -Type File -Path "$TEMPF\gitftc\.placeholder" -Force > $null
        adb push "$TEMPF\gitftc" "/sdcard" > $null
        Clear-Line
    }

    function pushup_overwrite {
        working "  uploading files, please wait"
        New-Item -Type Directory -Path "$TEMPF\gitftc" -Force > $null
        adb shell "rm -rf /sdcard/gitftc"
        adb push "$TEMPF\gitftc" "/sdcard" > $null
        Clear-Line
    }

    function require_repometa() {
        if (-not(Test-Path "$TEMPF\gitftc\$REPONAME" -PathType Container)) {
            wred "X No version info for this repo found on this device."
            throw "No repometa file found"
        }
        if (-not(Test-Path "$TEMPF\gitftc\$REPONAME\state" -PathType Leaf)) {
            wred "X Corrupt version info (no state file?!)"
            throw "Corrupt repometa file"
        }
    }

    Clear-Line

    # no arguments or "status"
    if ($args.Length -lt 1) {
        $command="status"
    } else {
        $command=$args[0]
    }
    switch -Regex ($command) {
        "^status$" {
            if (is_connected) {
                wgrn "  Device connected"
                pulldown
                if (-not(Test-Path "$TEMPF\gitftc\$REPONAME" -PathType Container)) {
                    wylw "! No version info for this repo found on the device."
                    wblu "> 'gitftc deploy' to get started!"
                } else {
                    require_repometa
                    wgrn "  Device's version of this repo:"
                    working "... processing version info ..."
                    $REMOTE_DETAIL_FILE="$TEMPF\gitftc\$REPONAME\state"
                    $remote_state_content=Get-Content -Raw $REMOTE_DETAIL_FILE
                    $remote_state_content -match '(?m)^\[head\] (\S*)\r?\n?$' > $null
                    $REMOTE_HEAD=$Matches[1]

                    # do we have REMOTE_HEAD locally?
                    git rev-parse "$REMOTE_HEAD" 2>&1> $null
                    if ($LASTEXITCODE -eq 0) {
                        $REMOTE_HEAD_LOCAL=$true

                        $REMOTE_HEAD_COMMIT_MSG=(git log -1 --format=%s "$REMOTE_HEAD")
                    } else {
                        $REMOTE_HEAD_LOCAL=$false
                    }

                    if ($remote_state_content -match '(?m)^\[staged\] (\S*)\r?\n?$') {
                        $REMOTE_PATCH_FILE=$Matches[1]
                        $REMOTE_PATCH_FILE="$TEMPF\gitftc\$REPONAME\$REMOTE_PATCH_FILE"
                        $REMOTE_HAS_PATCH=$true
                    } else {
                        $REMOTE_HAS_PATCH=$false
                    }

                    $remote_state_content -match '(?m)^\[deploy_by\] (\S*)\r?\n?$' > $null
                    $DEPLOY_BY=$Matches[1]
                    if ($DEPLOY_BY -eq "") {
                        $DEPLOY_BY="unknown"
                    }

                    $remote_state_content -match '(?m)^\[deploy_at\] (\S*)\r?\n?$' > $null
                    $DEPLOY_AT=[int]$Matches[1]
                    # convert the Unix timestamp to a human-readable date
                    $deploy_at_timestamp=([datetimeoffset]'1970-01-01Z').AddSeconds($DEPLOY_AT).LocalDateTime
                    $DEPLOY_AT=(Get-Date -Date $deploy_at_timestamp -Format "ddd MMM dd HH:mm:ss yyyy").ToString()
                    Clear-Line

                    $short_hash=$REMOTE_HEAD.Substring(0, 7)

                    if ($REMOTE_HEAD_LOCAL) {
                        Write-Host -N -F Green "    Commit: $short_hash "
                        Write-Host -F Blue "'$REMOTE_HEAD_COMMIT_MSG'"
                    } else {
                        wylw "    Commit: $short_hash (not found! fetched recently?)"
                    }
                    if ($REMOTE_HAS_PATCH) {
                        $patchsize=( Get-Content $REMOTE_PATCH_FILE -Raw ).Length
                        Write-Host -N -F Green "      (Staged changes included: "
                        Write-Host -N -F Blue ("{0:N0}-byte" -f $patchsize)
                        Write-Host -F Green " patch)"
                    }
                    Write-Host -N -F Green "    Deployed: "
                    Write-Host -N -F Blue $DEPLOY_AT
                    Write-Host -N -F Green " by "
                    Write-Host -F Blue $DEPLOY_BY
                }
            } else {
                wylw "X No device connected"
            }
        }
        "^(deploy|d)$" {
            require_connection
            pulldown

            if (-not(Test-Path "$TEMPF\gitftc\$REPONAME" -PathType Container)) {
                wblu "> No version info for this repo found on the device."
                New-Item -Type Directory -Path "$TEMPF\gitftc\$REPONAME" -Force > $null
            }
            working "  Writing deployment info"
            Set-Content -Path "$TEMPF\gitftc\$REPONAME\state" -Value "gitftc:"
            function append($content) {
                Add-Content -Path "$TEMPF\gitftc\$REPONAME\state" -Value $content
            }
            append "[version] $VERSION"
            append "[head] $HEAD_AT"
            $timenow=([datetimeoffset] (Get-Date).ToUniversalTime()).ToUnixTimeSeconds()

            append "[deploy_at] $timenow"
            append "[deploy_by] $( git config user.name )"

            Clear-Line

            if ((git status --porcelain=v1).Length -gt 0) {
                working "  Generating patch for staged changes"
                git add "$REPOROOT" > $null
                git --no-pager diff --cached --no-color > "$TEMPF\gitftc\$REPONAME\temp.patch"
                Get-Content "$TEMPF\gitftc\$REPONAME\temp.patch" | Set-Content "$TEMPF\gitftc\$REPONAME\staged.patch" -Encoding UTF8
                Remove-Item "$TEMPF\gitftc\$REPONAME\temp.patch" -Force > $null
                append "[staged] staged.patch"
                Clear-Line
                $DIFFED=$true
            } else {
                $DIFFED=$false
            }

            pushup
            wgrn "  Deployment successful"
            if ($DIFFED) {
                wblu "  Deployed commit $($HEAD_AT.Substring(0, 7) ) + staged changes"
            } else {
                wblu "  Deployed commit $($HEAD_AT.Substring(0, 7) )"
            }
        }
        "^delete$" {
            require_connection
            pulldown
            working "  Cleaning up"
            if (Test-Path "$TEMPF\gitftc\$REPONAME" -PathType Container) {
                Remove-Item -Path "$TEMPF\gitftc\$REPONAME" -Recurse -Force
                Clear-Line
                pushup_overwrite
                wgrn "  Deleted deployed version data for this repository."
            } else {
                Clear-Line
                wylw "  Nothing to delete."
            }
        }
        "^(checkout|c)$" {
            require_connection
            pulldown
            require_repometa

            if ((git status --porcelain=v1).Length -gt 0) {
                wred "X You have uncommitted changes. Please commit or stash them before using checkout."
                throw "checkout with uncommited changes"
            }

            $REMOTE_DETAIL_FILE="$TEMPF\gitftc\$REPONAME\state"
            $remote_state_content=Get-Content -Raw $REMOTE_DETAIL_FILE
            $remote_state_content -match '(?m)^\[head\] (\S*)\r?\n?$' > $null
            $REMOTE_HEAD=$Matches[1]
            $short_hash=$REMOTE_HEAD.Substring(0, 7)

            git rev-parse "$REMOTE_HEAD" 2>&1> $null
            if ($LASTEXITCODE -eq 0) {
                $REMOTE_HEAD_LOCAL=$true
            } else {
                $REMOTE_HEAD_LOCAL=$false
                wylw "  X Commit $short_hash not found locally, which is required to checkout"
                throw "checkout without local copy of commit"
            }
            if ($remote_state_content -match '(?m)^\[staged\] (\S*)\r?\n?$') {
                $REMOTE_PATCH_FILE=$Matches[1]
                $REMOTE_PATCH_FILE="$TEMPF\gitftc\$REPONAME\$REMOTE_PATCH_FILE"
                $REMOTE_HAS_PATCH=$true
            } else {
                $REMOTE_HAS_PATCH=$false
            }
            Clear-Line
            working "  Checking out commit $short_hash"
            git checkout "$REMOTE_HEAD" --quiet > $null
            if ($REMOTE_HAS_PATCH) {
                Clear-Line
                working "  Applying patch..."
                git apply "$REMOTE_PATCH_FILE" 2>&1> $null
            }
            git add $REPOROOT >$null
            Clear-Line
            wgrn "  Checked out commit $short_hash successfully"
            wylw "! Detached HEAD - any commits you create will be discarded when you checkout a branch."
            wylw "! Create a new branch (git switch -c <new-branch-name>) to save your work here, if you want."
        }
        Default {
            wred "X Unknown command '$command'"
            usage
            throw "Unknown command"
        }
    }
} catch {
    Write-Host "fatal: $_" -ForegroundColor Red
    exit 1
} finally {
    Remove-Item -Recurse -Force $TEMPF
    Write-Host "Cleaned up temporary files" -ForegroundColor DarkGray
}
