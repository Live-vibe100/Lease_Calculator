<#
.SYNOPSIS
    Opens the real Lease Calculator window and clicks through it like a person would.
.DESCRIPTION
    Types into fields, presses the buttons, closes any message boxes, and checks the
    results, the auto-filled fields, and which fields turn red. Uses only what's built
    into Windows (UI Automation + standard window messages) - nothing to install.

    Needs a normal desktop session. Takes about 30 seconds; best not to click around
    in the Lease Calculator window while it runs. The window is closed when it's done.

        powershell -ExecutionPolicy Bypass -File ".\Lease Calculator\Tests\Test-LeaseWindow.ps1"

    Prints PASS/FAIL per check and exits with code 1 if anything failed.
.PARAMETER ScreenshotFolder
    Optional. Saves screenshots of the empty, filled-in, and all-red window there.
#>
param([string]$ScreenshotFolder)

$appPath = Join-Path $PSScriptRoot '..\LeaseCalculator.ps1'
. (Join-Path $PSScriptRoot '..\LeaseMath.ps1')

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Namespace LeaseWindowTest -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, System.Text.StringBuilder l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$anything = [System.Windows.Automation.Condition]::TrueCondition
$WM_SETTEXT = 0x000C; $WM_GETTEXT = 0x000D; $BM_CLICK = 0x00F5

# The app's text boxes in the order it creates them
$fieldOrder = 'MSRP', 'CapCost', 'Fees', 'CapReduction', 'DownPayment', 'ResidualValue', 'ResidualPercent', 'MoneyFactor', 'APR', 'Term', 'Tax'
$script:edits = $null
$script:results = @()

# =============================
# HELPERS
# =============================

function Assert-Check {
    <# .SYNOPSIS Records and prints one PASS/FAIL line. #>
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:results += [pscustomobject]@{ Ok = $Ok; Name = $Name }
    if ($Ok) { Write-Host "PASS  $Name  $Detail" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red }
}

