# SAGE_PATH
$SAGE_PATH = git rev-parse --show-toplevel
$env:SAGE_PATH = $SAGE_PATH

# Log current pid
$PID | Out-File "launcher_pid.txt"

# Exit handler
function Cleanup {
    Write-Output "Terminating all spawned processes, browser processes, and any process from SAGE_PATH..."

    # Kills jobs spawned by this script
    Get-Job | Stop-Job -ErrorAction SilentlyContinue
    
    # Kills all child processes spawned by this script
    $parentId = [System.Diagnostics.Process]::GetCurrentProcess().Id
    Get-WmiObject Win32_Process | Where-Object { $_.ParentProcessId -eq $parentId } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # Explicitly kill processes started from SAGE_PATH
    Get-Process | Where-Object { $_.Path -like "*$SAGE_PATH*" } | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Output "Done!"
    Remove-Item "launcher_pid.txt"
}

try {
    # Fuzzer configuraitions
    $env:PRINT_TIME = $true
    $env:USE_INVALID_TREE = $true
    $env:COLLECT_TREE_INFO = $true
    $env:NO_XVFB = $true
    $env:INVALID_TREE_PATH = "$SAGE_PATH\invalid_tree\invalid_tree.pickle"
    $env:RULE_INFO_PATH = "$SAGE_PATH\invalid_tree\global_info.pickle"

    # Logging configurations
    $GENERAL_OUTPUT_DIR = "$SAGE_PATH\output"
    $LOG_FILE = "$GENERAL_OUTPUT_DIR\main.log"
    if (-not $LOG_SIZE_LIMIT) { $LOG_SIZE_LIMIT = 500 }
    $USE_LOLCAT = $true
    if (-not (Test-Path -Path $GENERAL_OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $GENERAL_OUTPUT_DIR | Out-Null
    }

    # Browser Paths
    # $env:CHROMIUM_PATH = "$SAGE_PATH\browser_bins\chrome-asan\chrome"
    # $env:CHROMEDRIVER_PATH = "$SAGE_PATH\browser_bins\chromedriver"
    $env:CHROMIUM_PATH = "C:\Users\oseo1\works\SaGe-Browser-Fuzzer\browser_bins\chrome-win64\chrome-win64\chrome.exe"
    $env:CHROMEDRIVER_PATH = "C:\Users\oseo1\works\SaGe-Browser-Fuzzer\browser_bins\chromedriver-win64\chromedriver-win64\chromedriver.exe"
    $env:FIREFOX_PATH = "$SAGE_PATH\browser_bins\firefox-asan\firefox"
    $env:FIREFOXDRIVER_PATH = "$SAGE_PATH\browser_bins\firefox-asan\geckodriver"
    $env:WEBKIT_BINARY_PATH = "$SAGE_PATH\browser_bins\webkit\MiniBrowser"
    $env:WEBKIT_WEBDRIVER_PATH = "$SAGE_PATH\browser_bins\webkit\WebKitWebDriver"

    # Browser Configurations
    $env:WEBKIT_DISABLE_COMPOSITING_MODE = 1

    # Command line arguments
    $FUZZER = "sage"
    $BROWSER_INSTANCES = @{}
    $KILL_OLD = $false
    # $valid_fuzzers = @("domato", "minerva", "freedom", "sage", "favocado")
    $valid_fuzzers = @("domato", "sage")
    $argsCount = $args.Length
    $i = 0

    while ($i -lt $argsCount) {
        switch -Wildcard ($args[$i]) {
            { $_ -in '--firefox', '--webkitgtk', '--chromium' } {
                $BROWSER = $args[$i].TrimStart('-')
                if (($i + 1) -lt $args.Length -and ($args[$i + 1] -match '^\d+$')) {
                    $BROWSER_INSTANCES[$BROWSER] = [int]$args[$i + 1]
                    $i += 2
                } else {
                    Write-Output "Error: Expected a number of instances after $($args[$i])"
                    Exit 1
                }
            }
            '--fuzzer' {
                if (($i + 1) -lt $argsCount -and ($valid_fuzzers -contains $args[$i + 1])) {
                    $FUZZER = $args[$i + 1]
                    $i += 2
                } else {
                    Write-Output "Error: Unsupported fuzzer. Supported fuzzers are domato, minerva, freedom, sage, and favocado."
                    Exit 1
                }
            }
            '--kill-old' {
                $KILL_OLD = $true
                $i += 1
            }
            default {
                Write-Output "Error: Unsupported option: $($args[$i])"
                Exit 1
            }
        }
    }

    # Background job: log trimming
    function Trim-LogFile {
        $maxSize = $using:LOG_SIZE_LIMIT * 1MB # Convert MB to bytes
        while ($true) {
            try {
                $fileSize = (Get-Item $using:LOG_FILE).Length
            } catch {
                $fileSize = 0
            }
            if ($fileSize -gt $maxSize) {
                Write-Output "Trimming $using:LOG_FILE (size: $fileSize, limit: $maxSize)"
                Get-Content -Path $using:LOG_FILE -Encoding Byte -Tail $maxSize | Set-Content -Path "$using:LOG_FILE.tmp" -Encoding Byte
                if ((Get-Item "$using:LOG_FILE.tmp").Length -gt 0) {
                    Move-Item -Path "$using:LOG_FILE.tmp" -Destination $using:LOG_FILE -Force
                } else {
                    Write-Output "Temporary file not created or is empty, skipping move operation."
                }
            }
            Start-Sleep -Seconds 60 # Check every 60 seconds
        }
    }
    Start-Job -ScriptBlock { Trim-LogFile }

    # --kill-old: kills old processes from SAGE_PATH
    function Kill-OldProcesses {
        Write-Output  "Killing old processes started from $SAGE_PATH..."
        Get-Process | Where-Object { $_.Path -like "*$SAGE_PATH*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Function to generate a unique output directory
    function Generate-UniqueOutputDir {
        param (
            [string]$BrowserName
        )

        $datetime = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
        $uid = [guid]::NewGuid().ToString().Split('-')[0] # Generates a short UID
        $output_dir = "$GENERAL_OUTPUT_DIR\$BrowserName\$datetime-$uid"
        
        return $output_dir
    }

    echo "SAGE_PATH: $SAGE_PATH"
    echo "FUZZER: $FUZZER"
    echo "BROSWER: $BROWSER"
    echo "BROWSER_INSTANCES: $($BROWSER_INSTANCES | Out-String)"
    echo "KILL_OLD: $KILL_OLD"
    echo "GENERAL_OUTPUT_DIR: $GENERAL_OUTPUT_DIR"
    echo "LOG_FILE: $LOG_FILE"

    ########################################################################

    echo "Launching..."

    # If --kill-old was specified, kill old processes
    if ($KILL_OLD -eq $true) {
        Kill-OldProcesses
    }

    # Start fuzzing sessions with unique output directories
    foreach ($BROWSER in $BROWSER_INSTANCES.Keys) {
        $NUM_INSTANCES = $BROWSER_INSTANCES[$BROWSER]
        
        # Generate a unique output directory for this session
        $PYTHON_OUTPUT_DIR = Generate-UniqueOutputDir -BrowserName $BROWSER
        if (-not (Test-Path -Path $PYTHON_OUTPUT_DIR)) {
            New-Item -ItemType Directory -Path $PYTHON_OUTPUT_DIR | Out-Null
        }
        echo "PYTHON_OUTPUT_DIR: $PYTHON_OUTPUT_DIR"
        
        # Record the start time and write it to a file
        Set-Content -Path "$PYTHON_OUTPUT_DIR\start_time.txt" -Value (Get-Date -UFormat %s)

        # Start main.py with specified parameters and redirect output to both the log file and terminal
        $command = "python $SAGE_PATH\main.py -t 50000 -b $BROWSER -p $NUM_INSTANCES --fuzzer $FUZZER -o $PYTHON_OUTPUT_DIR 2>&1 | Tee-Object -FilePath $LOG_FILE"
        echo "Will execute this command in background:"
        echo "    $command"
        Invoke-Expression -Command $command
        # Start-Job -ScriptBlock {
        # }
    }

    # Wait for all background processes to finish
    # Get-Job | Wait-Job
} finally {
    Cleanup
}