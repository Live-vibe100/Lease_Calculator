<#
.SYNOPSIS
    Lease Calculator - a small Windows Forms app for checking car lease deals.
.DESCRIPTION
    Plug in the numbers from a dealer worksheet and see the monthly payment breakdown.
    The math lives in LeaseMath.ps1 (same folder) so it can be tested on its own.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================
# STARTUP
# =============================

# The launcher hides the console, so a startup problem would otherwise just
# look like "nothing happened". Show it in a message box instead.
try {
    $mathFile = Join-Path $PSScriptRoot 'LeaseMath.ps1'
    if (-not (Test-Path -LiteralPath $mathFile)) {
        throw "LeaseMath.ps1 is missing. Keep it in the same folder as LeaseCalculator.ps1."
    }
    . $mathFile
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show("Lease Calculator couldn't start:`n`n$($_.Exception.Message)", "Lease Calculator", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

# Tell Windows we handle display scaling (125%, 150%...) ourselves so text stays
# sharp. Must happen before the window exists. If it fails, Windows stretches
# the window instead - blurrier, but everything still works.
try {
    Add-Type -Namespace LeaseCalculator -Name NativeMethods -ErrorAction Stop -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][LeaseCalculator.NativeMethods]::SetProcessDPIAware()
}
catch {
    Write-Warning "Display scaling support unavailable, window may look blurry: $($_.Exception.Message)"
}

# =============================
# FORM SETUP
# =============================

$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
# Layout below is in pixels at 100% scaling; WinForms scales it up for other settings
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Text = "Lease Calculator"
$form.ClientSize = New-Object System.Drawing.Size(1130, 610)
$form.StartPosition = "Manual"    # centered on Load, after sizing to fit the screen
$form.FormBorderStyle = 'FixedDialog'
$form.AutoScroll = $true
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

# =============================
# COLORS
# =============================

$colorValid = [System.Drawing.Color]::White
$colorInvalid = [System.Drawing.Color]::FromArgb(255, 230, 230)

# =============================
# TRACKING
# =============================

$script:allTextBoxes = @()
# True while the app itself is changing a field's text, so the sync handlers
# don't mistake it for the user typing
$script:syncing = $false
# Which field of each pair the user last edited. That one is used for the math;
# the other is just filled in to match. $null = nothing entered yet.
$script:residualSource = $null   # 'ResidualValue' or 'ResidualPercent'
$script:rateSource = $null       # 'MoneyFactor' or 'APR'
$resultsPlaceholder = "Results will appear here"

# =============================
# HELPER FUNCTIONS
# =============================

function Add-LabeledField {
    <#
    .SYNOPSIS
        Adds a label, text box (with gray placeholder text), and description to the form.
    .OUTPUTS
        The TextBox. Its Name is used to look up its validation rule.
    #>
    param(
        [string]$Name,
        [string]$Label,
        [string]$Description,
        [string]$Placeholder,
        [int]$X,
        [int]$Y
    )

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size(225, 20)
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Name = $Name
    $txt.Location = New-Object System.Drawing.Point(($X + 230), ($Y - 2))
    $txt.Size = New-Object System.Drawing.Size(140, 22)
    $txt.Tag = $Placeholder
    $txt.Text = $Placeholder
    $txt.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($txt)

    # Placeholder behavior - focus (not the user typing, so flagged as syncing)
    $txt.Add_GotFocus({
        if ($this.Text -eq $this.Tag) {
            $script:syncing = $true
            $this.Text = ""
            $this.ForeColor = [System.Drawing.Color]::Black
            $script:syncing = $false
        }
    })

    # Placeholder behavior - leave, then check the field
    $txt.Add_LostFocus({
        if ($this.Text.Trim() -eq "") {
            $script:syncing = $true
            $this.Text = $this.Tag
            $this.ForeColor = [System.Drawing.Color]::Gray
            $script:syncing = $false
        }
        Test-Field -Field $this | Out-Null
    })

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $Description
    $desc.Location = New-Object System.Drawing.Point($X, ($Y + 24))
    $desc.MaximumSize = New-Object System.Drawing.Size(370, 0)
    $desc.AutoSize = $true
    $desc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $desc.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $form.Controls.Add($desc)

    $script:allTextBoxes += $txt
    return $txt
}

function Test-FieldBlank {
    <# .SYNOPSIS True if the field is empty or still showing its placeholder. #>
    param([System.Windows.Forms.TextBox]$Field)
    $raw = $Field.Text.Trim()
    return ($raw -eq "" -or $raw -eq $Field.Tag)
}

function Get-FieldValue {
    <# .SYNOPSIS The field's number, or $null if it's blank or not a number. #>
    param([System.Windows.Forms.TextBox]$Field)
    if (Test-FieldBlank $Field) { return $null }
    return ConvertTo-LeaseNumber $Field.Text
}

function Set-FieldText {
    <#
    .SYNOPSIS
        Fills in a field from code rather than the user. Blank text puts the placeholder back.
    #>
    param([System.Windows.Forms.TextBox]$Field, [string]$Text)
    $script:syncing = $true
    try {
        if ([string]::IsNullOrEmpty($Text)) {
            $Field.Text = $Field.Tag
            $Field.ForeColor = [System.Drawing.Color]::Gray
        }
        else {
            $Field.Text = $Text
            $Field.ForeColor = [System.Drawing.Color]::Black
        }
        $Field.BackColor = $colorValid
    }
    finally {
        $script:syncing = $false
    }
}

function Test-Range {
    <#
    .SYNOPSIS
        Checks a field holds a number in range and colors it red if not.
        Text that isn't a number is always invalid, even in an optional field.
    #>
    param(
        [System.Windows.Forms.TextBox]$Field,
        [double]$Min = 0,
        [double]$Max = [double]::MaxValue,
        [bool]$Required = $true,
        [switch]$WholeNumber
    )
    if (Test-FieldBlank $Field) {
        $ok = -not $Required
    }
    else {
        $ok = Test-LeaseValue -Value (Get-FieldValue $Field) -Min $Min -Max $Max -WholeNumber:$WholeNumber
    }
    $Field.BackColor = if ($ok) { $colorValid } else { $colorInvalid }
    return $ok
}

# Rules for the stand-alone fields. Residual and rate pairs are handled separately below.
$fieldRules = @{
    MSRP         = @{ Min = 0.01; Max = [double]::MaxValue; Required = $true }
    CapCost      = @{ Min = 0.01; Max = [double]::MaxValue; Required = $true }
    Fees         = @{ Min = 0; Max = [double]::MaxValue; Required = $false }
    CapReduction = @{ Min = 0; Max = [double]::MaxValue; Required = $false }
    DownPayment  = @{ Min = 0; Max = [double]::MaxValue; Required = $false }
    Term         = @{ Min = $LeaseLimits.TermMin; Max = $LeaseLimits.TermMax; Required = $true; WholeNumber = $true }
    Tax          = @{ Min = 0; Max = $LeaseLimits.TaxMax; Required = $true }
}

function Test-PairFields {
    <#
    .SYNOPSIS
        Checks a two-way pair (Residual $/% or Money Factor/APR). Only the field the user
        edited is checked; the filled-in partner is cleared of any red.
    .PARAMETER Required
        When true (pressing Calculate), having neither field filled in is an error.
    #>
    param(
        [string]$Source,
        [System.Windows.Forms.TextBox]$First,
        [System.Windows.Forms.TextBox]$Second,
        [hashtable]$Limits,
        [bool]$Required
    )
    # [string] turns $null into "", so check for both
    if ([string]::IsNullOrEmpty($Source)) {
        $First.BackColor = if ($Required) { $colorInvalid } else { $colorValid }
        $Second.BackColor = $First.BackColor
        return (-not $Required)
    }
    $sourceField = if ($First.Name -eq $Source) { $First } else { $Second }
    $partner = if ($sourceField -eq $First) { $Second } else { $First }
    $partner.BackColor = $colorValid
    $limit = $Limits[$Source]
    return Test-Range -Field $sourceField -Min $limit.Min -Max $limit.Max -Required $Required
}

function Test-Field {
    <#
    .SYNOPSIS
        Checks one field against its rule and colors it.
    .PARAMETER Calculating
        True when Calculate was pressed - an empty pair then counts as an error.
    #>
    param([System.Windows.Forms.TextBox]$Field, [bool]$Calculating = $false)

    if ($Field.Name -in 'ResidualValue', 'ResidualPercent') {
        # A residual can't be worth more than the car's sticker price
        $msrp = Get-FieldValue $txtMSRP
        $maxValue = if ($null -ne $msrp -and $msrp -gt 0) { $msrp } else { [double]::MaxValue }
        $limits = @{
            ResidualValue   = @{ Min = 0; Max = $maxValue }
            ResidualPercent = @{ Min = 0; Max = $LeaseLimits.ResidualPctMax }
        }
        return Test-PairFields -Source $script:residualSource -First $txtResidualValue -Second $txtResidualPercent -Limits $limits -Required $Calculating
    }
    if ($Field.Name -in 'MoneyFactor', 'APR') {
        $limits = @{
            MoneyFactor = @{ Min = 0; Max = $LeaseLimits.MoneyFactorMax }
            APR         = @{ Min = 0; Max = $LeaseLimits.AprMax }
        }
        return Test-PairFields -Source $script:rateSource -First $txtMoneyFactor -Second $txtAPR -Limits $limits -Required $Calculating
    }
    $rule = $fieldRules[$Field.Name]
    return Test-Range -Field $Field -Min $rule.Min -Max $rule.Max -Required $rule.Required -WholeNumber:([bool]$rule.WholeNumber)
}

# =============================
# INPUT FIELDS
# =============================

# Left column - the price of the car and what's knocked off it
$colA = 20
$colB = 410

$txtMSRP = Add-LabeledField -Name "MSRP" -X $colA -Y 20 `
    -Label "MSRP" `
    -Description "Manufacturer's Suggested Retail Price. The original sticker price of the vehicle before discounts or incentives." `
    -Placeholder "e.g. 35000.00"

$txtCapCost = Add-LabeledField -Name "CapCost" -X $colA -Y 98 `
    -Label "Capitalized Cost" `
    -Description "The agreed-upon selling price of the vehicle before rebates or down payment reductions." `
    -Placeholder "e.g. 33000.00"

$txtFees = Add-LabeledField -Name "Fees" -X $colA -Y 176 `
    -Label "Fees" `
    -Description "Combined lease fees such as acquisition fee, documentation fee, etc." `
    -Placeholder "e.g. 895.00"

$txtCapReduction = Add-LabeledField -Name "CapReduction" -X $colA -Y 254 `
    -Label "Capitalized Cost Reduction" `
    -Description "Rebates, incentives, trade equity, manufacturer incentives, or cash used to reduce the lease amount financed." `
    -Placeholder "e.g. 2000.00"

$txtDownPayment = Add-LabeledField -Name "DownPayment" -X $colA -Y 332 `
    -Label "Down Payment" `
    -Description "Cash paid upfront toward the lease. This lowers the monthly payment but increases upfront cost." `
    -Placeholder "e.g. 1500.00"

# Right column - residual, rate, term, and tax
$txtResidualValue = Add-LabeledField -Name "ResidualValue" -X $colB -Y 20 `
    -Label "Residual Value ($)" `
    -Description "Estimated vehicle value at the end of the lease term. Enter this OR Residual Percent - the other fills in." `
    -Placeholder "e.g. 22750.00"

$txtResidualPercent = Add-LabeledField -Name "ResidualPercent" -X $colB -Y 98 `
    -Label "Residual Percent" `
    -Description "Residual as a percentage of MSRP. Example: 65 for 65%. Enter this OR Residual Value - the other fills in." `
    -Placeholder "e.g. 65"

$txtMoneyFactor = Add-LabeledField -Name "MoneyFactor" -X $colB -Y 176 `
    -Label "Money Factor" `
    -Description "Lease interest factor used to calculate finance charges. Example: 0.00180. Enter this OR APR." `
    -Placeholder "e.g. 0.00180"

$txtAPR = Add-LabeledField -Name "APR" -X $colB -Y 254 `
    -Label "APR" `
    -Description "Annual percentage rate. Example: 4.32. Enter this OR Money Factor - the other fills in." `
    -Placeholder "e.g. 4.32"

$txtTerm = Add-LabeledField -Name "Term" -X $colB -Y 332 `
    -Label "Lease Term (Months)" `
    -Description "Length of the lease in whole months. Typical terms are 24, 36, or 48 months." `
    -Placeholder "e.g. 36"

$txtTax = Add-LabeledField -Name "Tax" -X $colB -Y 410 `
    -Label "Sales Tax Rate" `
    -Description "Local sales tax rate applied to lease payments. Example: 5.9 for 5.9%." `
    -Placeholder "e.g. 5.9"

# =============================
# AUTO-SYNC: RESIDUAL $ <-> RESIDUAL %
# =============================
# Whichever field you edit last is the one the math uses. The other is filled
# in to match, and cleared if the one you edited is cleared.

function Sync-ResidualFields {
    <# .SYNOPSIS Fills in the residual field the user didn't edit, from the one they did. #>
    if ($null -eq $script:residualSource) { return }
    $msrp = Get-FieldValue $txtMSRP
    $haveMsrp = ($null -ne $msrp -and $msrp -gt 0)

    if ($script:residualSource -eq 'ResidualValue') {
        $rv = Get-FieldValue $txtResidualValue
        $text = $null
        if ($haveMsrp -and $null -ne $rv) { $text = (Get-ResidualPercent -Msrp $msrp -ResidualValue $rv).ToString("F2") }
        Set-FieldText $txtResidualPercent $text
    }
    else {
        $pct = Get-FieldValue $txtResidualPercent
        $text = $null
        if ($haveMsrp -and $null -ne $pct) { $text = (Get-ResidualValue -Msrp $msrp -Percent $pct).ToString("F2") }
        Set-FieldText $txtResidualValue $text
    }
}

$txtResidualValue.Add_TextChanged({
    if ($script:syncing) { return }
    $script:residualSource = 'ResidualValue'
    Sync-ResidualFields
})

$txtResidualPercent.Add_TextChanged({
    if ($script:syncing) { return }
    $script:residualSource = 'ResidualPercent'
    Sync-ResidualFields
})

# MSRP changes update whichever residual field you DIDN'T type
$txtMSRP.Add_TextChanged({
    if ($script:syncing) { return }
    Sync-ResidualFields
})

# =============================
# AUTO-SYNC: MONEY FACTOR <-> APR
# =============================

function Sync-RateFields {
    <# .SYNOPSIS Fills in the rate field the user didn't edit, from the one they did. #>
    if ($null -eq $script:rateSource) { return }

    if ($script:rateSource -eq 'APR') {
        $apr = Get-FieldValue $txtAPR
        $text = $null
        if ($null -ne $apr) { $text = (ConvertTo-MoneyFactor -Apr $apr).ToString("F5") }
        Set-FieldText $txtMoneyFactor $text
    }
    else {
        $mf = Get-FieldValue $txtMoneyFactor
        $text = $null
        if ($null -ne $mf) { $text = (ConvertTo-Apr -MoneyFactor $mf).ToString("F2") }
        Set-FieldText $txtAPR $text
    }
}

$txtMoneyFactor.Add_TextChanged({
    if ($script:syncing) { return }
    $script:rateSource = 'MoneyFactor'
    Sync-RateFields
})

$txtAPR.Add_TextChanged({
    if ($script:syncing) { return }
    $script:rateSource = 'APR'
    Sync-RateFields
})

# =============================
# OUTPUT LABEL
# =============================

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Location = New-Object System.Drawing.Point(810, 20)
$resultLabel.Size = New-Object System.Drawing.Size(300, 470)
$resultLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$resultLabel.Text = $resultsPlaceholder
$form.Controls.Add($resultLabel)

# =============================
# CALCULATE BUTTON
# =============================

$btnCalc = New-Object System.Windows.Forms.Button
$btnCalc.Text = "Calculate Lease"
$btnCalc.Location = New-Object System.Drawing.Point(810, 500)
$btnCalc.Size = New-Object System.Drawing.Size(220, 45)
$btnCalc.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnCalc.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCalc.ForeColor = [System.Drawing.Color]::White
$btnCalc.FlatStyle = 'Flat'
$btnCalc.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnCalc)

# =============================
# RESET BUTTON
# =============================

$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = "Reset All"
$btnReset.Location = New-Object System.Drawing.Point(810, 555)
$btnReset.Size = New-Object System.Drawing.Size(105, 35)
$btnReset.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnReset.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnReset.FlatStyle = 'Flat'
$btnReset.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnReset)

$btnReset.Add_Click({
    foreach ($tb in $script:allTextBoxes) {
        Set-FieldText $tb $null
    }
    $script:residualSource = $null
    $script:rateSource = $null
    $resultLabel.Text = $resultsPlaceholder
})

# =============================
# COPY RESULTS BUTTON
# =============================

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copy Results"
$btnCopy.Location = New-Object System.Drawing.Point(925, 555)
$btnCopy.Size = New-Object System.Drawing.Size(105, 35)
$btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnCopy.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnCopy.FlatStyle = 'Flat'
$btnCopy.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnCopy)

$btnCopy.Add_Click({
    if ($resultLabel.Text -ne $resultsPlaceholder) {
        [System.Windows.Forms.Clipboard]::SetText($resultLabel.Text)
        [System.Windows.Forms.MessageBox]::Show("Results copied to clipboard.", "Copied", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# =============================
# CALCULATION LOGIC
# =============================

$btnCalc.Add_Click({

    # Check every field - any red field blocks the calculation
    $valid = $true
    foreach ($tb in $script:allTextBoxes) {
        if (-not (Test-Field -Field $tb -Calculating $true)) { $valid = $false }
    }

    if (-not $valid) {
        [System.Windows.Forms.MessageBox]::Show("Please fix highlighted fields before calculating.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {

        $msrp = Get-FieldValue $txtMSRP
        $fees = Get-FieldValue $txtFees; if ($null -eq $fees) { $fees = 0 }
        $capReduction = Get-FieldValue $txtCapReduction; if ($null -eq $capReduction) { $capReduction = 0 }
        $downPayment = Get-FieldValue $txtDownPayment; if ($null -eq $downPayment) { $downPayment = 0 }

        # Use exactly what the user typed, not the rounded number filled in beside it
        if ($script:residualSource -eq 'ResidualPercent') {
            $residualValue = Get-ResidualValue -Msrp $msrp -Percent (Get-FieldValue $txtResidualPercent)
        }
        else {
            $residualValue = Get-FieldValue $txtResidualValue
        }

        if ($script:rateSource -eq 'APR') {
            $moneyFactor = ConvertTo-MoneyFactor -Apr (Get-FieldValue $txtAPR)
        }
        else {
            $moneyFactor = Get-FieldValue $txtMoneyFactor
        }

        $lease = Get-LeasePayment `
            -CapCost (Get-FieldValue $txtCapCost) `
            -Fees $fees `
            -CapReduction $capReduction `
            -DownPayment $downPayment `
            -ResidualValue $residualValue `
            -MoneyFactor $moneyFactor `
            -Term (Get-FieldValue $txtTerm) `
            -TaxRatePercent (Get-FieldValue $txtTax)

        # =============================
        # DISPLAY RESULTS
        # =============================

        $resultLabel.Text = @"
Net Capitalized Cost:
$($lease.NetCapCost.ToString('C'))

Residual Value:
$($lease.ResidualValue.ToString('C'))

Money Factor:
$([math]::Round($lease.MoneyFactor, 5).ToString("F5"))

Depreciation:
$($lease.Depreciation.ToString('C')) / mo

Finance Charge:
$($lease.FinanceCharge.ToString('C')) / mo

Monthly Payment (before tax):
$($lease.BasePayment.ToString('C'))

Sales Tax / mo:
$($lease.MonthlyTax.ToString('C'))

Monthly Payment (with tax):
$($lease.MonthlyPayment.ToString('C'))

Total Lease Cost:
$($lease.TotalLeaseCost.ToString('C'))
"@

    }
    catch [System.ArgumentException] {
        # The numbers are valid on their own but don't add up to a real lease
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Check Your Numbers", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Something went wrong calculating the lease:`n`n$($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# =============================
# RUN FORM
# =============================

# Never open bigger than the screen; scrollbars cover anything that doesn't fit.
# Done on Load because that's after the window has been scaled for the display.
$form.Add_Load({
    $workArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $width = [math]::Min($this.Width, $workArea.Width)
    $height = [math]::Min($this.Height, $workArea.Height)
    $this.Size = New-Object System.Drawing.Size($width, $height)
    $this.Location = New-Object System.Drawing.Point(
        ($workArea.X + [int](($workArea.Width - $width) / 2)),
        ($workArea.Y + [int](($workArea.Height - $height) / 2)))
})

$form.ResumeLayout($false)
$form.PerformLayout()

[void]$form.ShowDialog()