function Start-App {
    <# .SYNOPSIS Launches the calculator and waits for its window. #>
    $p = Start-Process powershell.exe -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$appPath`""
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    for ($i = 0; $i -lt 150; $i++) {
        $w = $AE::RootElement.FindFirst($TS::Children, $cond)
        if ($w) { return @{ Proc = $p; Win = $w } }
        Start-Sleep -Milliseconds 100
    }
    Stop-Process -Id $p.Id -ErrorAction SilentlyContinue
    throw "The Lease Calculator window never appeared."
}

function Get-Edit {
    <# .SYNOPSIS Finds a text box by its field name (e.g. 'MSRP'). #>
    param($Win, [string]$Id)
    if ($null -eq $script:edits) {
        $script:edits = @($Win.FindAll($TS::Descendants, $anything) | Where-Object { $_.Current.ClassName -like 'WindowsForms10.EDIT*' })
        if ($script:edits.Count -ne $fieldOrder.Count) { throw "Expected $($fieldOrder.Count) text boxes, found $($script:edits.Count)." }
    }
    $i = [array]::IndexOf($fieldOrder, $Id)
    if ($i -lt 0) { throw "No field named '$Id'." }
    return $script:edits[$i]
}

function Get-ByName {
    <# .SYNOPSIS Finds a control (button, label) by its visible text. #>
    param($Parent, [string]$Name)
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)
    return $Parent.FindFirst($TS::Descendants, $c)
}

function Set-RealFocus {
    <# .SYNOPSIS Gives a control real keyboard focus, so the app gets genuine GotFocus/LostFocus events. #>
    param([IntPtr]$Hwnd)
    $me = [LeaseWindowTest.Win]::GetCurrentThreadId()
    $them = [LeaseWindowTest.Win]::GetWindowThreadProcessId($Hwnd, [IntPtr]::Zero)
    [void][LeaseWindowTest.Win]::AttachThreadInput($me, $them, $true)
    [void][LeaseWindowTest.Win]::SetFocus($Hwnd)
    [void][LeaseWindowTest.Win]::AttachThreadInput($me, $them, $false)
}

function Set-Field {
    <# .SYNOPSIS Clicks into a field and replaces its text. #>
    param($Win, [string]$Id, [string]$Text)
    $h = [IntPtr](Get-Edit $Win $Id).Current.NativeWindowHandle
    Set-RealFocus $h
    Start-Sleep -Milliseconds 40
    [void][LeaseWindowTest.Win]::SendMessage($h, $WM_SETTEXT, [IntPtr]::Zero, $Text)
    Start-Sleep -Milliseconds 40
}

function Get-Field {
    <# .SYNOPSIS Reads a field's current text. #>
    param($Win, [string]$Id)
    $sb = New-Object System.Text.StringBuilder 256
    [void][LeaseWindowTest.Win]::SendMessage([IntPtr](Get-Edit $Win $Id).Current.NativeWindowHandle, $WM_GETTEXT, [IntPtr]256, $sb)
    return $sb.ToString()
}

function Move-FieldFocus {
    <# .SYNOPSIS Moves focus to another field, which fires LostFocus on the current one. #>
    param($Win, [string]$ToId = 'MSRP')
    Set-RealFocus ([IntPtr](Get-Edit $Win $ToId).Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 60
}

function Invoke-Button {
    <# .SYNOPSIS Clicks a button without waiting, so a message box it opens can't stall the test. #>
    param($Win, [string]$ButtonName)
    $b = Get-ByName $Win $ButtonName
    [void][LeaseWindowTest.Win]::PostMessage([IntPtr]$b.Current.NativeWindowHandle, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

function Get-ResultText {
    <# .SYNOPSIS Reads the results panel text. #>
    param($Win)
    foreach ($t in $Win.FindAll($TS::Descendants, $anything)) {
        $n = $t.Current.Name
        if ($n -like 'Net Capitalized Cost*' -or $n -eq 'Results will appear here') { return $n }
    }
    return $null
}

function Close-MessageBox {
    <# .SYNOPSIS Closes the app's open message box (clicks OK). Returns @{Title; Text}, or $null if none. #>
    param($Proc)
    $cond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $Proc.Id)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')))
    $box = $AE::RootElement.FindFirst($TS::Descendants, $cond)
    if (-not $box) { return $null }
    $text = ($box.FindAll($TS::Descendants, $anything) | ForEach-Object { $_.Current.Name }) -join ' '
    $info = @{ Title = $box.Current.Name; Text = $text }
    $ok = Get-ByName $box 'OK'
    [void][LeaseWindowTest.Win]::PostMessage([IntPtr]$ok.Current.NativeWindowHandle, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    return $info
}

function Get-WindowImage {
    <# .SYNOPSIS Captures the window as a bitmap (works even if other windows cover it). Caller disposes Bmp. #>
    param($Win)
    $h = [IntPtr]$Win.Current.NativeWindowHandle
    $r = New-Object LeaseWindowTest.Win+RECT
    [void][LeaseWindowTest.Win]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap(($r.Right - $r.Left), ($r.Bottom - $r.Top))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][LeaseWindowTest.Win]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    return @{ Bmp = $bmp; Rect = $r }
}

function Save-Screenshot {
    <# .SYNOPSIS Saves a screenshot if -ScreenshotFolder was given. #>
    param($Win, [string]$FileName)
    if (-not $ScreenshotFolder) { return }
    New-Item -ItemType Directory -Force $ScreenshotFolder | Out-Null
    $shot = Get-WindowImage $Win
    $shot.Bmp.Save((Join-Path $ScreenshotFolder $FileName), [System.Drawing.Imaging.ImageFormat]::Png)
    $shot.Bmp.Dispose()
}

function Test-FieldRed {
    <# .SYNOPSIS True if the text box is drawn with the red "invalid" background. #>
    param($Win, [string]$Id)
    $shot = Get-WindowImage $Win
    $b = (Get-Edit $Win $Id).Current.BoundingRectangle
    # Sample the empty right-hand side of the box, away from any text
    $x = [int]($b.Right - $shot.Rect.Left - 6)
    $y = [int]($b.Top - $shot.Rect.Top + $b.Height / 2)
    $px = $shot.Bmp.GetPixel($x, $y)
    $shot.Bmp.Dispose()
    return ($px.R -eq 255 -and $px.G -eq 230 -and $px.B -eq 230)
}

# =============================
# THE CLICK-THROUGH
# =============================

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$app = Start-App
$w = $app.Win

try {
    Assert-Check "Window opened" $true ("{0:N1}s to appear" -f $sw.Elapsed.TotalSeconds)

    $shot = Get-WindowImage $w
    $width = $shot.Rect.Right - $shot.Rect.Left; $height = $shot.Rect.Bottom - $shot.Rect.Top
    $shot.Bmp.Dispose()
    # Convert to its size at 100% scaling, so this check works at any display scaling
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]$w.Current.NativeWindowHandle)
    $scale = $g.DpiX / 96; $g.Dispose()
    $baseWidth = [int]($width / $scale); $baseHeight = [int]($height / $scale)
    Assert-Check "Window fits a 1366x728 laptop screen (at 100%)" ($baseWidth -le 1366 -and $baseHeight -le 728) "${baseWidth}x${baseHeight} at 100%, ${width}x${height} at $([int]($scale * 100))%"
    Add-Type -AssemblyName System.Windows.Forms
    $workArea = [System.Windows.Forms.Screen]::FromHandle([IntPtr]$w.Current.NativeWindowHandle).WorkingArea
    Assert-Check "Window fits on this screen" ($width -le $workArea.Width -and $height -le $workArea.Height) "screen work area $($workArea.Width)x$($workArea.Height)"
    Assert-Check "Text boxes found in the expected order" ((Get-Field $w CapCost) -eq 'e.g. 33000.00' -and (Get-Field $w ResidualPercent) -eq 'e.g. 65' -and (Get-Field $w Tax) -eq 'e.g. 5.9')
    Save-Screenshot $w 'empty.png'

    function Set-BaseDeal {
        <# .SYNOPSIS Resets, then fills in the example deal (everything but residual and rate). #>
        Invoke-Button $w 'Reset All'
        Set-Field $w MSRP '35000'
        Set-Field $w CapCost '33000'
        Set-Field $w Fees '895'
        Set-Field $w CapReduction '2000'
        Set-Field $w DownPayment '1500'
        Set-Field $w Term '36'
        Set-Field $w Tax '5.9'
    }

    # --- 1. The example deal: residual by %, rate by APR (hand-checked: $326.20/mo, $13,243.03 total) ---
    Set-BaseDeal
    Set-Field $w ResidualPercent '65'
    Set-Field $w APR '4.32'
    Move-FieldFocus $w
    Assert-Check "1: Residual % fills in Residual `$" ((Get-Field $w ResidualValue) -eq '22750.00') (Get-Field $w ResidualValue)
    Assert-Check "1: APR fills in Money Factor" ((Get-Field $w MoneyFactor) -eq '0.00180') (Get-Field $w MoneyFactor)
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    $r = Get-ResultText $w
    Assert-Check "1: no error message" ($null -eq $box) "$($box.Text)"
    Assert-Check "1: monthly with tax is `$326.20" ($r -match 'with tax\):\s+\$326\.20')
    Assert-Check "1: total lease cost is `$13,243.03" ($r -match 'Total Lease Cost:\s+\$13,243\.03')
    Save-Screenshot $w 'result.png'

    # --- 2. A typed residual $ is used exactly (the old version used $22,500.36) ---
    Invoke-Button $w 'Reset All'
    Set-Field $w MSRP '37345'
    Set-Field $w CapCost '33000'
    Set-Field $w ResidualValue '22500'
    Set-Field $w MoneyFactor '0.0018'
    Set-Field $w Term '36'
    Set-Field $w Tax '5.9'
    Move-FieldFocus $w
    Assert-Check "2: Residual % filled in as 60.25" ((Get-Field $w ResidualPercent) -eq '60.25') (Get-Field $w ResidualPercent)
    Invoke-Button $w 'Calculate Lease'
    [void](Close-MessageBox $app.Proc)
    $r = Get-ResultText $w
    $expected = (Get-LeasePayment -CapCost 33000 -ResidualValue 22500 -MoneyFactor 0.0018 -Term 36 -TaxRatePercent 5.9).MonthlyPayment.ToString('C')
    Assert-Check "2: result uses residual `$22,500.00" ($r -match 'Residual Value:\s+\$22,500\.00')
    Assert-Check "2: monthly payment matches the exact math" ($r -match ('with tax\):\s+' + [regex]::Escape($expected))) $expected

    # --- 3. Changing MSRP keeps the field you typed and updates its partner ---
    Set-Field $w MSRP '40000'
    Move-FieldFocus $w CapCost
    Assert-Check "3: typed residual `$ is kept" ((Get-Field $w ResidualValue) -eq '22500') (Get-Field $w ResidualValue)
    Assert-Check "3: Residual % updated to 56.25" ((Get-Field $w ResidualPercent) -eq '56.25') (Get-Field $w ResidualPercent)
    Set-Field $w ResidualPercent '60'
    Set-Field $w MSRP '35000'
    Move-FieldFocus $w CapCost
    Assert-Check "3: typed % is kept" ((Get-Field $w ResidualPercent) -eq '60') (Get-Field $w ResidualPercent)
    Assert-Check "3: Residual `$ updated to 21000.00" ((Get-Field $w ResidualValue) -eq '21000.00') (Get-Field $w ResidualValue)

    # --- 4. Negative money factor is blocked (the old version quietly used 0%) ---
    Set-BaseDeal
    Set-Field $w ResidualPercent '65'
    Set-Field $w MoneyFactor '-0.002'
    Move-FieldFocus $w
    Assert-Check "4: APR mirrors it as -4.80" ((Get-Field $w APR) -eq '-4.80') (Get-Field $w APR)
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "4: Calculate is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"
    Assert-Check "4: Money Factor is red" (Test-FieldRed $w MoneyFactor)
    Assert-Check "4: no result shown" ((Get-ResultText $w) -eq 'Results will appear here')

    # --- 5. Impossible residuals are blocked ---
    Set-BaseDeal
    Set-Field $w ResidualPercent '150'
    Set-Field $w APR '4.32'
    Move-FieldFocus $w
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "5: residual 150% is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"
    Assert-Check "5: Residual % is red" (Test-FieldRed $w ResidualPercent)
    Set-Field $w ResidualValue '40000'
    Move-FieldFocus $w
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "5: residual `$ above MSRP is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"

    # --- 6. Net cap cost below the residual gets a plain-English warning ---
    Set-BaseDeal
    Set-Field $w DownPayment '12000'
    Set-Field $w ResidualPercent '65'
    Set-Field $w APR '4.32'
    Move-FieldFocus $w
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "6: 'Check Your Numbers' warning shown" ($box.Title -eq 'Check Your Numbers' -and $box.Text -match 'negative depreciation') "$($box.Title)"

    # --- 7. Lease term must be whole months ---
    Set-BaseDeal
    Set-Field $w Term '36.5'
    Set-Field $w ResidualPercent '65'
    Set-Field $w APR '4.32'
    Move-FieldFocus $w
    Assert-Check "7: term 36.5 turns red on leaving the field" (Test-FieldRed $w Term)
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "7: term 36.5 is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"

    # --- 8. A typo in an optional field is caught, not counted as 0 ---
    Set-BaseDeal
    Set-Field $w Fees '1,5OO'
    Set-Field $w ResidualPercent '65'
    Set-Field $w APR '4.32'
    Move-FieldFocus $w
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "8: fees typo is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"
    Assert-Check "8: Fees is red" (Test-FieldRed $w Fees)

    # --- 9. APR 5 uses the exact money factor, not the rounded 0.00208 shown ---
    Set-BaseDeal
    Set-Field $w ResidualPercent '65'
    Set-Field $w APR '5'
    Move-FieldFocus $w
    Invoke-Button $w 'Calculate Lease'
    [void](Close-MessageBox $app.Proc)
    $exact = (Get-LeasePayment -CapCost 33000 -Fees 895 -CapReduction 2000 -DownPayment 1500 -ResidualValue 22750 -MoneyFactor (5 / 2400) -Term 36 -TaxRatePercent 5.9).FinanceCharge.ToString('C')
    Assert-Check "9: finance charge uses the exact APR" ((Get-ResultText $w) -match [regex]::Escape("$exact / mo")) $exact

    # --- 10. Clearing the field you typed clears its partner ---
    Set-Field $w APR ''
    Move-FieldFocus $w
    Assert-Check "10: clearing APR clears Money Factor" ((Get-Field $w MoneyFactor) -eq 'e.g. 0.00180') (Get-Field $w MoneyFactor)

    # --- 11. Tabbing through an empty partner doesn't wipe what you typed ---
    Invoke-Button $w 'Reset All'
    Set-Field $w ResidualValue '22750'
    Move-FieldFocus $w ResidualPercent   # MSRP is blank, so % still shows its placeholder
    Move-FieldFocus $w Term
    Assert-Check "11: residual `$ survives tabbing through %" ((Get-Field $w ResidualValue) -eq '22750') (Get-Field $w ResidualValue)

    # --- 12. Calculate on an empty form: every required field and both pairs go red ---
    Invoke-Button $w 'Reset All'
    Invoke-Button $w 'Calculate Lease'
    $box = Close-MessageBox $app.Proc
    Assert-Check "12: empty form is blocked" ($box.Title -eq 'Validation Error') "$($box.Title)"
    $notRed = @('MSRP', 'CapCost', 'ResidualValue', 'ResidualPercent', 'MoneyFactor', 'APR', 'Term', 'Tax') | Where-Object { -not (Test-FieldRed $w $_) }
    Assert-Check "12: required fields and both pairs are red" ($notRed.Count -eq 0) $(if ($notRed) { "not red: " + ($notRed -join ', ') })
    Assert-Check "12: optional fields are not red" (-not (Test-FieldRed $w Fees) -and -not (Test-FieldRed $w DownPayment))
    Save-Screenshot $w 'all-red.png'

    # --- 13. Reset clears everything ---
    Invoke-Button $w 'Reset All'
    Assert-Check "13: Reset clears the red" (-not (Test-FieldRed $w MSRP))
    Assert-Check "13: Reset clears the results" ((Get-ResultText $w) -eq 'Results will appear here')
}
catch {
    Assert-Check "Test run finished without crashing" $false $_.Exception.Message
}
finally {
    Stop-Process -Id $app.Proc.Id -ErrorAction SilentlyContinue
}

$failed = @($script:results | Where-Object { -not $_.Ok }).Count
Write-Host ""
Write-Host "$(@($script:results).Count - $failed) passed, $failed failed"
if ($failed -gt 0) { exit 1 }
